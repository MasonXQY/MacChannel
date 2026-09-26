#![allow(clippy::expect_used, clippy::unwrap_used)]

use base64::{Engine as _, engine::general_purpose::STANDARD};
use dropmesh_identity::{DerEcdsaSignature, DeviceIdentity, IdentityError, P256PublicKey};
use dropmesh_protocol::SignedEnvelope;
use dropmesh_rendezvous::{
    AUTHENTICATION_PAYLOAD, Challenge, RendezvousError, SUBPROTOCOL, ServerFrame, decode_challenge,
    decode_server_frame, encode_authentication, encode_signal, encode_signed_http_body,
};
use p256::{
    SecretKey,
    ecdsa::{SigningKey, signature::Signer as _},
    elliptic_curve::sec1::ToSec1Point as _,
};

struct TestIdentity {
    signing: SigningKey,
    signing_public: P256PublicKey,
    agreement_public: P256PublicKey,
}

#[test]
fn signed_http_body_is_verifiable_and_keeps_the_exact_inner_payload() {
    let identity = TestIdentity::seeded(11);
    let payload = br#"{"accessToken":"token","audience":"com.zensystech.dropmesh","purpose":"dropmesh.account.group.discover.v1"}"#;
    let body = encode_signed_http_body(&identity, &[5; 32], payload, 1_800_000_000_000).unwrap();
    let envelope = SignedEnvelope::decode_canonical_json(&body).unwrap();
    envelope.verify().unwrap();
    assert_eq!(envelope.payload, payload);
    assert_eq!(envelope.nonce, [5; 32]);

    assert_eq!(
        encode_signed_http_body(&identity, &[5; 32], &[], 1_800_000_000_000),
        Err(RendezvousError::InvalidFrame)
    );
    assert_eq!(
        encode_signed_http_body(
            &identity,
            &[5; 32],
            &vec![0; 24 * 1_024 + 1],
            1_800_000_000_000
        ),
        Err(RendezvousError::FrameTooLarge)
    );
}

impl TestIdentity {
    fn seeded(seed: u8) -> Self {
        let secret = SecretKey::from_slice(&[seed; 32]).unwrap();
        let signing = SigningKey::from(secret.clone());
        let signing_raw: [u8; 64] = secret.public_key().to_sec1_point(false).as_bytes()[1..]
            .try_into()
            .unwrap();
        let agreement_secret = SecretKey::from_slice(&[seed + 1; 32]).unwrap();
        let agreement_raw: [u8; 64] = agreement_secret
            .public_key()
            .to_sec1_point(false)
            .as_bytes()[1..]
            .try_into()
            .unwrap();
        Self {
            signing,
            signing_public: P256PublicKey::from_raw_xy(signing_raw).unwrap(),
            agreement_public: P256PublicKey::from_raw_xy(agreement_raw).unwrap(),
        }
    }
}

impl DeviceIdentity for TestIdentity {
    fn signing_public_key(&self) -> P256PublicKey {
        self.signing_public
    }
    fn agreement_public_key(&self) -> P256PublicKey {
        self.agreement_public
    }
    fn sign(&self, message: &[u8]) -> Result<DerEcdsaSignature, IdentityError> {
        let signature: p256::ecdsa::Signature = self.signing.sign(message);
        DerEcdsaSignature::from_bytes(signature.to_der().as_bytes())
    }
}

#[test]
fn emits_the_existing_websocket_auth_contract_and_valid_signature() {
    assert_eq!(SUBPROTOCOL, "macchannel.auth.v1");
    assert_eq!(AUTHENTICATION_PAYLOAD, br#"{"type":"websocket-auth-v1"}"#);
    let identity = TestIdentity::seeded(7);
    let challenge = Challenge {
        nonce: [9; 32],
        expires_at_milliseconds: 1_800_000_030_000,
    };

    let bytes = encode_authentication(&identity, &challenge, 1_800_000_000_000).unwrap();
    let object: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        object.as_object().unwrap().keys().collect::<Vec<_>>(),
        ["envelope", "trustRecords"]
    );
    assert_eq!(object["trustRecords"], serde_json::json!([]));

    let envelope_bytes = serde_json::to_vec(&object["envelope"]).unwrap();
    let envelope = SignedEnvelope::decode_canonical_json(&envelope_bytes).unwrap();
    assert_eq!(envelope.nonce, challenge.nonce);
    assert_eq!(envelope.payload, AUTHENTICATION_PAYLOAD);
    assert_eq!(envelope.epoch_milliseconds, 1_800_000_000_000);
    envelope.verify().unwrap();
}

