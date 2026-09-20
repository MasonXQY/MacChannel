package routeauth

import (
	"context"

	"macchannel/rendezvous/internal/signal"
)

// ConnectionRouter keeps the admission policy and the only queue owner it may
// enqueue into inseparable. Callers can hold opaque handles, never owner state.
type ConnectionRouter struct {
	owner  *ConnectionOwner
	policy *Policy
}

func NewCompositeConnectionRouter(capacity int, graph signal.TrustGraph, gate AccountGate) (*ConnectionRouter, error) {
	owner, err := NewConnectionOwner(capacity)
	if err != nil {
		return nil, err
	}
	return &ConnectionRouter{owner: owner, policy: NewCompositePolicy(owner, graph, gate)}, nil
}

func (r *ConnectionRouter) Register(deviceID string, publicKey []byte, source string) (ConnectionHandle, error) {
	if r == nil || r.owner == nil {
		return ConnectionHandle{}, ErrConnectionUnavailable
	}
	return r.owner.Register(deviceID, publicKey, source)
}
func (r *ConnectionRouter) Bind(h ConnectionHandle, b AccountBinding) error {
	if r == nil || r.owner == nil {
		return ErrConnectionUnavailable
	}
	return r.owner.Bind(h, b)
}
func (r *ConnectionRouter) Unbind(h ConnectionHandle) error {
	if r == nil || r.owner == nil {
		return ErrConnectionUnavailable
	}
	return r.owner.Unbind(h)
}
func (r *ConnectionRouter) Close(h ConnectionHandle) error {
	if r == nil || r.owner == nil {
		return ErrConnectionUnavailable
	}
	return r.owner.Close(h)
}
func (r *ConnectionRouter) Notifications(h ConnectionHandle) (<-chan struct{}, error) {
	if r == nil || r.owner == nil {
		return nil, ErrConnectionUnavailable
	}
	return r.owner.Notifications(h)
}
func (r *ConnectionRouter) Dequeue(h ConnectionHandle) (signal.Frame, QueueState) {
	if r == nil || r.owner == nil {
		return signal.Frame{}, QueueClosed
	}
	return r.owner.Dequeue(h)
}
func (r *ConnectionRouter) Route(ctx context.Context, from ConnectionHandle, target string, payload []byte) (RouteOutcome, error) {
	if r == nil || r.policy == nil {
		return RouteOutcome{}, ErrDenied
	}
	return r.policy.Route(ctx, from, target, payload)
}

func (*ConnectionRouter) String() string     { return "<routeauth.ConnectionRouter>" }
func (r *ConnectionRouter) GoString() string { return r.String() }
