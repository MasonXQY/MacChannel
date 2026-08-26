package presence

import (
	"fmt"
	"testing"
)

type graphSpy struct {
	adjacency map[string][]string
	queries   int
}

func (g *graphSpy) ShareGraph(_, _ string) bool {
	g.queries++
	return false
}

func (g *graphSpy) DevicesInGraph(deviceID string) []string {
	g.queries++
	return append([]string(nil), g.adjacency[deviceID]...)
}

type discardSink struct{}

func (discardSink) SendJSON(any) error { return nil }

func TestRefreshDeviceUsesTrustAdjacencyInsteadOfGlobalPairScan(t *testing.T) {
	graph := &graphSpy{adjacency: map[string][]string{"device-0": {"device-0", "device-1"}}}
	hub := NewHub(graph)
	for index := range 100 {
		disconnect, err := hub.Connect(string(rune(index+1)), fmt.Sprintf("source-%d", index), discardSink{})
		if err != nil {
			t.Fatal(err)
		}
		defer disconnect()
	}
	graph.queries = 0
	hub.RefreshDevice("device-0")
	if graph.queries != 1 {
		t.Fatalf("graph queries = %d, want one adjacency lookup", graph.queries)
	}
}
