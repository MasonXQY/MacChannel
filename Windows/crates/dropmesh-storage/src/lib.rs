//! Durable transfer history and receive staging for `DropMesh`.
//!
//! Payloads remain below a private directory in the receive root until a
//! verified transfer is published with a same-volume atomic rename. A small
//! `SQLite` commit journal lets restart recovery distinguish an interrupted
//! staging write from a rename that completed before its final database write.
//!
//! Staging roots and every discovered payload component are checked for
//! symlinks or Windows reparse points, and payload files/directories are pinned
//! by handles while hashed and flushed. Stable Rust does not expose relative
//! create/rename operations from a pinned Windows directory handle, so a local
//! attacker who can replace an ancestor between checks can still create a
//! junction race. The receive root must therefore remain owner-controlled.
//! Callers must also quiesce their writer handles before a progress checkpoint
//! or commit; no storage layer can make a concurrent writer's later bytes part
//! of an already persisted checkpoint.
//! Recognizable DOS 8.3 spellings are rejected syntactically. On Windows,
//! existing components are additionally compared with their Win32 normalized
//! final long names and retained file handles are compared by volume/file ID.
//! Filesystems which cannot return a normalized final name fail closed. `ReFS`
//! may expose wider IDs than the compatibility identity API; an ID collision
//! can therefore reject distinct files, but cannot make aliases acceptable.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};
use thiserror::Error;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

const STAGING_DIRECTORY: &str = ".dropmesh-staging";
const PAYLOAD_NAME: &str = "payload";
const SCHEMA: &str = r"
CREATE TABLE IF NOT EXISTS transfers (
    id              TEXT PRIMARY KEY NOT NULL,
    peer_id         TEXT NOT NULL,
    display_name    TEXT NOT NULL,
    entry_kind      TEXT NOT NULL CHECK (entry_kind IN ('file', 'directory')),
    total_bytes     INTEGER NOT NULL CHECK (total_bytes >= 0),
    completed_bytes INTEGER NOT NULL DEFAULT 0 CHECK (completed_bytes >= 0),
    state           TEXT NOT NULL CHECK (
        state IN ('preparing', 'receiving', 'interrupted', 'committing',
                  'completed', 'failed', 'cancelled')
    ),
    final_name      TEXT,
    expected_payload_size INTEGER CHECK (expected_payload_size >= 0),
    expected_payload_sha256 BLOB CHECK (
        expected_payload_sha256 IS NULL OR length(expected_payload_sha256) = 32
    ),
    error           TEXT,
    created_at_ms   INTEGER NOT NULL,
    updated_at_ms   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS transfers_updated_at
    ON transfers(updated_at_ms DESC, id ASC);
";

/// File-system type of the top-level item published for a receive operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EntryKind {
    File,
    Directory,
}

impl EntryKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::File => "file",
            Self::Directory => "directory",
        }
    }

    fn parse(value: &str) -> Result<Self, StorageError> {
        match value {
            "file" => Ok(Self::File),
            "directory" => Ok(Self::Directory),
            _ => Err(StorageError::InvalidDatabase),
        }
    }
}

/// Durable lifecycle of an inbound transfer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransferState {
    Preparing,
    Receiving,
    Interrupted,
    Committing,
    Completed,
    Failed,
    Cancelled,
}

impl TransferState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Preparing => "preparing",
            Self::Receiving => "receiving",
            Self::Interrupted => "interrupted",
            Self::Committing => "committing",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    fn parse(value: &str) -> Result<Self, StorageError> {
        match value {
            "preparing" => Ok(Self::Preparing),
            "receiving" => Ok(Self::Receiving),
            "interrupted" => Ok(Self::Interrupted),
            "committing" => Ok(Self::Committing),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            _ => Err(StorageError::InvalidDatabase),
        }
    }

    fn can_resume(self) -> bool {
        matches!(self, Self::Preparing | Self::Receiving | Self::Interrupted)
    }
}

/// A platform-neutral, Windows-safe relative path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelativePath(PathBuf);

impl RelativePath {
    /// Validates both slash conventions so a path accepted on Unix cannot turn
    /// into a Windows drive, UNC, traversal, alternate stream, or device path.
    ///
    /// # Errors
    ///
    /// Returns [`StorageError::UnsafePath`] for an empty, absolute, reserved,
    /// or traversal-capable path.
    pub fn parse(value: &str) -> Result<Self, StorageError> {
        if value.is_empty()
            || value.starts_with(['/', '\\'])
            || value.contains('\0')
            || value.chars().any(char::is_control)
        {
            return Err(StorageError::UnsafePath);
        }

        let mut path = PathBuf::new();
        let mut component_count = 0_usize;
        for component in value.split(['/', '\\']) {
            if component.is_empty()
                || matches!(component, "." | "..")
                || component.contains(':')
                || component
                    .chars()
                    .any(|character| matches!(character, '<' | '>' | '"' | '|' | '?' | '*'))
                || component.ends_with(['.', ' '])
                || is_windows_device_name(component)
                || is_recognizable_short_name(component)
            {
                return Err(StorageError::UnsafePath);
            }
            path.push(component);
            component_count += 1;
        }
        if component_count == 0 {
            return Err(StorageError::UnsafePath);
        }
        Ok(Self(path))
    }

    #[must_use]
    pub fn as_path(&self) -> &Path {
        &self.0
    }

    fn is_single_component(&self) -> bool {
        self.0.components().count() == 1
    }

    fn windows_collision_key(&self) -> Result<String, StorageError> {
        let mut key = String::new();
        for (index, component) in self.0.components().enumerate() {
            let component = component
                .as_os_str()
                .to_str()
                .ok_or(StorageError::UnsafePath)?;
            if index != 0 {
                key.push('/');
            }
            key.push_str(&windows_component_key(component));
        }
        Ok(key)
    }
}

/// One manifest path and its promised file-system type.
#[derive(Clone, Copy, Debug)]
pub struct PathEntry<'a> {
    pub path: &'a RelativePath,
    pub kind: EntryKind,
}

