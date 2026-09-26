#![allow(clippy::unwrap_used)]

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use dropmesh_account::{AccountError, AccountGroupState, ApprovalDraft};
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

fn first_event() -> dropmesh_account::VerifiedEvent {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let bytes = fs::read(root.join("Protocol/fixtures/account-group-approval-v1.json")).unwrap();
    let fixtures: FixtureFile = serde_json::from_slice(&bytes).unwrap();
    ApprovalDraft::decode_json_strict(fixtures.fixtures[0].draft_json.as_bytes())
        .unwrap()
        .finalize_base64(&fixtures.fixtures[0].subject_signature)
        .unwrap()
}

#[test]
fn restored_state_applies_only_the_exact_next_verified_event() {
    let event = first_event();
    let actor = event.actor().clone();
    let subject = event.subject().clone();
    let mut members = BTreeMap::new();
    members.insert(actor.device_id.clone(), actor);
    let mut state = AccountGroupState::restore(
        event.account_id(),
        event.group_id(),
        event.generation(),
        event.sequence() - 1,
        event.previous_hash(),
        members,
    )
    .unwrap();

    state.apply(event.clone()).unwrap();
    assert_eq!(state.sequence(), 2);
    assert_eq!(state.member(&subject.device_id), Some(&subject));

    assert_eq!(
        state.apply(event).unwrap_err(),
        AccountError::InvalidTransition
    );
}

#[test]
fn restore_rejects_empty_or_inconsistent_state() {
    assert_eq!(
        AccountGroupState::restore("", "group", 1, 1, [0; 32], BTreeMap::new()).unwrap_err(),
        AccountError::InvalidState
    );

    let event = first_event();
    let mut members = BTreeMap::new();
    let mut actor = event.actor().clone();
    actor.device_id = "00000000-0000-0000-0000-000000000000".to_owned();
    members.insert(actor.device_id.clone(), actor);
    assert_eq!(
        AccountGroupState::restore(
            event.account_id(),
            event.group_id(),
            event.generation(),
            event.sequence() - 1,
            event.previous_hash(),
            members,
        )
        .unwrap_err(),
        AccountError::InvalidState
    );
}

#[test]
fn restore_rejects_sequence_that_cannot_advance_without_panicking() {
    let event = first_event();
    let actor = event.actor().clone();
    let mut members = BTreeMap::new();
    members.insert(actor.device_id.clone(), actor);

    let result = std::panic::catch_unwind(|| {
        AccountGroupState::restore(
            event.account_id(),
            event.group_id(),
            event.generation(),
            u64::MAX,
            event.previous_hash(),
            members,
        )
    });
    assert!(result.is_ok(), "restore must never panic");
    assert_eq!(result.unwrap().unwrap_err(), AccountError::InvalidState);
}
