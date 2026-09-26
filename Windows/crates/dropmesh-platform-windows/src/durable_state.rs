//! DPAPI-backed durable small-state storage.

#![allow(unsafe_code)]

use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest, Sha256};
use thiserror::Error;
use windows::Win32::Storage::FileSystem::{
    FILE_FLAG_BACKUP_SEMANTICS, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
};
use windows::core::HSTRING;
use zeroize::Zeroizing;

use crate::dpapi::{
    DpapiError, MAX_DPAPI_STATE_BYTES, protect_current_user, unprotect_current_user,
};
use crate::durable_state_format::{
    self, FormatError, InitialRecoveryAction, RecoveryAction, classify_initial_recovery,
    classify_recovery, decode_anchor, decode_state, encode_anchor, encode_state, next_generation,
    validate_pair,
};

/// Maximum plaintext payload accepted by [`DpapiDurableStateStore`].
pub const MAX_DURABLE_PAYLOAD_BYTES: usize = durable_state_format::MAX_DURABLE_PAYLOAD_BYTES;

const MAX_STORED_BLOB_BYTES: u64 = 128 * 1024;
const MAX_ENTROPY_BYTES: usize = 1_024;
const STATE_ENTROPY_LABEL: &[u8] = b"\0DropMesh.DurableState.State.v1";
const ANCHOR_ENTROPY_LABEL: &[u8] = b"\0DropMesh.DurableState.Anchor.v1";
const NEXT_ENTROPY_LABEL: &[u8] = b"\0DropMesh.DurableState.AnchorNext.v1";

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// An authenticated durable-state generation and its zeroizing plaintext.
pub struct DurableStateSnapshot {
    generation: u64,
    payload: Zeroizing<Vec<u8>>,
}

impl DurableStateSnapshot {
    /// Returns the monotonic stored generation.
    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    /// Borrows the plaintext payload. Its owned allocation is zeroized on drop.
    #[must_use]
    pub fn payload(&self) -> &[u8] {
        &self.payload
    }
}

/// Atomic current-user DPAPI storage for small security-sensitive state.
///
/// Each state file is atomically replaced with write-through semantics. A
/// separately protected anchor records the high-water generation and SHA-256 of
/// the exact protected state blob. Updates first persist a protected
/// `anchor.next` marker, then replace state and the formal anchor, and finally
/// durably remove the marker. Recovery aborts a prepared-only marker, rolls
/// forward an exact one-generation state lead, or cleans an already committed
/// marker. Any other combination fails closed. A held lock file prevents
/// cooperative concurrent writers.
///
/// # Threat boundary
///
/// DPAPI protects against other users and offline disclosure, not a process
/// already running as the same Windows user. An attacker with that authority can
/// call DPAPI and can roll back both the state file and its anchor as a matched
/// pair; purely local user-scoped storage cannot distinguish that paired rollback.
/// Detecting it requires an external monotonic authority such as a trusted server
/// or hardware-backed counter. This store does detect a separately rolled-back
/// blob or anchor and rejects stale cooperative writers.
pub struct DpapiDurableStateStore {
    state_path: PathBuf,
    anchor_path: PathBuf,
    next_anchor_path: PathBuf,
    entropy: Zeroizing<Vec<u8>>,
    gate: Mutex<()>,
    _exclusive_lock: File,
}

