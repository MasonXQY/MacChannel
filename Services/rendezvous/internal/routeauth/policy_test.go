package routeauth

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/signal"
)

type graphFunc func(string, string) bool

func (f graphFunc) ShareGraph(a, b string) bool { return f(a, b) }

type gateFunc func(context.Context, accountgroup.RouteAdmissionRequest, func() bool) (accountgroup.RouteAdmissionOutcome, error)

func (f gateFunc) Admit(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	return f(ctx, r, fn)
}
func allowGate(_ context.Context, _ accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	if !fn() {
		return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrRouteNotAdmitted
	}
	return accountgroup.RouteAdmissionOutcome{Admitted: true}, nil
}
func bindPair(t *testing.T, o *ConnectionOwner, from, to ConnectionHandle) {
	t.Helper()
	for _, h := range []ConnectionHandle{from, to} {
		if err := o.Bind(h, bindingFor(h)); err != nil {
			t.Fatal(err)
		}
	}
}
func requireFrame(t *testing.T, o *ConnectionOwner, to ConnectionHandle, from string, payload []byte) {
	t.Helper()
	f, state := o.TryDequeue(to)
	if state != QueueReady || f.Type != "signal" || f.From != from || !bytes.Equal(f.Payload, payload) {
		t.Fatal("wrong frame", state)
	}
	if _, state = o.TryDequeue(to); state != QueueEmpty {
		t.Fatal("more than one frame", state)
	}
}

func TestPolicyManualSurvivesAccountState(t *testing.T) {
	for _, kind := range []string{"manual only", "overlap", "unbound", "logout", "account unavailable"} {
		t.Run(kind, func(t *testing.T) {
			o, from, to := ownerFixture(t, 1)
			if kind != "manual only" {
				bindPair(t, o, from, to)
			}
			if kind == "unbound" || kind == "logout" {
				o.Unbind(from)
				o.Unbind(to)
			}
			var gateCalls atomic.Int32
			gate := gateFunc(func(context.Context, accountgroup.RouteAdmissionRequest, func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				gateCalls.Add(1)
				return accountgroup.RouteAdmissionOutcome{}, errors.New("synthetic account unavailable")
			})
			p := NewCompositePolicy(o, graphFunc(func(a, b string) bool { return a == from.deviceID && b == to.deviceID }), gate)
			if kind == "manual only" {
				p = NewManualPolicy(o, graphFunc(func(string, string) bool { return true }))
			}
			out, err := p.Route(context.Background(), from, to.deviceID, []byte("manual"))
			if err != nil || out.Source != Manual || out.CleanupFailed || gateCalls.Load() != 0 {
				t.Fatal("manual lost", out, err)
			}
			requireFrame(t, o, to, from.deviceID, []byte("manual"))
		})
	}
}

func TestPolicyAccountOnlyOwnsExactRequestAndPayload(t *testing.T) {
	o, from, to := ownerFixture(t, 1)
	bindPair(t, o, from, to)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	var received accountgroup.RouteAdmissionRequest
	gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		received = r
		close(entered)
		<-release
		return allowGate(ctx, r, fn)
	})
	p := NewCompositePolicy(o, graphFunc(func(string, string) bool { return false }), gate)
	payload := []byte("original")
	done := make(chan error, 1)
	go func() {
		out, err := p.Route(context.Background(), from, to.deviceID, payload)
		if err == nil && out.Source != AccountGroup {
			err = errors.New("wrong authority source")
		}
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("gate not entered")
	}
	if received.From.Actor != bindingFor(from).Actor || received.To.Actor != bindingFor(to).Actor || received.From.ConnectionGeneration != from.generation || received.To.ConnectionGeneration != to.generation || received.GroupID != bindingFor(from).GroupID || received.Generation != 1 {
		t.Fatal("wrong exact gate tuple")
	}
	_, fromKey := identity(1, true)
	_, toKey := identity(2, false)
	if !bytes.Equal(received.From.PublicKey, fromKey) || !bytes.Equal(received.To.PublicKey, toKey) {
		t.Fatal("wrong gate keys")
	}
	payload[0] = 'X'
	received.From.PublicKey[0] ^= 1
	received.To.PublicKey[0] ^= 1
	unblock()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("route stuck")
	}
	requireFrame(t, o, to, from.deviceID, []byte("original"))
	pair, _ := o.snapshot(from, to.deviceID, true)
	if !bytes.Equal(pair.from.publicKey, fromKey) || !bytes.Equal(pair.to.publicKey, toKey) {
		t.Fatal("gate mutated owner keys")
	}
}

