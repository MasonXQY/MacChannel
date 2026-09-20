package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountgroup"
)

func pendingDatabase(t *testing.T) (string, *sql.DB) {
	t.Helper()
	return guardedGroupDatabase(t)
}

func TestPendingExactRoutes(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		calls := 0
		handler := newServiceMux(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(204) }), func(context.Context) error { return nil }, enabled)
		for _, op := range []string{"create", "get", "list", "propose", "countersign", "commit", "cancel", "reject"} {
			path := "/v1/account/group/join/" + op
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, httptest.NewRequest("POST", path, nil))
			want := 404
			if enabled {
				want = 204
			}
			if w.Code != want {
				t.Fatal(op, w.Code)
			}
			w = httptest.NewRecorder()
			handler.ServeHTTP(w, httptest.NewRequest("POST", path+"/unknown", nil))
			if w.Code != 404 {
				t.Fatal("prefix route")
			}
		}
		want := 0
		if enabled {
			want = 8
		}
		if calls != want {
			t.Fatal(calls)
		}
		for _, path := range []string{"/healthz", "/v1/account/login/challenge"} {
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
			if w.Code != 200 && w.Code != 204 {
				t.Fatal("legacy route changed")
			}
		}
	}
}

func hidePendingSchema(db *sql.DB) (func() error, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`ALTER TABLE account_group_pending RENAME TO account_group_pending_schema_test`); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return func() error {
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if _, err = tx.Exec(`ALTER TABLE account_group_pending_schema_test RENAME TO account_group_pending`); err != nil {
			return err
		}
		return tx.Commit()
	}, nil
}
func TestPendingSchemaRequiredOnlyWhenEnabled(t *testing.T) {
	dsn, db := pendingDatabase(t)
	restore, err := hidePendingSchema(db)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := restore(); err != nil {
			t.Error(err)
		}
	})
	for _, enabled := range []bool{false, true} {
		h, closeDB, err := buildService(context.Background(), groupAssemblyConfig(t, dsn, enabled))
		if closeDB != nil {
			closeDB()
		}
		if enabled {
			if err == nil || h != nil {
				t.Fatal("missing pending schema accepted")
			}
		} else if err != nil || h == nil {
			t.Fatal("login-only requires pending schema")
		}
	}
}
func TestPendingSchemaCleanupRegression(t *testing.T) {
	_, db := pendingDatabase(t)
	if os.Getenv("DROPMESH_PENDING_SCHEMA_CHILD") == "1" {
		restore, err := hidePendingSchema(db)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if err := restore(); err != nil {
				t.Error(err)
			}
		})
		t.Fatal("intentional pending schema assertion failure")
	}
	command := exec.Command(os.Args[0], "-test.run=^TestPendingSchemaCleanupRegression$", "-test.count=1")
	command.Env = append(os.Environ(), "DROPMESH_PENDING_SCHEMA_CHILD=1")
	output, err := command.CombinedOutput()
	if err == nil || !bytes.Contains(output, []byte("intentional pending schema assertion failure")) {
		t.Fatal("cleanup regression did not execute")
	}
	var present, hidden bool
	if err := db.QueryRow(`SELECT to_regclass('public.account_group_pending') IS NOT NULL,to_regclass('public.account_group_pending_schema_test') IS NOT NULL`).Scan(&present, &hidden); err != nil || !present || hidden {
		t.Fatal("schema restoration failed")
	}
}

type pendingSQLDevice struct {
	identity               groupTestIdentity
	family, session, token string
}

