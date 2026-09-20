package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

func guardedGroupDatabase(t *testing.T) (string, *sql.DB) {
	t.Helper()
	dsn := os.Getenv("DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("SQL group assembly skipped: set isolated DROPMESH_ACCOUNT_TEST_DATABASE_URL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal("open isolated database")
	}
	t.Cleanup(func() { _ = db.Close() })
	var name string
	var local bool
	if err := db.QueryRow(`SELECT current_database(), inet_server_addr() IS NULL`).Scan(&name, &local); err != nil || name != "dropmesh_account_auth_test" || !local {
		t.Fatal("requires isolated named database over Unix socket")
	}
	return dsn, db
}

func groupAssemblyConfig(t *testing.T, dsn string, enabled bool) config {
	t.Helper()
	return config{enabled: true, groupsEnabled: enabled, teamID: "ABCDEFGHIJ", keyID: "KLMNOPQRST", audience: "com.example.dropmesh", addr: "127.0.0.1:18080", applePrivateKey: testPKCS8(t), credentialKey: make([]byte, 32), databaseDSN: dsn}
}

func TestGroupAssemblyRequiresSchemaOnlyWhenEnabled(t *testing.T) {
	dsn, db := guardedGroupDatabase(t)
	restore, err := hideGroupSchema(db)
	if err != nil {
		t.Fatal("hide group schema")
	}
	t.Cleanup(func() {
		if err := restore(); err != nil {
			t.Errorf("restore group schema: %v", err)
		}
	})
	plain, closePlain, err := buildService(context.Background(), groupAssemblyConfig(t, dsn, false))
	if err != nil || plain == nil || closePlain == nil {
		t.Fatalf("disabled groups build = %v", err)
	}
	closePlain()
	grouped, closeGrouped, err := buildService(context.Background(), groupAssemblyConfig(t, dsn, true))
	if closeGrouped != nil {
		closeGrouped()
	}
	if err == nil || grouped != nil || err.Error() != errStartup.Error() {
		t.Fatalf("enabled groups without schema = handler=%v close=%v error=%v", grouped, closeGrouped != nil, err)
	}
}

func hideGroupSchema(db *sql.DB) (func() error, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	rollback := func(cause error) (func() error, error) {
		if rollbackErr := tx.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) {
			return nil, errors.Join(cause, rollbackErr)
		}
		return nil, cause
	}
	if _, err := tx.Exec(`ALTER TABLE account_group_events RENAME TO account_group_events_schema_test`); err != nil {
		return rollback(err)
	}
	if _, err := tx.Exec(`ALTER TABLE account_groups RENAME TO account_groups_schema_test`); err != nil {
		return rollback(err)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return func() error {
		restore, err := db.Begin()
		if err != nil {
			return err
		}
		fail := func(cause error) error {
			if rollbackErr := restore.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) {
				return errors.Join(cause, rollbackErr)
			}
			return cause
		}
		if _, err := restore.Exec(`ALTER TABLE account_groups_schema_test RENAME TO account_groups`); err != nil {
			return fail(err)
		}
		if _, err := restore.Exec(`ALTER TABLE account_group_events_schema_test RENAME TO account_group_events`); err != nil {
			return fail(err)
		}
		return restore.Commit()
	}, nil
}

func TestGroupAssemblySchemaCleanupRegression(t *testing.T) {
	_, db := guardedGroupDatabase(t)
	if os.Getenv("DROPMESH_SCHEMA_CLEANUP_CHILD") == "1" {
		restore, err := hideGroupSchema(db)
		if err != nil {
			t.Fatal("child hide schema")
		}
		t.Cleanup(func() {
			if err := restore(); err != nil {
				t.Errorf("child restore schema: %v", err)
			}
		})
		t.Fatal("intentional assertion failure after schema rename")
	}
	t.Run("partial rename rolls back", func(t *testing.T) {
		if _, err := db.Exec(`CREATE TABLE account_groups_schema_test(marker INTEGER)`); err != nil {
			t.Fatal("create collision")
		}
		t.Cleanup(func() {
			if _, err := db.Exec(`DROP TABLE IF EXISTS account_groups_schema_test`); err != nil {
				t.Errorf("drop collision: %v", err)
			}
		})
		if restore, err := hideGroupSchema(db); err == nil || restore != nil {
			t.Fatal("partial rename unexpectedly succeeded")
		}
		assertGroupSchemaPresent(t, db)
		var temporary bool
		if err := db.QueryRow(`SELECT to_regclass('public.account_group_events_schema_test') IS NOT NULL`).Scan(&temporary); err != nil || temporary {
			t.Fatalf("partial event rename remained: %v %v", temporary, err)
		}
	})
	command := exec.Command(os.Args[0], "-test.run=^TestGroupAssemblySchemaCleanupRegression$", "-test.count=1")
	command.Env = append(os.Environ(), "DROPMESH_SCHEMA_CLEANUP_CHILD=1")
	if output, err := command.CombinedOutput(); err == nil || !bytes.Contains(output, []byte("intentional assertion failure")) {
		t.Fatalf("cleanup child result err=%v output=%s", err, output)
	}
	assertGroupSchemaPresent(t, db)
}

