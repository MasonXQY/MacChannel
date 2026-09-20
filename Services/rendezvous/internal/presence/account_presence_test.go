package presence

import (
	"errors"
	"math"
	"sync"
	"testing"
	"time"
)

type ownedTestSink struct {
	events chan Event
	closed chan struct{}
	once   sync.Once
}

func TestAccountEpochCannotReserveTwiceAfterPublish(t *testing.T) {
	h, l, r, _, _ := ownedPair(t, &graphSpy{})
	epoch, _ := h.BeginAccountPair(l, r)
	batch, ok := reserveEventually(h, l, r, epoch, true)
	if !ok || !batch.Publish() {
		t.Fatal("first reservation")
	}
	if _, ok := h.ReserveAccountPair(l, r, epoch, true); ok {
		t.Fatal("same epoch reserved twice")
	}
}

func TestAccountReservationContentionAndSymmetricCapacity(t *testing.T) {
	h, l, r, _, _ := ownedPair(t, &graphSpy{})
	epoch, _ := h.BeginAccountPair(l, r)
	h.mu.Lock()
	done := make(chan bool, 1)
	go func() { _, ok := h.ReserveAccountPair(l, r, epoch, true); done <- ok }()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("reserved while locked")
		}
	case <-time.After(time.Second):
		h.mu.Unlock()
		t.Fatal("reserve blocked")
	}
	h.mu.Unlock()
	// Fill only the right side using unpublished reservations, so no worker can
	// consume slots or turn the capacity assertion into a scheduling race.
	for i := 0; i < MaximumPendingPerConnection; i++ {
		sink := newOwnedTestSink()
		id := string(rune('A' + i))
		handle, cleanup, err := h.ConnectOwned(id, id, sink)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(cleanup)
		ep, ok := h.BeginAccountPair(handle, r)
		if !ok {
			t.Fatal("begin filler")
		}
		if _, ok := reserveEventually(h, handle, r, ep, true); !ok {
			t.Fatal("reserve filler")
		}
	}
	before := h.pending
	if _, ok := h.ReserveAccountPair(l, r, epoch, true); ok {
		t.Fatal("asymmetric capacity accepted")
	}
	if h.pending != before || h.clients["left"].owned.reserved != 0 {
		t.Fatal("partial reservation")
	}
	h.AdvanceAccountSource(r)
	if h.pending != 0 {
		t.Fatalf("reservation leak: %d", h.pending)
	}
	if _, ok := h.ReserveAccountPair(l, r, epoch, true); ok {
		t.Fatal("retired epoch accepted")
	}
}

func TestAccountDoesNotExtendManualGraph(t *testing.T) {
	g := &graphSpy{adjacency: map[string][]string{"left": {"right"}, "right": {"left"}}}
	h, l, r, ls, rs := ownedPair(t, g)
	third := newOwnedTestSink()
	ch, cleanup, err := h.ConnectOwned("third", "third", third)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	publishPair(t, h, r, ch, true)
	assertPresenceEvent(t, rs.events, "third", "internet")
	assertPresenceEvent(t, third.events, "right", "internet")
	h.Refresh()
	assertNoPresenceEvent(t, ls.events)
	if h.visible[l.deviceID]["third"] != 0 || len(g.adjacency["right"]) != 1 {
		t.Fatal("account composed into manual graph")
	}
}

type blockedOwnedSink struct {
	started chan struct{}
	closed  chan struct{}
	once    sync.Once
	fail    bool
}

func (s *blockedOwnedSink) SendJSON(any) error {
	s.once.Do(func() { close(s.started) })
	<-s.closed
	return errors.New("closed")
}
func (s *blockedOwnedSink) Close() error {
	select {
	case <-s.closed:
	default:
		close(s.closed)
	}
	return nil
}

