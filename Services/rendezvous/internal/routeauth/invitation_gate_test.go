package routeauth

import (
	"context"
	"errors"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/accountinvite"
	"reflect"
	"testing"
)

type invitationStoreFunc func(context.Context, accountinvite.RouteAdmissionRequest, func(accountinvite.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error)

func (f invitationStoreFunc) AdmitRoute(c context.Context, r accountinvite.RouteAdmissionRequest, fn func(accountinvite.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error) {
	return f(c, r, fn)
}
func TestInvitationGateExactTupleAndCleanup(t *testing.T) {
	ctx := context.Background()
	request := accountinvite.RouteAdmissionRequest{From: accountinvite.RouteEndpoint{GroupID: "from", Generation: 3, ConnectionGeneration: 8}, To: accountinvite.RouteEndpoint{GroupID: "to", Generation: 7, ConnectionGeneration: 9}}
	cleanup := errors.New("synthetic cleanup")
	calls := 0
	gate := &PostgresInvitationGate{store: invitationStoreFunc(func(c context.Context, r accountinvite.RouteAdmissionRequest, fn func(accountinvite.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error) {
		if c != ctx || !reflect.DeepEqual(r, request) {
			t.Error("tuple changed")
		}
		if !fn(r) {
			t.Error("callback failed")
		}
		return accountgroup.RouteAdmissionOutcome{Admitted: true, CleanupError: cleanup}, nil
	})}
	out, e := gate.Admit(ctx, request, func() bool { calls++; return true })
	if e != nil || !out.Admitted || out.CleanupError != cleanup || calls != 1 {
		t.Fatal(out, e, calls)
	}
}
func TestInvitationGateNilOrDenied(t *testing.T) {
	for _, kind := range []string{"nil gate", "nil store", "nil callback", "denied"} {
		t.Run(kind, func(t *testing.T) {
			g := NewPostgresInvitationGate(nil)
			calls := 0
			fn := func() bool { calls++; return true }
			switch kind {
			case "nil gate":
				g = nil
			case "nil callback":
				fn = nil
			case "denied":
				g = &PostgresInvitationGate{store: invitationStoreFunc(func(context.Context, accountinvite.RouteAdmissionRequest, func(accountinvite.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error) {
					return accountgroup.RouteAdmissionOutcome{}, accountinvite.ErrInvalid
				})}
			}
			out, e := g.Admit(context.Background(), accountinvite.RouteAdmissionRequest{}, fn)
			if e == nil || out.Admitted || calls != 0 {
				t.Fatal(out, e, calls)
			}
		})
	}
}

var _ invitationAdmitter = (*accountinvite.PostgresStore)(nil)