func TestPolicyUniformDenialAndNoGateForMismatchedBindings(t *testing.T) {
	for _, kind := range []string{"unbound from", "unbound to", "different account", "different group", "different generation", "target absent", "target malformed", "self", "stale from", "foreign owner", "empty payload", "oversize", "cancelled", "nil context", "nil gate", "nil owner"} {
		t.Run(kind, func(t *testing.T) {
			o, from, to := ownerFixture(t, 1)
			bindPair(t, o, from, to)
			target := to.deviceID
			payload := []byte("frame")
			ctx := context.Background()
			var calls atomic.Int32
			var gate AccountGate = gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				calls.Add(1)
				return allowGate(ctx, r, fn)
			})
			switch kind {
			case "unbound from":
				o.Unbind(from)
			case "unbound to":
				o.Unbind(to)
			case "different account":
				b := bindingFor(to)
				b.Actor.AccountID = "22222222-2222-3333-4444-555555555555"
				o.Bind(to, b)
			case "different group":
				b := bindingFor(to)
				b.GroupID = "22222222-2222-3333-4444-555555555555"
				o.Bind(to, b)
			case "different generation":
				b := bindingFor(to)
				b.Generation++
				o.Bind(to, b)
			case "target absent":
				target, _ = identity(7, true)
			case "target malformed":
				target = "bad"
			case "self":
				target = from.deviceID
			case "stale from":
				o.Close(from)
			case "foreign owner":
				_, from, _ = ownerFixture(t, 1)
			case "empty payload":
				payload = nil
			case "oversize":
				payload = make([]byte, signal.MaximumFrameSize+1)
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			case "nil context":
				ctx = nil
			case "nil gate":
				gate = nil
			}
			owner := o
			if kind == "nil owner" {
				owner = nil
			}
			p := NewCompositePolicy(owner, nil, gate)
			out, err := p.Route(ctx, from, target, payload)
			if err != ErrDenied || out.Source != NoAuthority || calls.Load() != 0 {
				t.Fatal("nonuniform denial or gate called", kind, out, err, calls.Load())
			}
			if _, state := o.TryDequeue(to); state != QueueEmpty {
				t.Fatal("denial enqueued", state)
			}
		})
	}
}

