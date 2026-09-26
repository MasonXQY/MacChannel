use std::error::Error;
use std::sync::Mutex;

use dropmesh_identity::{
    DerEcdsaSignature, DeviceIdentity, IdentityError, IdentityMetadata, IdentityMetadataError,
    IdentityMetadataStore, MetadataStoreError, P256PublicKey, persist_or_validate_metadata,
};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};

struct InMemoryIdentity {
    signing: SigningKey,
    signing_public: P256PublicKey,
    agreement_public: P256PublicKey,
}

impl InMemoryIdentity {
    fn fixed() -> Result<Self, IdentityError> {
        let signing = signing_key(1)?;
        let agreement = signing_key(2)?;
        Ok(Self {
            signing_public: public_key(&signing)?,
            agreement_public: public_key(&agreement)?,
            signing,
        })
    }
}

impl DeviceIdentity for InMemoryIdentity {
    fn signing_public_key(&self) -> P256PublicKey {
        self.signing_public
    }

    fn agreement_public_key(&self) -> P256PublicKey {
        self.agreement_public
    }

    fn sign(&self, message: &[u8]) -> Result<DerEcdsaSignature, IdentityError> {
        let signature: Signature = self.signing.sign(message);
        DerEcdsaSignature::from_bytes(signature.to_der().as_bytes())
    }
}

#[derive(Default)]
struct InMemoryMetadataStore {
    value: Mutex<Option<IdentityMetadata>>,
}

impl IdentityMetadataStore for InMemoryMetadataStore {
    fn load(&self) -> Result<Option<IdentityMetadata>, MetadataStoreError> {
        self.value
            .lock()
            .map(|value| value.clone())
            .map_err(|_| MetadataStoreError::Unavailable)
    }

    fn save(&self, metadata: &IdentityMetadata) -> Result<(), MetadataStoreError> {
        let mut value = self
            .value
            .lock()
            .map_err(|_| MetadataStoreError::Unavailable)?;
        *value = Some(metadata.clone());
        Ok(())
    }
}

#[test]
fn stable_public_material_drives_metadata_and_device_id() -> Result<(), Box<dyn Error>> {
    let identity = InMemoryIdentity::fixed()?;
    let first = identity.metadata();
    let second = identity.metadata();

    assert_eq!(first, second);
    assert_eq!(first.device_id(), identity.device_id());
    assert_eq!(first.signing_public_key(), identity.signing_public_key());
    assert_eq!(
        first.agreement_public_key(),
        identity.agreement_public_key()
    );
    assert_ne!(first.signing_public_key(), first.agreement_public_key());
    Ok(())
}

#[test]
fn signatures_are_strict_der_and_verify_with_the_public_key() -> Result<(), Box<dyn Error>> {
    let identity = InMemoryIdentity::fixed()?;
    let message = b"dropmesh identity contract";
    let signature = identity.sign(message)?;

    identity
        .signing_public_key()
        .verify_der(message, &signature)?;
    assert!(
        identity
            .signing_public_key()
            .verify_der(b"changed", &signature)
            .is_err()
    );
    assert!(DerEcdsaSignature::from_bytes(&[0x30, 0x00]).is_err());
    Ok(())
}

#[test]
fn metadata_is_created_once_then_must_match_exactly() -> Result<(), Box<dyn Error>> {
    let store = InMemoryMetadataStore::default();
    let first = InMemoryIdentity::fixed()?;

    persist_or_validate_metadata(&store, &first.metadata())?;
    persist_or_validate_metadata(&store, &first.metadata())?;

    let different = InMemoryIdentity {
        signing: signing_key(3)?,
        signing_public: public_key(&signing_key(3)?)?,
        agreement_public: public_key(&signing_key(4)?)?,
    };
    assert_eq!(
        persist_or_validate_metadata(&store, &different.metadata()),
        Err(IdentityMetadataError::StoredIdentityMismatch)
    );
    Ok(())
}

fn signing_key(last_byte: u8) -> Result<SigningKey, IdentityError> {
    let mut raw = [0_u8; 32];
    raw[31] = last_byte;
    SigningKey::from_bytes((&raw).into()).map_err(|_| IdentityError::InvalidPrivateKey)
}

fn public_key(signing_key: &SigningKey) -> Result<P256PublicKey, IdentityError> {
    let encoded = signing_key.verifying_key().to_sec1_point(false);
    let mut raw = [0_u8; 64];
    raw.copy_from_slice(&encoded.as_bytes()[1..]);
    P256PublicKey::from_raw_xy(raw)
}