impl DpapiDurableStateStore {
    /// Opens a named store and acquires its exclusive cooperative writer lock.
    ///
    /// The directory is created if absent. `name` is restricted to ASCII
    /// letters, digits, dot, dash, and underscore so it cannot escape the
    /// directory. Caller entropy is copied into zeroizing memory and domain
    /// separated for the state and anchor DPAPI operations.
    ///
    /// # Errors
    ///
    /// Returns an error for an invalid name/entropy, directory or lock failure,
    /// or a concurrent open of the same store.
    pub fn open(
        directory: &Path,
        name: &str,
        optional_entropy: &[u8],
    ) -> Result<Self, DurableStateError> {
        validate_name(name)?;
        if optional_entropy.len() > MAX_ENTROPY_BYTES
            || optional_entropy.len() + STATE_ENTROPY_LABEL.len() > MAX_DPAPI_STATE_BYTES
            || optional_entropy.len() + ANCHOR_ENTROPY_LABEL.len() > MAX_DPAPI_STATE_BYTES
            || optional_entropy.len() + NEXT_ENTROPY_LABEL.len() > MAX_DPAPI_STATE_BYTES
        {
            return Err(DurableStateError::InvalidEntropy);
        }
        fs::create_dir_all(directory)
            .map_err(|error| io_error("create store directory", &error))?;

        let lock_path = directory.join(format!("{name}.lock"));
        let exclusive_lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .share_mode(0)
            .open(&lock_path)
            .map_err(|error| io_error("acquire store lock", &error))?;

        Ok(Self {
            state_path: directory.join(format!("{name}.state.dpapi")),
            anchor_path: directory.join(format!("{name}.anchor.dpapi")),
            next_anchor_path: directory.join(format!("{name}.anchor.next.dpapi")),
            entropy: Zeroizing::new(optional_entropy.to_vec()),
            gate: Mutex::new(()),
            _exclusive_lock: exclusive_lock,
        })
    }

    /// Loads and authenticates the current generation, if no state exists yet.
    ///
    /// # Errors
    ///
    /// Fails closed on a missing half, malformed or unprotectable bytes,
    /// generation rollback, anchor rollback, or protected-blob hash mismatch.
    pub fn load(&self) -> Result<Option<DurableStateSnapshot>, DurableStateError> {
        let _guard = self
            .gate
            .lock()
            .map_err(|_| DurableStateError::LockUnavailable)?;
        self.load_unlocked()
    }

    /// Atomically writes the next monotonic generation using a protected
    /// `anchor.next` write-ahead marker.
    ///
    /// `expected_generation` must equal the currently authenticated generation,
    /// or zero for a new store. The marker is written first, followed by state
    /// and the formal anchor. The marker is then deleted and its directory
    /// synced. A crash after state replacement can therefore roll forward the
    /// exact prepared anchor rather than permanently locking the store.
    ///
    /// # Errors
    ///
    /// Returns an error for oversized payloads, stale writers, overflow,
    /// existing rollback/corruption, DPAPI failure, or durable write failure.
    pub fn save_next(
        &self,
        expected_generation: u64,
        payload: &[u8],
    ) -> Result<u64, DurableStateError> {
        if payload.len() > MAX_DURABLE_PAYLOAD_BYTES {
            return Err(DurableStateError::PayloadTooLarge);
        }
        let _guard = self
            .gate
            .lock()
            .map_err(|_| DurableStateError::LockUnavailable)?;
        let current = self.load_unlocked()?;
        let current_generation = current.as_ref().map_or(0, DurableStateSnapshot::generation);
        let generation = next_generation(expected_generation, current_generation)?;

        let prepared = self.prepare_transaction(generation, payload)?;
        atomic_write(&self.next_anchor_path, &prepared.next_marker)?;
        if let Err(error) = atomic_write(&self.state_path, &prepared.state_blob) {
            let _ = self.remove_next_and_sync();
            return Err(error);
        }
        atomic_write(&self.anchor_path, &prepared.anchor_blob)?;
        self.remove_next_and_sync()?;
        Ok(generation)
    }

