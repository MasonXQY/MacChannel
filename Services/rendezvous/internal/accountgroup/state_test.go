package accountgroup

import (
	"bytes"
	"errors"
	"math"
	"sync"
	"testing"
)

func bootstrapState(t *testing.T, owner keyFixture) (*State, Event) {
	t.Helper()
	event := baseEvent(owner, owner, ActionBootstrap)
	event.Sequence, event.PreviousHash = 1, nil
	signActor(t, &event, owner.private)
	hash, err := event.Digest()
	if err != nil {
		t.Fatal(err)
	}
	state, err := NewState(event, event.AccountID, event.GroupID, event.Generation, hash)
	if err != nil {
		t.Fatal(err)
	}
	return state, event
}

func nextEvent(t *testing.T, state *State, actor, subject keyFixture, action Action) Event {
	t.Helper()
	snapshot := state.Snapshot()
	event := baseEvent(actor, subject, action)
	event.AccountID, event.GroupID, event.Generation = snapshot.AccountID, snapshot.GroupID, snapshot.Generation
	event.Sequence, event.PreviousHash = snapshot.Sequence+1, append([]byte(nil), snapshot.HeadHash[:]...)
	if action == ActionApprove {
		signBoth(t, &event, actor.private, subject.private)
	} else {
		signActor(t, &event, actor.private)
	}
	return event
}

func TestNewStateRequiresIndependentExactPinAndOwnsBuffers(t *testing.T) {
	owner := fixtureKey(t, true)
	event := baseEvent(owner, owner, ActionBootstrap)
	event.Sequence, event.PreviousHash = 1, nil
	signActor(t, &event, owner.private)
	hash, _ := event.Digest()

	for _, tc := range []struct {
		name           string
		account, group string
		generation     uint64
		hash           [32]byte
	}{
		{"account", "22222222-2222-3333-4444-555555555555", event.GroupID, event.Generation, hash},
		{"group", event.AccountID, "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee", event.Generation, hash},
		{"generation", event.AccountID, event.GroupID, event.Generation + 1, hash},
		{"digest", event.AccountID, event.GroupID, event.Generation, [32]byte{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := NewState(event, tc.account, tc.group, tc.generation, tc.hash); err != ErrInvalidTransition {
				t.Fatalf("error = %v", err)
			}
		})
	}
	state, err := NewState(event, event.AccountID, event.GroupID, event.Generation, hash)
	if err != nil {
		t.Fatal(err)
	}
	event.ActorPublicKey[0] ^= 1
	snapshot := state.Snapshot()
	if !bytes.Equal(snapshot.Members[0].PublicKey, owner.public) {
		t.Fatal("constructor retained caller buffer")
	}
	snapshot.Members[0].PublicKey[0] ^= 1
	if !bytes.Equal(state.Snapshot().Members[0].PublicKey, owner.public) {
		t.Fatal("snapshot exposed state buffer")
	}
}

func TestNewStateRejectsUnsignedBootstrapWithExactPinnedValues(t *testing.T) {
	owner := fixtureKey(t, true)
	event := baseEvent(owner, owner, ActionBootstrap)
	event.Sequence, event.PreviousHash = 1, nil
	signActor(t, &event, owner.private)
	hash, err := event.Digest()
	if err != nil {
		t.Fatal(err)
	}
	event.Signature = nil

	if _, err := NewState(event, event.AccountID, event.GroupID, event.Generation, hash); err != ErrInvalidTransition {
		t.Fatalf("unsigned bootstrap error = %v, want ErrInvalidTransition", err)
	}
}

func TestStateMembershipChainAndRemovedActor(t *testing.T) {
	a, b, c, d := fixtureKey(t, true), fixtureKey(t, false), fixtureKey(t, true), fixtureKey(t, true)
	state, _ := bootstrapState(t, a)
	addB := nextEvent(t, state, a, b, ActionApprove)
	if err := state.Apply(addB); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, b, c, ActionApprove)); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, b, a, ActionRemove)); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, a, d, ActionApprove)); err != ErrInvalidTransition {
		t.Fatalf("removed actor error = %v", err)
	}
	if err := state.Apply(addB); err != ErrInvalidTransition {
		t.Fatalf("stale event error = %v", err)
	}
	wantFirst, wantSecond := b.id, c.id
	if wantSecond < wantFirst {
		wantFirst, wantSecond = wantSecond, wantFirst
	}
	if got := state.Snapshot().Members; len(got) != 2 || got[0].DeviceID != wantFirst || got[1].DeviceID != wantSecond {
		t.Fatalf("members = %#v", got)
	}
}

