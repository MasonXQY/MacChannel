#![allow(clippy::expect_used, clippy::unwrap_used)]

use base64::{Engine as _, engine::general_purpose::STANDARD};
use dropmesh_account::{
    AccountDiscovery, AccountError, AccountGroupPage, encode_discovery_request,
    encode_history_request,
};
use p256::{
    SecretKey,
    ecdsa::{SigningKey, signature::Signer as _},
    elliptic_curve::sec1::ToSec1Point as _,
};
use sha2::{Digest as _, Sha256};

const ACCOUNT: &str = "11111111-1111-1111-1111-111111111111";
const GROUP: &str = "22222222-2222-2222-2222-222222222222";
const TOKEN: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

#[test]
fn discovery_request_is_exact_and_rejects_ambient_credentials() {
    assert_eq!(
        encode_discovery_request("com.zensystech.dropmesh", TOKEN).unwrap(),
        br#"{"accessToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","audience":"com.zensystech.dropmesh","purpose":"dropmesh.account.group.discover.v1"}"#
    );
    for (audience, token) in [
        ("", TOKEN),
        ("com.example. app", TOKEN),
        ("com.example.app", "short"),
        (
            "com.example.app",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA+",
        ),
    ] {
        assert_eq!(
            encode_discovery_request(audience, token),
            Err(AccountError::InvalidWire)
        );
    }
}

