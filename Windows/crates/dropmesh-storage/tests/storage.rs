#![allow(clippy::unwrap_used)]

use std::fs;

#[cfg(windows)]
use dropmesh_storage::StorageError;
use dropmesh_storage::{
    EntryKind, PathEntry, ReceiveRequest, RelativePath, Store, TransferState, validate_path_batch,
};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use uuid::Uuid;

fn request(id: Uuid, display_name: &str, kind: EntryKind) -> ReceiveRequest<'_> {
    request_with_size(id, display_name, kind, 11)
}

fn request_with_size(
    id: Uuid,
    display_name: &str,
    kind: EntryKind,
    total_bytes: u64,
) -> ReceiveRequest<'_> {
    ReceiveRequest {
        id,
        peer_id: "peer-a",
        display_name,
        kind,
        total_bytes,
    }
}

#[test]
fn history_and_preparation_survive_reopen() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("state/history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();

    let staging_path = {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request(id, "notes.txt", EntryKind::File))
            .unwrap();
        fs::write(&prepared.staging_path, b"hello").unwrap();
        store.record_progress(id, 5).unwrap();
        prepared.staging_path
    };

    let mut reopened = Store::open(&database, &receive_root).unwrap();
    let record = reopened.transfer(id).unwrap().unwrap();
    assert_eq!(record.state, TransferState::Interrupted);
    assert_eq!(record.completed_bytes, 5);
    assert_eq!(record.display_name, "notes.txt");
    assert_eq!(reopened.history(10).unwrap(), vec![record]);

    let resumed = reopened
        .prepare_receive(request(id, "notes.txt", EntryKind::File))
        .unwrap();
    assert_eq!(resumed.staging_path, staging_path);
    assert_eq!(fs::read(resumed.staging_path).unwrap(), b"hello");
}

#[test]
fn interrupted_staging_is_never_published_under_final_name() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();

    {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request(id, "draft.txt", EntryKind::File))
            .unwrap();
        fs::write(prepared.staging_path, b"partial").unwrap();
    }

    let reopened = Store::open(&database, &receive_root).unwrap();
    assert!(!receive_root.join("draft.txt").exists());
    assert_eq!(
        reopened.transfer(id).unwrap().unwrap().state,
        TransferState::Interrupted
    );
}

#[cfg(unix)]
#[test]
fn restart_fails_closed_when_interrupted_tree_contains_a_symlink() {
    use std::os::unix::fs::symlink;

    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();

    {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request(id, "Project", EntryKind::Directory))
            .unwrap();
        symlink(temp.path(), prepared.staging_path.join("escape")).unwrap();
    }

    let reopened = Store::open(&database, &receive_root).unwrap();
    assert_eq!(
        reopened.transfer(id).unwrap().unwrap().state,
        TransferState::Failed
    );
    assert!(!receive_root.join("Project").exists());
}

#[test]
fn rejects_traversal_absolute_and_windows_escape_paths() {
    for invalid in [
        "",
        ".",
        "..",
        "../secret",
        "folder/../../secret",
        "/absolute",
        r"C:\absolute",
        r"\\server\share",
        r"folder\..\secret",
        "safe//empty",
        "file.txt:stream",
        "invalid?.txt",
        "invalid|name",
        "name. ",
        "CON.txt",
        "COM\u{b9}.txt",
        "com\u{b2}",
        "COM\u{b3}.log",
        "LPT\u{b9}",
        "lpt\u{b2}.txt",
        "LPT\u{b3}.log",
        "LONGFI~1.TXT",
        "ab12cd~9.bin",
    ] {
        assert!(
            RelativePath::parse(invalid).is_err(),
            "accepted {invalid:?}"
        );
    }

    let safe = RelativePath::parse("資料/2026/report.txt").unwrap();
    assert_eq!(
        safe.as_path(),
        std::path::Path::new("資料").join("2026").join("report.txt")
    );
}

#[cfg(windows)]
#[test]
fn windows_short_name_probe_rejects_an_alias_when_the_volume_provides_one() {
    let temp = TempDir::new().unwrap();
    let long_name = "LongFilenameForEightDotThreeProbe.txt";
    let long_path = temp.path().join(long_name);
    fs::write(&long_path, b"probe").unwrap();
    let short_path = temp.path().join("LONGFI~1.TXT");
    if !short_path.exists() {
        eprintln!("skipped: this Windows volume did not materialize the probed 8.3 alias");
        return;
    }

    assert_eq!(
        fs::canonicalize(&short_path).unwrap(),
        fs::canonicalize(&long_path).unwrap()
    );
    assert!(RelativePath::parse("LONGFI~1.TXT").is_err());
}

