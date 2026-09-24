package routeauth

import (
	"context"
	"errors"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/presence"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type projectionFunc func(context.Context, accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error)

func (f projectionFunc) ProjectPresenceCandidates(c context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
	return f(c, r)
}

func adapterFixture(t *testing.T, gate AccountGate, projector PresenceProjector) (*ConnectionRouter, ConnectionHandle, ConnectionHandle, *eventSink, *eventSink) {
	t.Helper()
	a, ak := identity(81, true)
	b, bk := identity(82, true)
	if projector == nil {
		projector = projectionFunc(func(_ context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
			peer := a
			if r.Actor.DeviceID == a {
				peer = b
			}
			return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: []string{peer}}, nil
		})
	}
	r, err := NewCompositeConnectionRouterWithPresence(1, presenceGraph{}, gate, AccountPresenceConfig{Hub: presence.NewHub(presenceGraph{}), Projection: projector, CandidatesPerTurn: 1, WorkTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Shutdown)
	ah, _ := r.Register(a, ak, "a")
	bh, _ := r.Register(b, bk, "b")
	as := &eventSink{make(chan presence.Event, 32)}
	bs := &eventSink{make(chan presence.Event, 32)}
	if err := r.AttachPresence(ah, as); err != nil {
		t.Fatal(err)
	}
	if err := r.AttachPresence(bh, bs); err != nil {
		t.Fatal(err)
	}
	return r, ah, bh, as, bs
}
func noPresence(t *testing.T, s *eventSink) {
	t.Helper()
	select {
	case e := <-s.events:
		t.Fatalf("unexpected event %+v", e)
	case <-time.After(30 * time.Millisecond):
	}
}
func TestAccountPresenceAdapterPausedGateUnbindAndShutdown(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		once.Do(func() { close(entered) })
		select {
		case <-release:
		case <-ctx.Done():
		}
		return allowGate(ctx, r, fn)
	})
	r, a, b, as, bs := adapterFixture(t, gate, nil)
	r.Bind(a, bindingFor(a))
	r.Bind(b, bindingFor(b))
	<-entered
	if err := r.Unbind(b); err != nil {
		t.Fatal(err)
	}
	close(release)
	r.Shutdown()
	noPresence(t, as)
	noPresence(t, bs)
	if err := r.Bind(a, bindingFor(a)); err == nil {
		t.Fatal("bind after shutdown")
	}
}
func TestAccountPresenceAdapterPublishAfterGateAndOnce(t *testing.T) {
	reserved, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		if calls.Add(1) == 1 {
			if !fn() {
				t.Error("reservation failed")
			}
			if fn() {
				t.Error("repeated callback admitted")
			}
			close(reserved)
			<-release
			return accountgroup.RouteAdmissionOutcome{}, errors.New("cleanup uncertainty")
		}
		return allowGate(ctx, r, fn)
	})
	r, a, b, as, bs := adapterFixture(t, gate, nil)
	r.Bind(a, bindingFor(a))
	r.Bind(b, bindingFor(b))
	<-reserved
	noPresence(t, as)
	noPresence(t, bs)
	close(release)
	expectPresence(t, as, "internet", b.deviceID)
	expectPresence(t, bs, "internet", a.deviceID)
	noPresence(t, as)
	noPresence(t, bs)
}
func TestAccountPresenceAdapterProjectionCannotAuthorize(t *testing.T) {
	var late func() bool
	called := make(chan struct{}, 2)
	gate := gateFunc(func(_ context.Context, _ accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		late = fn
		called <- struct{}{}
		return accountgroup.RouteAdmissionOutcome{}, errors.New("denied")
	})
	r, a, b, as, bs := adapterFixture(t, gate, nil)
	r.Bind(a, bindingFor(a))
	r.Bind(b, bindingFor(b))
	<-called
	r.Shutdown()
	if late != nil && late() {
		t.Fatal("retained callback admitted")
	}
	noPresence(t, as)
	noPresence(t, bs)
}