func seedPendingDevice(t *testing.T, db *sql.DB, account string) pendingSQLDevice {
	t.Helper()
	d := pendingSQLDevice{identity: newGroupTestIdentity(t), family: newGroupTestIdentity(t).deviceID, session: newGroupTestIdentity(t).deviceID}
	raw := make([]byte, 32)
	rand.Read(raw)
	hash := sha256.Sum256(raw)
	d.token = base64.RawURLEncoding.EncodeToString(raw)
	refresh := make([]byte, 32)
	rand.Read(refresh)
	if _, err := db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,'com.example.dropmesh',clock_timestamp(),clock_timestamp()+interval '90 days')`, d.family, account, d.identity.deviceID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,clock_timestamp(),clock_timestamp()+interval '15 minutes',clock_timestamp()+interval '1 day')`, d.session, d.family, hash[:], refresh); err != nil {
		t.Fatal(err)
	}
	return d
}
func seedPendingAccount(t *testing.T, db *sql.DB) string {
	t.Helper()
	account := newGroupTestIdentity(t).deviceID
	t.Cleanup(func() { cleanPendingAccount(t, db, account) })
	if _, err := db.Exec(`INSERT INTO accounts(account_id,apple_subject,status,created_at) VALUES($1,$2,'active',clock_timestamp())`, account, "pending-http-synthetic:"+account); err != nil {
		t.Fatal(err)
	}
	return account
}
func cleanPendingAccount(t *testing.T, db *sql.DB, account string) {
	t.Helper()
	for _, query := range []string{
		`DELETE FROM auth_replay_nonces WHERE device_id IN (SELECT device_id FROM account_session_families WHERE account_id=$1)`,
		`DELETE FROM account_group_pending WHERE account_id=$1`, `DELETE FROM account_group_events WHERE account_id=$1`, `DELETE FROM account_groups WHERE account_id=$1`,
		`DELETE FROM account_sessions WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1)`,
		`DELETE FROM account_session_families WHERE account_id=$1`, `DELETE FROM accounts WHERE account_id=$1`,
	} {
		if _, err := db.Exec(query, account); err != nil {
			t.Error("scoped cleanup", err)
		}
	}
}