#[cfg(windows)]
#[test]
fn windows_file_identity_rejects_two_names_for_one_staged_object() {
    let temp = TempDir::new().unwrap();
    let mut store = Store::open(
        temp.path().join("history.sqlite3"),
        temp.path().join("received"),
    )
    .unwrap();
    let id = Uuid::new_v4();
    let prepared = store
        .prepare_receive(request_with_size(id, "Project", EntryKind::Directory, 8))
        .unwrap();
    let first = prepared.staging_path.join("first.txt");
    let second = prepared.staging_path.join("second.txt");
    fs::write(&first, b"12345678").unwrap();
    fs::hard_link(&first, &second).unwrap();

    assert!(matches!(
        store.record_progress(id, 8),
        Err(StorageError::PathCollision)
    ));
}

#[test]
fn directory_staging_accepts_only_validated_relative_paths() {
    let temp = TempDir::new().unwrap();
    let mut store = Store::open(
        temp.path().join("history.sqlite3"),
        temp.path().join("received"),
    )
    .unwrap();
    let id = Uuid::new_v4();
    store
        .prepare_receive(request(id, "Project", EntryKind::Directory))
        .unwrap();

    let path = store
        .staged_path(id, &RelativePath::parse("docs/readme.txt").unwrap())
        .unwrap();
    fs::write(&path, b"read me").unwrap();
    assert_eq!(fs::read(path).unwrap(), b"read me");
}

#[test]
fn batch_paths_reject_windows_case_unicode_and_file_prefix_aliases() {
    let upper = RelativePath::parse("Docs/A.txt").unwrap();
    let lower = RelativePath::parse("docs/a.TXT").unwrap();
    assert!(
        validate_path_batch(&[
            PathEntry {
                path: &upper,
                kind: EntryKind::File,
            },
            PathEntry {
                path: &lower,
                kind: EntryKind::File,
            },
        ])
        .is_err()
    );

    let composed = RelativePath::parse("caf\u{e9}.txt").unwrap();
    let decomposed = RelativePath::parse("cafe\u{301}.txt").unwrap();
    assert!(
        validate_path_batch(&[
            PathEntry {
                path: &composed,
                kind: EntryKind::File,
            },
            PathEntry {
                path: &decomposed,
                kind: EntryKind::File,
            },
        ])
        .is_err()
    );

    let compatibility = RelativePath::parse("\u{ff2b}.txt").unwrap();
    let ascii = RelativePath::parse("K.txt").unwrap();
    assert!(
        validate_path_batch(&[
            PathEntry {
                path: &compatibility,
                kind: EntryKind::File,
            },
            PathEntry {
                path: &ascii,
                kind: EntryKind::File,
            },
        ])
        .is_err()
    );

    let file = RelativePath::parse("folder").unwrap();
    let child = RelativePath::parse("folder/child.txt").unwrap();
    assert!(
        validate_path_batch(&[
            PathEntry {
                path: &file,
                kind: EntryKind::File,
            },
            PathEntry {
                path: &child,
                kind: EntryKind::File,
            },
        ])
        .is_err()
    );
}

#[test]
fn commit_uses_collision_safe_names_without_overwriting() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    fs::create_dir_all(&receive_root).unwrap();
    fs::write(receive_root.join("report.txt"), b"original").unwrap();
    fs::write(receive_root.join("report (1).txt"), b"another").unwrap();

    let id = Uuid::new_v4();
    let mut store = Store::open(&database, &receive_root).unwrap();
    let prepared = store
        .prepare_receive(request(id, "report.txt", EntryKind::File))
        .unwrap();
    fs::write(&prepared.staging_path, b"new payload").unwrap();
    store.record_progress(id, 11).unwrap();

    let committed = store.commit_receive(id).unwrap();
    assert_eq!(
        committed,
        fs::canonicalize(&receive_root)
            .unwrap()
            .join("report (2).txt")
    );
    assert_eq!(
        fs::read(receive_root.join("report.txt")).unwrap(),
        b"original"
    );
    assert_eq!(fs::read(committed).unwrap(), b"new payload");
    assert_eq!(
        store.transfer(id).unwrap().unwrap().state,
        TransferState::Completed
    );
}