func TestAccountPresenceAdapterStableProjectionCursor(t *testing.T) {
	a, ak := identity(91, true)
	b, bk := identity(92, true)
	c, ck := identity(93, true)
	var projections atomic.Int32
	var admitted atomic.Int32
	projector := projectionFunc(func(_ context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		ids := []string{}
		if r.Actor.DeviceID == a {
			if projections.Add(1) == 1 {
				ids = []string{b, c}
			} else {
				ids = []string{c}
			}
		}
		return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: ids}, nil
	})
	gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		admitted.Add(1)
		return allowGate(ctx, r, fn)
	})
	r, err := NewCompositeConnectionRouterWithPresence(1, presenceGraph{}, gate, AccountPresenceConfig{Hub: presence.NewHub(presenceGraph{}), Projection: projector, CandidatesPerTurn: 1, WorkTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Shutdown()
	hs := []ConnectionHandle{}
	ss := []*eventSink{}
	for i, id := range []string{a, b, c} {
		h, _ := r.Register(id, [][]byte{ak, bk, ck}[i], id)
		s := &eventSink{make(chan presence.Event, 32)}
		r.AttachPresence(h, s)
		hs = append(hs, h)
		ss = append(ss, s)
	}
	// Bind targets first; only the final source binding can enumerate them.
	r.Bind(hs[1], bindingFor(hs[1]))
	r.Bind(hs[2], bindingFor(hs[2]))
	r.Bind(hs[0], bindingFor(hs[0]))
	expectPresence(t, ss[0], "internet", b)
	expectPresence(t, ss[0], "internet", c)
	if admitted.Load() != 2 {
		t.Fatalf("wanted two fresh admissions, got %d", admitted.Load())
	}
}
func TestAccountPresenceAdapterSourceTimeoutLetsNextSourceProgress(t *testing.T) {
	a, _ := identity(81, true)
	b, _ := identity(82, true)
	entered := make(chan struct{})
	projector := projectionFunc(func(ctx context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		if r.Actor.DeviceID == a {
			select {
			case <-entered:
			default:
				close(entered)
			}
			<-ctx.Done()
			return accountgroup.PresenceProjection{}, ctx.Err()
		}
		return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: []string{a}}, nil
	})
	r, ah, bh, as, _ := adapterFixture(t, gateFunc(allowGate), projector)
	r.presence.config.WorkTimeout = 100 * time.Millisecond // worker has no queued work yet
	r.Bind(ah, bindingFor(ah))
	<-entered
	r.Bind(bh, bindingFor(bh))
	expectPresence(t, as, "internet", b)
}
func TestAccountPresenceAdapterCloseReplacesExactHandle(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		once.Do(func() { close(entered); <-release })
		return allowGate(ctx, r, fn)
	})
	r, a, b, as, bs := adapterFixture(t, gate, nil)
	r.Bind(a, bindingFor(a))
	r.Bind(b, bindingFor(b))
	<-entered
	if err := r.Close(b); err != nil {
		t.Fatal(err)
	}
	id, key := identity(82, true)
	replacement, err := r.Register(id, key, "b")
	if err != nil {
		t.Fatal(err)
	}
	fresh := &eventSink{make(chan presence.Event, 32)}
	r.AttachPresence(replacement, fresh)
	r.Bind(replacement, bindingFor(replacement))
	close(release)
	expectPresence(t, as, "internet", b.deviceID)
	expectPresence(t, fresh, "internet", a.deviceID)
	noPresence(t, bs)
	if err := r.Unbind(b); err == nil {
		t.Fatal("old route handle accepted")
	}
	noPresence(t, as)
}
func TestAccountPresenceAdapterQueueCoalescesAndDropsClosedHandles(t *testing.T) {
	entered := make(chan struct{})
	projector := projectionFunc(func(ctx context.Context, _ accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		select {
		case <-entered:
		default:
			close(entered)
		}
		<-ctx.Done()
		return accountgroup.PresenceProjection{}, ctx.Err()
	})
	r, a, b, _, _ := adapterFixture(t, gateFunc(allowGate), projector)
	r.Bind(a, bindingFor(a))
	<-entered
	for i := 0; i < 100; i++ {
		r.Bind(b, bindingFor(b))
	}
	r.presence.mu.Lock()
	n := len(r.presence.queue)
	r.presence.mu.Unlock()
	if n > 2 {
		t.Fatalf("uncoalesced %d", n)
	}
	r.Close(b)
	r.presence.mu.Lock()
	defer r.presence.mu.Unlock()
	if r.presence.pending[b] {
		t.Fatal("closed source retains pending slot")
	}
}
func TestAccountPresenceAdapterConfigAndAttachment(t *testing.T) {
	for _, timeout := range []time.Duration{0, -1, 6 * time.Second} {
		_, err := NewCompositeConnectionRouterWithPresence(1, presenceGraph{}, gateFunc(allowGate), AccountPresenceConfig{Hub: presence.NewHub(presenceGraph{}), Projection: projectionFunc(nil), CandidatesPerTurn: 1, WorkTimeout: timeout})
		if err == nil {
			t.Fatal("invalid timeout")
		}
	}
	r, a, _, as, _ := adapterFixture(t, gateFunc(allowGate), nil)
	if err := r.AttachPresence(a, as); err == nil {
		t.Fatal("duplicate attachment")
	}
	noPresence(t, as)
}

