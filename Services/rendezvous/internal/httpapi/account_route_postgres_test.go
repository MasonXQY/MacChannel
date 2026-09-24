package httpapi

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"fmt"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountauth"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/pairing"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/routeauth"
	"macchannel/rendezvous/internal/signal"

	_ "github.com/jackc/pgx/v5/stdlib"
)

type accountRoutePostgresFixture struct {
	db          *sql.DB
	accountID   string
	groupID     string
	generation  uint64
	audience    string
	left        testIdentity
	right       testIdentity
	leftToken   string
	rightToken  string
	leftRefresh string
	leftFamily  string
}

func newAccountRoutePostgresFixture(t *testing.T) accountRoutePostgresFixture {
	t.Helper()
	dsn := os.Getenv("DROPMESH_GROUP_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("DROPMESH_GROUP_TEST_DATABASE_URL absent; isolated PostgreSQL required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal("open fixture")
	}
	var safe bool
	if err := db.QueryRow(`SELECT current_database()='dropmesh_account_group_test' AND inet_server_addr() IS NULL`).Scan(&safe); err != nil || !safe {
		db.Close()
		t.Fatal("refusing writes: named Unix-socket fixture guard failed")
	}
	f := accountRoutePostgresFixture{db: db, accountID: accountRouteUUID(t), groupID: accountRouteUUID(t), generation: 1,
		audience: "com.dropmesh.account-route-test", left: newIdentity(t), right: newIdentity(t)}
	t.Cleanup(func() {
		for _, query := range []string{
			`DELETE FROM account_group_pending WHERE account_id=$1`,
			`DELETE FROM account_group_events WHERE account_id=$1`,
			`DELETE FROM account_groups WHERE account_id=$1`,
			`DELETE FROM account_session_refresh_history WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1)`,
			`DELETE FROM account_sessions WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1)`,
			`DELETE FROM account_session_token_issuance WHERE family_id IN (SELECT family_id FROM account_session_families WHERE account_id=$1)`,
			`DELETE FROM account_session_families WHERE account_id=$1`,
			`DELETE FROM accounts WHERE account_id=$1`,
		} {
			if _, err := db.Exec(query, f.accountID); err != nil {
				t.Errorf("fixture cleanup: %v", err)
			}
		}
		_ = db.Close()
	})
	if _, err := db.Exec(`INSERT INTO accounts(account_id,apple_subject,status,created_at) VALUES($1,$2,'active',clock_timestamp())`, f.accountID, "account-route:"+f.accountID); err != nil {
		t.Fatal(err)
	}
	f.leftToken, f.leftRefresh, f.leftFamily = f.seedSession(t, f.left)
	f.rightToken, _, _ = f.seedSession(t, f.right)
	store, err := accountgroup.NewPostgresStore(db)
	if err != nil {
		t.Fatal(err)
	}
	boot := f.event(t, f.left, f.left, accountgroup.ActionBootstrap, 1, nil)
	if err := store.Bootstrap(context.Background(), accountgroup.Actor{AccountID: f.accountID, DeviceID: f.left.id}, boot); err != nil {
		t.Fatal(err)
	}
	head, err := boot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	approve := f.event(t, f.left, f.right, accountgroup.ActionApprove, 2, head[:])
	if err := store.Append(context.Background(), accountgroup.Actor{AccountID: f.accountID, DeviceID: f.left.id}, approve); err != nil {
		t.Fatal(err)
	}
	return f
}

func accountRouteUUID(t *testing.T) string {
	t.Helper()
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		t.Fatal(err)
	}
	raw[6] = raw[6]&0x0f | 0x40
	raw[8] = raw[8]&0x3f | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16])
}

func (f accountRoutePostgresFixture) seedSession(t *testing.T, identity testIdentity) (string, string, string) {
	t.Helper()
	family, session := accountRouteUUID(t), accountRouteUUID(t)
	var accessRaw, refreshRaw [32]byte
	if _, err := rand.Read(accessRaw[:]); err != nil {
		t.Fatal(err)
	}
	if _, err := rand.Read(refreshRaw[:]); err != nil {
		t.Fatal(err)
	}
	accessHash, refreshHash := sha256.Sum256(accessRaw[:]), sha256.Sum256(refreshRaw[:])
	if _, err := f.db.Exec(`WITH stamp AS (SELECT clock_timestamp()-interval '1 minute' AS created) INSERT INTO account_session_families(family_id,account_id,device_id,audience,created_at,absolute_expires_at) SELECT $1,$2,$3,$4,created,created+interval '90 days' FROM stamp`, family, f.accountID, identity.id, f.audience); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO account_sessions(session_id,family_id,generation,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at) VALUES($1,$2,1,$3,$4,clock_timestamp()-interval '1 minute',clock_timestamp()+interval '15 minutes',clock_timestamp()+interval '30 days')`, session, family, accessHash[:], refreshHash[:]); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO account_session_token_issuance(token_hash,token_role,family_id,issued_at,retain_until) VALUES($1,'access',$3,clock_timestamp()-interval '1 minute',clock_timestamp()+interval '89 days'),($2,'refresh',$3,clock_timestamp()-interval '1 minute',clock_timestamp()+interval '89 days')`, accessHash[:], refreshHash[:], family); err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(accessRaw[:]), base64.RawURLEncoding.EncodeToString(refreshRaw[:]), family
}