/// Validates a manifest as a set under default Windows path semantics.
///
/// Each component's collision key is Unicode NFKC followed by Unicode
/// lowercase conversion; component keys are joined with `/`. This rejects
/// case-insensitive and compatibility-normalized aliases, inconsistent
/// component spelling, and a file which is also the parent of another entry.
///
/// # Errors
///
/// Returns [`StorageError::PathCollision`] if two entries can resolve to the
/// same Windows destination or if a file is used as a parent directory.
pub fn validate_path_batch(entries: &[PathEntry<'_>]) -> Result<(), StorageError> {
    let mut paths = HashMap::new();
    let mut component_spellings = HashMap::new();
    for entry in entries {
        let key = entry.path.windows_collision_key()?;
        if paths.insert(key.clone(), entry.kind).is_some() {
            return Err(StorageError::PathCollision);
        }

        let mut parent_key = String::new();
        for component in entry.path.as_path().components() {
            let spelling = component
                .as_os_str()
                .to_str()
                .ok_or(StorageError::UnsafePath)?
                .nfc()
                .collect::<String>();
            let component_key = windows_component_key(&spelling);
            let identity = format!("{parent_key}\0{component_key}");
            if let Some(existing) = component_spellings.insert(identity, spelling.clone())
                && existing != spelling
            {
                return Err(StorageError::PathCollision);
            }
            if !parent_key.is_empty() {
                parent_key.push('/');
            }
            parent_key.push_str(&component_key);
        }
    }

    for (path, kind) in &paths {
        if *kind == EntryKind::File {
            let prefix = format!("{path}/");
            if paths.keys().any(|candidate| candidate.starts_with(&prefix)) {
                return Err(StorageError::PathCollision);
            }
        }
    }
    Ok(())
}

fn windows_component_key(component: &str) -> String {
    component
        .nfkc()
        .flat_map(char::to_lowercase)
        .collect::<String>()
}

fn is_windows_device_name(component: &str) -> bool {
    let basename = component.split('.').next().unwrap_or_default();
    // Windows also reserves COM/LPT followed by superscript 1, 2, or 3.
    // NFKC maps those compatibility digits to their ASCII equivalents.
    let uppercase = basename.nfkc().collect::<String>().to_ascii_uppercase();
    matches!(uppercase.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || matches!(
            uppercase.strip_prefix("COM"),
            Some("1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
        )
        || matches!(
            uppercase.strip_prefix("LPT"),
            Some("1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
        )
}

fn is_recognizable_short_name(component: &str) -> bool {
    let (stem, extension) = match component.rsplit_once('.') {
        Some((stem, extension)) => (stem, Some(extension)),
        None => (component, None),
    };
    if !stem.is_ascii()
        || stem.is_empty()
        || stem.len() > 8
        || extension.is_some_and(|value| value.is_empty() || !value.is_ascii() || value.len() > 3)
    {
        return false;
    }
    let Some((prefix, ordinal)) = stem.rsplit_once('~') else {
        return false;
    };
    !prefix.is_empty()
        && prefix.len() <= 6
        && !ordinal.is_empty()
        && ordinal.len() <= 6
        && ordinal.bytes().all(|byte| byte.is_ascii_digit())
}

/// Immutable metadata needed to begin or resume an inbound transfer.
#[derive(Clone, Copy, Debug)]
pub struct ReceiveRequest<'a> {
    pub id: Uuid,
    pub peer_id: &'a str,
    pub display_name: &'a str,
    pub kind: EntryKind,
    pub total_bytes: u64,
}

/// Location of the private payload which callers may populate.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReceivePreparation {
    pub id: Uuid,
    pub staging_path: PathBuf,
    pub resumed: bool,
}

/// Durable history row exposed to the later Windows core and UI boundary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransferRecord {
    pub id: Uuid,
    pub peer_id: String,
    pub display_name: String,
    pub kind: EntryKind,
    pub total_bytes: u64,
    pub completed_bytes: u64,
    pub state: TransferState,
    pub final_path: Option<PathBuf>,
    pub error: Option<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("database operation failed")]
    Database(#[from] rusqlite::Error),
    #[error("file-system operation failed")]
    Io(#[from] io::Error),
    #[error("path is not a safe portable relative path")]
    UnsafePath,
    #[error("transfer does not exist")]
    NotFound,
    #[error("transfer metadata conflicts with its durable record")]
    MetadataConflict,
    #[error("operation is not valid in the transfer's current state")]
    InvalidState,
    #[error("progress must be monotonic and no greater than the declared total")]
    InvalidProgress,
    #[error("stored data is invalid")]
    InvalidDatabase,
    #[error("no collision-free destination name is available")]
    CollisionExhausted,
    #[error("paths collide under Windows destination semantics")]
    PathCollision,
    #[error("payload identity does not match its durable commit record")]
    PayloadIdentityMismatch,
}

/// SQLite-backed receive state rooted in one controlled destination directory.
pub struct Store {
    connection: Connection,
    receive_root: PathBuf,
    staging_root: PathBuf,
}

impl Store {
    /// Opens storage, creates its schema, and reconciles interrupted work.
    ///
    /// # Errors
    ///
    /// Returns an error when the roots cannot be created safely, the database
    /// cannot be opened or migrated, or recovery finds invalid durable data.
    pub fn open(
        database_path: impl AsRef<Path>,
        receive_root: impl AsRef<Path>,
    ) -> Result<Self, StorageError> {
        let database_path = database_path.as_ref();
        if let Some(parent) = database_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::create_dir_all(receive_root.as_ref())?;
        let receive_root = fs::canonicalize(receive_root.as_ref())?;
        let staging_root = receive_root.join(STAGING_DIRECTORY);
        create_controlled_directory(&staging_root)?;

        let connection = Connection::open(database_path)?;
        connection.execute_batch(
            "PRAGMA busy_timeout = 5000;\
             PRAGMA journal_mode = WAL;\
             PRAGMA synchronous = FULL;\
             PRAGMA foreign_keys = ON;",
        )?;
        connection.execute_batch(SCHEMA)?;
        migrate_commit_identity_columns(&connection)?;
        if let Some(parent) = database_path.parent()
            && !parent.as_os_str().is_empty()
        {
            sync_directory(parent)?;
        }

        let mut store = Self {
            connection,
            receive_root,
            staging_root,
        };
        store.recover()?;
        Ok(store)
    }

    /// Creates a private payload or resumes byte-for-byte identical metadata.
    ///
    /// # Errors
    ///
    /// Returns an error for unsafe names, conflicting metadata, a terminal
    /// transfer state, or a database/file-system failure.
    pub fn prepare_receive(
        &mut self,
        request: ReceiveRequest<'_>,
    ) -> Result<ReceivePreparation, StorageError> {
        let display_name = RelativePath::parse(request.display_name)?;
        if !display_name.is_single_component() || request.peer_id.is_empty() {
            return Err(StorageError::UnsafePath);
        }
        let total_bytes = to_sql_integer(request.total_bytes)?;
        if let Some(existing) = self.transfer(request.id)? {
            if existing.peer_id != request.peer_id
                || existing.display_name != request.display_name
                || existing.kind != request.kind
                || existing.total_bytes != request.total_bytes
            {
                return Err(StorageError::MetadataConflict);
            }
            if !existing.state.can_resume() {
                return Err(StorageError::InvalidState);
            }
            let payload = self.payload_path(request.id);
            validate_payload(&payload, request.kind)?;
            sync_payload(&payload, request.kind)?;
            self.update_state(request.id, TransferState::Receiving, None, None)?;
            return Ok(ReceivePreparation {
                id: request.id,
                staging_path: payload,
                resumed: true,
            });
        }

        let now = now_ms()?;
        self.connection.execute(
            "INSERT INTO transfers (
                id, peer_id, display_name, entry_kind, total_bytes,
                completed_bytes, state, created_at_ms, updated_at_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, 0, 'preparing', ?6, ?6)",
            params![
                request.id.to_string(),
                request.peer_id,
                request.display_name,
                request.kind.as_str(),
                total_bytes,
                now
            ],
        )?;

        let payload = self.payload_path(request.id);
        let create_result = create_payload(&payload, request.kind);
        if let Err(error) = create_result {
            let message = error.to_string();
            self.update_state(request.id, TransferState::Failed, None, Some(&message))?;
            return Err(StorageError::Io(error));
        }
        sync_payload(&payload, request.kind)?;
        sync_directory(&self.transfer_staging_path(request.id))?;
        sync_directory(&self.staging_root)?;
        sync_directory(&self.receive_root)?;
        self.update_state(request.id, TransferState::Receiving, None, None)?;
        Ok(ReceivePreparation {
            id: request.id,
            staging_path: payload,
            resumed: false,
        })
    }

    /// Resolves a validated path below a staged directory payload, creating
    /// ordinary parent directories without traversing symlinks.
    ///
    /// # Errors
    ///
    /// Returns an error when the transfer is missing, is not a resumable
    /// directory transfer, or a staged component is unsafe.
    pub fn staged_path(&self, id: Uuid, relative: &RelativePath) -> Result<PathBuf, StorageError> {
        let record = self.transfer(id)?.ok_or(StorageError::NotFound)?;
        if record.kind != EntryKind::Directory || !record.state.can_resume() {
            return Err(StorageError::InvalidState);
        }
        let payload = self.payload_path(id);
        validate_payload(&payload, EntryKind::Directory)?;

        let mut current = payload;
        let components: Vec<_> = relative.as_path().components().collect();
        for component in &components[..components.len().saturating_sub(1)] {
            current.push(component.as_os_str());
            create_controlled_directory(&current)?;
            sync_directory(&current)?;
            if let Some(parent) = current.parent() {
                sync_directory(parent)?;
            }
        }
        let destination = current.join(
            components
                .last()
                .ok_or(StorageError::UnsafePath)?
                .as_os_str(),
        );
        if let Ok(metadata) = fs::symlink_metadata(&destination)
            && (is_reparse_or_symlink(&metadata) || metadata.is_dir())
        {
            return Err(StorageError::UnsafePath);
        }
        Ok(destination)
    }

    /// Persists monotonic progress before acknowledging it to a sender.
    ///
    /// # Errors
    ///
    /// Returns an error when the transfer is missing or not resumable, progress
    /// regresses or exceeds the declared total, or the database write fails.
    pub fn record_progress(&mut self, id: Uuid, completed: u64) -> Result<(), StorageError> {
        let existing = self.transfer(id)?.ok_or(StorageError::NotFound)?;
        if !existing.state.can_resume()
            || completed < existing.completed_bytes
            || completed > existing.total_bytes
        {
            return Err(StorageError::InvalidProgress);
        }
        sync_payload(&self.payload_path(id), existing.kind)?;
        sync_directory(&self.transfer_staging_path(id))?;
        sync_directory(&self.staging_root)?;
        let completed = to_sql_integer(completed)?;
        let changed = self.connection.execute(
            "UPDATE transfers
             SET completed_bytes = ?1, state = 'receiving', error = NULL,
                 updated_at_ms = ?2
             WHERE id = ?3
               AND state IN ('preparing', 'receiving', 'interrupted')",
            params![completed, now_ms()?, id.to_string()],
        )?;
        if changed != 1 {
            return Err(StorageError::InvalidState);
        }
        Ok(())
    }

    /// Atomically publishes a complete payload without replacing an existing
    /// item. Collisions use `name (n).ext` deterministically.
    ///
    /// # Errors
    ///
    /// Returns an error when the transfer is incomplete or not resumable, its
    /// staging payload is invalid, no destination is available, or persistence
    /// or atomic publication fails.
    pub fn commit_receive(&mut self, id: Uuid) -> Result<PathBuf, StorageError> {
        let record = self.transfer(id)?.ok_or(StorageError::NotFound)?;
        if !record.state.can_resume() {
            return Err(StorageError::InvalidState);
        }
        if record.completed_bytes != record.total_bytes {
            return Err(StorageError::InvalidProgress);
        }
        let payload = self.payload_path(id);
        if let Err(error) = validate_payload(&payload, record.kind) {
            let message = error.to_string();
            self.update_state(id, TransferState::Failed, None, Some(&message))?;
            return Err(error);
        }

        let expected = payload_identity_and_sync(&payload, record.kind)?;
        if expected.size != record.total_bytes {
            self.update_state(
                id,
                TransferState::Failed,
                None,
                Some("payload size does not match the declared transfer total"),
            )?;
            return Err(StorageError::PayloadIdentityMismatch);
        }
        sync_directory(&self.transfer_staging_path(id))?;
        sync_directory(&self.staging_root)?;

        for collision_index in 0_u32..10_000 {
            let final_name = collision_name(&record.display_name, collision_index);
            let final_path = self.receive_root.join(&final_name);
            if self.destination_collision_exists(&final_name)? {
                continue;
            }
            self.update_committing(id, &final_name, &expected)?;
            let before_rename = payload_identity_and_sync(&payload, record.kind)?;
            if before_rename != expected {
                self.update_state(
                    id,
                    TransferState::Failed,
                    None,
                    Some("staged payload changed while committing"),
                )?;
                return Err(StorageError::PayloadIdentityMismatch);
            }
            sync_directory(&self.transfer_staging_path(id))?;
            sync_directory(&self.staging_root)?;
            match rename_no_replace(&payload, &final_path) {
                Ok(()) => {
                    let published = payload_identity_and_sync(&final_path, record.kind)?;
                    sync_directory(&self.receive_root)?;
                    if published != expected {
                        self.update_state(
                            id,
                            TransferState::Failed,
                            Some(&final_name),
                            Some("published payload identity changed during commit"),
                        )?;
                        return Err(StorageError::PayloadIdentityMismatch);
                    }
                    self.update_state(id, TransferState::Completed, Some(&final_name), None)?;
                    // The payload has moved and the completed state is durable.
                    // A leftover empty private directory is safe and will be
                    // retried by startup orphan cleanup.
                    let _ = remove_staging_entry(&self.transfer_staging_path(id));
                    sync_directory(&self.staging_root)?;
                    return Ok(final_path);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => {
                    let message = error.to_string();
                    self.update_state(id, TransferState::Failed, None, Some(&message))?;
                    return Err(StorageError::Io(error));
                }
            }
        }
        self.update_state(
            id,
            TransferState::Failed,
            None,
            Some("destination collision limit reached"),
        )?;
        Err(StorageError::CollisionExhausted)
    }

    /// Marks a transfer cancelled before removing its unpublished bytes.
    ///
    /// # Errors
    ///
    /// Returns an error when the transfer is missing or terminal, or when its
    /// durable state or staged bytes cannot be updated.
    pub fn cancel_receive(&mut self, id: Uuid) -> Result<(), StorageError> {
        let record = self.transfer(id)?.ok_or(StorageError::NotFound)?;
        if matches!(
            record.state,
            TransferState::Completed | TransferState::Cancelled
        ) {
            return Err(StorageError::InvalidState);
        }
        self.update_state(id, TransferState::Cancelled, None, None)?;
        remove_staging_entry(&self.transfer_staging_path(id))?;
        sync_directory(&self.staging_root)?;
        Ok(())
    }

    /// Fetches one durable transfer record.
    ///
    /// # Errors
    ///
    /// Returns an error when the database cannot be read or contains invalid
    /// persisted values.
    pub fn transfer(&self, id: Uuid) -> Result<Option<TransferRecord>, StorageError> {
        let stored = self
            .connection
            .query_row(
                "SELECT id, peer_id, display_name, entry_kind, total_bytes,
                        completed_bytes, state, final_name, error,
                        created_at_ms, updated_at_ms
                 FROM transfers WHERE id = ?1",
                [id.to_string()],
                StoredRecord::from_row,
            )
            .optional()?;
        stored
            .map(|record| record.into_public(&self.receive_root))
            .transpose()
    }

    /// Returns recently updated transfers, newest first.
    ///
    /// # Errors
    ///
    /// Returns an error when the database cannot be read or contains invalid
    /// persisted values.
    pub fn history(&self, limit: usize) -> Result<Vec<TransferRecord>, StorageError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let mut statement = self.connection.prepare(
            "SELECT id, peer_id, display_name, entry_kind, total_bytes,
                    completed_bytes, state, final_name, error,
                    created_at_ms, updated_at_ms
             FROM transfers
             ORDER BY updated_at_ms DESC, id ASC
             LIMIT ?1",
        )?;
        let rows = statement.query_map([limit], StoredRecord::from_row)?;
        let mut records = Vec::new();
        for row in rows {
            records.push(row?.into_public(&self.receive_root)?);
        }
        Ok(records)
    }

    fn recover(&mut self) -> Result<(), StorageError> {
        let pending = self.pending_records()?;
        for record in pending {
            let id = Uuid::parse_str(&record.id).map_err(|_| StorageError::InvalidDatabase)?;
            let payload = self.payload_path(id);
            let payload_exists = payload.exists();
            if record.state == "committing" {
                self.recover_commit(id, &record, payload_exists)?;
            } else if payload_exists {
                let valid = EntryKind::parse(&record.kind)
                    .and_then(|kind| sync_payload(&payload, kind))
                    .is_ok();
                if valid {
                    self.update_state(id, TransferState::Interrupted, None, None)?;
                } else {
                    self.update_state(
                        id,
                        TransferState::Failed,
                        None,
                        Some("staged payload cannot be safely recovered"),
                    )?;
                }
            } else {
                self.update_state(
                    id,
                    TransferState::Failed,
                    None,
                    Some("staged payload is missing"),
                )?;
            }
        }
        self.remove_orphan_staging()
    }

    fn pending_records(&self) -> Result<Vec<PendingRecord>, StorageError> {
        let mut statement = self.connection.prepare(
            "SELECT id, state, final_name, entry_kind,
                    expected_payload_size, expected_payload_sha256
             FROM transfers
             WHERE state IN ('preparing', 'receiving', 'committing')",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(PendingRecord {
                id: row.get(0)?,
                state: row.get(1)?,
                final_name: row.get(2)?,
                kind: row.get(3)?,
                expected_size: row.get(4)?,
                expected_digest: row.get(5)?,
            })
        })?;
        let mut records = Vec::new();
        for row in rows {
            records.push(row?);
        }
        Ok(records)
    }

    fn remove_orphan_staging(&self) -> Result<(), StorageError> {
        let mut removed = false;
        for entry in fs::read_dir(&self.staging_root)? {
            let entry = entry?;
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                remove_staging_entry(&entry.path())?;
                removed = true;
                continue;
            };
            let Ok(id) = Uuid::parse_str(&name) else {
                remove_staging_entry(&entry.path())?;
                removed = true;
                continue;
            };
            let keep = self.transfer(id)?.is_some_and(|record| {
                record.state.can_resume() || record.state == TransferState::Failed
            });
            if !keep {
                remove_staging_entry(&entry.path())?;
                removed = true;
            }
        }
        if removed {
            sync_directory(&self.staging_root)?;
        }
        Ok(())
    }

    fn recover_commit(
        &mut self,
        id: Uuid,
        record: &PendingRecord,
        payload_exists: bool,
    ) -> Result<(), StorageError> {
        let Some(final_name) = record.final_name.as_deref() else {
            return self.fail_recovery(id, "commit record has no final name");
        };
        if validate_single_component(final_name).is_err() {
            return self.fail_recovery(id, "commit record has an unsafe final name");
        }
        let expected = match record.identity() {
            Ok(Some(identity)) => identity,
            Ok(None) => return self.fail_recovery(id, "commit record has no payload identity"),
            Err(_) => {
                return self.fail_recovery(id, "commit record has an invalid payload identity");
            }
        };
        let Ok(kind) = EntryKind::parse(&record.kind) else {
            return self.fail_recovery(id, "commit record has an invalid payload kind");
        };
        let final_path = self.receive_root.join(final_name);
        let final_exists = final_path.exists();
        match (payload_exists, final_exists) {
            (false, true) => match payload_identity_and_sync(&final_path, kind) {
                Ok(found) if found == expected => {
                    if sync_directory(&self.receive_root).is_err() {
                        return self.fail_recovery(id, "published payload could not be flushed");
                    }
                    self.update_state(id, TransferState::Completed, Some(final_name), None)?;
                    let _ = remove_staging_entry(&self.transfer_staging_path(id));
                    let _ = sync_directory(&self.staging_root);
                    Ok(())
                }
                Ok(_) => self.fail_recovery(id, "published payload identity does not match"),
                Err(_) => self.fail_recovery(id, "published payload cannot be verified"),
            },
            (true, false) => match payload_identity_and_sync(&self.payload_path(id), kind) {
                Ok(found) if found == expected => {
                    self.update_state(id, TransferState::Interrupted, None, None)
                }
                Ok(_) => self.fail_recovery(id, "staged payload identity does not match"),
                Err(_) => self.fail_recovery(id, "staged payload cannot be verified"),
            },
            (true, true) => self.fail_recovery(
                id,
                "both staged and final payloads exist; publication is ambiguous",
            ),
            (false, false) => self.fail_recovery(id, "commit payload is missing"),
        }
    }

    fn fail_recovery(&mut self, id: Uuid, message: &str) -> Result<(), StorageError> {
        self.update_state(id, TransferState::Failed, None, Some(message))
    }

    fn destination_collision_exists(&self, candidate: &str) -> Result<bool, StorageError> {
        let candidate = RelativePath::parse(candidate)?.windows_collision_key()?;
        for entry in fs::read_dir(&self.receive_root)? {
            let entry = entry?;
            if entry.file_name() == STAGING_DIRECTORY {
                continue;
            }
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            let Ok(path) = RelativePath::parse(&name) else {
                continue;
            };
            if path.windows_collision_key()? == candidate {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn update_committing(
        &mut self,
        id: Uuid,
        final_name: &str,
        identity: &PayloadIdentity,
    ) -> Result<(), StorageError> {
        validate_single_component(final_name)?;
        let size = to_sql_integer(identity.size)?;
        let changed = self.connection.execute(
            "UPDATE transfers
             SET state = 'committing', final_name = ?1,
                 expected_payload_size = ?2, expected_payload_sha256 = ?3,
                 error = NULL, updated_at_ms = ?4
             WHERE id = ?5
               AND state IN ('preparing', 'receiving', 'interrupted', 'committing')",
            params![
                final_name,
                size,
                identity.digest.as_slice(),
                now_ms()?,
                id.to_string()
            ],
        )?;
        if changed != 1 {
            return Err(StorageError::InvalidState);
        }
        Ok(())
    }

    fn update_state(
        &mut self,
        id: Uuid,
        state: TransferState,
        final_name: Option<&str>,
        error: Option<&str>,
    ) -> Result<(), StorageError> {
        if let Some(name) = final_name {
            validate_single_component(name)?;
        }
        let transaction = self.connection.transaction()?;
        update_state_in_transaction(&transaction, id, state, final_name, error)?;
        transaction.commit()?;
        Ok(())
    }

    fn payload_path(&self, id: Uuid) -> PathBuf {
        self.transfer_staging_path(id).join(PAYLOAD_NAME)
    }

    fn transfer_staging_path(&self, id: Uuid) -> PathBuf {
        self.staging_root.join(id.to_string())
    }
}

fn update_state_in_transaction(
    transaction: &Transaction<'_>,
    id: Uuid,
    state: TransferState,
    final_name: Option<&str>,
    error: Option<&str>,
) -> Result<(), StorageError> {
    let changed = transaction.execute(
        "UPDATE transfers
         SET state = ?1, final_name = ?2, error = ?3, updated_at_ms = ?4
         WHERE id = ?5",
        params![state.as_str(), final_name, error, now_ms()?, id.to_string()],
    )?;
    if changed != 1 {
        return Err(StorageError::NotFound);
    }
    Ok(())
}

struct PendingRecord {
    id: String,
    state: String,
    final_name: Option<String>,
    kind: String,
    expected_size: Option<i64>,
    expected_digest: Option<Vec<u8>>,
}

impl PendingRecord {
    fn identity(&self) -> Result<Option<PayloadIdentity>, StorageError> {
        let (Some(size), Some(digest)) = (self.expected_size, self.expected_digest.as_deref())
        else {
            return Ok(None);
        };
        let size = u64::try_from(size).map_err(|_| StorageError::InvalidDatabase)?;
        let digest: [u8; 32] = digest
            .try_into()
            .map_err(|_| StorageError::InvalidDatabase)?;
        Ok(Some(PayloadIdentity { size, digest }))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PayloadIdentity {
    size: u64,
    digest: [u8; 32],
}

struct StoredRecord {
    id: String,
    peer_id: String,
    display_name: String,
    kind: String,
    total_bytes: i64,
    completed_bytes: i64,
    state: String,
    final_name: Option<String>,
    error: Option<String>,
    created_at_ms: i64,
    updated_at_ms: i64,
}

impl StoredRecord {
    fn from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            peer_id: row.get(1)?,
            display_name: row.get(2)?,
            kind: row.get(3)?,
            total_bytes: row.get(4)?,
            completed_bytes: row.get(5)?,
            state: row.get(6)?,
            final_name: row.get(7)?,
            error: row.get(8)?,
            created_at_ms: row.get(9)?,
            updated_at_ms: row.get(10)?,
        })
    }

    fn into_public(self, receive_root: &Path) -> Result<TransferRecord, StorageError> {
        let id = Uuid::parse_str(&self.id).map_err(|_| StorageError::InvalidDatabase)?;
        validate_single_component(&self.display_name).map_err(|_| StorageError::InvalidDatabase)?;
        let total_bytes =
            u64::try_from(self.total_bytes).map_err(|_| StorageError::InvalidDatabase)?;
        let completed_bytes =
            u64::try_from(self.completed_bytes).map_err(|_| StorageError::InvalidDatabase)?;
        let final_path = self
            .final_name
            .map(|name| {
                validate_single_component(&name)
                    .map(|()| receive_root.join(name))
                    .map_err(|_| StorageError::InvalidDatabase)
            })
            .transpose()?;
        Ok(TransferRecord {
            id,
            peer_id: self.peer_id,
            display_name: self.display_name,
            kind: EntryKind::parse(&self.kind)?,
            total_bytes,
            completed_bytes,
            state: TransferState::parse(&self.state)?,
            final_path,
            error: self.error,
            created_at_ms: self.created_at_ms,
            updated_at_ms: self.updated_at_ms,
        })
    }
}

fn migrate_commit_identity_columns(connection: &Connection) -> Result<(), StorageError> {
    let mut statement = connection.prepare("PRAGMA table_info(transfers)")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(1))?;
    let mut columns = Vec::new();
    for row in rows {
        columns.push(row?);
    }
    drop(statement);
    if !columns
        .iter()
        .any(|column| column == "expected_payload_size")
    {
        connection.execute_batch(
            "ALTER TABLE transfers ADD COLUMN expected_payload_size INTEGER
                 CHECK (expected_payload_size >= 0);",
        )?;
    }
    if !columns
        .iter()
        .any(|column| column == "expected_payload_sha256")
    {
        connection.execute_batch(
            "ALTER TABLE transfers ADD COLUMN expected_payload_sha256 BLOB
                 CHECK (expected_payload_sha256 IS NULL
                        OR length(expected_payload_sha256) = 32);",
        )?;
    }
    connection.pragma_update(None, "user_version", 2_i64)?;
    Ok(())
}