func TestRemoveAndFreshRejoinWithNewConsent(t *testing.T) {
	a, b := fixtureKey(t, true), fixtureKey(t, false)
	state, _ := bootstrapState(t, a)
	if err := state.Apply(nextEvent(t, state, a, b, ActionApprove)); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, a, b, ActionRemove)); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, a, b, ActionApprove)); err != nil {
		t.Fatal(err)
	}
}

func TestRemovedMemberRejectsOriginalApprovalReplayBeforeFreshChainedRejoin(t *testing.T) {
	a, b := fixtureKey(t, true), fixtureKey(t, false)
	state, _ := bootstrapState(t, a)
	originalApproval := nextEvent(t, state, a, b, ActionApprove)
	if err := state.Apply(originalApproval); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, a, b, ActionRemove)); err != nil {
		t.Fatal(err)
	}

	beforeReplay := state.Snapshot()
	if err := state.Apply(originalApproval); err != ErrInvalidTransition {
		t.Fatalf("stale approval replay error = %v, want ErrInvalidTransition", err)
	}
	if afterReplay := state.Snapshot(); !snapshotsEqual(beforeReplay, afterReplay) {
		t.Fatalf("stale approval replay mutated state: %#v -> %#v", beforeReplay, afterReplay)
	}

	freshApproval := nextEvent(t, state, a, b, ActionApprove)
	if err := state.Apply(freshApproval); err != nil {
		t.Fatalf("fresh chained rejoin: %v", err)
	}
	if got := state.Snapshot(); got.Sequence != beforeReplay.Sequence+1 || len(got.Members) != 2 {
		t.Fatalf("fresh chained rejoin snapshot = %#v", got)
	}
}

func TestInvalidTransitionsDoNotMutateState(t *testing.T) {
	a, b, outsider := fixtureKey(t, true), fixtureKey(t, true), fixtureKey(t, true)
	state, bootstrap := bootstrapState(t, a)
	valid := nextEvent(t, state, a, b, ActionApprove)
	tests := []struct {
		name string
		edit func(*Event)
	}{
		{"bad signature", func(e *Event) { e.SubjectSignature = nil }},
		{"account", func(e *Event) {
			e.AccountID = "22222222-2222-3333-4444-555555555555"
			signBoth(t, e, a.private, b.private)
		}},
		{"group", func(e *Event) {
			e.GroupID = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
			signBoth(t, e, a.private, b.private)
		}},
		{"generation", func(e *Event) { e.Generation++; signBoth(t, e, a.private, b.private) }},
		{"hash", func(e *Event) { e.PreviousHash[0] ^= 1; signBoth(t, e, a.private, b.private) }},
		{"gap", func(e *Event) { e.Sequence++; signBoth(t, e, a.private, b.private) }},
		{"inactive actor", func(e *Event) { *e = nextEvent(t, state, outsider, b, ActionApprove) }},
		{"actor key mismatch", func(e *Event) {
			state.mu.Lock()
			state.members[a.id] = append([]byte(nil), outsider.public...)
			state.mu.Unlock()
		}},
		{"bootstrap", func(e *Event) { *e = bootstrap }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			before := state.Snapshot()
			event := cloneEvent(valid)
			tc.edit(&event)
			if err := state.Apply(event); err != ErrInvalidTransition {
				t.Fatalf("error = %v", err)
			}
			if tc.name == "actor key mismatch" {
				state.mu.Lock()
				state.members[a.id] = append([]byte(nil), a.public...)
				state.mu.Unlock()
			}
			if after := state.Snapshot(); !snapshotsEqual(before, after) {
				t.Fatalf("state mutated: %#v -> %#v", before, after)
			}
		})
	}
	if err := state.Apply(valid); err != nil {
		t.Fatal(err)
	}
	valid.SubjectPublicKey[0] ^= 1
	if got := state.Snapshot(); !bytes.Equal(got.Members[1].PublicKey, b.public) && !bytes.Equal(got.Members[0].PublicKey, b.public) {
		t.Fatal("Apply retained caller buffer")
	}
	if err := state.Apply(valid); err != ErrInvalidTransition {
		t.Fatalf("repeat error = %v", err)
	}
}