fn device_id(public_key: &[u8]) -> String {
    let hex = hex::encode(&Sha256::digest(public_key)[..16]);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

fn bootstrap_wire() -> (String, [u8; 32]) {
    let secret = SecretKey::from_slice(&[23; 32]).unwrap();
    let signing = SigningKey::from(secret.clone());
    let public_key = secret.public_key().to_sec1_point(false).as_bytes()[1..].to_vec();
    let device = device_id(&public_key);
    let payload = format!(
        "{{\"accountID\":\"{ACCOUNT}\",\"action\":\"bootstrap\",\"actorDeviceID\":\"{device}\",\"actorPublicKey\":\"{}\",\"epochMilliseconds\":1800000000000,\"generation\":1,\"groupID\":\"{GROUP}\",\"previousHash\":\"\",\"purpose\":\"dropmesh.account.group.event.v1\",\"sequence\":1,\"subjectDeviceID\":\"{device}\",\"subjectPublicKey\":\"{}\"}}",
        STANDARD.encode(&public_key),
        STANDARD.encode(&public_key)
    );
    let signature: p256::ecdsa::Signature = signing.sign(payload.as_bytes());
    let wire = format!(
        "{{\"payload\":\"{}\",\"signature\":\"{}\",\"subjectSignature\":\"\"}}",
        STANDARD.encode(payload.as_bytes()),
        STANDARD.encode(signature.to_der().as_bytes())
    );
    let digest = Sha256::digest(payload.as_bytes()).into();
    (wire, digest)
}

fn present_response(anchor: &str, digest: [u8; 32]) -> String {
    let hash = STANDARD.encode(digest);
    format!(
        "{{\"status\":\"present\",\"groupID\":\"{GROUP}\",\"generation\":1,\"anchor\":{anchor},\"anchorHash\":\"{hash}\",\"headSequence\":1,\"headHash\":\"{hash}\"}}"
    )
}

fn history_response(anchor: &str, digest: [u8; 32]) -> String {
    let hash = STANDARD.encode(digest);
    format!(
        "{{\"groupID\":\"{GROUP}\",\"generation\":1,\"headSequence\":1,\"headHash\":\"{hash}\",\"afterSequence\":0,\"nextSequence\":1,\"hasMore\":false,\"events\":[{anchor}]}}"
    )
}

#[test]
fn decodes_absent_and_strictly_verified_present_discovery() {
    assert_eq!(
        AccountDiscovery::decode_json_strict(br#"{"status":"absent"}"#, ACCOUNT).unwrap(),
        AccountDiscovery::Absent
    );

    let (anchor, digest) = bootstrap_wire();
    let discovery =
        AccountDiscovery::decode_json_strict(present_response(&anchor, digest).as_bytes(), ACCOUNT)
            .unwrap();
    let AccountDiscovery::Present(metadata) = discovery else {
        panic!("present discovery expected");
    };
    assert_eq!(metadata.group_id(), GROUP);
    assert_eq!(metadata.generation(), 1);
    assert_eq!(metadata.anchor().action(), "bootstrap");
    assert_eq!(metadata.anchor_hash(), digest);
    assert_eq!(metadata.head_sequence(), 1);
    assert_eq!(metadata.head_hash(), digest);
}

#[test]
fn rejects_ambiguous_or_inconsistently_bound_discovery() {
    let (anchor, digest) = bootstrap_wire();
    let valid = present_response(&anchor, digest);
    assert_eq!(
        AccountDiscovery::decode_json_strict(
            valid.as_bytes(),
            "33333333-3333-3333-3333-333333333333",
        ),
        Err(AccountError::InvalidWire)
    );
    let wrong_hash = valid.replacen(&STANDARD.encode(digest), &STANDARD.encode([9; 32]), 1);
    let duplicate = valid.replacen('{', "{\"status\":\"present\",", 1);
    let unknown = valid.replacen('{', "{\"extra\":true,", 1);
    let duplicate_anchor_field =
        valid.replacen("{\"payload\":", "{\"payload\":\"\",\"payload\":", 1);
    for (name, invalid) in [
        ("wrong hash", wrong_hash),
        ("duplicate", duplicate),
        ("unknown", unknown),
        ("duplicate anchor field", duplicate_anchor_field),
    ] {
        assert_eq!(
            AccountDiscovery::decode_json_strict(invalid.as_bytes(), ACCOUNT),
            Err(AccountError::InvalidWire),
            "{name}",
        );
    }
}

#[test]
fn history_request_and_initial_page_are_exact_and_chain_verified() {
    assert_eq!(
        encode_history_request("com.zensystech.dropmesh", TOKEN, GROUP, 0, None).unwrap(),
        format!(
            "{{\"accessToken\":\"{TOKEN}\",\"afterSequence\":\"0\",\"audience\":\"com.zensystech.dropmesh\",\"expectedHeadHash\":\"\",\"groupID\":\"{GROUP}\",\"purpose\":\"dropmesh.account.group.events.v1\"}}"
        )
        .into_bytes()
    );
    assert_eq!(
        encode_history_request("com.zensystech.dropmesh", TOKEN, GROUP, 1, None),
        Err(AccountError::InvalidWire)
    );

    let (anchor, digest) = bootstrap_wire();
    let page = AccountGroupPage::decode_json_strict(
        history_response(&anchor, digest).as_bytes(),
        ACCOUNT,
        GROUP,
        0,
        None,
        None,
    )
    .unwrap();
    assert_eq!(page.generation(), 1);
    assert_eq!(page.head_sequence(), 1);
    assert_eq!(page.head_hash(), digest);
    assert_eq!(page.after_sequence(), 0);
    assert_eq!(page.next_sequence(), 1);
    assert!(!page.has_more());
    assert_eq!(page.events().len(), 1);
    assert_eq!(page.events()[0].digest(), digest);
}

#[test]
fn history_page_rejects_empty_ambiguous_or_inconsistent_chains() {
    let (anchor, digest) = bootstrap_wire();
    let valid = history_response(&anchor, digest);
    let hash = STANDARD.encode(digest);
    for (name, invalid) in [
        ("empty events", valid.replace(&format!("[{anchor}]"), "[]")),
        (
            "wrong next",
            valid.replace("\"nextSequence\":1", "\"nextSequence\":0"),
        ),
        (
            "wrong head",
            valid.replace(&hash, &STANDARD.encode([4; 32])),
        ),
        ("duplicate", valid.replacen('{', "{\"groupID\":\"x\",", 1)),
        ("unknown", valid.replacen('{', "{\"extra\":true,", 1)),
    ] {
        assert_eq!(
            AccountGroupPage::decode_json_strict(invalid.as_bytes(), ACCOUNT, GROUP, 0, None, None,),
            Err(AccountError::InvalidWire),
            "{name}"
        );
    }
}