func assertGroupSchemaPresent(t *testing.T, db *sql.DB) {
	t.Helper()
	var groups, events bool
	if err := db.QueryRow(`SELECT to_regclass('public.account_groups') IS NOT NULL,to_regclass('public.account_group_events') IS NOT NULL`).Scan(&groups, &events); err != nil || !groups || !events {
		t.Fatalf("group schema present=%v/%v err=%v", groups, events, err)
	}
}

type groupTestIdentity struct {
	key      *ecdsa.PrivateKey
	public   []byte
	deviceID string
}

func newGroupTestIdentity(t *testing.T) groupTestIdentity {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	return groupTestIdentity{key: key, public: public, deviceID: auth.DeviceID(public)}
}

func (i groupTestIdentity) request(t *testing.T, path string, payload map[string]string) *http.Request {
	t.Helper()
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	envelope := auth.Envelope{DeviceID: i.deviceID, Nonce: make([]byte, 32), Payload: payloadBytes, PublicKey: i.public, EpochMilliseconds: time.Now().UnixMilli()}
	if _, err := rand.Read(envelope.Nonce); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(envelope.CanonicalPayload())
	envelope.Signature, err = ecdsa.SignASN1(rand.Reader, i.key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.RemoteAddr = "127.0.0.1:42100"
	return r
}

func signedBootstrap(t *testing.T, i groupTestIdentity, accountID, groupID string) (accountgroup.Event, string) {
	t.Helper()
	event := accountgroup.Event{AccountID: accountID, GroupID: groupID, Generation: 1, Sequence: 1, Action: accountgroup.ActionBootstrap, ActorDeviceID: i.deviceID, ActorPublicKey: i.public, SubjectDeviceID: i.deviceID, SubjectPublicKey: i.public, EpochMilliseconds: time.Now().UnixMilli()}
	payload, err := event.CanonicalPayload()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(payload)
	event.Signature, err = ecdsa.SignASN1(rand.Reader, i.key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	w, err := accountgroup.EncodeWireEvent(event)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(w)
	if err != nil {
		t.Fatal(err)
	}
	return event, base64.StdEncoding.EncodeToString(raw)
}

func serveGroupRequest(t *testing.T, handler http.Handler, identity groupTestIdentity, path string, fields map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, identity.request(t, path, fields))
	return w
}

func TestGroupAssemblySQLRoutesPersistAndHonorRevocation(t *testing.T) {
	dsn, db := guardedGroupDatabase(t)
	identity := newGroupTestIdentity(t)
	const accountID = "11111111-2222-4333-8444-555555555555"
	const familyID = "22222222-3333-4444-8555-666666666666"
	const sessionID = "33333333-4444-4555-8666-777777777777"
	const groupID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	const audience = "com.example.dropmesh"
	accessRaw := bytes.Repeat([]byte{7}, 32)
	accessToken := base64.RawURLEncoding.EncodeToString(accessRaw)
	accessHash := sha256.Sum256(accessRaw)
	const sentinelNonce = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
	if _, err := db.Exec(`INSERT INTO auth_replay_nonces(nonce_hash,source_hash,device_id,expires_at) VALUES($1,$2,$3,clock_timestamp()+interval '1 day') ON CONFLICT(nonce_hash) DO UPDATE SET expires_at=EXCLUDED.expires_at`, sentinelNonce, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "99999999-9999-4999-8999-999999999999"); err != nil {
		t.Fatal("seed unrelated replay sentinel")
	}
	t.Cleanup(func() {
		if _, err := db.Exec(`DELETE FROM auth_replay_nonces WHERE nonce_hash=$1`, sentinelNonce); err != nil {
			t.Errorf("clean replay sentinel: %v", err)
		}
	})
	for _, cleanup := range []struct{ query, value string }{
		{`DELETE FROM account_group_events WHERE account_id=$1`, accountID},
		{`DELETE FROM account_groups WHERE account_id=$1`, accountID},
		{`DELETE FROM account_sessions WHERE family_id=$1`, familyID},
		{`DELETE FROM account_session_families WHERE family_id=$1`, familyID},
		{`DELETE FROM accounts WHERE account_id=$1`, accountID},
	} {
		var err error
		if cleanup.value == "" {
			_, err = db.Exec(cleanup.query)
		} else {
			_, err = db.Exec(cleanup.query, cleanup.value)
		}
		if err != nil {
			t.Fatal("clean synthetic rows")
		}
	}
	if _, err := db.Exec(`INSERT INTO accounts(account_id,apple_subject,status,created_at) VALUES($1,$2,'active',clock_timestamp())`, accountID, "synthetic-group-composition-subject"); err != nil {
		t.Fatal("seed account")
	}
	if _, err := db.Exec(`INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) VALUES($1,$2,$3,$4,clock_timestamp(),clock_timestamp()+interval '90 days')`, familyID, accountID, identity.deviceID, audience); err != nil {
		t.Fatal("seed family")
	}
	if _, err := db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,clock_timestamp(),clock_timestamp()+interval '15 minutes',clock_timestamp()+interval '1 day')`, sessionID, familyID, accessHash[:], bytes.Repeat([]byte{8}, 32)); err != nil {
		t.Fatal("seed session")
	}
	event, wire := signedBootstrap(t, identity, accountID, groupID)
	cfg := groupAssemblyConfig(t, dsn, true)
	handler, closeFirst, err := buildService(context.Background(), cfg)
	if err != nil {
		t.Fatal("build grouped service")
	}
	discover := map[string]string{"purpose": "dropmesh.account.group.discover.v1", "audience": audience, "accessToken": accessToken}
	if w := serveGroupRequest(t, handler, identity, "/v1/account/group/discover", discover); w.Code != 200 || w.Body.String() != "{\"status\":\"absent\"}" {
		closeFirst()
		t.Fatalf("absent discovery=%d %s", w.Code, w.Body.String())
	}
	bootstrap := map[string]string{"purpose": "dropmesh.account.group.bootstrap.v1", "audience": audience, "accessToken": accessToken, "confirmation": "join_this_device", "event": wire}
	if w := serveGroupRequest(t, handler, identity, "/v1/account/group/bootstrap", bootstrap); w.Code != 200 {
		closeFirst()
		t.Fatalf("bootstrap=%d %s", w.Code, w.Body.String())
	}
	w := serveGroupRequest(t, handler, identity, "/v1/account/group/discover", discover)
	if w.Code != 200 {
		closeFirst()
		t.Fatalf("present discovery=%d %s", w.Code, w.Body.String())
	}
	var discovery struct {
		Status, GroupID, AnchorHash, HeadHash string
		Generation, HeadSequence              uint64
		Anchor                                accountgroup.WireEvent
	}
	if err := json.Unmarshal(w.Body.Bytes(), &discovery); err != nil || discovery.Status != "present" || discovery.GroupID != groupID || discovery.Generation != 1 || discovery.HeadSequence != 1 {
		closeFirst()
		t.Fatalf("discovery=%+v err=%v", discovery, err)
	}
	expectedWire, _ := accountgroup.EncodeWireEvent(event)
	if discovery.Anchor != expectedWire {
		closeFirst()
		t.Fatal("persisted discovery anchor changed")
	}
	eventDigest, _ := event.Digest()
	expectedHash := base64.StdEncoding.EncodeToString(eventDigest[:])
	if discovery.AnchorHash != expectedHash || discovery.HeadHash != expectedHash {
		closeFirst()
		t.Fatal("persisted discovery hashes changed")
	}
	events := map[string]string{"purpose": "dropmesh.account.group.events.v1", "audience": audience, "accessToken": accessToken, "groupID": groupID, "afterSequence": "0", "expectedHeadHash": ""}
	w = serveGroupRequest(t, handler, identity, "/v1/account/group/events", events)
	if w.Code != 200 {
		closeFirst()
		t.Fatalf("events=%d %s", w.Code, w.Body.String())
	}
	var page struct {
		GroupID, HeadHash                                     string
		Generation, HeadSequence, AfterSequence, NextSequence uint64
		HasMore                                               bool
		Events                                                []accountgroup.WireEvent
	}
	if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil || page.GroupID != groupID || page.Generation != 1 || page.HeadSequence != 1 || page.AfterSequence != 0 || page.NextSequence != 1 || page.HasMore || len(page.Events) != 1 || page.Events[0] != expectedWire || page.HeadHash != expectedHash {
		closeFirst()
		t.Fatalf("events page=%+v err=%v", page, err)
	}
	closeFirst()
	handler, closeSecond, err := buildService(context.Background(), cfg)
	if err != nil {
		t.Fatal("restart grouped service")
	}
	defer closeSecond()
	if w := serveGroupRequest(t, handler, identity, "/v1/account/group/bootstrap", bootstrap); w.Code != 200 {
		t.Fatalf("durable retry=%d %s", w.Code, w.Body.String())
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM account_group_events WHERE account_id=$1`, accountID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("durable event count=%d err=%v", count, err)
	}
	if _, err := db.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=$1`, familyID); err != nil {
		t.Fatal("revoke family")
	}
	if w := serveGroupRequest(t, handler, identity, "/v1/account/group/bootstrap", bootstrap); w.Code != http.StatusUnauthorized || w.Body.String() != "{\"error\":\"authentication_failed\"}\n" {
		t.Fatalf("revoked bootstrap=%d %q", w.Code, w.Body.String())
	}
	if err := db.QueryRow(`SELECT count(*) FROM account_group_events WHERE account_id=$1`, accountID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("post-revocation event count=%d err=%v", count, err)
	}
	var sentinelCount int
	if err := db.QueryRow(`SELECT count(*) FROM auth_replay_nonces WHERE nonce_hash=$1`, sentinelNonce).Scan(&sentinelCount); err != nil || sentinelCount != 1 {
		t.Fatalf("unrelated replay sentinel count=%d err=%v", sentinelCount, err)
	}
}
