#![allow(clippy::expect_used)]

use base64::{Engine as _, engine::general_purpose::STANDARD};
use dropmesh_protocol::{
    Chunk, ChunkCoordinate, ChunkRange, Direction, EntryKind, MAX_CHUNK_BYTES,
    MAX_FRAME_PLAINTEXT_BYTES, MAX_MANIFEST_ENTRIES, MAX_PAIRING_OFFER_JSON_BYTES,
    MAX_SIGNED_ENVELOPE_JSON_BYTES, MAX_SIGNED_ENVELOPE_PAYLOAD_BYTES, MAX_TRANSFER_CHUNKS,
    ManifestEntry, PairingOffer, ProtocolError, RelativePath, ResumeMap, SignedEnvelope,
    TransferFrame, TransferManifest, UnverifiedPairingOffer,
};
use p256::{SecretKey, elliptic_curve::sec1::ToSec1Point as _};
use sha2::{Digest as _, Sha256};
use uuid::Uuid;

fn valid_raw_public_key(seed: u8) -> [u8; 64] {
    let secret = SecretKey::from_slice(&[seed; 32]).expect("valid nonzero scalar");
    secret.public_key().to_sec1_point(false).as_bytes()[1..]
        .try_into()
        .expect("uncompressed P-256 coordinates")
}

fn device_id(key: &[u8]) -> Uuid {
    let digest = Sha256::digest(key);
    Uuid::from_bytes(digest[..16].try_into().expect("SHA-256 prefix"))
}

#[test]
fn relative_paths_require_safe_nfc_forward_slash_form() {
    assert_eq!(
        RelativePath::new("folder/file.txt").map(|path| path.as_str().to_owned()),
        Ok("folder/file.txt".to_owned())
    );
    for unsafe_path in [
        "",
        "/absolute",
        "../escape",
        "folder/./file",
        "folder//file",
        "C:/Windows/file",
        r"folder\file",
        "cafe\u{301}.txt",
        "nul\0byte",
    ] {
        assert_eq!(
            RelativePath::new(unsafe_path),
            Err(ProtocolError::InvalidRelativePath),
            "{unsafe_path:?}"
        );
    }
    assert!(RelativePath::new("caf\u{e9}.txt").is_ok());
}

#[test]
fn resume_ranges_are_canonicalized_but_wire_decode_is_strict() {
    let canonical = ResumeMap::new(vec![
        ChunkRange::new(0, 2, 4).expect("range"),
        ChunkRange::new(0, 0, 2).expect("range"),
    ])
    .expect("canonical map");
    assert_eq!(
        canonical.ranges,
        vec![ChunkRange::new(0, 0, 4).expect("range")]
    );

    assert_eq!(
        ChunkRange::new(
            u32::try_from(MAX_MANIFEST_ENTRIES).expect("limit fits"),
            0,
            1,
        ),
        Err(ProtocolError::InvalidResumeMap)
    );
    assert_eq!(
        ChunkRange::new(0, 0, MAX_TRANSFER_CHUNKS + 1),
        Err(ProtocolError::InvalidResumeMap)
    );
}

#[test]
fn chunk_and_plaintext_limits_are_inclusive() {
    let coordinate = ChunkCoordinate {
        entry_index: 0,
        chunk_index: 0,
    };
    assert!(Chunk::new(coordinate, 0, vec![0; MAX_CHUNK_BYTES]).is_ok());
    assert_eq!(
        Chunk::new(coordinate, 0, vec![0; MAX_CHUNK_BYTES + 1]),
        Err(ProtocolError::InvalidChunk)
    );

    let cipher = dropmesh_protocol::ChunkCipher::new([7; 32]);
    let wire = cipher
        .seal(
            &vec![0; MAX_FRAME_PLAINTEXT_BYTES],
            Uuid::nil(),
            0,
            Direction::SenderToReceiver,
            [9; 16],
        )
        .expect("maximum plaintext seals");
    assert_eq!(wire.len(), dropmesh_protocol::MAX_WIRE_FRAME_BYTES);
    assert_eq!(
        cipher.seal(
            &vec![0; MAX_FRAME_PLAINTEXT_BYTES + 1],
            Uuid::nil(),
            0,
            Direction::SenderToReceiver,
            [9; 16],
        ),
        Err(ProtocolError::FrameTooLarge)
    );
}

