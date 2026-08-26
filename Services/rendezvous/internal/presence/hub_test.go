package presence

import (
	"fmt"
	"sync"
	"testing"
	"time"
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

type blockingGraph struct {
	mu        sync.Mutex
	adjacency map[string][]string
	blockID   string
	blockIDs  map[string]bool
	started   chan struct{}
	release   chan struct{}
}

func (g *blockingGraph) ShareGraph(_, _ string) bool { return false }

func (g *blockingGraph) DevicesInGraph(deviceID string) []string {
	g.mu.Lock()
	result := append([]string(nil), g.adjacency[deviceID]...)
	shouldBlock := (deviceID == g.blockID || g.blockIDs[deviceID]) && g.started != nil
	started := g.started
	release := g.release
	if shouldBlock {
		g.started = nil
	}
	g.mu.Unlock()
	if shouldBlock {
		close(started)
		<-release
	}
	return result
}

func (g *blockingGraph) revoke() {
	g.mu.Lock()
	g.adjacency = map[string][]string{"left": {"left"}, "right": {"right"}}
	g.mu.Unlock()
}

type eventSink struct {
	events chan Event
}

func (s eventSink) SendJSON(value any) error {
	if event, ok := value.(Event); ok {
		s.events <- event
	}
	return nil
}

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

func TestOlderBlockedGraphQueryCannotReinstallVisibilityAfterFailClosed(t *testing.T) {
	graph := &blockingGraph{adjacency: map[string][]string{
		"left": {"left", "right"}, "right": {"left", "right"},
	}}
	hub := NewHub(graph)
	leftEvents := make(chan Event, 8)
	rightEvents := make(chan Event, 8)
	disconnectLeft, err := hub.Connect("left", "source-left", eventSink{events: leftEvents})
	if err != nil {
		t.Fatal(err)
	}
	defer disconnectLeft()
	disconnectRight, err := hub.Connect("right", "source-right", eventSink{events: rightEvents})
	if err != nil {
		t.Fatal(err)
	}
	defer disconnectRight()
	assertPresenceEvent(t, leftEvents, "right", "internet")
	assertPresenceEvent(t, rightEvents, "left", "internet")

	graph.mu.Lock()
	graph.blockID = "left"
	graph.started = make(chan struct{})
	graph.release = make(chan struct{})
	started := graph.started
	release := graph.release
	graph.mu.Unlock()
	refreshDone := make(chan struct{})
	go func() {
		hub.RefreshDevice("left")
		close(refreshDone)
	}()
	<-started
	graph.revoke()
	failClosedStarted := make(chan struct{})
	failClosedDone := make(chan struct{})
	go func() {
		close(failClosedStarted)
		hub.FailClosed()
		close(failClosedDone)
	}()
	<-failClosedStarted
	close(release)
	<-refreshDone
	<-failClosedDone
	assertPresenceEvent(t, leftEvents, "right", "offline")
	assertPresenceEvent(t, rightEvents, "left", "offline")
	assertNoPresenceEvent(t, leftEvents)
	assertNoPresenceEvent(t, rightEvents)

	disconnectRight()
	assertNoPresenceEvent(t, leftEvents)
}

func TestUnrelatedConnectCannotPreemptGlobalRevocationRefresh(t *testing.T) {
	graph := &blockingGraph{adjacency: map[string][]string{
		"left": {"left", "right"}, "right": {"left", "right"},
	}}
	hub := NewHub(graph)
	leftEvents := make(chan Event, 8)
	rightEvents := make(chan Event, 8)
	disconnectLeft, err := hub.Connect("left", "source-left", eventSink{events: leftEvents})
	if err != nil {
		t.Fatal(err)
	}
	defer disconnectLeft()
	disconnectRight, err := hub.Connect("right", "source-right", eventSink{events: rightEvents})
	if err != nil {
		t.Fatal(err)
	}
	defer disconnectRight()
	assertPresenceEvent(t, leftEvents, "right", "internet")
	assertPresenceEvent(t, rightEvents, "left", "internet")

	graph.revoke()
	graph.mu.Lock()
	graph.blockIDs = map[string]bool{"left": true, "right": true}
	graph.started = make(chan struct{})
	graph.release = make(chan struct{})
	started := graph.started
	release := graph.release
	graph.mu.Unlock()
	refreshDone := make(chan struct{})
	go func() {
		hub.Refresh()
		close(refreshDone)
	}()
	<-started

	connectDone := make(chan error, 1)
	var disconnectUnrelated func()
	go func() {
		var connectErr error
		disconnectUnrelated, connectErr = hub.Connect("unrelated", "source-unrelated", discardSink{})
		connectDone <- connectErr
	}()
	deadline := time.Now().Add(time.Second)
	for {
		hub.mu.Lock()
		_, connected := hub.clients["unrelated"]
		hub.mu.Unlock()
		if connected {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("unrelated device did not connect while global refresh was blocked")
		}
		time.Sleep(time.Millisecond)
	}
	close(release)
	<-refreshDone
	if err := <-connectDone; err != nil {
		t.Fatal(err)
	}
	defer disconnectUnrelated()

	assertPresenceEvent(t, leftEvents, "right", "offline")
	assertPresenceEvent(t, rightEvents, "left", "offline")
	disconnectRight()
	assertNoPresenceEvent(t, leftEvents)
}

func assertPresenceEvent(t *testing.T, events <-chan Event, deviceID, availability string) {
	t.Helper()
	select {
	case event := <-events:
		if event.DeviceID != deviceID || event.Availability != availability {
			t.Fatalf("presence event=%+v want device=%s availability=%s", event, deviceID, availability)
		}
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s presence for %s", availability, deviceID)
	}
}

func assertNoPresenceEvent(t *testing.T, events <-chan Event) {
	t.Helper()
	select {
	case event := <-events:
		t.Fatalf("unexpected stale presence event=%+v", event)
	case <-time.After(50 * time.Millisecond):
	}
}