func TestOwnedCleanupInterruptsAndJoinsDrainerAndRetiresBatch(t *testing.T) {
	h := NewHub(&graphSpy{})
	slow := &blockedOwnedSink{started: make(chan struct{}), closed: make(chan struct{})}
	l, lc, err := h.ConnectOwned("left", "left", slow)
	if err != nil {
		t.Fatal(err)
	}
	rs := newOwnedTestSink()
	r, rc, err := h.ConnectOwned("right", "right", rs)
	if err != nil {
		t.Fatal(err)
	}
	defer rc()
	publishPair(t, h, l, r, true)
	<-slow.started
	epoch, _ := h.BeginAccountPair(l, r)
	b, ok := reserveEventually(h, l, r, epoch, false)
	if !ok {
		t.Fatal("reserve")
	}
	h.mu.Lock()
	worker := h.clients["left"].owned
	h.mu.Unlock()
	done := make(chan struct{})
	go func() { lc(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cleanup did not interrupt writer")
	}
	select {
	case <-worker.done:
	default:
		t.Fatal("worker not joined")
	}
	if b.Publish() {
		t.Fatal("retired batch published")
	}
	replacement := newOwnedTestSink()
	fresh, fc, err := h.ConnectOwned("left", "left", replacement)
	if err != nil {
		t.Fatal(err)
	}
	defer fc()
	lc()
	if _, ok := h.BeginAccountPair(l, r); ok {
		t.Fatal("old handle accepted")
	}
	if fresh == l {
		t.Fatal("reused incarnation")
	}
	assertNoPresenceEvent(t, replacement.events)
}

type pausedOwnedSink struct {
	*ownedTestSink
	entered, release chan struct{}
	first            sync.Once
}

func (s *pausedOwnedSink) SendJSON(v any) error {
	s.first.Do(func() {
		close(s.entered)
		select {
		case <-s.release:
		case <-s.closed:
		}
	})
	return s.ownedTestSink.SendJSON(v)
}
func TestAccountWithdrawalSuppressesQueuedOldOnline(t *testing.T) {
	g := &graphSpy{adjacency: map[string][]string{"left": {"third"}, "third": {"left"}}}
	h := NewHub(g)
	slow := &pausedOwnedSink{ownedTestSink: newOwnedTestSink(), entered: make(chan struct{}), release: make(chan struct{})}
	l, lc, err := h.ConnectOwned("left", "left", slow)
	if err != nil {
		t.Fatal(err)
	}
	defer lc()
	_, tc, err := h.ConnectOwned("third", "third", newOwnedTestSink())
	if err != nil {
		t.Fatal(err)
	}
	defer tc()
	<-slow.entered
	rs := newOwnedTestSink()
	r, rc, err := h.ConnectOwned("right", "right", rs)
	if err != nil {
		t.Fatal(err)
	}
	defer rc()
	publishPair(t, h, l, r, true)
	h.AdvanceAccountSource(l)
	close(slow.release)
	assertPresenceEvent(t, slow.events, "third", "internet")
	assertPresenceEvent(t, slow.events, "right", "offline")
	assertNoPresenceEvent(t, slow.events)
}

func TestOlderWithdrawalCannotEraseNewerSuccessfulEpoch(t *testing.T) {
	h, l, r, ls, rs := ownedPair(t, &graphSpy{})
	publishPair(t, h, l, r, true)
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	old, _ := h.BeginAccountPair(l, r)
	withdraw, ok := reserveEventually(h, l, r, old, false)
	if !ok {
		t.Fatal("withdraw reserve")
	}
	publishPair(t, h, l, r, true)
	if withdraw.Publish() {
		t.Fatal("old withdrawal published")
	}
	assertNoPresenceEvent(t, ls.events)
	assertNoPresenceEvent(t, rs.events)
	if h.visible["left"]["right"]&accountSource == 0 {
		t.Fatal("newer account source lost")
	}
}

func TestQueuedWithdrawalDoesNotHideReboundPair(t *testing.T) {
	g := &graphSpy{adjacency: map[string][]string{"left": {"third"}, "third": {"left"}}}
	h := NewHub(g)
	slow := &pausedOwnedSink{ownedTestSink: newOwnedTestSink(), entered: make(chan struct{}), release: make(chan struct{})}
	l, lc, e := h.ConnectOwned("left", "left", slow)
	if e != nil {
		t.Fatal(e)
	}
	defer lc()
	_, tc, e := h.ConnectOwned("third", "third", newOwnedTestSink())
	if e != nil {
		t.Fatal(e)
	}
	defer tc()
	<-slow.entered
	r, rc, e := h.ConnectOwned("right", "right", newOwnedTestSink())
	if e != nil {
		t.Fatal(e)
	}
	defer rc()
	publishPair(t, h, l, r, true)
	h.AdvanceAccountSource(l)
	publishPair(t, h, l, r, true)
	close(slow.release)
	assertPresenceEvent(t, slow.events, "third", "internet")
	assertPresenceEvent(t, slow.events, "right", "internet")
	assertNoPresenceEvent(t, slow.events)
}

func TestQueuedDisconnectDoesNotHideReplacementPair(t *testing.T) {
	g := &graphSpy{adjacency: map[string][]string{"left": {"third"}, "third": {"left"}}}
	h := NewHub(g)
	slow := &pausedOwnedSink{ownedTestSink: newOwnedTestSink(), entered: make(chan struct{}), release: make(chan struct{})}
	l, lc, e := h.ConnectOwned("left", "left", slow)
	if e != nil {
		t.Fatal(e)
	}
	defer lc()
	_, tc, e := h.ConnectOwned("third", "third", newOwnedTestSink())
	if e != nil {
		t.Fatal(e)
	}
	defer tc()
	<-slow.entered
	r, rc, e := h.ConnectOwned("right", "right", newOwnedTestSink())
	if e != nil {
		t.Fatal(e)
	}
	publishPair(t, h, l, r, true)
	rc()
	r, rc, e = h.ConnectOwned("right", "right", newOwnedTestSink())
	if e != nil {
		t.Fatal(e)
	}
	defer rc()
	publishPair(t, h, l, r, true)
	close(slow.release)
	assertPresenceEvent(t, slow.events, "third", "internet")
	assertPresenceEvent(t, slow.events, "right", "internet")
	assertNoPresenceEvent(t, slow.events)
}

func TestConnectionIncarnationExhaustionFailsClosed(t *testing.T) {
	h := NewHub(&graphSpy{})
	h.nextToken = math.MaxUint64
	_, _, err := h.ConnectOwned("left", "left", newOwnedTestSink())
	if err == nil {
		t.Fatal("exhausted incarnation wrapped")
	}
}

type failingOwnedSink struct{ *ownedTestSink }

func (s *failingOwnedSink) SendJSON(any) error { return errors.New("writer failed") }
func TestOwnedWriterFailureRetiresAndJoins(t *testing.T) {
	h := NewHub(&graphSpy{})
	failed := &failingOwnedSink{newOwnedTestSink()}
	l, lc, e := h.ConnectOwned("left", "left", failed)
	if e != nil {
		t.Fatal(e)
	}
	defer lc()
	r, rc, e := h.ConnectOwned("right", "right", newOwnedTestSink())
	if e != nil {
		t.Fatal(e)
	}
	defer rc()
	h.mu.Lock()
	worker := h.clients["left"].owned
	h.mu.Unlock()
	publishPair(t, h, l, r, true)
	select {
	case <-worker.done:
	case <-time.After(time.Second):
		t.Fatal("failed writer leaked")
	}
	select {
	case <-failed.closed:
	default:
		t.Fatal("failed writer sink not closed")
	}
	if _, ok := h.BeginAccountPair(l, r); ok {
		t.Fatal("failed writer remained registered")
	}
	lc()
}

func newOwnedTestSink() *ownedTestSink {
	return &ownedTestSink{events: make(chan Event, 128), closed: make(chan struct{})}
}
func (s *ownedTestSink) SendJSON(v any) error {
	select {
	case s.events <- v.(Event):
	case <-s.closed:
	}
	return nil
}
func (s *ownedTestSink) Close() error { s.once.Do(func() { close(s.closed) }); return nil }
func ownedPair(t *testing.T, g TrustGraph) (*Hub, ConnectionHandle, ConnectionHandle, *ownedTestSink, *ownedTestSink) {
	t.Helper()
	h := NewHub(g)
	l, r := newOwnedTestSink(), newOwnedTestSink()
	lh, lc, e := h.ConnectOwned("left", "l", l)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(lc)
	rh, rc, e := h.ConnectOwned("right", "r", r)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(rc)
	return h, lh, rh, l, r
}
func publishPair(t *testing.T, h *Hub, l, r ConnectionHandle, visible bool) {
	t.Helper()
	epoch, ok := h.BeginAccountPair(l, r)
	if !ok {
		t.Fatal("begin")
	}
	b, ok := reserveEventually(h, l, r, epoch, visible)
	if !ok || !b.Publish() {
		t.Fatal("publish")
	}
}
func TestAccountBatchInvisibleUntilPublishAndSingleUse(t *testing.T) {
	h, l, r, ls, rs := ownedPair(t, &graphSpy{})
	epoch, ok := h.BeginAccountPair(l, r)
	if !ok {
		t.Fatal("begin")
	}
	b, ok := reserveEventually(h, l, r, epoch, true)
	if !ok {
		t.Fatal("reserve")
	}
	assertNoPresenceEvent(t, ls.events)
	assertNoPresenceEvent(t, rs.events)
	if !b.Publish() || b.Publish() {
		t.Fatal("batch must publish exactly once")
	}
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	publishPair(t, h, l, r, false)
	assertPresenceEvent(t, ls.events, "right", "offline")
	assertPresenceEvent(t, rs.events, "left", "offline")
}
func TestAccountManualUnion(t *testing.T) {
	g := &graphSpy{adjacency: map[string][]string{"left": {"right"}, "right": {"left"}}}
	h, l, r, ls, rs := ownedPair(t, g)
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	publishPair(t, h, l, r, true)
	assertNoPresenceEvent(t, ls.events)
	h.FailClosed()
	assertNoPresenceEvent(t, ls.events)
	assertNoPresenceEvent(t, rs.events)
	publishPair(t, h, l, r, false)
	assertPresenceEvent(t, ls.events, "right", "offline")
	assertPresenceEvent(t, rs.events, "left", "offline")
	h.Refresh()
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	publishPair(t, h, l, r, true)
	publishPair(t, h, l, r, false)
	assertNoPresenceEvent(t, ls.events)
	assertNoPresenceEvent(t, rs.events)
}
func TestAccountSourceEpochRetiresReservation(t *testing.T) {
	h, l, r, ls, rs := ownedPair(t, &graphSpy{})
	epoch, _ := h.BeginAccountPair(l, r)
	b, ok := reserveEventually(h, l, r, epoch, true)
	if !ok {
		t.Fatal("reserve")
	}
	if !h.AdvanceAccountSource(l) {
		t.Fatal("advance")
	}
	if b.Publish() {
		t.Fatal("stale publish")
	}
	if _, ok := h.ReserveAccountPair(l, r, epoch, true); ok {
		t.Fatal("stale reserve")
	}
	publishPair(t, h, l, r, true)
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	h.AdvanceAccountSource(r)
	assertPresenceEvent(t, ls.events, "right", "offline")
	assertPresenceEvent(t, rs.events, "left", "offline")
}

// TryLock may legitimately lose to an idle drainer starting. Successful-path
// fixtures retry boundedly; denial/contention assertions call Reserve directly.
func reserveEventually(h *Hub, l, r ConnectionHandle, epoch uint64, visible bool) (*AccountBatch, bool) {
	deadline := time.Now().Add(time.Second)
	for {
		if b, ok := h.ReserveAccountPair(l, r, epoch, visible); ok {
			return b, true
		}
		if time.Now().After(deadline) {
			return nil, false
		}
		time.Sleep(time.Millisecond)
	}
}

func TestWithdrawAccountPairWhenReservationCapacityExhausted(t *testing.T) {
	h, l, r, ls, rs := ownedPair(t, &graphSpy{})
	publishPair(t, h, l, r, true)
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	epoch, _ := h.BeginAccountPair(l, r)
	for i := 0; i < MaximumPendingPerConnection; i++ {
		id := string(rune('A' + i))
		handle, cleanup, err := h.ConnectOwned(id, id, newOwnedTestSink())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(cleanup)
		ep, ok := h.BeginAccountPair(handle, r)
		if !ok {
			t.Fatal("begin filler")
		}
		if _, ok := reserveEventually(h, handle, r, ep, true); !ok {
			t.Fatal("reserve filler")
		}
	}
	if _, ok := h.ReserveAccountPair(l, r, epoch, false); ok {
		t.Fatal("saturated reservation accepted")
	}
	if !h.WithdrawAccountPair(l, r, epoch) {
		t.Fatal("current denied refresh was not withdrawn")
	}
	h.mu.Lock()
	bits := h.visible["left"]["right"]
	_, rightCurrent := h.current(r)
	h.mu.Unlock()
	if bits != 0 || rightCurrent {
		t.Fatal("withdrawal must retire saturated socket and visibility")
	}
	assertPresenceEvent(t, ls.events, "right", "offline")
}

func TestWithdrawAccountPairEpochAndIdempotence(t *testing.T) {
	h, l, r, ls, rs := ownedPair(t, &graphSpy{})
	publishPair(t, h, l, r, true)
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	old, _ := h.BeginAccountPair(l, r)
	publishPair(t, h, l, r, true)
	if h.WithdrawAccountPair(l, r, old) {
		t.Fatal("old epoch withdrew newer success")
	}
	current, _ := h.BeginAccountPair(l, r)
	batch, ok := reserveEventually(h, l, r, current, true)
	if !ok {
		t.Fatal("reserve")
	}
	if !h.WithdrawAccountPair(l, r, current) || !h.WithdrawAccountPair(l, r, current) {
		t.Fatal("current withdrawal is idempotent")
	}
	if batch.Publish() {
		t.Fatal("withdrawn reservation published")
	}
	if _, ok := h.ReserveAccountPair(l, r, current, true); ok {
		t.Fatal("withdrawn epoch reused")
	}
	assertPresenceEvent(t, ls.events, "right", "offline")
	assertPresenceEvent(t, rs.events, "left", "offline")
	assertNoPresenceEvent(t, ls.events)
	assertNoPresenceEvent(t, rs.events)
}

func TestWithdrawAccountPairPreservesManualOverlap(t *testing.T) {
	g := &graphSpy{adjacency: map[string][]string{"left": {"right"}, "right": {"left"}}}
	h, l, r, ls, rs := ownedPair(t, g)
	assertPresenceEvent(t, ls.events, "right", "internet")
	assertPresenceEvent(t, rs.events, "left", "internet")
	publishPair(t, h, l, r, true)
	epoch, _ := h.BeginAccountPair(l, r)
	if !h.WithdrawAccountPair(l, r, epoch) {
		t.Fatal("withdraw")
	}
	assertNoPresenceEvent(t, ls.events)
	assertNoPresenceEvent(t, rs.events)
	h.mu.Lock()
	bits := h.visible["left"]["right"]
	h.mu.Unlock()
	if bits != manualSource {
		t.Fatalf("sources=%d", bits)
	}
}