    fn load_unlocked(&self) -> Result<Option<DurableStateSnapshot>, DurableStateError> {
        let state_exists = path_exists(&self.state_path)?;
        let anchor_exists = path_exists(&self.anchor_path)?;
        let next_exists = path_exists(&self.next_anchor_path)?;
        if !anchor_exists {
            if !next_exists {
                return if state_exists {
                    Err(DurableStateError::IncompleteState)
                } else {
                    Ok(None)
                };
            }
            return self.recover_initial_transaction(state_exists);
        }
        if !state_exists {
            return Err(DurableStateError::IncompleteState);
        }

        let protected_state = read_bounded(&self.state_path)?;
        let protected_anchor = read_bounded(&self.anchor_path)?;
        let state_entropy = self.domain_entropy(STATE_ENTROPY_LABEL);
        let anchor_entropy = self.domain_entropy(ANCHOR_ENTROPY_LABEL);
        let clear_state = unprotect_current_user(&protected_state, Some(&state_entropy))?;
        let clear_anchor = unprotect_current_user(&protected_anchor, Some(&anchor_entropy))?;
        let state = decode_state(&clear_state)?;
        let anchor = decode_anchor(&clear_anchor)?;

        if next_exists {
            let protected_next = read_bounded(&self.next_anchor_path)?;
            let next_entropy = self.domain_entropy(NEXT_ENTROPY_LABEL);
            let clear_next = unprotect_current_user(&protected_next, Some(&next_entropy))?;
            let next = decode_anchor(&clear_next)?;
            match classify_recovery(&state, &anchor, &next, &protected_state)? {
                RecoveryAction::AbortPrepared | RecoveryAction::CleanupCommitted => {
                    self.remove_next_and_sync()?;
                }
                RecoveryAction::RollForward => {
                    let clear_recovered_anchor = Zeroizing::new(
                        encode_anchor(next.generation, next.protected_blob_hash).to_vec(),
                    );
                    let recovered_anchor =
                        protect_current_user(&clear_recovered_anchor, Some(&anchor_entropy))?;
                    atomic_write(&self.anchor_path, &recovered_anchor)?;
                    self.remove_next_and_sync()?;
                }
            }
        } else {
            validate_pair(&state, &anchor, &protected_state)?;
        }

        Ok(Some(DurableStateSnapshot {
            generation: state.generation,
            payload: Zeroizing::new(state.payload.to_vec()),
        }))
    }

    fn recover_initial_transaction(
        &self,
        state_exists: bool,
    ) -> Result<Option<DurableStateSnapshot>, DurableStateError> {
        let protected_next = read_bounded(&self.next_anchor_path)?;
        let next_entropy = self.domain_entropy(NEXT_ENTROPY_LABEL);
        let clear_next = unprotect_current_user(&protected_next, Some(&next_entropy))?;
        let next = decode_anchor(&clear_next)?;

        if !state_exists {
            match classify_initial_recovery(None, &next)? {
                InitialRecoveryAction::AbortPrepared => {
                    self.remove_next_and_sync()?;
                    return Ok(None);
                }
                InitialRecoveryAction::RollForward => unreachable!("initial state is absent"),
            }
        }

        let protected_state = read_bounded(&self.state_path)?;
        let state_entropy = self.domain_entropy(STATE_ENTROPY_LABEL);
        let clear_state = unprotect_current_user(&protected_state, Some(&state_entropy))?;
        let state = decode_state(&clear_state)?;
        match classify_initial_recovery(Some((&state, &protected_state)), &next)? {
            InitialRecoveryAction::AbortPrepared => unreachable!("initial state is present"),
            InitialRecoveryAction::RollForward => {
                let clear_recovered_anchor = Zeroizing::new(
                    encode_anchor(next.generation, next.protected_blob_hash).to_vec(),
                );
                let anchor_entropy = self.domain_entropy(ANCHOR_ENTROPY_LABEL);
                let recovered_anchor =
                    protect_current_user(&clear_recovered_anchor, Some(&anchor_entropy))?;
                atomic_write(&self.anchor_path, &recovered_anchor)?;
                self.remove_next_and_sync()?;
            }
        }

        Ok(Some(DurableStateSnapshot {
            generation: state.generation,
            payload: Zeroizing::new(state.payload.to_vec()),
        }))
    }

    fn domain_entropy(&self, label: &[u8]) -> Zeroizing<Vec<u8>> {
        let mut entropy = Zeroizing::new(Vec::with_capacity(self.entropy.len() + label.len()));
        entropy.extend_from_slice(&self.entropy);
        entropy.extend_from_slice(label);
        entropy
    }

    fn prepare_transaction(
        &self,
        generation: u64,
        payload: &[u8],
    ) -> Result<PreparedTransaction, DurableStateError> {
        let clear_state = encode_state(generation, payload)?;
        let state_entropy = self.domain_entropy(STATE_ENTROPY_LABEL);
        let protected_state = protect_current_user(&clear_state, Some(&state_entropy))?;
        let state_hash: [u8; 32] = Sha256::digest(&protected_state).into();
        let clear_anchor = Zeroizing::new(encode_anchor(generation, state_hash).to_vec());
        let next_entropy = self.domain_entropy(NEXT_ENTROPY_LABEL);
        let anchor_entropy = self.domain_entropy(ANCHOR_ENTROPY_LABEL);
        let protected_next = protect_current_user(&clear_anchor, Some(&next_entropy))?;
        let protected_anchor = protect_current_user(&clear_anchor, Some(&anchor_entropy))?;
        Ok(PreparedTransaction {
            state_blob: protected_state,
            next_marker: protected_next,
            anchor_blob: protected_anchor,
        })
    }

