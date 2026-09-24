package routeauth

import (
	"bytes"
	"context"
	"errors"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/accountinvite"
	"macchannel/rendezvous/internal/signal"
	"reflect"
	"testing"
)

type invitationGateFunc func(context.Context, accountinvite.RouteAdmissionRequest, func() bool) (accountgroup.RouteAdmissionOutcome, error)

func (f invitationGateFunc) Admit(c context.Context, r accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	return f(c, r, fn)
}
func bindInvitationPair(t *testing.T, o *ConnectionOwner, from, to ConnectionHandle) {
	t.Helper()
	bindPair(t, o, from, to)
	b := bindingFor(to)
	b.Actor.AccountID = "22222222-2222-3333-4444-555555555555"
	b.Actor.Audience = "other.app"
	b.GroupID = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
	b.Generation = 7
	if e := o.Bind(to, b); e != nil {
		t.Fatal(e)
	}
}
func TestInvitationPolicyDirectCrossAccountPair(t *testing.T) {
	o, from, to := ownerFixture(t, 1)
	bindInvitationPair(t, o, from, to)
	calls := 0
	gate := invitationGateFunc(func(ctx context.Context, r accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		calls++
		if r.From.Actor.AccountID == r.To.Actor.AccountID || r.From.GroupID == r.To.GroupID || r.From.Generation != 1 || r.To.Generation != 7 {
			t.Error("separate endpoint contexts lost")
		}
		return accountgroup.RouteAdmissionOutcome{Admitted: fn()}, nil
	})
	p := NewCompositePolicyWithInvitations(o, nil, nil, gate)
	out, e := p.Route(context.Background(), from, to.deviceID, []byte("invitation"))
	if e != nil || calls != 1 || out.Source != AccountInvitation {
		t.Fatal("direct invitation not routed", out, e, calls)
	}
	requireFrame(t, o, to, from.deviceID, []byte("invitation"))
}

func allowInvitation(_ context.Context, _ accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	return accountgroup.RouteAdmissionOutcome{Admitted: fn()}, nil
}

func TestInvitationPolicyManualAndGroupIsolation(t *testing.T) {
	for _, kind := range []string{"manual overlap", "manual queue failure", "invitation nil", "legacy constructor", "group success", "group denied", "same account wrong group", "same account wrong generation", "same account nil group", "source unbound", "target unbound"} {
		t.Run(kind, func(t *testing.T) {
			o, from, to := ownerFixture(t, 1)
			bindInvitationPair(t, o, from, to)
			groupCalls, inviteCalls := 0, 0
			group := gateFunc(func(c context.Context, r accountgroup.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				groupCalls++
				if kind == "group denied" {
					return accountgroup.RouteAdmissionOutcome{}, errors.New("private group revoked")
				}
				return allowGate(c, r, fn)
			})
			invite := invitationGateFunc(func(c context.Context, r accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				inviteCalls++
				return allowInvitation(c, r, fn)
			})
			var manual signal.TrustGraph
			if kind == "manual overlap" || kind == "manual queue failure" {
				manual = graphFunc(func(string, string) bool { return true })
			}
			if kind == "manual queue failure" {
				o.maximumQueuedBytes = 1
			}
			if kind == "group success" || kind == "group denied" || kind == "same account wrong group" || kind == "same account wrong generation" || kind == "same account nil group" {
				bindPair(t, o, from, to)
				b := bindingFor(to)
				if kind == "same account wrong group" {
					b.GroupID = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
					o.Bind(to, b)
				}
				if kind == "same account wrong generation" {
					b.Generation++
					o.Bind(to, b)
				}
			}
			p := NewCompositePolicyWithInvitations(o, manual, group, invite)
			if kind == "invitation nil" {
				p = NewCompositePolicyWithInvitations(o, nil, group, nil)
			}
			if kind == "legacy constructor" {
				p = NewCompositePolicy(o, nil, group)
			}
			if kind == "same account nil group" {
				p = NewCompositePolicyWithInvitations(o, nil, nil, invite)
			}
			if kind == "source unbound" {
				o.Unbind(from)
			}
			if kind == "target unbound" {
				o.Unbind(to)
			}
			out, e := p.Route(context.Background(), from, to.deviceID, []byte("frame"))
			switch kind {
			case "manual overlap":
				if e != nil || out.Source != Manual {
					t.Fatal(out, e)
				}
				requireFrame(t, o, to, from.deviceID, []byte("frame"))
			case "group success":
				if e != nil || out.Source != AccountGroup || groupCalls != 1 {
					t.Fatal(out, e, groupCalls)
				}
				requireFrame(t, o, to, from.deviceID, []byte("frame"))
			default:
				if e != ErrDenied || out.Source != NoAuthority || o.queuedBytes != 0 {
					t.Fatal("expected denial", kind, out, e)
				}
			}
			if inviteCalls != 0 {
				t.Fatal("independent source was fallback", kind, inviteCalls)
			}
			if kind != "group success" && kind != "group denied" && groupCalls != 0 {
				t.Fatal("group gate called for unrelated authority", kind)
			}
		})
	}
}