fn sync_payload(path: &Path, kind: EntryKind) -> Result<(), StorageError> {
    payload_identity_and_sync(path, kind).map(|_| ())
}

fn payload_identity_and_sync(
    path: &Path,
    kind: EntryKind,
) -> Result<PayloadIdentity, StorageError> {
    validate_payload(path, kind)?;
    match kind {
        EntryKind::File => file_identity_and_sync(path),
        EntryKind::Directory => directory_identity_and_sync(path),
    }
}

fn file_identity_and_sync(path: &Path) -> Result<PayloadIdentity, StorageError> {
    file_identity_and_sync_with_object(path).map(|result| result.payload)
}

fn file_identity_and_sync_with_object(path: &Path) -> Result<MaterializedFile, StorageError> {
    let mut file = open_file_no_reparse(path)?;
    let before = file.metadata()?;
    if !before.is_file() {
        return Err(StorageError::UnsafePath);
    }
    let mut hasher = Sha256::new();
    let mut size = 0_u64;
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        size = size
            .checked_add(u64::try_from(count).map_err(|_| StorageError::InvalidDatabase)?)
            .ok_or(StorageError::InvalidProgress)?;
        hasher.update(&buffer[..count]);
    }
    file.sync_all()?;
    let after = file.metadata()?;
    if before.len() != after.len() || after.len() != size {
        return Err(StorageError::PayloadIdentityMismatch);
    }
    // The retained handle supplies a stable Windows volume+file-index key (or
    // Unix device+inode key) and remains alive until the whole tree is checked.
    let object = same_file::Handle::from_file(file)?;
    Ok(MaterializedFile {
        payload: PayloadIdentity {
            size,
            digest: hasher.finalize().into(),
        },
        object,
    })
}