    fn remove_next_and_sync(&self) -> Result<(), DurableStateError> {
        fs::remove_file(&self.next_anchor_path)
            .map_err(|error| io_error("remove durable state recovery marker", &error))?;
        let directory = self
            .next_anchor_path
            .parent()
            .ok_or(DurableStateError::InvalidName)?;
        sync_directory(directory)
    }
}

struct PreparedTransaction {
    state_blob: Vec<u8>,
    next_marker: Vec<u8>,
    anchor_blob: Vec<u8>,
}

/// Failures from the atomic DPAPI durable-state boundary.
#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum DurableStateError {
    /// The file-safe logical name was invalid.
    #[error("invalid durable state name")]
    InvalidName,
    /// Caller entropy exceeded the bounded limit.
    #[error("durable state entropy exceeds the bounded limit")]
    InvalidEntropy,
    /// The plaintext payload exceeded the bounded limit.
    #[error("durable state payload exceeds the bounded limit")]
    PayloadTooLarge,
    /// Only the state or anchor file existed.
    #[error("durable state and high-water anchor are incomplete")]
    IncompleteState,
    /// State or anchor encoding was malformed.
    #[error("durable state is corrupt")]
    CorruptState,
    /// State/anchor generation or protected bytes moved backwards or diverged.
    #[error("durable state rollback detected")]
    RollbackDetected,
    /// A cooperative writer supplied an out-of-date generation.
    #[error("stale durable state writer")]
    StaleGeneration,
    /// The monotonic generation cannot advance.
    #[error("durable state generation overflow")]
    GenerationOverflow,
    /// The process-local mutex was poisoned.
    #[error("durable state lock is unavailable")]
    LockUnavailable,
    /// A filesystem operation failed without exposing path or state bytes.
    #[error("durable state filesystem operation {operation} failed: {kind:?}")]
    Io {
        /// Bounded operation label.
        operation: &'static str,
        /// Stable I/O error kind.
        kind: io::ErrorKind,
    },
    /// Atomic Windows replacement failed.
    #[error("atomic durable state replacement failed with HRESULT 0x{code:08x}")]
    AtomicReplace {
        /// Windows HRESULT.
        code: u32,
    },
    /// DPAPI protection or unprotection failed.
    #[error(transparent)]
    Dpapi(#[from] DpapiError),
}

impl From<FormatError> for DurableStateError {
    fn from(error: FormatError) -> Self {
        match error {
            FormatError::PayloadTooLarge => Self::PayloadTooLarge,
            FormatError::InvalidEncoding => Self::CorruptState,
            FormatError::GenerationRollback
            | FormatError::AnchorRollback
            | FormatError::ProtectedBlobMismatch
            | FormatError::InvalidRecoveryJournal => Self::RollbackDetected,
            FormatError::StaleGeneration => Self::StaleGeneration,
            FormatError::GenerationOverflow => Self::GenerationOverflow,
        }
    }
}

fn validate_name(name: &str) -> Result<(), DurableStateError> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
    {
        return Err(DurableStateError::InvalidName);
    }
    Ok(())
}

fn path_exists(path: &Path) -> Result<bool, DurableStateError> {
    match fs::metadata(path) {
        Ok(metadata) => {
            if !metadata.is_file() || metadata.len() > MAX_STORED_BLOB_BYTES {
                return Err(DurableStateError::CorruptState);
            }
            Ok(true)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error("inspect durable state", &error)),
    }
}

