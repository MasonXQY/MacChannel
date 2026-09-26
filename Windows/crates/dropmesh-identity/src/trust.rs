use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{DEVICE_ID_LEN, DeviceId, P256_RAW_XY_LEN, P256PublicKey};

/// Maximum number of actively trusted peers in one local store.
pub const MAX_TRUSTED_DEVICES: usize = 256;

/// Maximum number of retained revocation tombstones.
pub const MAX_REVOKED_DEVICES: usize = 4_096;

/// Maximum accepted size of the versioned restart representation.
pub const MAX_TRUST_STORE_JSON_BYTES: usize = 512 * 1024;

const TRUST_STORE_VERSION: u8 = 1;

/// Public identity material authorized by completed manual pairing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrustRecord {
    device_id: DeviceId,
    signing_public_key: P256PublicKey,
    agreement_public_key: P256PublicKey,
}

impl TrustRecord {
    /// Creates a record only when the exact signing key derives `device_id`.
    ///
    /// # Errors
    ///
    /// Returns [`TrustStoreError::DeviceIdMismatch`] for a mismatched binding.
    pub fn new(
        device_id: DeviceId,
        signing_public_key: P256PublicKey,
        agreement_public_key: P256PublicKey,
    ) -> Result<Self, TrustStoreError> {
        if device_id != DeviceId::from_signing_public_key(&signing_public_key) {
            return Err(TrustStoreError::DeviceIdMismatch);
        }
        Ok(Self {
            device_id,
            signing_public_key,
            agreement_public_key,
        })
    }

    /// Returns the authorized peer identifier.
    #[must_use]
    pub const fn device_id(&self) -> DeviceId {
        self.device_id
    }

    /// Returns the exact authorized signing key.
    #[must_use]
    pub const fn signing_public_key(&self) -> P256PublicKey {
        self.signing_public_key
    }

    /// Returns the exact authorized agreement key.
    #[must_use]
    pub const fn agreement_public_key(&self) -> P256PublicKey {
        self.agreement_public_key
    }
}

/// Bounded, persistence-neutral active trust and revocation state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrustStore {
    records: BTreeMap<DeviceId, TrustRecord>,
    revoked: BTreeSet<DeviceId>,
}

impl TrustStore {
    /// Creates an empty trust store.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            records: BTreeMap::new(),
            revoked: BTreeSet::new(),
        }
    }

    /// Authorizes one exact peer identity.
    ///
    /// Repeated authorization is rejected rather than treated as an implicit
    /// update. Any public-key change for an existing device ID also fails.
    ///
    /// # Errors
    ///
    /// Returns a specific duplicate, key-change, revocation, or capacity error.
    pub fn authorize(&mut self, record: TrustRecord) -> Result<(), TrustStoreError> {
        let device_id = record.device_id();
        if self.revoked.contains(&device_id) {
            return Err(TrustStoreError::RevokedDevice);
        }
        if let Some(existing) = self.records.get(&device_id) {
            return if existing == &record {
                Err(TrustStoreError::DuplicateDevice)
            } else {
                Err(TrustStoreError::KeyChanged)
            };
        }
        if self.records.len() >= MAX_TRUSTED_DEVICES {
            return Err(TrustStoreError::CapacityExceeded);
        }
        self.records.insert(device_id, record);
        Ok(())
    }

    /// Revokes a device and retains a tombstone across restarts.
    ///
    /// Unknown device IDs can be revoked preemptively, which lets authenticated
    /// revocation state arrive before stale trust state during recovery.
    ///
    /// # Errors
    ///
    /// Returns an error for a duplicate tombstone or exhausted capacity.
    pub fn revoke(&mut self, device_id: DeviceId) -> Result<(), TrustStoreError> {
        if self.revoked.contains(&device_id) {
            return Err(TrustStoreError::AlreadyRevoked);
        }
        if self.revoked.len() >= MAX_REVOKED_DEVICES {
            return Err(TrustStoreError::CapacityExceeded);
        }
        self.records.remove(&device_id);
        self.revoked.insert(device_id);
        Ok(())
    }

    /// Looks up an actively trusted peer.
    #[must_use]
    pub fn get(&self, device_id: DeviceId) -> Option<&TrustRecord> {
        self.records.get(&device_id)
    }

    /// Reports whether a revocation tombstone exists.
    #[must_use]
    pub fn is_revoked(&self, device_id: DeviceId) -> bool {
        self.revoked.contains(&device_id)
    }

    /// Returns the number of active records.
    #[must_use]
    pub fn len(&self) -> usize {
        self.records.len()
    }

    /// Reports whether there are no active records.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Serializes the bounded store into its versioned restart representation.
    ///
    /// # Errors
    ///
    /// Returns [`TrustStoreError::CorruptPersistence`] if serialization fails.
    pub fn to_json(&self) -> Result<Vec<u8>, TrustStoreError> {
        let records = self
            .records
            .values()
            .map(PersistedTrustRecord::from)
            .collect();
        let revoked = self.revoked.iter().map(ToString::to_string).collect();
        let encoded = serde_json::to_vec(&PersistedTrustStore {
            version: TRUST_STORE_VERSION,
            records,
            revoked,
        })
        .map_err(|_| TrustStoreError::CorruptPersistence)?;
        if encoded.len() > MAX_TRUST_STORE_JSON_BYTES {
            return Err(TrustStoreError::CorruptPersistence);
        }
        Ok(encoded)
    }

    /// Restores a store while revalidating key points, ID binding, uniqueness,
    /// capacities, and active/revoked separation.
    ///
    /// # Errors
    ///
    /// Returns a precise trust error for duplicate/key-change conditions, or
    /// [`TrustStoreError::CorruptPersistence`] for malformed state.
    pub fn from_json(bytes: &[u8]) -> Result<Self, TrustStoreError> {
        if bytes.len() > MAX_TRUST_STORE_JSON_BYTES {
            return Err(TrustStoreError::CorruptPersistence);
        }
        let persisted: PersistedTrustStore =
            serde_json::from_slice(bytes).map_err(|_| TrustStoreError::CorruptPersistence)?;
        if persisted.version != TRUST_STORE_VERSION
            || persisted.records.len() > MAX_TRUSTED_DEVICES
            || persisted.revoked.len() > MAX_REVOKED_DEVICES
        {
            return Err(TrustStoreError::CorruptPersistence);
        }

        let mut store = Self::new();
        for persisted_record in persisted.records {
            store.authorize(persisted_record.try_into()?)?;
        }
        for encoded_id in persisted.revoked {
            let device_id = parse_device_id(&encoded_id)?;
            if store.records.contains_key(&device_id) || !store.revoked.insert(device_id) {
                return Err(TrustStoreError::CorruptPersistence);
            }
        }
        Ok(store)
    }
}