func TestInvitationPolicyOneShotCallbackAndQueueBounds(t *testing.T) {
	for _, kind := range []string{"denied", "false admission claim", "late callback", "twice", "cleanup failure", "error after enqueue", "full", "busy", "byte budget", "cancelled at callback"} {
		t.Run(kind, func(t *testing.T) {
			o, from, to := ownerFixture(t, 1)
			bindInvitationPair(t, o, from, to)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			var late func() bool
			gate := invitationGateFunc(func(c context.Context, r accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
				calls++
				switch kind {
				case "denied":
					return accountgroup.RouteAdmissionOutcome{}, errors.New("private invitation details")
				case "false admission claim":
					return accountgroup.RouteAdmissionOutcome{Admitted: true}, nil
				case "late callback":
					late = fn
					return accountgroup.RouteAdmissionOutcome{}, nil
				case "busy":
					o.mu.Lock()
					defer o.mu.Unlock()
				case "cancelled at callback":
					cancel()
				}
				admitted := fn()
				if kind == "twice" && fn() {
					t.Error("second callback inserted")
				}
				if kind == "error after enqueue" {
					return accountgroup.RouteAdmissionOutcome{}, errors.New("private cleanup error")
				}
				out := accountgroup.RouteAdmissionOutcome{Admitted: admitted}
				if kind == "cleanup failure" {
					out.CleanupError = errors.New("private SQL detail")
				}
				return out, nil
			})
			p := NewCompositePolicyWithInvitations(o, nil, nil, gate)
			if kind == "full" {
				prefill := NewCompositePolicyWithInvitations(o, nil, nil, invitationGateFunc(allowInvitation))
				if _, e := prefill.Route(ctx, from, to.deviceID, []byte("old")); e != nil {
					t.Fatal(e)
				}
			}
			if kind == "byte budget" {
				o.maximumQueuedBytes = 1
			}
			out, e := p.Route(ctx, from, to.deviceID, []byte("new"))
			want := kind == "twice" || kind == "cleanup failure" || kind == "error after enqueue"
			if calls != 1 {
				t.Fatal("gate repeated", calls)
			}
			if want {
				if e != nil || out.Source != AccountInvitation || out.CleanupFailed != (kind != "twice") {
					t.Fatal(out, e)
				}
				requireFrame(t, o, to, from.deviceID, []byte("new"))
			} else {
				if e != ErrDenied || out.Source != NoAuthority {
					t.Fatal(out, e)
				}
				if late != nil && late() {
					t.Fatal("retained callback inserted")
				}
				if kind == "full" {
					requireFrame(t, o, to, from.deviceID, []byte("old"))
				} else if _, state := o.TryDequeue(to); state != QueueEmpty {
					t.Fatal("denied frame queued")
				}
			}
		})
	}
}