fn read_bounded(path: &Path) -> Result<Vec<u8>, DurableStateError> {
    let file = File::open(path).map_err(|error| io_error("open durable state", &error))?;
    let metadata = file
        .metadata()
        .map_err(|error| io_error("inspect durable state", &error))?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_STORED_BLOB_BYTES {
        return Err(DurableStateError::CorruptState);
    }
    let mut bytes = Vec::with_capacity(
        usize::try_from(metadata.len()).map_err(|_| DurableStateError::CorruptState)?,
    );
    file.take(MAX_STORED_BLOB_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| io_error("read durable state", &error))?;
    if bytes.is_empty()
        || u64::try_from(bytes.len()).map_err(|_| DurableStateError::CorruptState)?
            > MAX_STORED_BLOB_BYTES
    {
        return Err(DurableStateError::CorruptState);
    }
    Ok(bytes)
}

fn atomic_write(destination: &Path, bytes: &[u8]) -> Result<(), DurableStateError> {
    let parent = destination.parent().ok_or(DurableStateError::InvalidName)?;
    let (temporary, mut file) = create_temporary(parent, destination)?;
    let write_result = file
        .write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|error| io_error("write durable state", &error));
    drop(file);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }

    let source = HSTRING::from(temporary.as_os_str());
    let target = HSTRING::from(destination.as_os_str());
    // SAFETY: both HSTRING paths are live, NUL-safe Windows strings. Source and
    // destination are on the same directory/volume and the source file is closed.
    let replace_result = unsafe {
        MoveFileExW(
            &source,
            &target,
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if let Err(error) = replace_result {
        let _ = fs::remove_file(&temporary);
        return Err(DurableStateError::AtomicReplace {
            code: error.code().0.cast_unsigned(),
        });
    }
    Ok(())
}

fn sync_directory(directory: &Path) -> Result<(), DurableStateError> {
    let handle = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0)
        .open(directory)
        .map_err(|error| io_error("open durable state directory", &error))?;
    handle
        .sync_all()
        .map_err(|error| io_error("sync durable state directory", &error))
}

