package presence

import (
	"errors"
	"sync"
)

var ErrCapacity = errors.New("presence capacity reached")

type TrustGraph interface {
	ShareGraph(left, right string) bool
	DevicesInGraph(deviceID string) []string
}

type Sink interface {
	SendJSON(value any) error
}

type Event struct {
	Type         string `json:"type"`
	DeviceID     string `json:"deviceID"`
	Availability string `json:"availability"`
}

type clientEntry struct {
	token  uint64
	sink   Sink
	source string
}

type delivery struct {
	sink  Sink
	event Event
}

type Hub struct {
	mu             sync.Mutex
	graph          TrustGraph
	clients        map[string]clientEntry
	visible        map[string]map[string]bool
	sources        map[string]int
	nextToken      uint64
	globalLimit    int
	perSourceLimit int
}

func NewHub(graph TrustGraph) *Hub {
	return &Hub{
		graph:          graph,
		clients:        make(map[string]clientEntry),
		visible:        make(map[string]map[string]bool),
		sources:        make(map[string]int),
		globalLimit:    1024,
		perSourceLimit: 32,
	}
}

func (h *Hub) Connect(deviceID, source string, sink Sink) (func(), error) {
	h.mu.Lock()
	if len(h.clients) >= h.globalLimit || h.sources[source] >= h.perSourceLimit {
		h.mu.Unlock()
		return nil, ErrCapacity
	}
	if _, exists := h.clients[deviceID]; exists {
		h.mu.Unlock()
		return nil, ErrCapacity
	}
	h.nextToken++
	token := h.nextToken
	h.clients[deviceID] = clientEntry{token: token, sink: sink, source: source}
	h.sources[source]++
	h.mu.Unlock()
	h.RefreshDevice(deviceID)

	var once sync.Once
	return func() {
		once.Do(func() {
			h.mu.Lock()
			current, exists := h.clients[deviceID]
			if !exists || current.token != token {
				h.mu.Unlock()
				return
			}
			delete(h.clients, deviceID)
			h.sources[current.source]--
			if h.sources[current.source] == 0 {
				delete(h.sources, current.source)
			}
			var deliveries []delivery
			for peerID := range h.visible[deviceID] {
				if peer, online := h.clients[peerID]; online {
					deliveries = append(deliveries, delivery{
						sink:  peer.sink,
						event: Event{Type: "presence", DeviceID: deviceID, Availability: "offline"},
					})
				}
			}
			h.clearVisibilityLocked(deviceID)
			h.mu.Unlock()
			sendAll(deliveries)
		})
	}, nil
}

func (h *Hub) Refresh() {
	h.mu.Lock()
	identifiers := make([]string, 0, len(h.clients))
	for deviceID := range h.clients {
		identifiers = append(identifiers, deviceID)
	}
	h.mu.Unlock()
	for _, deviceID := range identifiers {
		h.RefreshDevice(deviceID)
	}
}

func (h *Hub) FailClosed() {
	h.mu.Lock()
	seen := make(map[string]bool)
	var deliveries []delivery
	for deviceID, peers := range h.visible {
		for peerID := range peers {
			key := deviceID + "\x00" + peerID
			reverseKey := peerID + "\x00" + deviceID
			if seen[key] || seen[reverseKey] {
				continue
			}
			seen[key] = true
			if client, online := h.clients[deviceID]; online {
				deliveries = append(deliveries, delivery{sink: client.sink,
					event: Event{Type: "presence", DeviceID: peerID, Availability: "offline"}})
			}
			if peer, online := h.clients[peerID]; online {
				deliveries = append(deliveries, delivery{sink: peer.sink,
					event: Event{Type: "presence", DeviceID: deviceID, Availability: "offline"}})
			}
		}
	}
	h.visible = make(map[string]map[string]bool)
	h.mu.Unlock()
	sendAll(deliveries)
}

func (h *Hub) RefreshDevice(deviceID string) {
	graphPeers := h.graph.DevicesInGraph(deviceID)
	allowed := make(map[string]bool, len(graphPeers))
	for _, peerID := range graphPeers {
		if peerID != deviceID {
			allowed[peerID] = true
		}
	}
	h.mu.Lock()
	client, online := h.clients[deviceID]
	if !online {
		h.mu.Unlock()
		return
	}
	candidates := make(map[string]bool, len(allowed)+len(h.visible[deviceID]))
	for peerID := range allowed {
		candidates[peerID] = true
	}
	for peerID := range h.visible[deviceID] {
		candidates[peerID] = true
	}
	var deliveries []delivery
	for peerID := range candidates {
		peer, peerOnline := h.clients[peerID]
		wasVisible := h.visible[deviceID][peerID]
		isVisible := allowed[peerID] && peerOnline
		if wasVisible == isVisible {
			continue
		}
		availability := "offline"
		if isVisible {
			availability = "internet"
			h.setVisibleLocked(deviceID, peerID)
		} else {
			h.clearPairLocked(deviceID, peerID)
		}
		deliveries = append(deliveries, delivery{sink: client.sink, event: Event{Type: "presence", DeviceID: peerID, Availability: availability}})
		if peerOnline {
			deliveries = append(deliveries, delivery{sink: peer.sink, event: Event{Type: "presence", DeviceID: deviceID, Availability: availability}})
		}
	}
	h.mu.Unlock()
	sendAll(deliveries)
}

func (h *Hub) setVisibleLocked(left, right string) {
	if h.visible[left] == nil {
		h.visible[left] = make(map[string]bool)
	}
	if h.visible[right] == nil {
		h.visible[right] = make(map[string]bool)
	}
	h.visible[left][right] = true
	h.visible[right][left] = true
}

func (h *Hub) clearPairLocked(left, right string) {
	delete(h.visible[left], right)
	delete(h.visible[right], left)
}

func (h *Hub) clearVisibilityLocked(deviceID string) {
	for peerID := range h.visible[deviceID] {
		delete(h.visible[peerID], deviceID)
	}
	delete(h.visible, deviceID)
}

func sendAll(deliveries []delivery) {
	for _, item := range deliveries {
		_ = item.sink.SendJSON(item.event)
	}
}