#[test]
fn commit_treats_windows_case_alias_as_a_collision_on_case_sensitive_hosts() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    fs::create_dir_all(&receive_root).unwrap();
    fs::write(receive_root.join("REPORT.TXT"), b"original").unwrap();

    let id = Uuid::new_v4();
    let mut store = Store::open(&database, &receive_root).unwrap();
    let prepared = store
        .prepare_receive(request(id, "report.txt", EntryKind::File))
        .unwrap();
    fs::write(&prepared.staging_path, b"new payload").unwrap();
    store.record_progress(id, 11).unwrap();

    let committed = store.commit_receive(id).unwrap();
    assert_eq!(
        committed.file_name().unwrap().to_string_lossy(),
        "report (1).txt"
    );
    assert_eq!(
        fs::read(receive_root.join("REPORT.TXT")).unwrap(),
        b"original"
    );
}

#[test]
fn commit_treats_unicode_canonical_alias_as_a_collision() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    fs::create_dir_all(&receive_root).unwrap();
    fs::write(receive_root.join("cafe\u{301}.txt"), b"original").unwrap();

    let id = Uuid::new_v4();
    let mut store = Store::open(&database, &receive_root).unwrap();
    let prepared = store
        .prepare_receive(request_with_size(id, "caf\u{e9}.txt", EntryKind::File, 3))
        .unwrap();
    fs::write(&prepared.staging_path, b"new").unwrap();
    store.record_progress(id, 3).unwrap();

    let committed = store.commit_receive(id).unwrap();
    assert_eq!(
        committed.file_name().unwrap().to_string_lossy(),
        "caf\u{e9} (1).txt"
    );
    assert_eq!(
        fs::read(receive_root.join("cafe\u{301}.txt")).unwrap(),
        b"original"
    );
}

#[test]
fn restart_finishes_database_record_after_atomic_publish() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();

    let final_path = {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request_with_size(id, "ready.txt", EntryKind::File, 8))
            .unwrap();
        fs::write(&prepared.staging_path, b"complete").unwrap();
        store.record_progress(id, 8).unwrap();
        let final_path = receive_root.join("ready.txt");
        let digest = Sha256::digest(b"complete");
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute(
                "UPDATE transfers
                 SET state = 'committing', final_name = 'ready.txt',
                     expected_payload_size = 8, expected_payload_sha256 = ?2
                 WHERE id = ?1",
                rusqlite::params![id.to_string(), digest.as_slice()],
            )
            .unwrap();
        final_path
    };
    let staging_payload = receive_root
        .join(".dropmesh-staging")
        .join(id.to_string())
        .join("payload");
    fs::rename(staging_payload, &final_path).unwrap();

    let reopened = Store::open(&database, &receive_root).unwrap();
    let record = reopened.transfer(id).unwrap().unwrap();
    assert_eq!(record.state, TransferState::Completed);
    let canonical_final = fs::canonicalize(&final_path).unwrap();
    assert_eq!(
        record.final_path.as_deref(),
        Some(canonical_final.as_path())
    );
    assert_eq!(fs::read(final_path).unwrap(), b"complete");
}

#[test]
fn restart_fails_closed_when_final_payload_does_not_match_commit_identity() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();

    let final_path = {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request_with_size(id, "ready.txt", EntryKind::File, 8))
            .unwrap();
        fs::write(&prepared.staging_path, b"complete").unwrap();
        store.record_progress(id, 8).unwrap();
        let digest = Sha256::digest(b"complete");
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute(
                "UPDATE transfers
                 SET state = 'committing', final_name = 'ready.txt',
                     expected_payload_size = 8, expected_payload_sha256 = ?2
                 WHERE id = ?1",
                rusqlite::params![id.to_string(), digest.as_slice()],
            )
            .unwrap();
        receive_root.join("ready.txt")
    };
    let staging_payload = receive_root
        .join(".dropmesh-staging")
        .join(id.to_string())
        .join("payload");
    fs::remove_file(staging_payload).unwrap();
    fs::write(&final_path, b"tampered").unwrap();

    let reopened = Store::open(&database, &receive_root).unwrap();
    let record = reopened.transfer(id).unwrap().unwrap();
    assert_eq!(record.state, TransferState::Failed);
    assert_eq!(fs::read(final_path).unwrap(), b"tampered");
}

