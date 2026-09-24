package routeauth

import (
	"context"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/accountinvite"
	"macchannel/rendezvous/internal/signal"
)

// InvitationGate is independent direct-pair authority. It follows AccountGate's
// synchronous at-most-once callback contract, with each endpoint's own group.
type InvitationGate interface {
	Admit(context.Context, accountinvite.RouteAdmissionRequest, func() bool) (accountgroup.RouteAdmissionOutcome, error)
}
type invitationAdmitter interface {
	AdmitRoute(context.Context, accountinvite.RouteAdmissionRequest, func(accountinvite.RouteAdmissionRequest) bool) (accountgroup.RouteAdmissionOutcome, error)
}
type PostgresInvitationGate struct{ store invitationAdmitter }

func NewPostgresInvitationGate(store *accountinvite.PostgresStore) *PostgresInvitationGate {
	if store == nil {
		return &PostgresInvitationGate{}
	}
	return &PostgresInvitationGate{store: store}
}
func (g *PostgresInvitationGate) Admit(ctx context.Context, r accountinvite.RouteAdmissionRequest, fn func() bool) (accountgroup.RouteAdmissionOutcome, error) {
	if g == nil || g.store == nil || fn == nil {
		return accountgroup.RouteAdmissionOutcome{}, ErrDenied
	}
	return g.store.AdmitRoute(ctx, r, func(accountinvite.RouteAdmissionRequest) bool { return fn() })
}

// Explicit opt-in; existing constructors remain invitation-disabled.
func NewCompositePolicyWithInvitations(o *ConnectionOwner, g signal.TrustGraph, a AccountGate, i InvitationGate) *Policy {
	p := NewCompositePolicy(o, g, a)
	p.invitation = i
	return p
}

var _ InvitationGate = (*PostgresInvitationGate)(nil)
