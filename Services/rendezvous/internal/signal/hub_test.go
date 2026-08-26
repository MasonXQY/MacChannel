package signal

import (
	"fmt"
	"testing"
)

type allowGraph struct{}

func (allowGraph) ShareGraph(_, _ string) bool { return true }

type discardSink struct{}

func (discardSink) SendJSON(any) error { return nil }

func TestRegisterBoundsClientsPerSource(t *testing.T) {
	hub := NewHub(allowGraph{})
	for index := range 32 {
		unregister, err := hub.Register(fmt.Sprintf("device-%d", index), "source", discardSink{})
		if err != nil {
			t.Fatal(err)
		}
		defer unregister()
	}
	if _, err := hub.Register("device-overflow", "source", discardSink{}); err != ErrCapacity {
		t.Fatalf("error = %v, want capacity", err)
	}
}