#[test]
fn restart_fails_closed_when_commit_identity_is_missing() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();

    {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request_with_size(id, "ready.txt", EntryKind::File, 8))
            .unwrap();
        fs::write(&prepared.staging_path, b"complete").unwrap();
        store.record_progress(id, 8).unwrap();
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute(
                "UPDATE transfers
                 SET state = 'committing', final_name = 'ready.txt'
                 WHERE id = ?1",
                [id.to_string()],
            )
            .unwrap();
    }
    let staging_payload = receive_root
        .join(".dropmesh-staging")
        .join(id.to_string())
        .join("payload");
    fs::rename(staging_payload, receive_root.join("ready.txt")).unwrap();

    let reopened = Store::open(&database, &receive_root).unwrap();
    assert_eq!(
        reopened.transfer(id).unwrap().unwrap().state,
        TransferState::Failed
    );
}

#[test]
fn restart_does_not_mistake_a_raced_collision_for_our_publish() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();

    let staging_path = {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request_with_size(id, "raced.txt", EntryKind::File, 4))
            .unwrap();
        fs::write(&prepared.staging_path, b"ours").unwrap();
        store.record_progress(id, 4).unwrap();
        let digest = Sha256::digest(b"ours");
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute(
                "UPDATE transfers
                 SET state = 'committing', final_name = 'raced.txt',
                     expected_payload_size = 4, expected_payload_sha256 = ?2
                 WHERE id = ?1",
                rusqlite::params![id.to_string(), digest.as_slice()],
            )
            .unwrap();
        prepared.staging_path
    };
    fs::write(receive_root.join("raced.txt"), b"someone else").unwrap();

    let mut reopened = Store::open(&database, &receive_root).unwrap();
    assert_eq!(
        reopened.transfer(id).unwrap().unwrap().state,
        TransferState::Failed
    );
    assert_eq!(fs::read(&staging_path).unwrap(), b"ours");
    assert_eq!(
        fs::read(receive_root.join("raced.txt")).unwrap(),
        b"someone else"
    );

    assert!(reopened.commit_receive(id).is_err());
}

#[test]
fn cancel_cleans_staging_and_persists_state() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();
    let staging = {
        let mut store = Store::open(&database, &receive_root).unwrap();
        let prepared = store
            .prepare_receive(request(id, "cancel.txt", EntryKind::File))
            .unwrap();
        fs::write(&prepared.staging_path, b"partial").unwrap();
        store.cancel_receive(id).unwrap();
        prepared.staging_path
    };

    assert!(!staging.exists());
    let reopened = Store::open(&database, &receive_root).unwrap();
    assert_eq!(
        reopened.transfer(id).unwrap().unwrap().state,
        TransferState::Cancelled
    );
    assert!(!receive_root.join("cancel.txt").exists());
}

#[test]
fn commit_failure_is_recorded_and_never_publishes_a_final_file() {
    let temp = TempDir::new().unwrap();
    let database = temp.path().join("history.sqlite3");
    let receive_root = temp.path().join("received");
    let id = Uuid::new_v4();
    let mut store = Store::open(&database, &receive_root).unwrap();
    let prepared = store
        .prepare_receive(request(id, "missing.txt", EntryKind::File))
        .unwrap();
    store.record_progress(id, 11).unwrap();
    fs::remove_file(prepared.staging_path).unwrap();

    assert!(store.commit_receive(id).is_err());
    assert!(!receive_root.join("missing.txt").exists());
    assert_eq!(
        store.transfer(id).unwrap().unwrap().state,
        TransferState::Failed
    );
}

#[test]
fn progress_failure_does_not_corrupt_the_last_durable_value() {
    let temp = TempDir::new().unwrap();
    let mut store = Store::open(
        temp.path().join("history.sqlite3"),
        temp.path().join("received"),
    )
    .unwrap();
    let id = Uuid::new_v4();
    store
        .prepare_receive(request(id, "bounded.txt", EntryKind::File))
        .unwrap();
    store.record_progress(id, 7).unwrap();

    assert!(store.record_progress(id, 12).is_err());
    assert!(store.record_progress(id, 6).is_err());
    let record = store.transfer(id).unwrap().unwrap();
    assert_eq!(record.completed_bytes, 7);
    assert_eq!(record.state, TransferState::Receiving);
}
