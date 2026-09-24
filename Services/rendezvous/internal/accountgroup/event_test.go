package accountgroup

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"testing"

	"macchannel/rendezvous/internal/auth"
)

func TestCanonicalPayloadExactAndAllowsUnsignedConstruction(t *testing.T) {
	actor := fixtureKey(t, false)
	subject := fixtureKey(t, true)
	event := Event{
		AccountID: "11111111-2222-3333-4444-555555555555", GroupID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
		Generation: 7, Sequence: 2, PreviousHash: bytes.Repeat([]byte{0x5a}, 32), Action: ActionApprove,
		ActorDeviceID: auth.DeviceID(actor.public), ActorPublicKey: actor.public,
		SubjectDeviceID: auth.DeviceID(subject.public), SubjectPublicKey: subject.public,
		EpochMilliseconds: 1_700_000_000_123,
	}

	payload, err := event.CanonicalPayload()
	if err != nil {
		t.Fatalf("CanonicalPayload: %v", err)
	}
	want := fmt.Sprintf(`{"accountID":"11111111-2222-3333-4444-555555555555","action":"approve","actorDeviceID":%q,"actorPublicKey":%q,"epochMilliseconds":1700000000123,"generation":7,"groupID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","previousHash":%q,"purpose":"dropmesh.account.group.event.v1","sequence":2,"subjectDeviceID":%q,"subjectPublicKey":%q}`,
		event.ActorDeviceID, base64.StdEncoding.EncodeToString(event.ActorPublicKey), base64.StdEncoding.EncodeToString(event.PreviousHash), event.SubjectDeviceID, base64.StdEncoding.EncodeToString(event.SubjectPublicKey))
	if string(payload) != want {
		t.Fatalf("canonical payload mismatch\n got: %s\nwant: %s", payload, want)
	}
}

func TestValidEventsAndSignatureIndependentDigest(t *testing.T) {
	for _, raw64 := range []bool{true, false} {
		t.Run(fmt.Sprintf("bootstrap_raw64_%t", raw64), func(t *testing.T) {
			owner := fixtureKey(t, raw64)
			event := baseEvent(owner, owner, ActionBootstrap)
			event.Sequence = 1
			event.PreviousHash = []byte{}
			signActor(t, &event, owner.private)
			if err := event.Validate(); err != nil {
				t.Fatalf("Validate: %v", err)
			}
		})
	}

	actor, subject := fixtureKey(t, true), fixtureKey(t, false)
	approve := baseEvent(actor, subject, ActionApprove)
	signBoth(t, &approve, actor.private, subject.private)
	if err := approve.Validate(); err != nil {
		t.Fatalf("approve Validate: %v", err)
	}
	digest1, err := approve.Digest()
	if err != nil {
		t.Fatalf("approve Digest: %v", err)
	}
	signBoth(t, &approve, actor.private, subject.private)
	digest2, err := approve.Digest()
	if err != nil || digest1 != digest2 {
		t.Fatalf("digest must ignore randomized signatures: %x %x, %v", digest1, digest2, err)
	}

	remove := baseEvent(actor, subject, ActionRemove)
	signActor(t, &remove, actor.private)
	if err := remove.Validate(); err != nil {
		t.Fatalf("remove Validate: %v", err)
	}

	selfRemove := baseEvent(actor, actor, ActionRemove)
	signActor(t, &selfRemove, actor.private)
	if err := selfRemove.Validate(); err != nil {
		t.Fatalf("self remove must be structurally valid; membership policy is external: %v", err)
	}
}

func TestApproveValidityDoesNotImplyMembershipAuthorization(t *testing.T) {
	actor, subject := fixtureKey(t, true), fixtureKey(t, true)
	event := baseEvent(actor, subject, ActionApprove)
	signBoth(t, &event, actor.private, subject.private)
	if err := event.Validate(); err != nil {
		t.Fatalf("cryptographically valid approve: %v", err)
	}
	// A caller must still reject this event if its pinned group state says the
	// actor is not a current member authorized for this generation/sequence.
}