func TestSubjectKeyExactnessTerminalZeroAndNilSafety(t *testing.T) {
	a, b, other := fixtureKey(t, true), fixtureKey(t, true), fixtureKey(t, true)
	state, _ := bootstrapState(t, a)
	if err := state.Apply(nextEvent(t, state, a, b, ActionApprove)); err != nil {
		t.Fatal(err)
	}
	remove := nextEvent(t, state, a, b, ActionRemove)
	state.mu.Lock()
	state.members[b.id] = append([]byte(nil), other.public...)
	state.mu.Unlock()
	if err := state.Apply(remove); err != ErrInvalidTransition {
		t.Fatalf("wrong subject key = %v", err)
	}
	state.mu.Lock()
	state.members[b.id] = append([]byte(nil), b.public...)
	state.mu.Unlock()
	if err := state.Apply(nextEvent(t, state, a, b, ActionRemove)); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, a, a, ActionRemove)); err != nil {
		t.Fatal(err)
	}
	if err := state.Apply(nextEvent(t, state, b, other, ActionApprove)); err != ErrInvalidTransition {
		t.Fatalf("terminal apply = %v", err)
	}
	var zero State
	if err := zero.Apply(Event{}); err != ErrInvalidTransition {
		t.Fatalf("zero apply = %v", err)
	}
	if got := zero.Snapshot(); !snapshotsEqual(got, Snapshot{}) {
		t.Fatalf("zero snapshot = %#v", got)
	}
	var nilState *State
	if err := nilState.Apply(Event{}); err != ErrInvalidTransition {
		t.Fatalf("nil apply = %v", err)
	}
	if got := nilState.Snapshot(); !snapshotsEqual(got, Snapshot{}) {
		t.Fatalf("nil snapshot = %#v", got)
	}
}

func TestMemberCapOverflowAndConcurrentSameHead(t *testing.T) {
	a := fixtureKey(t, true)
	state, _ := bootstrapState(t, a)
	state.mu.Lock()
	for i := 1; i < 64; i++ {
		state.members[string(rune(i))] = []byte{byte(i)}
	}
	state.mu.Unlock()
	b := fixtureKey(t, true)
	if err := state.Apply(nextEvent(t, state, a, b, ActionApprove)); err != ErrInvalidTransition {
		t.Fatalf("cap error = %v", err)
	}
	state.mu.Lock()
	state.members = map[string][]byte{a.id: append([]byte(nil), a.public...)}
	state.sequence = math.MaxInt64
	state.mu.Unlock()
	e := baseEvent(a, b, ActionApprove)
	e.AccountID, e.GroupID, e.Generation = state.accountID, state.groupID, state.generation
	e.Sequence, e.PreviousHash = uint64(math.MaxInt64), append([]byte(nil), state.headHash[:]...)
	signBoth(t, &e, a.private, b.private)
	if err := state.Apply(e); err != ErrInvalidTransition {
		t.Fatalf("overflow error = %v", err)
	}

	state, _ = bootstrapState(t, a)
	b, c := fixtureKey(t, true), fixtureKey(t, true)
	e1, e2 := nextEvent(t, state, a, b, ActionApprove), nextEvent(t, state, a, c, ActionApprove)
	errs := make(chan error, 2)
	var wg sync.WaitGroup
	for _, e := range []Event{e1, e2} {
		wg.Add(1)
		go func(event Event) { defer wg.Done(); errs <- state.Apply(event) }(e)
	}
	wg.Wait()
	close(errs)
	ok, rejected := 0, 0
	for err := range errs {
		if err == nil {
			ok++
		} else if errors.Is(err, ErrInvalidTransition) {
			rejected++
		}
	}
	if ok != 1 || rejected != 1 || len(state.Snapshot().Members) != 2 {
		t.Fatalf("ok=%d rejected=%d members=%d", ok, rejected, len(state.Snapshot().Members))
	}
}

func snapshotsEqual(a, b Snapshot) bool {
	if a.AccountID != b.AccountID || a.GroupID != b.GroupID || a.Generation != b.Generation || a.Sequence != b.Sequence || a.HeadHash != b.HeadHash || len(a.Members) != len(b.Members) {
		return false
	}
	for i := range a.Members {
		if a.Members[i].DeviceID != b.Members[i].DeviceID || !bytes.Equal(a.Members[i].PublicKey, b.Members[i].PublicKey) {
			return false
		}
	}
	return true
}