#[derive(Debug)]
struct MaterializedFile {
    payload: PayloadIdentity,
    object: FileObjectIdentity,
}

// `same-file` retains this exact handle while deriving device/inode on Unix and
// Win32 volume serial + file index on Windows. Retention prevents ID reuse
// between comparisons inside one tree walk.
type FileObjectIdentity = same_file::Handle;

#[derive(Debug)]
struct TreeNode {
    path: RelativePath,
    collision_key: String,
    kind: EntryKind,
    size: u64,
    digest: Option<[u8; 32]>,
}

fn directory_identity_and_sync(path: &Path) -> Result<PayloadIdentity, StorageError> {
    let mut nodes = Vec::new();
    let mut file_objects = HashSet::new();
    collect_tree(path, path, &mut nodes, &mut file_objects)?;
    let entries: Vec<_> = nodes
        .iter()
        .map(|node| PathEntry {
            path: &node.path,
            kind: node.kind,
        })
        .collect();
    validate_path_batch(&entries)?;
    nodes.sort_by(|left, right| left.collision_key.cmp(&right.collision_key));

    let mut total_size = 0_u64;
    let mut hasher = Sha256::new();
    hasher.update(b"dropmesh-directory-v1\0");
    for node in nodes {
        let portable_path = portable_path(&node.path)?;
        let path_bytes = portable_path.as_bytes();
        hasher.update([match node.kind {
            EntryKind::File => 1_u8,
            EntryKind::Directory => 2_u8,
        }]);
        hasher.update(
            u64::try_from(path_bytes.len())
                .map_err(|_| StorageError::InvalidDatabase)?
                .to_le_bytes(),
        );
        hasher.update(path_bytes);
        hasher.update(node.size.to_le_bytes());
        if let Some(digest) = node.digest {
            hasher.update(digest);
            total_size = total_size
                .checked_add(node.size)
                .ok_or(StorageError::InvalidProgress)?;
        }
    }
    sync_directory(path)?;
    Ok(PayloadIdentity {
        size: total_size,
        digest: hasher.finalize().into(),
    })
}

