use std::error::Error;

use dropmesh_identity::{
    DeviceId, MAX_TRUST_STORE_JSON_BYTES, MAX_TRUSTED_DEVICES, P256PublicKey, TrustRecord,
    TrustStore, TrustStoreError,
};
use p256::ecdsa::SigningKey;

#[test]
fn record_binds_device_id_and_rejects_duplicates_and_key_changes() -> Result<(), Box<dyn Error>> {
    let signing = public_key(1)?;
    let agreement = public_key(2)?;
    let device_id = DeviceId::from_signing_public_key(&signing);
    let record = TrustRecord::new(device_id, signing, agreement)?;
    let mut store = TrustStore::new();

    store.authorize(record.clone())?;
    assert_eq!(
        store.authorize(record),
        Err(TrustStoreError::DuplicateDevice)
    );

    let changed_agreement = TrustRecord::new(device_id, signing, public_key(3)?)?;
    assert_eq!(
        store.authorize(changed_agreement),
        Err(TrustStoreError::KeyChanged)
    );

    let wrong_id = DeviceId::from_signing_public_key(&public_key(4)?);
    assert_eq!(
        TrustRecord::new(wrong_id, signing, agreement),
        Err(TrustStoreError::DeviceIdMismatch)
    );
    Ok(())
}

#[test]
fn revocation_and_active_records_survive_restart_serialization() -> Result<(), Box<dyn Error>> {
    let revoked = record(10, 11)?;
    let retained = record(20, 21)?;
    let revoked_id = revoked.device_id();
    let mut store = TrustStore::new();
    store.authorize(revoked.clone())?;
    store.authorize(retained.clone())?;
    store.revoke(revoked_id)?;

    let encoded = store.to_json()?;
    let mut restored = TrustStore::from_json(&encoded)?;

    assert!(restored.is_revoked(revoked_id));
    assert!(restored.get(revoked_id).is_none());
    assert_eq!(restored.get(retained.device_id()), Some(&retained));
    assert_eq!(
        restored.authorize(revoked),
        Err(TrustStoreError::RevokedDevice)
    );
    Ok(())
}

#[test]
fn persistence_rejects_unknown_fields_duplicates_and_broken_bindings() -> Result<(), Box<dyn Error>>
{
    let trusted = record(30, 31)?;
    let mut store = TrustStore::new();
    store.authorize(trusted)?;
    let encoded = String::from_utf8(store.to_json()?)?;

    let with_unknown = encoded.replacen("{\"version\":1", "{\"unknown\":true,\"version\":1", 1);
    assert_eq!(
        TrustStore::from_json(with_unknown.as_bytes()),
        Err(TrustStoreError::CorruptPersistence)
    );

    let value: serde_json::Value = serde_json::from_str(&encoded)?;
    let first = value["records"][0].clone();
    let duplicate = serde_json::json!({
        "version": 1,
        "records": [first.clone(), first],
        "revoked": []
    });
    assert_eq!(
        TrustStore::from_json(&serde_json::to_vec(&duplicate)?),
        Err(TrustStoreError::DuplicateDevice)
    );

    let mut broken = value;
    broken["records"][0]["device_id"] =
        serde_json::Value::String(DeviceId::from_signing_public_key(&public_key(40)?).to_string());
    assert_eq!(
        TrustStore::from_json(&serde_json::to_vec(&broken)?),
        Err(TrustStoreError::DeviceIdMismatch)
    );
    Ok(())
}

#[test]
fn active_trust_is_bounded() -> Result<(), Box<dyn Error>> {
    let mut store = TrustStore::new();
    for index in 1..=MAX_TRUSTED_DEVICES {
        let signing = u16::try_from(index + 100)?;
        let agreement = u16::try_from(index + 500)?;
        store.authorize(record(signing, agreement)?)?;
    }

    assert_eq!(
        store.authorize(record(1_500, 1_501)?),
        Err(TrustStoreError::CapacityExceeded)
    );
    Ok(())
}

#[test]
fn oversized_restart_state_is_rejected_before_parsing() {
    let oversized = vec![b' '; MAX_TRUST_STORE_JSON_BYTES + 1];
    assert_eq!(
        TrustStore::from_json(&oversized),
        Err(TrustStoreError::CorruptPersistence)
    );
}

fn record(signing: u16, agreement: u16) -> Result<TrustRecord, TrustStoreError> {
    let signing = public_key(signing).map_err(|_| TrustStoreError::InvalidPublicKey)?;
    let agreement = public_key(agreement).map_err(|_| TrustStoreError::InvalidPublicKey)?;
    TrustRecord::new(
        DeviceId::from_signing_public_key(&signing),
        signing,
        agreement,
    )
}

fn public_key(scalar: u16) -> Result<P256PublicKey, Box<dyn Error>> {
    let mut raw = [0_u8; 32];
    raw[30..].copy_from_slice(&scalar.to_be_bytes());
    let signing = SigningKey::from_bytes((&raw).into())?;
    let encoded = signing.verifying_key().to_sec1_point(false);
    let mut raw_xy = [0_u8; 64];
    raw_xy.copy_from_slice(&encoded.as_bytes()[1..]);
    Ok(P256PublicKey::from_raw_xy(raw_xy)?)
}
