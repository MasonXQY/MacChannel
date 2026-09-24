package routeauth

import (
	"context"

	"macchannel/rendezvous/internal/accountgroup"
)

type routeAdmitter interface {
	AdmitRoute(context.Context, accountgroup.RouteAdmissionRequest, func(accountgroup.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error)
}

// PostgresAccountGate composes the already-reviewed SQL admission primitive.
// Only Policy should expose its result to a route caller: Policy redacts failures
// and owns the single exact-connection enqueue. No network I/O occurs here.
// A database-session failure can independently release SQL locks; this adapter
// does not claim distributed atomicity between SQL and an in-memory queue.
type PostgresAccountGate struct{ store routeAdmitter }

func NewPostgresAccountGate(store *accountgroup.PostgresStore) *PostgresAccountGate {
	if store == nil {
		return &PostgresAccountGate{}
	}
	return &PostgresAccountGate{store: store}
}
func (g *PostgresAccountGate) Admit(ctx context.Context, r accountgroup.RouteAdmissionRequest, enqueue func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	if g == nil || g.store == nil || enqueue == nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrDenied
	}
	return g.store.AdmitRoute(ctx, r, func(accountgroup.RouteAdmissionRequest) bool { return enqueue() })
}

var _ AccountGate = (*PostgresAccountGate)(nil)