func TestPolicyGateDenyOrCleanupNeverRetries(t *testing.T) {
	for _, kind := range []string{"denied", "unavailable", "claims admitted without callback", "cleanup failure", "error after enqueue", "callback twice", "late callback"} {
		t.Run(kind, func(t *testing.T) {
			o, from, to := ownerFixture(t, 2)
			bindPair(t, o, from, to)
			calls := 0
			var late func() bool
			gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				calls++
				switch kind {
				case "denied", "unavailable":
					return accountgroup.RouteAdmissionOutcome{}, errors.New("private group session detail")
				case "claims admitted without callback":
					return accountgroup.RouteAdmissionOutcome{Admitted: true}, nil
				case "late callback":
					late = fn
					return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrGroupInvalid
				default:
					if !fn() {
						t.Error("first callback denied")
					}
					if kind == "callback twice" && fn() {
						t.Error("second callback admitted")
					}
					if kind == "error after enqueue" {
						return accountgroup.RouteAdmissionOutcome{}, errors.New("unexpected post-admission error")
					}
					out := accountgroup.RouteAdmissionOutcome{Admitted: true}
					if kind == "cleanup failure" {
						out.CleanupError = errors.New("private SQL detail")
					}
					return out, nil
				}
			})
			p := NewCompositePolicy(o, nil, gate)
			out, err := p.Route(context.Background(), from, to.deviceID, []byte("one"))
			admitted := kind == "cleanup failure" || kind == "error after enqueue" || kind == "callback twice"
			if calls != 1 {
				t.Fatal("gate retried", calls)
			}
			if admitted {
				if err != nil || out.Source != AccountGroup || out.CleanupFailed != (kind != "callback twice") {
					t.Fatal(out, err)
				}
				requireFrame(t, o, to, from.deviceID, []byte("one"))
			} else {
				if err != ErrDenied || out.Source != NoAuthority {
					t.Fatal(out, err)
				}
				if late != nil && late() {
					t.Fatal("retained callback admitted after return")
				}
				if _, state := o.TryDequeue(to); state != QueueEmpty {
					t.Fatal("denied gate inserted frame")
				}
			}
			if strings.Contains(errString(err), "private") {
				t.Fatal("private gate details leaked")
			}
		})
	}
}
func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestPolicyBindingAndConnectionChangesDuringGate(t *testing.T) {
	for _, side := range []string{"from", "to"} {
		for _, kind := range []string{"session", "account", "audience", "group", "generation", "unbind", "same binding ABA", "replace", "close"} {
			t.Run(side+"/"+kind, func(t *testing.T) {
				o, from, to := ownerFixture(t, 1)
				bindPair(t, o, from, to)
				entered, release := make(chan struct{}), make(chan struct{})
				var once sync.Once
				unblock := func() { once.Do(func() { close(release) }) }
				defer unblock()
				gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
					close(entered)
					<-release
					return allowGate(ctx, r, fn)
				})
				p := NewCompositePolicy(o, nil, gate)
				done := make(chan error, 1)
				go func() { _, err := p.Route(context.Background(), from, to.deviceID, []byte("stale")); done <- err }()
				select {
				case <-entered:
				case <-time.After(time.Second):
					t.Fatal("gate not entered")
				}
				h := from
				if side == "to" {
					h = to
				}
				b := bindingFor(h)
				switch kind {
				case "session":
					b.Actor.SessionID = "eeeeeeee-1111-2222-3333-444444444444"
					o.Bind(h, b)
				case "account":
					b.Actor.AccountID = "22222222-2222-3333-4444-555555555555"
					o.Bind(h, b)
				case "audience":
					b.Actor.Audience = "other.app"
					o.Bind(h, b)
				case "group":
					b.GroupID = "22222222-2222-3333-4444-555555555555"
					o.Bind(h, b)
				case "generation":
					b.Generation++
					o.Bind(h, b)
				case "unbind":
					o.Unbind(h)
				case "same binding ABA":
					o.Unbind(h)
					o.Bind(h, b)
				case "close":
					o.Close(h)
				case "replace":
					o.Close(h)
					n, raw := 1, true
					if side == "to" {
						n, raw = 2, false
					}
					id, key := identity(n, raw)
					replacement, err := o.Register(id, key, "replacement")
					if err != nil {
						t.Fatal(err)
					}
					// A new socket may authenticate the same still-live session.
					// Only exact handle fencing can reject this old request.
					if err := o.Bind(replacement, b); err != nil {
						t.Fatal(err)
					}
					if side == "to" {
						to = replacement
					}
				}
				unblock()
				select {
				case err := <-done:
					if err != ErrDenied {
						t.Fatal("stale snapshot admitted", err)
					}
				case <-time.After(time.Second):
					t.Fatal("callback blocked")
				}
				if _, state := o.TryDequeue(to); state != QueueEmpty && state != QueueClosed {
					t.Fatal("stale frame queued", state)
				}
				if o.queuedBytes != 0 {
					t.Fatal("failed admission consumed budget")
				}
			})
		}
	}
}

func TestPolicyQueueFullBusyAndBudget(t *testing.T) {
	for _, kind := range []string{"full", "busy", "byte budget"} {
		t.Run(kind, func(t *testing.T) {
			o, from, to := ownerFixture(t, 1)
			bindPair(t, o, from, to)
			var lockHeld bool
			gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				if kind == "busy" {
					o.mu.Lock()
					lockHeld = true
					defer func() { lockHeld = false; o.mu.Unlock() }()
				}
				return allowGate(ctx, r, fn)
			})
			p := NewCompositePolicy(o, nil, gate)
			wantBytes := 0
			if kind == "full" {
				if _, err := p.Route(context.Background(), from, to.deviceID, []byte("first")); err != nil {
					t.Fatal(err)
				}
				wantBytes = 5
			}
			if kind == "byte budget" {
				o.maximumQueuedBytes = 2
			}
			if _, err := p.Route(context.Background(), from, to.deviceID, []byte("later")); err != ErrDenied {
				t.Fatal("queue limit bypass", err)
			}
			if lockHeld || o.queuedBytes != wantBytes {
				t.Fatal("rejection changed budget")
			}
			if kind == "full" {
				requireFrame(t, o, to, from.deviceID, []byte("first"))
				if o.queuedBytes != 0 {
					t.Fatal("dequeue did not return bytes")
				}
			}
		})
	}
}