func TestInvitationPolicyRechecksEveryBindingIncarnation(t *testing.T) {
	for _, side := range []string{"from", "to"} {
		for _, kind := range []string{"session", "account", "audience", "group", "generation", "unbind", "ABA", "close", "replace"} {
			t.Run(side+"/"+kind, func(t *testing.T) {
				o, from, to := ownerFixture(t, 1)
				bindInvitationPair(t, o, from, to)
				target := to
				gate := invitationGateFunc(func(c context.Context, r accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
					pair, _ := o.snapshot(from, to.deviceID, true)
					h := from
					b := *pair.from.binding
					if side == "to" {
						h = to
						b = *pair.to.binding
					}
					switch kind {
					case "session":
						b.Actor.SessionID = "eeeeeeee-1111-2222-3333-444444444444"
						o.Bind(h, b)
					case "account":
						b.Actor.AccountID = "33333333-2222-3333-4444-555555555555"
						o.Bind(h, b)
					case "audience":
						b.Actor.Audience = "changed.app"
						o.Bind(h, b)
					case "group":
						b.GroupID = "cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee"
						o.Bind(h, b)
					case "generation":
						b.Generation++
						o.Bind(h, b)
					case "unbind":
						o.Unbind(h)
					case "ABA":
						o.Unbind(h)
						o.Bind(h, b)
					case "close":
						o.Close(h)
					case "replace":
						o.Close(h)
						key := pair.from.publicKey
						if side == "to" {
							key = pair.to.publicKey
						}
						replacement, e := o.Register(h.deviceID, key, "replacement")
						if e != nil {
							t.Error(e)
							return accountgroup.RouteAdmissionOutcome{}, e
						}
						if e = o.Bind(replacement, b); e != nil {
							t.Error(e)
						}
						if side == "to" {
							target = replacement
						}
					}
					return allowInvitation(c, r, fn)
				})
				p := NewCompositePolicyWithInvitations(o, nil, nil, gate)
				out, e := p.Route(context.Background(), from, to.deviceID, []byte("stale"))
				if e != ErrDenied || out.Source != NoAuthority || o.queuedBytes != 0 {
					t.Fatal("stale admission", out, e)
				}
				if _, state := o.TryDequeue(target); state != QueueEmpty && state != QueueClosed {
					t.Fatal("stale frame queued")
				}
			})
		}
	}
}

func TestInvitationPolicyOwnsPayloadAndKeys(t *testing.T) {
	o, from, to := ownerFixture(t, 1)
	bindInvitationPair(t, o, from, to)
	before, _ := o.snapshot(from, to.deviceID, true)
	payload := []byte("original")
	gate := invitationGateFunc(func(c context.Context, r accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
		if !reflect.DeepEqual(r.From.Actor, before.from.binding.Actor) || !bytes.Equal(r.From.PublicKey, before.from.publicKey) || r.From.ConnectionGeneration != from.generation || r.To.ConnectionGeneration != to.generation || r.To.Actor.Audience != "other.app" {
			t.Error("wrong exact request")
		}
		payload[0] = 'X'
		r.From.PublicKey[0] ^= 1
		r.To.PublicKey[0] ^= 1
		return allowInvitation(c, r, fn)
	})
	p := NewCompositePolicyWithInvitations(o, nil, nil, gate)
	if _, e := p.Route(context.Background(), from, to.deviceID, payload); e != nil {
		t.Fatal(e)
	}
	requireFrame(t, o, to, from.deviceID, []byte("original"))
	after, _ := o.snapshot(from, to.deviceID, true)
	if !bytes.Equal(before.from.publicKey, after.from.publicKey) || !bytes.Equal(before.to.publicKey, after.to.publicKey) {
		t.Fatal("gate changed owner key")
	}
}

func TestInvitationRouterOptionalComposition(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		r, e := NewCompositeConnectionRouterWithInvitations(1, nil, nil, func() InvitationGate {
			if enabled {
				return invitationGateFunc(allowInvitation)
			}
			return nil
		}())
		if e != nil {
			t.Fatal(e)
		}
		a, ak := identity(1, true)
		b, bk := identity(2, false)
		from, _ := r.Register(a, ak, "a")
		to, _ := r.Register(b, bk, "b")
		bindInvitationPair(t, r.owner, from, to)
		out, e := r.Route(context.Background(), from, b, []byte("x"))
		if enabled {
			if e != nil || out.Source != AccountInvitation {
				t.Fatal(out, e)
			}
		} else if e != ErrDenied {
			t.Fatal("nil enabled")
		}
		r.Close(from)
		r.Close(to)
	}
	if _, e := NewCompositeConnectionRouterWithInvitations(0, nil, nil, nil); e != ErrQueueCapacity {
		t.Fatal("constructor queue limit", e)
	}
}