func (f accountRoutePostgresFixture) event(t *testing.T, actor, subject testIdentity, action accountgroup.Action, sequence uint64, previous []byte) accountgroup.Event {
	t.Helper()
	event := accountgroup.Event{AccountID: f.accountID, GroupID: f.groupID, Generation: f.generation, Sequence: sequence,
		PreviousHash: append([]byte(nil), previous...), Action: action, ActorDeviceID: actor.id,
		ActorPublicKey: append([]byte(nil), actor.publicKey...), SubjectDeviceID: subject.id,
		SubjectPublicKey: append([]byte(nil), subject.publicKey...), EpochMilliseconds: time.Now().UTC().UnixMilli()}
	signAccountRouteEvent(t, &event, actor.privateKey, false)
	if action == accountgroup.ActionApprove {
		signAccountRouteEvent(t, &event, subject.privateKey, true)
	}
	return event
}

func signAccountRouteEvent(t *testing.T, event *accountgroup.Event, key *ecdsa.PrivateKey, subject bool) {
	t.Helper()
	payload, err := event.CanonicalPayload()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(payload)
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	if subject {
		event.SubjectSignature = signature
	} else {
		event.Signature = signature
	}
}

func TestAccountRoutePostgresRevocationDeniesNextWebSocketRoute(t *testing.T) {
	f := newAccountRoutePostgresFixture(t)
	clock := &testClock{now: time.Now().UTC()}
	registry := auth.NewTrustRegistry()
	for _, identity := range []testIdentity{f.left, f.right} {
		if err := registry.AuthenticateDevice(identity.id, identity.publicKey, nil); err != nil {
			t.Fatal(err)
		}
	}
	store, err := accountgroup.NewPostgresStore(f.db)
	if err != nil {
		t.Fatal(err)
	}
	routes, err := routeauth.NewCompositeConnectionRouter(2, accountRouteDenyGraph{}, routeauth.NewPostgresAccountGate(store))
	if err != nil {
		t.Fatal(err)
	}
	protector, err := accountauth.NewAppleCredentialProtector("test", map[string][]byte{"test": make([]byte, 32)})
	if err != nil {
		t.Fatal(err)
	}
	sessions, err := accountauth.NewPostgresSessions(f.db, protector, []string{f.audience})
	if err != nil {
		t.Fatal(err)
	}
	handler := NewRouter(Config{Clock: clock.Now, Verifier: auth.NewVerifier(auth.VerifierConfig{Clock: clock.Now}), Registry: registry,
		Pairings: pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock.Now}), Presence: presence.NewHub(accountRouteDenyGraph{}),
		Signals: signal.NewHub(accountRouteDenyGraph{}), AccountRoutes: &AccountRouteConfig{Routes: routes, Sessions: sessions}})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	api := &testAPI{t: t, clock: clock, server: server}
	leftSocket := api.authenticatedWebSocket(t, f.left, nil)
	defer leftSocket.Close()
	rightSocket := api.authenticatedWebSocket(t, f.right, nil)
	defer rightSocket.Close()
	refreshed, err := sessions.Refresh(context.Background(), f.leftRefresh, f.left.id, f.audience)
	if err != nil {
		t.Fatal(err)
	}
	bindAccountRouteForGroupExpect(t, clock, leftSocket, f.left, f.leftToken, f.audience, f.groupID, f.generation, "account-route-bind-error")
	bindAccountRouteForGroup(t, clock, leftSocket, f.left, refreshed.AccessToken, f.audience, f.groupID, f.generation)
	bindAccountRouteForGroup(t, clock, rightSocket, f.right, f.rightToken, f.audience, f.groupID, f.generation)
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": f.right.id, "payload": []byte("before-revoke")}); err != nil {
		t.Fatal(err)
	}
	if frame := readUntilType(t, rightSocket, "signal"); frame["from"] != f.left.id {
		t.Fatalf("frame=%#v", frame)
	}
	if _, err := f.db.Exec(`UPDATE account_session_families SET revoked_at=clock_timestamp() WHERE family_id=$1 AND account_id=$2`, f.leftFamily, f.accountID); err != nil {
		t.Fatal(err)
	}
	if err := leftSocket.WriteJSON(map[string]any{"type": "signal", "to": f.right.id, "payload": []byte("after-revoke")}); err != nil {
		t.Fatal(err)
	}
	result := readUntilType(t, leftSocket, "signal-error")
	if result["code"] != "unavailable" {
		t.Fatalf("route result=%#v", result)
	}
	expectNoFrameType(t, rightSocket, "signal")
}

func bindAccountRouteForGroup(t *testing.T, clock *testClock, connection accountRouteJSONConnection, identity testIdentity, token, audience, group string, generation uint64) {
	t.Helper()
	bindAccountRouteForGroupExpect(t, clock, connection, identity, token, audience, group, generation, "account-route-bind-ok")
}

func bindAccountRouteForGroupExpect(t *testing.T, clock *testClock, connection accountRouteJSONConnection, identity testIdentity, token, audience, group string, generation uint64, want string) {
	t.Helper()
	challenge := requestAccountRouteChallenge(t, connection)
	payload := mustJSON(t, map[string]any{"type": "account-route-bind-v1", "accessToken": token, "audience": audience,
		"groupID": group, "generation": generation})
	writeAccountRouteBind(t, connection, identity.envelope(t, clock.Now(), challenge.Nonce, payload))
	requireAccountRouteBindResult(t, connection, want)
}