fn create_temporary(
    parent: &Path,
    destination: &Path,
) -> Result<(PathBuf, File), DurableStateError> {
    let destination_name = destination
        .file_name()
        .ok_or(DurableStateError::InvalidName)?;
    for _ in 0..16 {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let mut temporary_name = OsString::from(destination_name);
        temporary_name.push(format!(".tmp.{}.{sequence}", std::process::id()));
        let temporary = parent.join(temporary_name);
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => return Ok((temporary, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(io_error("create durable state temporary", &error)),
        }
    }
    Err(DurableStateError::Io {
        operation: "create durable state temporary",
        kind: io::ErrorKind::AlreadyExists,
    })
}

fn io_error(operation: &'static str, error: &io::Error) -> DurableStateError {
    DurableStateError::Io {
        operation,
        kind: error.kind(),
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;

    use tempfile::tempdir;

    use super::{DpapiDurableStateStore, DurableStateError, atomic_write};

    #[test]
    fn restart_is_monotonic_and_single_blob_rollback_fails_closed() -> Result<(), Box<dyn Error>> {
        let directory = tempdir()?;
        let store = DpapiDurableStateStore::open(directory.path(), "identity", b"test entropy")?;
        assert!(store.load()?.is_none());

        assert_eq!(store.save_next(0, b"generation one")?, 1);
        let old_state = fs::read(&store.state_path)?;
        assert_eq!(store.save_next(1, b"generation two")?, 2);
        let current = store.load()?.ok_or("state should exist")?;
        assert_eq!(current.generation(), 2);
        assert_eq!(current.payload(), b"generation two");
        assert_eq!(
            store.save_next(1, b"stale"),
            Err(DurableStateError::StaleGeneration)
        );

        fs::write(&store.state_path, old_state)?;
        assert!(matches!(
            store.load(),
            Err(DurableStateError::RollbackDetected)
        ));
        Ok(())
    }

    #[test]
    fn write_ahead_marker_recovers_each_commit_stage_and_rejects_tampering()
    -> Result<(), Box<dyn Error>> {
        let directory = tempdir()?;
        let store = DpapiDurableStateStore::open(directory.path(), "journal", b"test entropy")?;
        assert_eq!(store.save_next(0, b"one")?, 1);

        let prepared_two = store.prepare_transaction(2, b"two")?;
        atomic_write(&store.next_anchor_path, &prepared_two.next_marker)?;
        let after_prepare = store
            .load()?
            .ok_or("prepared state should retain generation one")?;
        assert_eq!(after_prepare.generation(), 1);
        assert!(!store.next_anchor_path.exists());

        let prepared_two = store.prepare_transaction(2, b"two")?;
        atomic_write(&store.next_anchor_path, &prepared_two.next_marker)?;
        atomic_write(&store.state_path, &prepared_two.state_blob)?;
        let after_state = store.load()?.ok_or("state recovery should roll forward")?;
        assert_eq!(after_state.generation(), 2);
        assert_eq!(after_state.payload(), b"two");
        assert!(!store.next_anchor_path.exists());

        let prepared_three = store.prepare_transaction(3, b"three")?;
        let rolled_back_next = prepared_three.next_marker.clone();
        atomic_write(&store.next_anchor_path, &prepared_three.next_marker)?;
        atomic_write(&store.state_path, &prepared_three.state_blob)?;
        atomic_write(&store.anchor_path, &prepared_three.anchor_blob)?;
        let after_anchor = store.load()?.ok_or("committed state should load")?;
        assert_eq!(after_anchor.generation(), 3);
        assert!(!store.next_anchor_path.exists());

        assert_eq!(store.save_next(3, b"four")?, 4);
        assert!(!store.next_anchor_path.exists());

        let mut forged = store.prepare_transaction(5, b"five")?.next_marker;
        if let Some(first) = forged.first_mut() {
            *first ^= 0x80;
        }
        atomic_write(&store.next_anchor_path, &forged)?;
        assert!(matches!(store.load(), Err(DurableStateError::Dpapi(_))));
        store.remove_next_and_sync()?;

        atomic_write(&store.next_anchor_path, &rolled_back_next)?;
        assert!(matches!(
            store.load(),
            Err(DurableStateError::RollbackDetected)
        ));
        Ok(())
    }

    #[test]
    fn initial_write_ahead_marker_recovers_each_crash_stage() -> Result<(), Box<dyn Error>> {
        let directory = tempdir()?;
        let store = DpapiDurableStateStore::open(directory.path(), "initial", b"test entropy")?;

        let prepared_one = store.prepare_transaction(1, b"one")?;
        atomic_write(&store.next_anchor_path, &prepared_one.next_marker)?;
        assert!(store.load()?.is_none());
        assert!(!store.next_anchor_path.exists());

        let prepared_one = store.prepare_transaction(1, b"one")?;
        atomic_write(&store.next_anchor_path, &prepared_one.next_marker)?;
        atomic_write(&store.state_path, &prepared_one.state_blob)?;
        let after_state = store
            .load()?
            .ok_or("initial state recovery should roll forward")?;
        assert_eq!(after_state.generation(), 1);
        assert_eq!(after_state.payload(), b"one");
        assert!(store.anchor_path.exists());
        assert!(!store.next_anchor_path.exists());

        let committed =
            DpapiDurableStateStore::open(directory.path(), "initial-committed", b"test entropy")?;
        let prepared_one = committed.prepare_transaction(1, b"committed")?;
        atomic_write(&committed.next_anchor_path, &prepared_one.next_marker)?;
        atomic_write(&committed.state_path, &prepared_one.state_blob)?;
        atomic_write(&committed.anchor_path, &prepared_one.anchor_blob)?;
        let after_anchor = committed.load()?.ok_or("committed state should load")?;
        assert_eq!(after_anchor.generation(), 1);
        assert!(!committed.next_anchor_path.exists());

        let state_only =
            DpapiDurableStateStore::open(directory.path(), "state-only", b"test entropy")?;
        let prepared_one = state_only.prepare_transaction(1, b"orphan")?;
        atomic_write(&state_only.state_path, &prepared_one.state_blob)?;
        assert!(matches!(
            state_only.load(),
            Err(DurableStateError::IncompleteState)
        ));

        let mismatched =
            DpapiDurableStateStore::open(directory.path(), "mismatched", b"test entropy")?;
        let first = mismatched.prepare_transaction(1, b"first")?;
        let second = mismatched.prepare_transaction(1, b"second")?;
        atomic_write(&mismatched.next_anchor_path, &first.next_marker)?;
        atomic_write(&mismatched.state_path, &second.state_blob)?;
        assert!(matches!(
            mismatched.load(),
            Err(DurableStateError::RollbackDetected)
        ));
        Ok(())
    }
}