func TestAccountPresenceAdapterShutdownRetiresAllRouteHandles(t *testing.T) {
	r, a, b, _, _ := adapterFixture(t, gateFunc(allowGate), nil)
	id, key := identity(84, true)
	unattached, _ := r.Register(id, key, "unattached")
	notifications, _ := r.Notifications(unattached)
	r.Bind(a, bindingFor(a))
	r.Bind(b, bindingFor(b))
	r.Shutdown()
	if _, err := r.Route(context.Background(), a, b.deviceID, []byte("after stop")); err == nil {
		t.Error("route after shutdown")
	}
	if _, err := r.Notifications(unattached); err == nil {
		t.Error("unattached handle after shutdown")
	}
	select {
	case <-notifications:
	default:
		t.Error("notification channel still open")
	}
	if _, state := r.Dequeue(b); state != QueueClosed {
		t.Error("queue not retired")
	}
}
func TestAccountPresenceAdapterProjectionFailureWithdraws(t *testing.T) {
	var fail atomic.Bool
	projector := projectionFunc(func(_ context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		if fail.Load() {
			return accountgroup.PresenceProjection{}, errors.New("db down")
		}
		a, _ := identity(81, true)
		b, _ := identity(82, true)
		peer := a
		if r.Actor.DeviceID == a {
			peer = b
		}
		return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: []string{peer}}, nil
	})
	r, a, b, as, bs := adapterFixture(t, gateFunc(allowGate), projector)
	r.Bind(a, bindingFor(a))
	r.Bind(b, bindingFor(b))
	expectPresence(t, as, "internet", b.deviceID)
	expectPresence(t, bs, "internet", a.deviceID)
	fail.Store(true)
	r.presence.mu.Lock()
	r.presence.scheduleGroup(&AccountBinding{Actor: bindingFor(a).Actor, GroupID: bindingFor(a).GroupID, Generation: 1})
	r.presence.mu.Unlock()
	expectPresence(t, as, "offline", b.deviceID)
	expectPresence(t, bs, "offline", a.deviceID)
}

type closingSink struct {
	eventSink
	entered, release chan struct{}
	once             sync.Once
}

func (s *closingSink) Close() error { s.once.Do(func() { close(s.entered) }); <-s.release; return nil }
func TestAccountPresenceAdapterConcurrentShutdownJoinsSinks(t *testing.T) {
	r, a, _, _, _ := adapterFixture(t, gateFunc(allowGate), nil)
	// A separate owned connection supplies a deliberately slow but releasable Close.
	id, key := identity(83, true)
	h, _ := r.Register(id, key, "c")
	sink := &closingSink{eventSink: eventSink{make(chan presence.Event, 10)}, entered: make(chan struct{}), release: make(chan struct{})}
	if err := r.AttachPresence(h, sink); err != nil {
		t.Fatal(err)
	}
	_ = a
	first, second := make(chan struct{}), make(chan struct{})
	go func() { r.Shutdown(); close(first) }()
	<-sink.entered
	go func() { r.Shutdown(); close(second) }()
	select {
	case <-second:
		close(sink.release)
		<-first
		t.Fatal("second shutdown returned before sink joined")
	case <-time.After(30 * time.Millisecond):
	}
	close(sink.release)
	<-first
	<-second
}

type presenceGraph struct{}

type manualPairGraph struct{ a, b string }