func TestPendingSQLRoundTripRestartAndRotation(t *testing.T) {
	dsn, db := pendingDatabase(t)
	account := seedPendingAccount(t, db)
	actor, subject := seedPendingDevice(t, db, account), seedPendingDevice(t, db, account)
	foreignAccount := seedPendingAccount(t, db)
	foreign := seedPendingDevice(t, db, foreignAccount)
	groupID, requestID := newGroupTestIdentity(t).deviceID, newGroupTestIdentity(t).deviceID
	// A different account and its session are live throughout the pending flow;
	// scoped cleanup must preserve them until their own registered cleanup runs.
	cfg := groupAssemblyConfig(t, dsn, true)
	handler, closeDB, err := buildService(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { closeDB() }()
	anchor, wire := signedBootstrap(t, actor.identity, account, groupID)
	w := serveGroupRequest(t, handler, actor.identity, "/v1/account/group/bootstrap", map[string]string{"purpose": "dropmesh.account.group.bootstrap.v1", "audience": cfg.audience, "accessToken": actor.token, "confirmation": "join_this_device", "event": wire})
	if w.Code != 200 {
		t.Fatal("bootstrap", w.Code)
	}
	call := func(device pendingSQLDevice, op, id string, extra map[string]string) *httptest.ResponseRecorder {
		fields := map[string]string{"purpose": "dropmesh.account.group.join." + op + ".v1", "audience": cfg.audience, "accessToken": device.token}
		if op != "list" {
			fields["requestID"] = id
		}
		for k, v := range extra {
			fields[k] = v
		}
		return serveGroupRequest(t, handler, device.identity, "/v1/account/group/join/"+op, fields)
	}
	require := func(w *httptest.ResponseRecorder, status int) {
		t.Helper()
		if w.Code != status {
			t.Fatalf("pending HTTP status=%d want=%d body=%s", w.Code, status, w.Body.String())
		}
	}
	create := func(device pendingSQLDevice, id string) {
		require(call(device, "create", id, map[string]string{"groupID": groupID, "generation": "1", "publicKey": base64.StdEncoding.EncodeToString(device.identity.public)}), 200)
	}
	members := func(want int) {
		t.Helper()
		store, _ := accountgroup.NewPostgresStore(db)
		events, err := store.Events(context.Background(), accountgroup.Actor{AccountID: account, DeviceID: actor.identity.deviceID}, groupID)
		if err != nil {
			t.Fatal(err)
		}
		hash, _ := events[0].Digest()
		state, err := accountgroup.NewState(events[0], account, groupID, 1, hash)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range events[1:] {
			if err := state.Apply(e); err != nil {
				t.Fatal(err)
			}
		}
		if len(state.Snapshot().Members) != want || len(events) != want {
			t.Fatal("membership/event count", len(state.Snapshot().Members), len(events), want)
		}
	}
	create(subject, requestID)
	require(call(subject, "get", requestID, nil), 200)
	require(call(actor, "list", "", nil), 200)
	members(1)
	require(call(foreign, "get", requestID, nil), 409)
	foreignList := call(foreign, "list", "", nil)
	if foreignList.Code == 200 {
		if bytes.Contains(foreignList.Body.Bytes(), []byte(requestID)) {
			t.Fatal("foreign list leak")
		}
	} else {
		require(foreignList, 409)
	}
	propose := func(device pendingSQLDevice, id string, previous accountgroup.Event, sequence uint64) (accountgroup.Event, string) {
		t.Helper()
		head, _ := previous.Digest()
		e := accountgroup.Event{AccountID: account, GroupID: groupID, Generation: 1, Sequence: sequence, PreviousHash: head[:], Action: accountgroup.ActionApprove, ActorDeviceID: actor.identity.deviceID, ActorPublicKey: actor.identity.public, SubjectDeviceID: device.identity.deviceID, SubjectPublicKey: device.identity.public, EpochMilliseconds: time.Now().UnixMilli()}
		payload, err := e.CanonicalPayload()
		if err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(payload)
		e.Signature, err = ecdsa.SignASN1(rand.Reader, actor.identity.key, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		draft, err := accountgroup.NewApprovalDraft(e)
		if err != nil {
			t.Fatal(err)
		}
		wire, _ := accountgroup.EncodeWireApprovalDraft(draft)
		raw, _ := json.Marshal(wire)
		require(call(actor, "propose", id, map[string]string{"draft": base64.StdEncoding.EncodeToString(raw)}), 200)
		e.SubjectSignature, err = ecdsa.SignASN1(rand.Reader, device.identity.key, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		return e, base64.StdEncoding.EncodeToString(digest[:])
	}
	final, digest := propose(subject, requestID, anchor, 2)
	members(1)
	require(call(subject, "countersign", requestID, map[string]string{"draftHash": digest, "subjectSignature": base64.StdEncoding.EncodeToString(final.SubjectSignature)}), 200)
	members(1)
	receipt := call(actor, "commit", requestID, map[string]string{"draftHash": digest})
	require(receipt, 200)
	members(2)
	closeDB()
	handler, closeDB, err = buildService(context.Background(), cfg)
	if err != nil {
		closeDB = func() {}
		t.Fatal(err)
	}
	retry := call(actor, "commit", requestID, map[string]string{"draftHash": digest})
	require(retry, 200)
	if !bytes.Equal(receipt.Body.Bytes(), retry.Body.Bytes()) {
		t.Fatal("restart changed durable receipt")
	}
	members(2)
	// A third device is unfinished when its exact original session is replaced.
	unfinished := seedPendingDevice(t, db, account)
	secondID := newGroupTestIdentity(t).deviceID
	create(unfinished, secondID)
	next, nextHash := propose(unfinished, secondID, final, 3)
	require(call(unfinished, "countersign", secondID, map[string]string{"draftHash": nextHash, "subjectSignature": base64.StdEncoding.EncodeToString(next.SubjectSignature)}), 200)
	if _, err := db.Exec(`UPDATE account_sessions SET session_id=$1 WHERE session_id=$2`, newGroupTestIdentity(t).deviceID, unfinished.session); err != nil {
		t.Fatal(err)
	}
	rotated := call(actor, "commit", secondID, map[string]string{"draftHash": nextHash})
	require(rotated, 200)
	var response struct{ Request struct{ Status string } }
	if json.Unmarshal(rotated.Body.Bytes(), &response) != nil || response.Request.Status != "invalidated" {
		t.Fatal("rotated consent not invalidated")
	}
	members(2)
	cleanPendingAccount(t, db, account)
	var sentinel int
	if err := db.QueryRow(`SELECT count(*) FROM accounts a JOIN account_session_families f USING(account_id) JOIN account_sessions s USING(family_id) WHERE a.account_id=$1`, foreignAccount).Scan(&sentinel); err != nil || sentinel != 1 {
		t.Fatal("foreign sentinel modified")
	}
}