fn collect_tree(
    root: &Path,
    directory: &Path,
    nodes: &mut Vec<TreeNode>,
    file_objects: &mut HashSet<FileObjectIdentity>,
) -> Result<(), StorageError> {
    ensure_directory_no_reparse(directory)?;
    let mut children = Vec::new();
    for entry in fs::read_dir(directory)? {
        children.push(entry?.path());
    }
    children.sort();
    for child in children {
        let metadata = fs::symlink_metadata(&child)?;
        if is_reparse_or_symlink(&metadata) {
            return Err(StorageError::UnsafePath);
        }
        let relative = child
            .strip_prefix(root)
            .map_err(|_| StorageError::UnsafePath)?;
        let relative = relative
            .components()
            .map(|component| {
                component
                    .as_os_str()
                    .to_str()
                    .ok_or(StorageError::UnsafePath)
            })
            .collect::<Result<Vec<_>, _>>()?
            .join("/");
        let relative = RelativePath::parse(&relative)?;
        let collision_key = relative.windows_collision_key()?;
        if metadata.is_file() {
            let materialized = file_identity_and_sync_with_object(&child)?;
            if !file_objects.insert(materialized.object) {
                return Err(StorageError::PathCollision);
            }
            nodes.push(TreeNode {
                path: relative,
                collision_key,
                kind: EntryKind::File,
                size: materialized.payload.size,
                digest: Some(materialized.payload.digest),
            });
        } else if metadata.is_dir() {
            ensure_directory_no_reparse(&child)?;
            nodes.push(TreeNode {
                path: relative,
                collision_key,
                kind: EntryKind::Directory,
                size: 0,
                digest: None,
            });
            collect_tree(root, &child, nodes, file_objects)?;
            sync_directory(&child)?;
        } else {
            return Err(StorageError::UnsafePath);
        }
    }
    sync_directory(directory)?;
    Ok(())
}