#[test]
fn transfer_decoder_never_accepts_truncation_or_trailing_data() {
    for wire in [vec![], vec![1], vec![1, 3], vec![1, 9, 0]] {
        assert_eq!(
            TransferFrame::decode(&wire),
            Err(ProtocolError::InvalidFrame)
        );
    }
    assert_eq!(
        TransferFrame::decode(&[1, 5, 0]),
        Err(ProtocolError::InvalidFrame)
    );
}

#[test]
fn pairing_offer_rejects_noncanonical_uuid_and_base64_spellings() {
    let identity_key = valid_raw_public_key(1);
    let offer = PairingOffer::new(
        "123456".to_owned(),
        1_700_000_300_123,
        device_id(&identity_key),
        identity_key,
        valid_raw_public_key(2),
        "host".to_owned(),
        [0; 32],
    )
    .expect("valid pairing offer");
    let canonical = offer.encode_canonical_json().expect("encode");
    assert_eq!(
        PairingOffer::decode_canonical_json(&canonical).expect("canonical offer"),
        offer
    );

    let uppercase_host_id = offer.host_id().to_string().to_uppercase();
    let lowercase_uuid = String::from_utf8(canonical)
        .expect("utf8")
        .replace(&uppercase_host_id, &uppercase_host_id.to_lowercase());
    assert_eq!(
        PairingOffer::decode_canonical_json(lowercase_uuid.as_bytes()),
        Err(ProtocolError::InvalidPairingOffer)
    );
}

#[test]
fn json_boundaries_and_signed_payload_are_bounded_before_use() {
    assert_eq!(
        UnverifiedPairingOffer::decode_canonical_json(&vec![
            b' ';
            MAX_PAIRING_OFFER_JSON_BYTES + 1
        ]),
        Err(ProtocolError::InvalidPairingOffer)
    );
    assert_eq!(
        SignedEnvelope::decode_canonical_json(&vec![b' '; MAX_SIGNED_ENVELOPE_JSON_BYTES + 1]),
        Err(ProtocolError::InvalidSignedEnvelope)
    );

    let oversized_payload = STANDARD.encode(vec![0x5a; MAX_SIGNED_ENVELOPE_PAYLOAD_BYTES + 1]);
    assert_eq!(
        SignedEnvelope::from_base64_fields(
            "00112233-4455-6677-8899-aabbccddeeff",
            1,
            "AA==",
            &oversized_payload,
            &STANDARD.encode([0; 64]),
            "AQ==",
        ),
        Err(ProtocolError::InvalidSignedEnvelope)
    );
}

#[test]
fn usable_pairing_offer_rejects_invalid_p256_coordinates() {
    let wire = UnverifiedPairingOffer {
        code: "123456".to_owned(),
        expires_at_milliseconds: 1_700_000_300_123,
        host_id: Uuid::parse_str("00112233-4455-6677-8899-aabbccddeeff").expect("uuid"),
        host_identity_public_key: [0; 64],
        host_ephemeral_public_key: valid_raw_public_key(2),
        host_display_name: "host".to_owned(),
        challenge: [0; 32],
    }
    .encode_canonical_json()
    .expect("structurally valid pairing wire");

    assert_eq!(
        PairingOffer::decode_canonical_json(&wire),
        Err(ProtocolError::InvalidPairingOffer)
    );
}

#[test]
fn manifest_rejects_windows_aliases_and_file_prefixes_in_one_batch() {
    let entry = |path: &str| {
        ManifestEntry::new(
            RelativePath::new(path).expect("relative path"),
            EntryKind::File,
            0,
            0.0,
            0,
            [0; 32],
        )
        .expect("valid empty file")
    };

    assert_eq!(
        TransferManifest::new(
            Uuid::nil(),
            vec![entry("Folder/A.txt"), entry("folder/a.TXT")],
        ),
        Err(ProtocolError::InvalidFrame)
    );
    assert_eq!(
        TransferManifest::new(
            Uuid::nil(),
            vec![entry("Folder/A.txt"), entry("folder/B.txt")],
        ),
        Err(ProtocolError::InvalidFrame),
        "one logical Windows directory must use one spelling"
    );
    assert_eq!(
        TransferManifest::new(Uuid::nil(), vec![entry("K.txt"), entry("Ｋ.txt")]),
        Err(ProtocolError::InvalidFrame),
        "NFKC-equivalent names must collide"
    );
    assert_eq!(
        TransferManifest::new(
            Uuid::nil(),
            vec![entry("folder"), entry("folder/child.txt")],
        ),
        Err(ProtocolError::InvalidFrame),
        "a file cannot also be a parent directory"
    );
}
