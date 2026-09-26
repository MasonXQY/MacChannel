//! Platform-neutral device identity contracts for `DropMesh`.
//!
//! Private key custody belongs to the platform adapter. This crate exposes only
//! stable public identity material, strict DER signatures, and the contract used
//! to persist and fail-closed on public metadata mismatches.

use std::fmt;

use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// The byte length of a P-256 public key in `DropMesh`'s `X || Y` wire form.
pub const P256_RAW_XY_LEN: usize = 64;

/// The byte length of a `DropMesh` device identifier.
pub const DEVICE_ID_LEN: usize = 16;

/// A stable identifier derived from the signing public key.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DeviceId([u8; DEVICE_ID_LEN]);

impl DeviceId {
    /// Derives the device identifier as the first 16 bytes of SHA-256 over the
    /// exact 64-byte signing public key wire representation.
    #[must_use]
    pub fn from_signing_public_key(public_key: &P256PublicKey) -> Self {
        let digest = Sha256::digest(public_key.as_raw_xy());
        let mut bytes = [0_u8; DEVICE_ID_LEN];
        bytes.copy_from_slice(&digest[..DEVICE_ID_LEN]);
        Self(bytes)
    }

    /// Returns the identifier bytes in network order.
    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; DEVICE_ID_LEN] {
        &self.0
    }

    /// Constructs an identifier from its network-order bytes.
    #[must_use]
    pub const fn from_bytes(bytes: [u8; DEVICE_ID_LEN]) -> Self {
        Self(bytes)
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let encoded = hex::encode(self.0);
        write!(
            formatter,
            "{}-{}-{}-{}-{}",
            &encoded[0..8],
            &encoded[8..12],
            &encoded[12..16],
            &encoded[16..20],
            &encoded[20..32]
        )
    }
}

impl fmt::Debug for DeviceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, formatter)
    }
}

/// A validated P-256 public key in the canonical 64-byte `X || Y` form.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct P256PublicKey([u8; P256_RAW_XY_LEN]);

impl P256PublicKey {
    /// Validates and constructs a public key from canonical `X || Y` bytes.
    ///
    /// # Errors
    ///
    /// Returns [`IdentityError::InvalidPublicKey`] when the bytes are not a
    /// valid P-256 curve point.
    pub fn from_raw_xy(raw_xy: [u8; P256_RAW_XY_LEN]) -> Result<Self, IdentityError> {
        let sec1 = sec1_uncompressed(&raw_xy);
        p256::PublicKey::from_sec1_bytes(&sec1)
            .map(|_| Self(raw_xy))
            .map_err(|_| IdentityError::InvalidPublicKey)
    }

    /// Returns the exact canonical 64-byte `X || Y` representation.
    #[must_use]
    pub const fn as_raw_xy(&self) -> &[u8; P256_RAW_XY_LEN] {
        &self.0
    }

    /// Verifies a SHA-256 ECDSA signature over `message`.
    ///
    /// # Errors
    ///
    /// Returns an identity error when the public key or signature is invalid.
    pub fn verify_der(
        &self,
        message: &[u8],
        signature: &DerEcdsaSignature,
    ) -> Result<(), IdentityError> {
        let verifying_key = VerifyingKey::from_sec1_bytes(&sec1_uncompressed(&self.0))
            .map_err(|_| IdentityError::InvalidPublicKey)?;
        let parsed = Signature::from_der(signature.as_bytes())
            .map_err(|_| IdentityError::InvalidSignature)?;
        verifying_key
            .verify(message, &parsed)
            .map_err(|_| IdentityError::InvalidSignature)
    }
}

/// A validated, minimally encoded ASN.1 DER ECDSA P-256 signature.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DerEcdsaSignature(Vec<u8>);

impl DerEcdsaSignature {
    /// Validates strict DER and rejects alternate encodings.
    ///
    /// # Errors
    ///
    /// Returns [`IdentityError::InvalidSignature`] for malformed or nonminimal
    /// DER.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, IdentityError> {
        let parsed = Signature::from_der(bytes).map_err(|_| IdentityError::InvalidSignature)?;
        let canonical = parsed.to_der();
        if canonical.as_bytes() != bytes {
            return Err(IdentityError::InvalidSignature);
        }
        Ok(Self(bytes.to_vec()))
    }

    /// Converts CNG's fixed-width `r || s` result into strict DER.
    ///
    /// # Errors
    ///
    /// Returns [`IdentityError::InvalidSignature`] when either scalar is not a
    /// valid P-256 signature scalar.
    pub fn from_fixed_width(raw: &[u8; 64]) -> Result<Self, IdentityError> {
        let parsed = Signature::from_slice(raw).map_err(|_| IdentityError::InvalidSignature)?;
        Self::from_bytes(parsed.to_der().as_bytes())
    }

    /// Returns the strict DER bytes.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

/// Errors produced by platform-neutral identity operations.
#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum IdentityError {
    /// A private test or platform key could not be constructed.
    #[error("invalid P-256 private key")]
    InvalidPrivateKey,
    /// Public key bytes did not encode a valid P-256 point.
    #[error("invalid P-256 public key")]
    InvalidPublicKey,
    /// Signature bytes were malformed or signature verification failed.
    #[error("invalid ECDSA signature")]
    InvalidSignature,
    /// The platform key provider could not sign the message.
    #[error("device identity signing failed")]
    SigningFailed,
}