func TestPolicyManualAndAccountDoNotCreateTransitiveEdges(t *testing.T) {
	o, a, b := ownerFixture(t, 2)
	cid, ck := identity(3, true)
	c, err := o.Register(cid, ck, "source-c")
	if err != nil {
		t.Fatal(err)
	}
	bindPair(t, o, b, c)
	manual := graphFunc(func(x, y string) bool {
		return x == a.deviceID && y == b.deviceID || x == b.deviceID && y == a.deviceID
	})
	p := NewCompositePolicy(o, manual, gateFunc(allowGate))
	if _, err := p.Route(context.Background(), a, b.deviceID, []byte("manual")); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Route(context.Background(), b, c.deviceID, []byte("account")); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Route(context.Background(), a, c.deviceID, []byte("forbidden")); err != ErrDenied {
		t.Fatal("mixed transitivity", err)
	}
	requireFrame(t, o, c, b.deviceID, []byte("account"))
	// Legacy graph's own transitive decision remains authoritative when supplied.
	legacy := NewManualPolicy(o, graphFunc(func(string, string) bool { return true }))
	if _, err := legacy.Route(context.Background(), a, c.deviceID, []byte("legacy")); err != nil {
		t.Fatal(err)
	}
	requireFrame(t, o, c, a.deviceID, []byte("legacy"))
}

func TestPolicyManualMaximumPayloadOwnership(t *testing.T) {
	o, from, to := ownerFixture(t, 1)
	p := NewManualPolicy(o, graphFunc(func(string, string) bool { return true }))
	payload := bytes.Repeat([]byte{42}, signal.MaximumFrameSize)
	if _, err := p.Route(context.Background(), from, to.deviceID, payload); err != nil {
		t.Fatal(err)
	}
	payload[0] = 9
	f, state := o.TryDequeue(to)
	if state != QueueReady || len(f.Payload) != signal.MaximumFrameSize || f.Payload[0] != 42 || o.queuedBytes != 0 {
		t.Fatal("manual queue did not own payload")
	}
}

func TestPolicyManualRechecksHandlesButIgnoresAccountChange(t *testing.T) {
	for _, kind := range []string{"unbind", "source replaced", "target replaced"} {
		t.Run(kind, func(t *testing.T) {
			o, from, to := ownerFixture(t, 1)
			bindPair(t, o, from, to)
			var gates atomic.Int32
			graph := graphFunc(func(string, string) bool {
				// Graph is called outside the owner lock. Simulate replacement during
				// authority lookup, without any SQL or owner callback scheduler hook.
				switch kind {
				case "unbind":
					o.Unbind(from)
					o.Unbind(to)
				case "source replaced":
					o.Close(from)
					id, key := identity(1, true)
					if _, err := o.Register(id, key, "replacement"); err != nil {
						t.Error(err)
					}
				case "target replaced":
					o.Close(to)
					id, key := identity(2, false)
					var err error
					to, err = o.Register(id, key, "replacement")
					if err != nil {
						t.Error(err)
					}
				}
				return true
			})
			gate := gateFunc(func(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				gates.Add(1)
				return allowGate(ctx, r, fn)
			})
			p := NewCompositePolicy(o, graph, gate)
			out, err := p.Route(context.Background(), from, to.deviceID, []byte("manual"))
			if kind == "unbind" {
				if err != nil || out.Source != Manual {
					t.Fatal("account unbind withdrew manual", out, err)
				}
				requireFrame(t, o, to, from.deviceID, []byte("manual"))
			} else if err != ErrDenied || o.queuedBytes != 0 {
				t.Fatal("stale manual handle accepted", out, err)
			}
			if gates.Load() != 0 {
				t.Fatal("manual queue failure triggered account retry")
			}
		})
	}
}

func TestPolicyIndependentOwnersAndFreshBinding(t *testing.T) {
	a, af, at := ownerFixture(t, 1)
	b, bf, bt := ownerFixture(t, 1)
	bindPair(t, a, af, at)
	gate := gateFunc(allowGate)
	pa, pb := NewCompositePolicy(a, nil, gate), NewCompositePolicy(b, nil, gate)
	if _, err := pa.Route(context.Background(), af, at.deviceID, []byte("a")); err != nil {
		t.Fatal(err)
	}
	if _, state := b.TryDequeue(bt); state != QueueEmpty {
		t.Fatal("cross-owner queue")
	}
	if _, err := pb.Route(context.Background(), bf, bt.deviceID, []byte("unbound")); err != ErrDenied {
		t.Fatal("restart inherited account binding")
	}
	if _, err := pb.Route(context.Background(), af, bt.deviceID, []byte("foreign")); err != ErrDenied {
		t.Fatal("foreign incarnation accepted")
	}
	bindPair(t, b, bf, bt)
	if _, err := pb.Route(context.Background(), bf, bt.deviceID, []byte("b")); err != nil {
		t.Fatal(err)
	}
	requireFrame(t, a, at, af.deviceID, []byte("a"))
	requireFrame(t, b, bt, bf.deviceID, []byte("b"))
}