func TestInvalidEventsReturnOnlySentinel(t *testing.T) {
	actor, subject, other := fixtureKey(t, true), fixtureKey(t, false), fixtureKey(t, true)
	validApprove := baseEvent(actor, subject, ActionApprove)
	signBoth(t, &validApprove, actor.private, subject.private)
	validRemove := baseEvent(actor, subject, ActionRemove)
	signActor(t, &validRemove, actor.private)
	validBootstrap := baseEvent(actor, actor, ActionBootstrap)
	validBootstrap.Sequence, validBootstrap.PreviousHash = 1, []byte{}
	signActor(t, &validBootstrap, actor.private)

	tests := []struct {
		name string
		base Event
		edit func(*Event)
	}{
		{"tampered account", validApprove, func(e *Event) { e.AccountID = "22222222-2222-3333-4444-555555555555" }},
		{"tampered group", validApprove, func(e *Event) { e.GroupID = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee" }},
		{"tampered generation", validApprove, func(e *Event) { e.Generation++ }},
		{"tampered sequence", validApprove, func(e *Event) { e.Sequence++ }},
		{"tampered previous hash", validApprove, func(e *Event) { e.PreviousHash[0]++ }},
		{"tampered action", validApprove, func(e *Event) { e.Action = ActionRemove }},
		{"tampered actor ID", validApprove, func(e *Event) { e.ActorDeviceID = auth.DeviceID(other.public) }},
		{"tampered actor key", validApprove, func(e *Event) { e.ActorPublicKey = other.public }},
		{"tampered subject ID", validApprove, func(e *Event) { e.SubjectDeviceID = auth.DeviceID(other.public) }},
		{"tampered subject key", validApprove, func(e *Event) { e.SubjectPublicKey = other.public }},
		{"tampered timestamp", validApprove, func(e *Event) { e.EpochMilliseconds++ }},
		{"missing actor signature", validApprove, func(e *Event) { e.Signature = nil }},
		{"wrong actor signature", validApprove, func(e *Event) { e.Signature = append([]byte(nil), e.Signature...); e.Signature[3] ^= 1 }},
		{"oversized actor signature", validApprove, func(e *Event) { e.Signature = make([]byte, 81) }},
		{"missing subject signature", validApprove, func(e *Event) { e.SubjectSignature = nil }},
		{"wrong subject signature", validApprove, func(e *Event) {
			e.SubjectSignature = append([]byte(nil), e.SubjectSignature...)
			e.SubjectSignature[3] ^= 1
		}},
		{"oversized subject signature", validApprove, func(e *Event) { e.SubjectSignature = make([]byte, 81) }},
		{"alternate actor identity", validApprove, func(e *Event) { e.ActorDeviceID = auth.DeviceID(append([]byte{4}, actor.public...)) }},
		{"bad actor point", validApprove, func(e *Event) { e.ActorPublicKey = make([]byte, 64); e.ActorDeviceID = auth.DeviceID(e.ActorPublicKey) }},
		{"bad subject point", validApprove, func(e *Event) {
			e.SubjectPublicKey = make([]byte, 65)
			e.SubjectDeviceID = auth.DeviceID(e.SubjectPublicKey)
		}},
		{"uppercase account UUID", validApprove, func(e *Event) { e.AccountID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" }},
		{"uppercase group UUID", validApprove, func(e *Event) { e.GroupID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" }},
		{"extra remove subject signature", validRemove, func(e *Event) { e.SubjectSignature = []byte{1} }},
		{"invalid action", validApprove, func(e *Event) { e.Action = "invite" }},
		{"zero sequence", validApprove, func(e *Event) { e.Sequence = 0 }},
		{"overflow sequence", validApprove, func(e *Event) { e.Sequence = math.MaxInt64 + 1 }},
		{"zero generation", validApprove, func(e *Event) { e.Generation = 0 }},
		{"overflow generation", validApprove, func(e *Event) { e.Generation = math.MaxInt64 + 1 }},
		{"zero timestamp", validApprove, func(e *Event) { e.EpochMilliseconds = 0 }},
		{"negative timestamp", validApprove, func(e *Event) { e.EpochMilliseconds = -1 }},
		{"bootstrap sequence", validBootstrap, func(e *Event) { e.Sequence = 2 }},
		{"bootstrap hash", validBootstrap, func(e *Event) { e.PreviousHash = make([]byte, 32) }},
		{"bootstrap different subject", validBootstrap, func(e *Event) { e.SubjectDeviceID = subject.id; e.SubjectPublicKey = subject.public }},
		{"bootstrap subject signature", validBootstrap, func(e *Event) { e.SubjectSignature = []byte{1} }},
		{"approve missing prior hash", validApprove, func(e *Event) { e.PreviousHash = nil }},
		{"approve non32 prior hash", validApprove, func(e *Event) { e.PreviousHash = make([]byte, 31) }},
		{"remove non32 prior hash", validRemove, func(e *Event) { e.PreviousHash = make([]byte, 33) }},
		{"self approve", validApprove, func(e *Event) {
			e.SubjectDeviceID = e.ActorDeviceID
			e.SubjectPublicKey = append([]byte(nil), e.ActorPublicKey...)
		}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			event := cloneEvent(tc.base)
			tc.edit(&event)
			if err := event.Validate(); !errors.Is(err, ErrInvalidEvent) || err != ErrInvalidEvent {
				t.Fatalf("Validate error = %v, want exact ErrInvalidEvent", err)
			}
			if _, err := event.Digest(); err != ErrInvalidEvent {
				t.Fatalf("Digest error = %v, want exact ErrInvalidEvent", err)
			}
		})
	}
}

func TestCanonicalPayloadRejectsStructuralErrorsButNotMissingSignatures(t *testing.T) {
	actor, subject := fixtureKey(t, true), fixtureKey(t, true)
	event := baseEvent(actor, subject, ActionApprove)
	if _, err := event.CanonicalPayload(); err != nil {
		t.Fatalf("unsigned structurally valid event rejected: %v", err)
	}
	event.GroupID = "not-a-uuid"
	if _, err := event.CanonicalPayload(); err != ErrInvalidEvent {
		t.Fatalf("structural error = %v, want ErrInvalidEvent", err)
	}
}

func TestMethodsDoNotMutateInputBuffers(t *testing.T) {
	actor, subject := fixtureKey(t, true), fixtureKey(t, false)
	event := baseEvent(actor, subject, ActionApprove)
	signBoth(t, &event, actor.private, subject.private)
	want := cloneEvent(event)
	if _, err := event.CanonicalPayload(); err != nil {
		t.Fatal(err)
	}
	if err := event.Validate(); err != nil {
		t.Fatal(err)
	}
	if _, err := event.Digest(); err != nil {
		t.Fatal(err)
	}
	if !eventsEqualBytes(event, want) {
		t.Fatal("event input buffers mutated")
	}
}

type keyFixture struct {
	private *ecdsa.PrivateKey
	public  []byte
	id      string
}

func fixtureKey(t *testing.T, raw64 bool) keyFixture {
	t.Helper()
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := elliptic.Marshal(elliptic.P256(), private.X, private.Y)
	if raw64 {
		public = append([]byte(nil), public[1:]...)
	}
	return keyFixture{private: private, public: public, id: auth.DeviceID(public)}
}

func baseEvent(actor, subject keyFixture, action Action) Event {
	return Event{
		AccountID: "11111111-2222-3333-4444-555555555555", GroupID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
		Generation: 1, Sequence: 2, PreviousHash: bytes.Repeat([]byte{0x42}, 32), Action: action,
		ActorDeviceID: actor.id, ActorPublicKey: append([]byte(nil), actor.public...),
		SubjectDeviceID: subject.id, SubjectPublicKey: append([]byte(nil), subject.public...), EpochMilliseconds: 1_700_000_000_123,
	}
}

func signActor(t *testing.T, event *Event, key *ecdsa.PrivateKey) {
	t.Helper()
	payload, err := event.CanonicalPayload()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(payload)
	event.Signature, err = ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
}

func signBoth(t *testing.T, event *Event, actor, subject *ecdsa.PrivateKey) {
	t.Helper()
	signActor(t, event, actor)
	payload, err := event.CanonicalPayload()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(payload)
	event.SubjectSignature, err = ecdsa.SignASN1(rand.Reader, subject, digest[:])
	if err != nil {
		t.Fatal(err)
	}
}

func cloneEvent(event Event) Event {
	event.PreviousHash = append([]byte(nil), event.PreviousHash...)
	event.ActorPublicKey = append([]byte(nil), event.ActorPublicKey...)
	event.SubjectPublicKey = append([]byte(nil), event.SubjectPublicKey...)
	event.Signature = append([]byte(nil), event.Signature...)
	event.SubjectSignature = append([]byte(nil), event.SubjectSignature...)
	return event
}

func eventsEqualBytes(a, b Event) bool {
	return a.AccountID == b.AccountID && a.GroupID == b.GroupID && a.Generation == b.Generation && a.Sequence == b.Sequence &&
		a.Action == b.Action && a.ActorDeviceID == b.ActorDeviceID && a.SubjectDeviceID == b.SubjectDeviceID &&
		a.EpochMilliseconds == b.EpochMilliseconds && bytes.Equal(a.PreviousHash, b.PreviousHash) &&
		bytes.Equal(a.ActorPublicKey, b.ActorPublicKey) && bytes.Equal(a.SubjectPublicKey, b.SubjectPublicKey) &&
		bytes.Equal(a.Signature, b.Signature) && bytes.Equal(a.SubjectSignature, b.SubjectSignature)
}