fn portable_path(path: &RelativePath) -> Result<String, StorageError> {
    path.as_path()
        .components()
        .map(|component| {
            component
                .as_os_str()
                .to_str()
                .ok_or(StorageError::UnsafePath)
        })
        .collect::<Result<Vec<_>, _>>()
        .map(|components| components.join("/"))
}

fn create_payload(path: &Path, kind: EntryKind) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "payload has no parent"))?;
    fs::create_dir(parent)?;
    match kind {
        EntryKind::File => {
            OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(path)?;
        }
        EntryKind::Directory => fs::create_dir(path)?,
    }
    Ok(())
}

fn validate_single_component(value: &str) -> Result<(), StorageError> {
    let relative = RelativePath::parse(value)?;
    if !relative.is_single_component() {
        return Err(StorageError::UnsafePath);
    }
    Ok(())
}

fn validate_payload(path: &Path, kind: EntryKind) -> Result<(), StorageError> {
    let metadata = fs::symlink_metadata(path)?;
    if is_reparse_or_symlink(&metadata)
        || (kind == EntryKind::File && !metadata.is_file())
        || (kind == EntryKind::Directory && !metadata.is_dir())
    {
        return Err(StorageError::UnsafePath);
    }
    match kind {
        EntryKind::File => drop(open_file_no_reparse(path)?),
        EntryKind::Directory => ensure_directory_no_reparse(path)?,
    }
    Ok(())
}

