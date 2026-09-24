package routeauth

import (
	"context"
	"testing"
)

func TestConnectionRouterOwnsPolicyQueueCoherently(t *testing.T) {
	routes, err := NewCompositeConnectionRouter(1, graphFunc(func(string, string) bool { return true }), nil)
	if err != nil {
		t.Fatal(err)
	}
	a, ak := identity(31, true)
	b, bk := identity(32, false)
	from, err := routes.Register(a, ak, "source-a")
	if err != nil {
		t.Fatal(err)
	}
	to, err := routes.Register(b, bk, "source-b")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := routes.Route(context.Background(), from, b, []byte("frame")); err != nil {
		t.Fatal(err)
	}
	frame, state := routes.Dequeue(to)
	if state != QueueReady || frame.Type != "signal" || frame.From != a || string(frame.Payload) != "frame" {
		t.Fatalf("wrong coherent dequeue: %v %+v", state, frame)
	}
	if _, state := routes.Dequeue(to); state != QueueEmpty {
		t.Fatal("extra frame", state)
	}
}
