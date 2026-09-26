#![allow(clippy::expect_used, clippy::manual_let_else)]

use std::{collections::BTreeSet, fs, path::PathBuf};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use dropmesh_protocol::{
    ChunkCipher, Direction, PairingOffer, ProtocolError, SignedEnvelope, TransferFrame,
};
use serde::Deserialize;
use sha2::{Digest as _, Sha256};
use uuid::Uuid;

fn fixture(name: &str) -> Vec<u8> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .expect("crate remains under Windows/crates")
        .join("Protocol/fixtures");
    fs::read(root.join(name)).expect("frozen protocol fixture must exist")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransferFixture {
    version: u8,
    vectors: Vec<TransferVector>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransferVector {
    name: String,
    kind: String,
    wire_base64: String,
}

#[test]
fn transfer_frames_decode_and_reencode_exact_fixture_bytes() {
    let vectors: TransferFixture =
        serde_json::from_slice(&fixture("transfer-frames-v1.json")).expect("valid fixture file");
    assert_eq!(vectors.version, 1);

    for vector in vectors.vectors {
        let wire = STANDARD
            .decode(&vector.wire_base64)
            .expect("fixture base64");
        let frame = TransferFrame::decode(&wire).unwrap_or_else(|error| {
            panic!("{} failed to decode: {error}", vector.name);
        });
        assert_eq!(frame.kind_name(), vector.kind, "{}", vector.name);
        assert_eq!(
            frame.encode().expect("fixture re-encodes"),
            wire,
            "{}",
            vector.name
        );
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InvalidFixture {
    version: u8,
    vectors: Vec<InvalidVector>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InvalidVector {
    name: String,
    wire_base64: String,
    expected_error: String,
}

#[test]
fn invalid_transfer_fixtures_have_stable_rejections() {
    let vectors: InvalidFixture =
        serde_json::from_slice(&fixture("invalid-v1.json")).expect("valid fixture file");
    assert_eq!(vectors.version, 1);

    for vector in vectors.vectors {
        let wire = STANDARD
            .decode(&vector.wire_base64)
            .expect("fixture base64");
        let error = match TransferFrame::decode(&wire) {
            Ok(_) => panic!("{} unexpectedly decoded", vector.name),
            Err(error) => error,
        };
        assert_eq!(error.to_string(), vector.expected_error, "{}", vector.name);
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CipherFixture {
    version: u8,
    key_base64: String,
    #[serde(rename = "transferID")]
    transfer_id: Uuid,
    sequence: u64,
    direction: u8,
    nonce_epoch_base64: String,
    plaintext_base64: String,
    wire_base64: String,
}

#[test]
fn chunk_cipher_opens_and_seals_exact_fixture_wire() {
    let vector: CipherFixture =
        serde_json::from_slice(&fixture("chunk-cipher-v1.json")).expect("valid fixture file");
    assert_eq!(vector.version, 1);
    let key: [u8; 32] = STANDARD
        .decode(&vector.key_base64)
        .expect("key base64")
        .try_into()
        .expect("32-byte key");
    let epoch: [u8; 16] = STANDARD
        .decode(&vector.nonce_epoch_base64)
        .expect("epoch base64")
        .try_into()
        .expect("16-byte epoch");
    let plaintext = STANDARD
        .decode(&vector.plaintext_base64)
        .expect("plaintext base64");
    let expected_wire = STANDARD.decode(&vector.wire_base64).expect("wire base64");
    let direction = Direction::try_from(vector.direction).expect("known direction");
    let cipher = ChunkCipher::new(key);

    assert_eq!(
        cipher
            .open_wire(
                &expected_wire,
                vector.transfer_id,
                vector.sequence,
                direction,
            )
            .expect("fixture authenticates"),
        plaintext
    );
    assert_eq!(
        cipher
            .seal(
                &plaintext,
                vector.transfer_id,
                vector.sequence,
                direction,
                epoch,
            )
            .expect("fixture seals"),
        expected_wire
    );
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairingFixture {
    version: u8,
    wire_base64: String,
}

#[test]
fn pairing_offer_requires_the_frozen_canonical_json() {
    let vector: PairingFixture =
        serde_json::from_slice(&fixture("pairing-v1.json")).expect("valid fixture file");
    assert_eq!(vector.version, 1);
    let wire = STANDARD.decode(vector.wire_base64).expect("wire base64");
    let offer = PairingOffer::decode_canonical_json(&wire).expect("valid canonical pairing offer");
    assert_eq!(offer.encode_canonical_json().expect("encode offer"), wire);
    let digest = Sha256::digest(offer.host_identity_public_key());
    let expected_host_id = Uuid::from_bytes(digest[..16].try_into().expect("SHA-256 prefix"));
    assert_eq!(offer.host_id(), expected_host_id);

    let mut reordered: serde_json::Value = serde_json::from_slice(&wire).expect("fixture object");
    reordered["unexpected"] = serde_json::Value::Bool(true);
    let noncanonical = serde_json::to_vec(&reordered).expect("mutated JSON");
    assert_eq!(
        PairingOffer::decode_canonical_json(&noncanonical),
        Err(ProtocolError::InvalidPairingOffer)
    );
}

#[derive(Deserialize)]
struct SignedFixtureFile {
    fixtures: Vec<SignedFixture>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignedFixture {
    generated_by: String,
    #[serde(rename = "deviceID")]
    device_id: String,
    epoch_milliseconds: i64,
    nonce: String,
    payload: String,
    public_key: String,
    canonical_payload: String,
    signature: String,
}

#[test]
fn signed_envelope_fixtures_are_canonical_and_verify() {
    let vectors: SignedFixtureFile =
        serde_json::from_slice(&fixture("signed-envelope-v1.json")).expect("valid fixture file");
    assert_eq!(vectors.fixtures.len(), 2);

    let mut public_key_lengths = BTreeSet::new();
    for vector in vectors.fixtures {
        let envelope = SignedEnvelope::from_base64_fields(
            &vector.device_id,
            vector.epoch_milliseconds,
            &vector.nonce,
            &vector.payload,
            &vector.public_key,
            &vector.signature,
        )
        .expect("strict fixture fields");
        public_key_lengths.insert(envelope.public_key.len());
        assert_eq!(
            envelope.canonical_payload().expect("canonical payload"),
            STANDARD
                .decode(vector.canonical_payload)
                .expect("canonical base64")
        );
        envelope.verify().expect("P-256 signature verifies");
        let mut mismatched = envelope.clone();
        mismatched.device_id = Uuid::nil().to_string();
        assert_eq!(
            mismatched.verify(),
            Err(ProtocolError::InvalidSignedEnvelope),
            "{} exact wire key bytes must bind the device ID",
            vector.generated_by
        );
        let outer = envelope
            .encode_canonical_json()
            .expect("canonical signed envelope");
        let decoded = SignedEnvelope::decode_canonical_json(&outer).expect("strict outer JSON");
        assert_eq!(decoded, envelope);
        decoded.verify().expect("decoded signature verifies");
    }
    assert_eq!(public_key_lengths, BTreeSet::from([64, 65]));
}

#[test]
fn authenticated_boundaries_reject_tampering_and_oversize() {
    let vector: CipherFixture =
        serde_json::from_slice(&fixture("chunk-cipher-v1.json")).expect("valid fixture file");
    let key: [u8; 32] = STANDARD
        .decode(vector.key_base64)
        .expect("key base64")
        .try_into()
        .expect("32-byte key");
    let direction = Direction::try_from(vector.direction).expect("known direction");
    let mut wire = STANDARD.decode(vector.wire_base64).expect("wire base64");
    *wire.last_mut().expect("tag byte") ^= 1;
    assert_eq!(
        ChunkCipher::new(key).open_wire(&wire, vector.transfer_id, vector.sequence, direction,),
        Err(ProtocolError::AuthenticationFailed)
    );

    assert_eq!(
        TransferFrame::decode(&vec![0_u8; 65_537]),
        Err(ProtocolError::FrameTooLarge)
    );
}
