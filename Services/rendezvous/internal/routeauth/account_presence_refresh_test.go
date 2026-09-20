package routeauth

import (
	"context"
	"errors"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/presence"
	"sync/atomic"
	"testing"
	"time"
)

func refreshFixture(t *testing.T, interval time.Duration, ticks <-chan time.Time, graph presence.TrustGraph, gate AccountGate, projector PresenceProjector) (*ConnectionRouter, ConnectionHandle, ConnectionHandle, *eventSink, *eventSink) {
	t.Helper()
	a, ak := identity(81, true)
	b, bk := identity(82, true)
	if graph == nil {
		graph = presenceGraph{}
	}
	if projector == nil {
		projector = projectionFunc(refreshProjection)
	}
	r, err := NewCompositeConnectionRouterWithPresence(1, graph, gate, AccountPresenceConfig{Hub: presence.NewHub(graph), Projection: projector, CandidatesPerTurn: 1, WorkTimeout: time.Second, RefreshInterval: interval, refreshTicks: ticks})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Shutdown)
	ah, err := r.Register(a, ak, "a")
	if err != nil {
		t.Fatal(err)
	}
	bh, err := r.Register(b, bk, "b")
	if err != nil {
		t.Fatal(err)
	}
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
func refreshProjection(_ context.Context, r accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
	a, _ := identity(81, true)
	b, _ := identity(82, true)
	peer := a
	if r.Actor.DeviceID == a {
		peer = b
	}
	return accountgroup.PresenceProjection{GroupID: r.GroupID, Generation: r.Generation, DeviceIDs: []string{peer}}, nil
}
func refreshTick(t *testing.T, ticks chan<- time.Time) {
	t.Helper()
	select {
	case ticks <- time.Time{}:
	case <-time.After(time.Second):
		t.Fatal("refresh runner did not receive tick")
	}
}
func refreshAwait(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(time.Second):
		t.Fatal("refresh work did not complete")
	}
}
func refreshBind(t *testing.T, r *ConnectionRouter, a, b ConnectionHandle) {
	t.Helper()
	if err := r.Bind(a, bindingFor(a)); err != nil {
		t.Fatal(err)
	}
	if err := r.Bind(b, bindingFor(b)); err != nil {
		t.Fatal(err)
	}
}
func TestAccountPresenceRefreshIdleAuthorityChange(t *testing.T) {
	for _, mode := range []string{"projection", "admission"} {
		t.Run(mode, func(t *testing.T) {
			ticks := make(chan time.Time)
			var denied atomic.Bool
			projector := projectionFunc(func(ctx context.Context, req accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
				if mode == "projection" && denied.Load() {
					return accountgroup.PresenceProjection{}, errors.New("revoked")
				}
				return refreshProjection(ctx, req)
			})
			gate := gateFunc(func(ctx context.Context, req accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				if mode == "admission" && denied.Load() {
					return accountgroup.RouteAdmissionOutcome{}, errors.New("revoked")
				}
				return allowGate(ctx, req, fn)
			})
			r, a, b, as, bs := refreshFixture(t, time.Second, ticks, nil, gate, projector)
			refreshBind(t, r, a, b)
			expectPresence(t, as, "internet", b.deviceID)
			expectPresence(t, bs, "internet", a.deviceID)
			denied.Store(true)
			refreshTick(t, ticks)
			expectPresence(t, as, "offline", b.deviceID)
			expectPresence(t, bs, "offline", a.deviceID)
		})
	}
}
func TestAccountPresenceRefreshNewApprovalWithoutRebind(t *testing.T) {
	ticks := make(chan time.Time)
	var approved atomic.Bool
	projected := make(chan struct{}, 32)
	projector := projectionFunc(func(ctx context.Context, req accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		p, e := refreshProjection(ctx, req)
		if !approved.Load() {
			p.DeviceIDs = nil
		}
		projected <- struct{}{}
		return p, e
	})
	r, a, b, as, bs := refreshFixture(t, time.Second, ticks, nil, gateFunc(allowGate), projector)
	refreshBind(t, r, a, b)
	refreshAwait(t, projected)
	refreshAwait(t, projected)
	noPresence(t, as)
	approved.Store(true)
	refreshTick(t, ticks)
	expectPresence(t, as, "internet", b.deviceID)
	expectPresence(t, bs, "internet", a.deviceID)
}
func TestAccountPresenceRefreshUnchangedAndManualOverlap(t *testing.T) {
	for _, manual := range []bool{false, true} {
		name := "unchanged"
		if manual {
			name = "manual"
		}
		t.Run(name, func(t *testing.T) {
			ticks := make(chan time.Time)
			var denied atomic.Bool
			var graph presence.TrustGraph
			aID, _ := identity(81, true)
			bID, _ := identity(82, true)
			if manual {
				graph = manualPairGraph{aID, bID}
			}
			calls := make(chan struct{}, 64)
			gate := gateFunc(func(ctx context.Context, req accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				defer func() { calls <- struct{}{} }()
				if denied.Load() {
					return accountgroup.RouteAdmissionOutcome{}, errors.New("revoked")
				}
				return allowGate(ctx, req, fn)
			})
			r, a, b, as, bs := refreshFixture(t, time.Second, ticks, graph, gate, nil)
			refreshBind(t, r, a, b)
			expectPresence(t, as, "internet", b.deviceID)
			expectPresence(t, bs, "internet", a.deviceID)
			refreshAwait(t, calls)
			refreshAwait(t, calls)
			if manual {
				denied.Store(true)
			}
			for i := 0; i < 3; i++ {
				refreshTick(t, ticks)
				refreshAwait(t, calls)
				refreshAwait(t, calls)
			}
			noPresence(t, as)
			noPresence(t, bs)
			if manual {
				if _, err := r.Route(context.Background(), a, b.deviceID, []byte("manual")); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
func TestAccountPresenceRefreshBlockedProviderCoalescesExactRoutes(t *testing.T) {
	ticks := make(chan time.Time)
	entered := make(chan struct{}, 1)
	var calls atomic.Int32
	projector := projectionFunc(func(ctx context.Context, _ accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		calls.Add(1)
		entered <- struct{}{}
		<-ctx.Done()
		return accountgroup.PresenceProjection{}, ctx.Err()
	})
	r, a, b, _, _ := refreshFixture(t, time.Second, ticks, nil, gateFunc(allowGate), projector)
	if err := r.Bind(a, bindingFor(a)); err != nil {
		t.Fatal(err)
	}
	refreshAwait(t, entered)
	if err := r.Bind(b, bindingFor(b)); err != nil {
		t.Fatal(err)
	}
	id, key := identity(83, true)
	unattached, err := r.Register(id, key, "unattached")
	if err != nil {
		t.Fatal(err)
	}
	if err = r.Bind(unattached, bindingFor(unattached)); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		refreshTick(t, ticks)
	}
	if err = r.Unbind(b); err != nil {
		t.Fatal(err)
	}
	if err = r.Bind(b, bindingFor(b)); err != nil {
		t.Fatal(err)
	}
	refreshTick(t, ticks)
	refreshTick(t, ticks)
	r.presence.mu.Lock()
	r.owner.mu.Lock()
	if len(r.presence.queue) != 2 {
		t.Errorf("queue=%d, want two coalesced attached routes", len(r.presence.queue))
	}
	for _, j := range r.presence.queue {
		c := r.owner.current(j.handle)
		if c == nil || c.presence == nil || c.binding == nil || c.bindingVersion != j.version {
			t.Error("queued stale/unattached route")
		}
	}
	r.owner.mu.Unlock()
	r.presence.mu.Unlock()
	if calls.Load() != 1 {
		t.Errorf("overlapping provider work: %d", calls.Load())
	}
	r.Shutdown()
}
func TestAccountPresenceRefreshShutdownAndLateTick(t *testing.T) {
	ticks := make(chan time.Time, 1)
	entered := make(chan struct{}, 1)
	var calls atomic.Int32
	projector := projectionFunc(func(ctx context.Context, _ accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		calls.Add(1)
		entered <- struct{}{}
		<-ctx.Done()
		return accountgroup.PresenceProjection{}, ctx.Err()
	})
	r, a, _, _, _ := refreshFixture(t, time.Second, ticks, nil, gateFunc(allowGate), projector)
	if err := r.Bind(a, bindingFor(a)); err != nil {
		t.Fatal(err)
	}
	refreshAwait(t, entered)
	done := make(chan struct{}, 2)
	for i := 0; i < 2; i++ {
		go func() { r.Shutdown(); done <- struct{}{} }()
	}
	refreshAwait(t, done)
	refreshAwait(t, done)
	select {
	case <-r.presence.refreshDone:
	default:
		t.Fatal("shutdown did not join refresh runner")
	}
	ticks <- time.Time{}
	if err := r.Bind(a, bindingFor(a)); err == nil {
		t.Fatal("bind after shutdown")
	}
	r.presence.mu.Lock()
	defer r.presence.mu.Unlock()
	if len(r.presence.queue) != 0 || len(r.presence.pending) != 0 || calls.Load() != 1 {
		t.Fatal("post-stop work resurrected")
	}
}
func TestAccountPresenceRefreshConfiguration(t *testing.T) {
	for _, interval := range []time.Duration{-1, 60*time.Second + 1, 0, 60 * time.Second} {
		r, err := NewCompositeConnectionRouterWithPresence(1, presenceGraph{}, gateFunc(allowGate), AccountPresenceConfig{Hub: presence.NewHub(presenceGraph{}), Projection: projectionFunc(refreshProjection), CandidatesPerTurn: 1, WorkTimeout: time.Second, RefreshInterval: interval})
		invalid := interval < 0 || interval > 60*time.Second
		if r != nil {
			r.Shutdown()
		}
		if (err != nil) != invalid {
			t.Errorf("interval %v err=%v", interval, err)
		}
	}
}
func TestAccountPresenceRefreshZeroIsEventOnly(t *testing.T) {
	ticks := make(chan time.Time, 1)
	var calls atomic.Int32
	projector := projectionFunc(func(ctx context.Context, req accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		calls.Add(1)
		return refreshProjection(ctx, req)
	})
	r, a, b, as, bs := refreshFixture(t, 0, ticks, nil, gateFunc(allowGate), projector)
	select {
	case <-r.presence.refreshDone:
	default:
		t.Fatal("zero interval started a runner")
	}
	refreshBind(t, r, a, b)
	expectPresence(t, as, "internet", b.deviceID)
	expectPresence(t, bs, "internet", a.deviceID)
	noPresence(t, as)
	before := calls.Load()
	ticks <- time.Time{}
	noPresence(t, as)
	if calls.Load() != before {
		t.Fatal("zero interval refreshed")
	}
}

func TestAccountPresenceRefreshClosedTickStreamExits(t *testing.T) {
	ticks := make(chan time.Time)
	r, _, _, _, _ := refreshFixture(t, time.Second, ticks, nil, gateFunc(allowGate), nil)
	close(ticks)
	refreshAwait(t, r.presence.refreshDone)
}
func TestAccountPresenceRefreshRealTimer(t *testing.T) {
	var denied atomic.Bool
	projector := projectionFunc(func(ctx context.Context, req accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error) {
		if denied.Load() {
			return accountgroup.PresenceProjection{}, errors.New("revoked")
		}
		return refreshProjection(ctx, req)
	})
	r, a, b, as, bs := refreshFixture(t, 5*time.Millisecond, nil, nil, gateFunc(allowGate), projector)
	refreshBind(t, r, a, b)
	expectPresence(t, as, "internet", b.deviceID)
	expectPresence(t, bs, "internet", a.deviceID)
	noPresence(t, as)
	denied.Store(true)
	expectPresence(t, as, "offline", b.deviceID)
	expectPresence(t, bs, "offline", a.deviceID)
}