fn create_controlled_directory(path: &Path) -> Result<(), StorageError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if is_reparse_or_symlink(&metadata) || !metadata.is_dir() {
                return Err(StorageError::UnsafePath);
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir(path)?;
            let metadata = fs::symlink_metadata(path)?;
            if is_reparse_or_symlink(&metadata) || !metadata.is_dir() {
                return Err(StorageError::UnsafePath);
            }
        }
        Err(error) => return Err(StorageError::Io(error)),
    }
    ensure_directory_no_reparse(path)?;
    Ok(())
}

#[cfg(windows)]
fn open_file_no_reparse(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};

    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_SHARE_ALL: u32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0004;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(FILE_SHARE_ALL)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "reparse points are not valid payload files",
        ));
    }
    verify_windows_long_spelling(path)?;
    Ok(file)
}

#[cfg(unix)]
fn open_file_no_reparse(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::MetadataExt;

    let before = fs::symlink_metadata(path)?;
    if before.file_type().is_symlink() || !before.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "payload path is not a regular file",
        ));
    }
    let file = OpenOptions::new().read(true).write(true).open(path)?;
    let after = file.metadata()?;
    if before.dev() != after.dev() || before.ino() != after.ino() || !after.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "payload file changed while opening",
        ));
    }
    Ok(file)
}

#[cfg(not(any(unix, windows)))]
fn open_file_no_reparse(path: &Path) -> io::Result<File> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "payload path is not a regular file",
        ));
    }
    OpenOptions::new().read(true).write(true).open(path)
}

#[cfg(windows)]
fn open_directory_no_reparse(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};

    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_SHARE_ALL: u32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0004;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    let directory = OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(FILE_SHARE_ALL)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = directory.metadata()?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "reparse points are not valid payload directories",
        ));
    }
    verify_windows_long_spelling(path)?;
    Ok(directory)
}

