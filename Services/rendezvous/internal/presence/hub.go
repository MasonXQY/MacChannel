package presence

import "sync"

type TrustGraph interface {
	ShareGraph(left, right string) bool
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
	token uint64
	sink  Sink
}

type delivery struct {
	sink  Sink
	event Event
}

type Hub struct {
	mu        sync.Mutex
	graph     TrustGraph
	clients   map[string]clientEntry
	visible   map[string]map[string]bool
	nextToken uint64
}

func NewHub(graph TrustGraph) *Hub {
	return &Hub{
		graph:   graph,
		clients: make(map[string]clientEntry),
		visible: make(map[string]map[string]bool),
	}
}

func (h *Hub) Connect(deviceID string, sink Sink) func() {
	h.mu.Lock()
	h.nextToken++
	token := h.nextToken
	if _, replacing := h.clients[deviceID]; replacing {
		h.clearVisibilityLocked(deviceID)
	}
	h.clients[deviceID] = clientEntry{token: token, sink: sink}
	h.mu.Unlock()
	h.Refresh()

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
	}
}

func (h *Hub) Refresh() {
	h.mu.Lock()
	identifiers := make([]string, 0, len(h.clients))
	for deviceID := range h.clients {
		identifiers = append(identifiers, deviceID)
	}
	var deliveries []delivery
	for leftIndex, leftID := range identifiers {
		for _, rightID := range identifiers[leftIndex+1:] {
			wasVisible := h.visible[leftID][rightID]
			isVisible := h.graph.ShareGraph(leftID, rightID)
			if wasVisible == isVisible {
				continue
			}
			availability := "offline"
			if isVisible {
				availability = "internet"
				h.setVisibleLocked(leftID, rightID)
			} else {
				h.clearPairLocked(leftID, rightID)
			}
			deliveries = append(deliveries,
				delivery{sink: h.clients[leftID].sink, event: Event{Type: "presence", DeviceID: rightID, Availability: availability}},
				delivery{sink: h.clients[rightID].sink, event: Event{Type: "presence", DeviceID: leftID, Availability: availability}},
			)
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
