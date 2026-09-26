#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::fs;
use std::path::PathBuf;

use dropmesh_account::{AccountError, ApprovalDraft};
use serde::Deserialize;

#[derive(Deserialize)]
struct FixtureFile {
    fixtures: Vec<Fixture>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    canonical_payload: String,
    #[serde(rename = "draftJSON")]
    draft_json: String,
    finalized_digest: String,
    subject_signature: String,
}

fn fixture() -> FixtureFile {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let bytes = fs::read(root.join("Protocol/fixtures/account-group-approval-v1.json"))
        .expect("fixture must be readable");
    serde_json::from_slice(&bytes).expect("fixture must decode")
}

#[test]
fn verifies_swift_go_approval_vectors_and_exact_digest() {
    let vectors = fixture();
    assert_eq!(vectors.fixtures.len(), 2);

    for vector in vectors.fixtures {
        let draft = ApprovalDraft::decode_json_strict(vector.draft_json.as_bytes())
            .expect("actor proof must verify");
        assert_eq!(draft.canonical_payload_base64(), vector.canonical_payload);
        assert_eq!(draft.encode_json(), vector.draft_json.as_bytes());

        let finalized = draft
            .finalize_base64(&vector.subject_signature)
            .expect("subject proof must verify");
        assert_eq!(hex::encode(finalized.digest()), vector.finalized_digest);
    }
}

#[test]
fn rejects_noncanonical_and_ambiguous_draft_json() {
    let original = &fixture().fixtures[0].draft_json;
    let parsed: serde_json::Value = serde_json::from_str(original).expect("fixture JSON");
    let duplicate = original.replacen('{', "{\"payload\":\"\",", 1);
    let unknown = original.replacen('{', "{\"extra\":\"\",", 1);
    let trailing = format!("{original}{{}}");
    let trailing_whitespace = format!("{original} ");
    let reversed = format!(
        "{{\"signature\":{},\"payload\":{}}}",
        serde_json::to_string(&parsed["signature"]).expect("signature string"),
        serde_json::to_string(&parsed["payload"]).expect("payload string")
    );

    for bytes in [
        duplicate.as_bytes(),
        unknown.as_bytes(),
        trailing.as_bytes(),
        trailing_whitespace.as_bytes(),
        reversed.as_bytes(),
    ] {
        assert_eq!(
            ApprovalDraft::decode_json_strict(bytes).unwrap_err(),
            AccountError::InvalidWire
        );
    }
}

#[test]
fn rejects_wrong_or_missing_subject_proof() {
    let vector = &fixture().fixtures[0];
    let draft = ApprovalDraft::decode_json_strict(vector.draft_json.as_bytes()).unwrap();
    assert_eq!(
        draft.finalize_base64("").unwrap_err(),
        AccountError::InvalidProof
    );
    assert_eq!(
        draft.finalize_base64("AQ==").unwrap_err(),
        AccountError::InvalidProof
    );
}
