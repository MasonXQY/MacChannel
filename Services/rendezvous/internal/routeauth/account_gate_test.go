package routeauth

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"macchannel/rendezvous/internal/accountgroup"
)

type storeFunc func(context.Context, accountgroup.RouteAdmissionRequest, func(accountgroup.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error)

func (f storeFunc) AdmitRoute(ctx context.Context, r accountgroup.RouteAdmissionRequest, fn func(accountgroup.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error) {
	return f(ctx, r, fn)
}

func TestAccountGateForwardsExactRequestAndAdmittedCleanup(t *testing.T) {
	o, from, to := ownerFixture(t, 1)
	bindPair(t, o, from, to)
	pair, _ := o.snapshot(from, to.deviceID, true)
	req := accountgroup.RouteAdmissionRequest{From: accountgroup.RouteEndpoint{Actor: pair.from.binding.Actor, PublicKey: pair.from.publicKey, ConnectionGeneration: from.generation}, To: accountgroup.RouteEndpoint{Actor: pair.to.binding.Actor, PublicKey: pair.to.publicKey, ConnectionGeneration: to.generation}, GroupID: pair.from.binding.GroupID, Generation: pair.from.binding.Generation}
	ctx := context.Background()
	cleanup := errors.New("synthetic SQL cleanup failure")
	calls, callbacks := 0, 0
	gate := &PostgresAccountGate{store: storeFunc(func(gotContext context.Context, got accountgroup.RouteAdmissionRequest, fn func(accountgroup.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error) {
		calls++
		if gotContext != ctx || !reflect.DeepEqual(got, req) {
			t.Error("adapter changed exact request")
		}
		if !fn(got) {
			t.Error("enqueue not forwarded")
		}
		return accountgroup.RouteAdmissionOutcome{Admitted: true, CleanupError: cleanup}, nil
	})}
	out, err := gate.Admit(ctx, req, func() bool { callbacks++; return true })
	if err != nil || !out.Admitted || out.CleanupError != cleanup || calls != 1 || callbacks != 1 {
		t.Fatal("adapter lost admission", out, err, calls, callbacks)
	}
}

func TestAccountGateDenialAndNilComposition(t *testing.T) {
	for _, kind := range []string{"nil gate", "nil store", "nil callback", "denied"} {
		t.Run(kind, func(t *testing.T) {
			gate := NewPostgresAccountGate(nil)
			calls := 0
			callback := func() bool { calls++; return true }
			switch kind {
			case "nil gate":
				gate = nil
			case "nil callback":
				callback = nil
			case "denied":
				gate = &PostgresAccountGate{store: storeFunc(func(context.Context, accountgroup.RouteAdmissionRequest, func(accountgroup.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error) {
					return accountgroup.RouteAdmissionOutcome{}, accountgroup.ErrGroupSessionInvalid
				})}
			}
			out, err := gate.Admit(context.Background(), accountgroup.RouteAdmissionRequest{}, callback)
			if out.Admitted || err == nil || calls != 0 {
				t.Fatal("failed composition callback", out, err, calls)
			}
		})
	}
}

// Compile-time assertion covers the actual SQL store seam; this task deliberately
// does not claim an injected store test is live PostgreSQL routing integration.
var _ routeAdmitter = (*accountgroup.PostgresStore)(nil)