func (g manualPairGraph) ShareGraph(a, b string) bool {
	return (a == g.a && b == g.b) || (a == g.b && b == g.a)
}
func (g manualPairGraph) DevicesInGraph(id string) []string {
	if id == g.a {
		return []string{g.b}
	}
	if id == g.b {
		return []string{g.a}
	}
	return nil
}
func TestAccountPresenceAdapterManualOverlapAndNoTransitiveComposition(t *testing.T) {
	a, ak := identity(101, true)
	b, bk := identity(102, true)
	c, ck := identity(103, true)
	g := manualPairGraph{a, b}
	projector := projectionFunc(func(_ context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		ids := []string{}
		if r.Actor.DeviceID == b {
			ids = []string{a, c}
		}
		if r.Actor.DeviceID == c {
			ids = []string{b}
		}
		return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: ids}, nil
	})
	gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		if r.From.Actor.DeviceID == a && r.To.Actor.DeviceID == c || r.From.Actor.DeviceID == c && r.To.Actor.DeviceID == a {
			t.Error("transitive account admission")
		}
		return allowGate(ctx, r, fn)
	})
	r, err := NewCompositeConnectionRouterWithPresence(1, g, gate, AccountPresenceConfig{Hub: presence.NewHub(g), Projection: projector, CandidatesPerTurn: 1, WorkTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Shutdown()
	hs := []ConnectionHandle{}
	ss := []*eventSink{}
	for i, id := range []string{a, b, c} {
		h, _ := r.Register(id, [][]byte{ak, bk, ck}[i], id)
		s := &eventSink{make(chan presence.Event, 32)}
		r.AttachPresence(h, s)
		hs = append(hs, h)
		ss = append(ss, s)
	}
	expectPresence(t, ss[0], "internet", b)
	expectPresence(t, ss[1], "internet", a)
	for _, h := range hs {
		r.Bind(h, bindingFor(h))
	}
	expectPresence(t, ss[1], "internet", c)
	expectPresence(t, ss[2], "internet", b)
	noPresence(t, ss[0])
	r.Unbind(hs[1])
	expectPresence(t, ss[1], "offline", c)
	expectPresence(t, ss[2], "offline", b)
	noPresence(t, ss[0])
	if _, err := r.Route(context.Background(), hs[0], b, []byte("manual")); err != nil {
		t.Fatal(err)
	}
}

func (presenceGraph) ShareGraph(string, string) bool { return false }
func (presenceGraph) DevicesInGraph(string) []string { return nil }

type eventSink struct{ events chan presence.Event }

func (s *eventSink) SendJSON(v any) error { s.events <- v.(presence.Event); return nil }
func (s *eventSink) Close() error         { return nil }
func TestAccountPresenceAdapterOnlineAndUnbind(t *testing.T) {
	a, ak := identity(71, true)
	b, bk := identity(72, true)
	projector := projectionFunc(func(_ context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		peer := a
		if r.Actor.DeviceID == a {
			peer = b
		}
		return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: []string{peer}}, nil
	})
	r, err := NewCompositeConnectionRouterWithPresence(1, presenceGraph{}, gateFunc(allowGate), AccountPresenceConfig{Hub: presence.NewHub(presenceGraph{}), Projection: projector, CandidatesPerTurn: 1, WorkTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Shutdown()
	ah, _ := r.Register(a, ak, "a")
	bh, _ := r.Register(b, bk, "b")
	as := &eventSink{make(chan presence.Event, 20)}
	bs := &eventSink{make(chan presence.Event, 20)}
	if err = r.AttachPresence(ah, as); err != nil {
		t.Fatal(err)
	}
	if err = r.AttachPresence(bh, bs); err != nil {
		t.Fatal(err)
	}
	r.Bind(ah, bindingFor(ah))
	r.Bind(bh, bindingFor(bh))
	expectPresence(t, as, "internet", b)
	expectPresence(t, bs, "internet", a)
	if err = r.Unbind(ah); err != nil {
		t.Fatal(err)
	}
	expectPresence(t, as, "offline", b)
	expectPresence(t, bs, "offline", a)
}
func expectPresence(t *testing.T, s *eventSink, state, id string) {
	t.Helper()
	select {
	case e := <-s.events:
		if e.Availability != state || e.DeviceID != id {
			t.Fatalf("got %+v", e)
		}
	case <-time.After(time.Second):
		t.Fatalf("missing %s", state)
	}
}
