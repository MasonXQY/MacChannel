#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::{fs, path::PathBuf};

use dropmesh_account::{AccountError, VerifiedEvent};
use serde::Deserialize;

#[derive(Deserialize)]
struct FixtureFile {
    fixtures: Vec<Fixture>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    #[serde(rename = "draftJSON")]
    draft_json: String,
    subject_signature: String,
}

fn fixture() -> FixtureFile {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let bytes = fs::read(root.join("Protocol/fixtures/account-group-approval-v1.json"))
        .expect("fixture must be readable");
    serde_json::from_slice(&bytes).expect("fixture must decode")
}

fn finalized_wire(vector: &Fixture) -> String {
    let draft: serde_json::Value = serde_json::from_str(&vector.draft_json).unwrap();
    format!(
        "{{\"payload\":{},\"signature\":{},\"subjectSignature\":{}}}",
        serde_json::to_string(draft["payload"].as_str().unwrap()).unwrap(),
        serde_json::to_string(draft["signature"].as_str().unwrap()).unwrap(),
        serde_json::to_string(&vector.subject_signature).unwrap(),
    )
}

#[test]
fn decodes_the_finalized_swift_go_event_and_verifies_both_signatures() {
    for vector in fixture().fixtures {
        let event = VerifiedEvent::decode_json_strict(finalized_wire(&vector).as_bytes()).unwrap();
        assert_eq!(event.action(), "approve");
        assert_eq!(event.sequence(), 2);
        assert_eq!(event.previous_hash(), [0x42; 32]);
    }
}

#[test]
fn rejects_duplicate_unknown_reordered_or_tampered_event_wire() {
    let vector = &fixture().fixtures[0];
    let valid = finalized_wire(vector);
    let parsed: serde_json::Value = serde_json::from_str(&valid).unwrap();
    let duplicate = valid.replacen('{', "{\"payload\":\"\",", 1);
    let unknown = valid.replacen('{', "{\"extra\":\"\",", 1);
    let reordered = format!(
        "{{\"signature\":{},\"payload\":{},\"subjectSignature\":{}}}",
        serde_json::to_string(&parsed["signature"]).unwrap(),
        serde_json::to_string(&parsed["payload"]).unwrap(),
        serde_json::to_string(&parsed["subjectSignature"]).unwrap(),
    );
    let mut tampered: serde_json::Value = parsed;
    tampered["subjectSignature"] = serde_json::Value::String("AQ==".to_owned());
    for invalid in [duplicate, unknown, reordered] {
        assert_eq!(
            VerifiedEvent::decode_json_strict(invalid.as_bytes()).unwrap_err(),
            AccountError::InvalidWire
        );
    }
    assert_eq!(
        VerifiedEvent::decode_json_strict(serde_json::to_string(&tampered).unwrap().as_bytes())
            .unwrap_err(),
        AccountError::InvalidProof
    );
}