#[cfg(windows)]
fn verify_windows_long_spelling(path: &Path) -> io::Result<()> {
    // `std::fs::canonicalize` uses the Win32 final-path APIs and expands an
    // 8.3 alias to the materialized long spelling. The root is canonicalized
    // when `Store` opens, so checking each opened leaf also checks every newly
    // traversed manifest component without trusting NFKC/case folding alone.
    let Some(requested) = path.file_name() else {
        return Ok(());
    };
    let canonical = fs::canonicalize(path)?;
    let materialized = canonical.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Windows final path has no final component",
        )
    })?;
    if requested != materialized {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "requested path spelling differs from its Windows long name",
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn open_directory_no_reparse(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::MetadataExt;

    let before = fs::symlink_metadata(path)?;
    if before.file_type().is_symlink() || !before.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "payload path is not a directory",
        ));
    }
    let directory = File::open(path)?;
    let after = directory.metadata()?;
    if before.dev() != after.dev() || before.ino() != after.ino() || !after.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "payload directory changed while opening",
        ));
    }
    Ok(directory)
}

#[cfg(not(any(unix, windows)))]
fn open_directory_no_reparse(path: &Path) -> io::Result<File> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "payload path is not a directory",
        ));
    }
    File::open(path)
}

fn ensure_directory_no_reparse(path: &Path) -> Result<(), StorageError> {
    drop(open_directory_no_reparse(path)?);
    Ok(())
}

#[cfg(windows)]
fn is_reparse_or_symlink(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_type().is_symlink()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn is_reparse_or_symlink(metadata: &fs::Metadata) -> bool {
    metadata.file_type().is_symlink()
}

fn remove_staging_entry(path: &Path) -> Result<(), StorageError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if is_reparse_or_symlink(&metadata) && metadata.is_dir() => {
            fs::remove_dir(path)?;
        }
        Ok(metadata) if is_reparse_or_symlink(&metadata) || metadata.is_file() => {
            fs::remove_file(path)?;
        }
        Ok(_) => fs::remove_dir_all(path)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(StorageError::Io(error)),
    }
    Ok(())
}

fn collision_name(display_name: &str, index: u32) -> String {
    if index == 0 {
        return display_name.to_owned();
    }
    let path = Path::new(display_name);
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or(display_name);
    match path.extension().and_then(|value| value.to_str()) {
        Some(extension) => format!("{stem} ({index}).{extension}"),
        None => format!("{display_name} ({index})"),
    }
}

fn rename_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    renamore::rename_exclusive(source, destination)
}

fn sync_directory(path: &Path) -> io::Result<()> {
    // `File::sync_all` invokes the platform fsync operation. On Windows this
    // is `FlushFileBuffers` on the real GENERIC_WRITE directory handle opened
    // above with `FILE_FLAG_BACKUP_SEMANTICS`, never a no-op fallback.
    open_directory_no_reparse(path)?.sync_all()
}

fn now_ms() -> Result<i64, StorageError> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| io::Error::other(error.to_string()))?;
    i64::try_from(duration.as_millis()).map_err(|_| StorageError::InvalidDatabase)
}

fn to_sql_integer(value: u64) -> Result<i64, StorageError> {
    i64::try_from(value).map_err(|_| StorageError::InvalidProgress)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use tempfile::TempDir;

    #[test]
    fn directory_tree_digest_is_creation_order_independent_and_content_sensitive() {
        let temp = TempDir::new().unwrap();
        let first = temp.path().join("first");
        let second = temp.path().join("second");
        fs::create_dir_all(first.join("nested")).unwrap();
        fs::write(first.join("z.txt"), b"z").unwrap();
        fs::write(first.join("nested/a.txt"), b"alpha").unwrap();
        fs::create_dir_all(second.join("nested")).unwrap();
        fs::write(second.join("nested/a.txt"), b"alpha").unwrap();
        fs::write(second.join("z.txt"), b"z").unwrap();

        let first_identity = directory_identity_and_sync(&first).unwrap();
        let second_identity = directory_identity_and_sync(&second).unwrap();
        assert_eq!(first_identity, second_identity);

        fs::write(second.join("nested/a.txt"), b"altered").unwrap();
        assert_ne!(
            first_identity,
            directory_identity_and_sync(&second).unwrap()
        );
    }

    #[cfg(unix)]
    #[test]
    fn directory_tree_rejects_symlinks_in_any_component() {
        use std::os::unix::fs::symlink;

        let temp = TempDir::new().unwrap();
        let payload = temp.path().join("payload");
        fs::create_dir(&payload).unwrap();
        symlink(temp.path(), payload.join("escape")).unwrap();

        assert!(matches!(
            directory_identity_and_sync(&payload),
            Err(StorageError::UnsafePath)
        ));
    }

    #[test]
    fn directory_tree_rejects_windows_aliases_on_case_sensitive_hosts() {
        let temp = TempDir::new().unwrap();
        let payload = temp.path().join("payload");
        fs::create_dir(&payload).unwrap();
        fs::write(payload.join("A.txt"), b"upper").unwrap();
        if fs::write(payload.join("a.txt"), b"lower").is_err() {
            return;
        }
        if fs::read_dir(&payload).unwrap().count() < 2 {
            return;
        }

        assert!(matches!(
            directory_identity_and_sync(&payload),
            Err(StorageError::PathCollision)
        ));
    }

    #[test]
    fn directory_tree_rejects_hard_link_aliases() {
        let temp = TempDir::new().unwrap();
        let payload = temp.path().join("payload");
        fs::create_dir(&payload).unwrap();
        let first = payload.join("first.txt");
        fs::write(&first, b"same object").unwrap();
        fs::hard_link(&first, payload.join("second.txt")).unwrap();

        assert!(matches!(
            directory_identity_and_sync(&payload),
            Err(StorageError::PathCollision)
        ));
    }

    #[cfg(windows)]
    #[test]
    fn windows_open_rejects_a_materialized_eight_dot_three_alias() {
        let temp = TempDir::new().unwrap();
        let long_path = temp
            .path()
            .join("LongFilenameForEightDotThreeNativeProbe.txt");
        fs::write(&long_path, b"probe").unwrap();
        let short_path = temp.path().join("LONGFI~1.TXT");
        if !short_path.exists() {
            eprintln!("skipped: this Windows volume did not materialize the probed 8.3 alias");
            return;
        }

        assert!(open_file_no_reparse(&long_path).is_ok());
        assert!(open_file_no_reparse(&short_path).is_err());
    }
}