/// Public identity operations implemented by a platform key provider.
pub trait DeviceIdentity: Send + Sync {
    /// Returns the stable signing public key.
    fn signing_public_key(&self) -> P256PublicKey;

    /// Returns the stable agreement public key.
    fn agreement_public_key(&self) -> P256PublicKey;

    /// Signs `message` with ECDSA P-256/SHA-256 and returns strict DER.
    ///
    /// # Errors
    ///
    /// Returns [`IdentityError::SigningFailed`] or a more specific bounded
    /// identity error when the platform key provider cannot sign.
    fn sign(&self, message: &[u8]) -> Result<DerEcdsaSignature, IdentityError>;

    /// Returns the stable ID derived only from the signing public key.
    fn device_id(&self) -> DeviceId {
        DeviceId::from_signing_public_key(&self.signing_public_key())
    }

    /// Returns the public metadata that must remain stable across restarts.
    fn metadata(&self) -> IdentityMetadata {
        IdentityMetadata {
            device_id: self.device_id(),
            signing_public_key: self.signing_public_key(),
            agreement_public_key: self.agreement_public_key(),
        }
    }
}

/// Public metadata persisted independently of platform private-key handles.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IdentityMetadata {
    device_id: DeviceId,
    signing_public_key: P256PublicKey,
    agreement_public_key: P256PublicKey,
}

impl IdentityMetadata {
    /// Reconstructs persisted metadata and verifies its device-ID binding.
    ///
    /// # Errors
    ///
    /// Returns [`IdentityMetadataError::DeviceIdMismatch`] when the ID is not
    /// derived from the exact signing-key bytes.
    pub fn from_parts(
        device_id: DeviceId,
        signing_public_key: P256PublicKey,
        agreement_public_key: P256PublicKey,
    ) -> Result<Self, IdentityMetadataError> {
        if device_id != DeviceId::from_signing_public_key(&signing_public_key) {
            return Err(IdentityMetadataError::DeviceIdMismatch);
        }
        Ok(Self {
            device_id,
            signing_public_key,
            agreement_public_key,
        })
    }

    /// Returns the device identifier.
    #[must_use]
    pub const fn device_id(&self) -> DeviceId {
        self.device_id
    }

    /// Returns the signing public key.
    #[must_use]
    pub const fn signing_public_key(&self) -> P256PublicKey {
        self.signing_public_key
    }

    /// Returns the agreement public key.
    #[must_use]
    pub const fn agreement_public_key(&self) -> P256PublicKey {
        self.agreement_public_key
    }
}

/// Bounded storage errors for public identity metadata.
#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum MetadataStoreError {
    /// Stored metadata is malformed or cannot be authenticated.
    #[error("identity metadata is corrupt")]
    Corrupt,
    /// The durable store is currently unavailable.
    #[error("identity metadata store is unavailable")]
    Unavailable,
}

/// Persistence boundary for public identity metadata.
pub trait IdentityMetadataStore: Send + Sync {
    /// Loads previously persisted metadata, if any.
    ///
    /// # Errors
    ///
    /// Returns a bounded storage error for corrupt or unavailable persistence.
    fn load(&self) -> Result<Option<IdentityMetadata>, MetadataStoreError>;

    /// Durably saves metadata before the identity is advertised.
    ///
    /// # Errors
    ///
    /// Returns a bounded storage error when durability cannot be established.
    fn save(&self, metadata: &IdentityMetadata) -> Result<(), MetadataStoreError>;
}

/// Errors enforcing the durable public-metadata contract.
#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum IdentityMetadataError {
    /// Persisted ID does not match its signing public key.
    #[error("persisted device ID does not match the signing public key")]
    DeviceIdMismatch,
    /// Platform key material changed without an explicit identity reset.
    #[error("platform identity does not match persisted metadata")]
    StoredIdentityMismatch,
    /// The metadata store failed.
    #[error(transparent)]
    Store(#[from] MetadataStoreError),
}

/// Persists first-use metadata and rejects silent key replacement thereafter.
///
/// # Errors
///
/// Returns a storage error or [`IdentityMetadataError::StoredIdentityMismatch`]
/// when the persisted identity differs.
pub fn persist_or_validate_metadata(
    store: &dyn IdentityMetadataStore,
    current: &IdentityMetadata,
) -> Result<(), IdentityMetadataError> {
    match store.load()? {
        None => store.save(current).map_err(IdentityMetadataError::from),
        Some(stored) if stored == *current => Ok(()),
        Some(_) => Err(IdentityMetadataError::StoredIdentityMismatch),
    }
}

fn sec1_uncompressed(raw_xy: &[u8; P256_RAW_XY_LEN]) -> [u8; P256_RAW_XY_LEN + 1] {
    let mut sec1 = [0_u8; P256_RAW_XY_LEN + 1];
    sec1[0] = 0x04;
    sec1[1..].copy_from_slice(raw_xy);
    sec1
}

mod trust;

pub use trust::{
    MAX_REVOKED_DEVICES, MAX_TRUST_STORE_JSON_BYTES, MAX_TRUSTED_DEVICES, TrustRecord, TrustStore,
    TrustStoreError,
};