impl Default for TrustStore {
    fn default() -> Self {
        Self::new()
    }
}

/// Rejection reasons for trust mutation and restart recovery.
#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum TrustStoreError {
    /// Device ID was not derived from the exact signing key bytes.
    #[error("device ID does not match signing public key")]
    DeviceIdMismatch,
    /// A public key failed P-256 validation.
    #[error("invalid P-256 public key")]
    InvalidPublicKey,
    /// The exact device is already active; pairing is single-commit.
    #[error("device is already trusted")]
    DuplicateDevice,
    /// A record attempted to replace public key material for an existing ID.
    #[error("trusted device public keys changed")]
    KeyChanged,
    /// A revocation tombstone prevents reauthorization.
    #[error("device is revoked")]
    RevokedDevice,
    /// The same revocation was applied twice.
    #[error("device is already revoked")]
    AlreadyRevoked,
    /// The bounded active or revocation capacity was reached.
    #[error("trust store capacity exceeded")]
    CapacityExceeded,
    /// Persisted state was malformed, unsupported, or internally inconsistent.
    #[error("corrupt trust store persistence")]
    CorruptPersistence,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedTrustStore {
    version: u8,
    records: Vec<PersistedTrustRecord>,
    revoked: Vec<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedTrustRecord {
    device_id: String,
    signing_public_key: String,
    agreement_public_key: String,
}

impl From<&TrustRecord> for PersistedTrustRecord {
    fn from(record: &TrustRecord) -> Self {
        Self {
            device_id: record.device_id.to_string(),
            signing_public_key: hex::encode(record.signing_public_key.as_raw_xy()),
            agreement_public_key: hex::encode(record.agreement_public_key.as_raw_xy()),
        }
    }
}

impl TryFrom<PersistedTrustRecord> for TrustRecord {
    type Error = TrustStoreError;

    fn try_from(record: PersistedTrustRecord) -> Result<Self, Self::Error> {
        Self::new(
            parse_device_id(&record.device_id)?,
            parse_public_key(&record.signing_public_key)?,
            parse_public_key(&record.agreement_public_key)?,
        )
    }
}

fn parse_device_id(encoded: &str) -> Result<DeviceId, TrustStoreError> {
    if encoded.len() != 36
        || encoded.as_bytes().get(8) != Some(&b'-')
        || encoded.as_bytes().get(13) != Some(&b'-')
        || encoded.as_bytes().get(18) != Some(&b'-')
        || encoded.as_bytes().get(23) != Some(&b'-')
    {
        return Err(TrustStoreError::CorruptPersistence);
    }
    let compact = encoded.replace('-', "");
    let mut bytes = [0_u8; DEVICE_ID_LEN];
    hex::decode_to_slice(&compact, &mut bytes).map_err(|_| TrustStoreError::CorruptPersistence)?;
    let device_id = DeviceId::from_bytes(bytes);
    if device_id.to_string() != encoded {
        return Err(TrustStoreError::CorruptPersistence);
    }
    Ok(device_id)
}

fn parse_public_key(encoded: &str) -> Result<P256PublicKey, TrustStoreError> {
    if encoded.len() != P256_RAW_XY_LEN * 2 {
        return Err(TrustStoreError::InvalidPublicKey);
    }
    let mut bytes = [0_u8; P256_RAW_XY_LEN];
    hex::decode_to_slice(encoded, &mut bytes).map_err(|_| TrustStoreError::InvalidPublicKey)?;
    if hex::encode(bytes) != encoded {
        return Err(TrustStoreError::InvalidPublicKey);
    }
    P256PublicKey::from_raw_xy(bytes).map_err(|_| TrustStoreError::InvalidPublicKey)
}