#[test]
fn challenge_is_strict_bounded_and_must_be_live() {
    let valid = serde_json::json!({
        "type": "challenge",
        "nonce": STANDARD.encode([3; 32]),
        "expiresAt": 1_800_000_030_000_i64,
    });
    let bytes = serde_json::to_vec(&valid).unwrap();
    assert_eq!(
        decode_challenge(&bytes, 1_800_000_000_000).unwrap(),
        Challenge {
            nonce: [3; 32],
            expires_at_milliseconds: 1_800_000_030_000
        }
    );

    for invalid in [
        br#"{"type":"challenge","nonce":"Aw==","expiresAt":1800000030000}"#.as_slice(),
        br#"{"type":"challenge","nonce":"Aw==","expiresAt":1800000030000,"extra":true}"#,
        br#"{"type":"challenge","nonce":"Aw==","nonce":"Aw==","expiresAt":1800000030000}"#,
        br#"{"type":"challenge","nonce":"Aw==","expiresAt":1799999999999}"#,
    ] {
        assert_eq!(
            decode_challenge(invalid, 1_800_000_000_000),
            Err(RendezvousError::InvalidFrame)
        );
    }
}

#[test]
fn decodes_presence_and_bounded_signal_without_accepting_ambiguous_json() {
    let device = "698bea63-dc44-a344-663f-f1429aea1084";
    assert_eq!(
        decode_server_frame(
            format!(r#"{{"type":"presence","deviceID":"{device}","availability":"internet"}}"#)
                .as_bytes()
        )
        .unwrap(),
        ServerFrame::Presence {
            device_id: device.to_owned(),
            online: true
        }
    );
    assert_eq!(
        decode_server_frame(
            format!(
                r#"{{"type":"signal","from":"{device}","payload":"{}"}}"#,
                STANDARD.encode(b"offer")
            )
            .as_bytes()
        )
        .unwrap(),
        ServerFrame::Signal {
            from: device.to_owned(),
            payload: b"offer".to_vec()
        }
    );

    let oversize = STANDARD.encode(vec![0; 65_537]);
    assert_eq!(
        decode_server_frame(
            format!(r#"{{"type":"signal","from":"{device}","payload":"{oversize}"}}"#).as_bytes()
        ),
        Err(RendezvousError::FrameTooLarge)
    );
    assert_eq!(
        decode_server_frame(format!(r#"{{"type":"presence","deviceID":"{device}","deviceID":"{device}","availability":"internet"}}"#).as_bytes()),
        Err(RendezvousError::InvalidFrame)
    );
}

#[test]
fn encodes_exact_signal_shape_and_enforces_target_and_payload_limits() {
    let target = "d07aeb13-4840-b152-42e1-2d4a06ce3ab4";
    assert_eq!(
        encode_signal(target, b"candidate").unwrap(),
        format!(
            r#"{{"payload":"{}","to":"{target}","type":"signal"}}"#,
            STANDARD.encode(b"candidate")
        )
        .into_bytes()
    );
    assert_eq!(
        encode_signal(target, &[]),
        Err(RendezvousError::InvalidFrame)
    );
    assert_eq!(
        encode_signal(target, &vec![0; 65_537]),
        Err(RendezvousError::FrameTooLarge)
    );
    assert_eq!(
        encode_signal("NOT-A-UUID", b"x"),
        Err(RendezvousError::InvalidFrame)
    );
}
