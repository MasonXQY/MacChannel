package presence

import (
	"errors"
	"math"
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
	owned  *ownedConnection
}

type delivery struct {
	sink  Sink
	event Event
	owned *ownedConnection
	close *ownedConnection
}

type Hub struct {
	mu               sync.Mutex
	refreshMu        sync.Mutex
	graph            TrustGraph
	clients          map[string]clientEntry
	visible          map[string]map[string]sourceBits
	sources          map[string]int
	nextToken        uint64
	globalLimit      int
	perSourceLimit   int
	epoch            uint64
	accountPairs     map[pairKey]*accountPair
	nextAccountEpoch uint64
	pending          int
}

func NewHub(graph TrustGraph) *Hub {
	return &Hub{
		graph:          graph,
		clients:        make(map[string]clientEntry),
		visible:        make(map[string]map[string]sourceBits),
		accountPairs:   make(map[pairKey]*accountPair),
		sources:        make(map[string]int),
		globalLimit:    1024,
		perSourceLimit: 32,
	}
}

func (h *Hub) Connect(deviceID, source string, sink Sink) (func(), error) {
	_, cleanup, err := h.connect(deviceID, source, sink, nil)
	return cleanup, err
}

func (h *Hub) connect(deviceID, source string, sink Sink, owned *ownedConnection) (ConnectionHandle, func(), error) {
	h.mu.Lock()
	if len(h.clients) >= h.globalLimit || h.sources[source] >= h.perSourceLimit || h.nextToken == math.MaxUint64 {
		h.mu.Unlock()
		return ConnectionHandle{}, nil, ErrCapacity
	}
	if _, exists := h.clients[deviceID]; exists {
		h.mu.Unlock()
		return ConnectionHandle{}, nil, ErrCapacity
	}
	h.nextToken++
	token := h.nextToken
	handle := ConnectionHandle{hub: h, deviceID: deviceID, token: token}
	h.clients[deviceID] = clientEntry{token: token, sink: sink, source: source, owned: owned}
	if owned != nil {
		owned.handle = handle
	}
	h.sources[source]++
	h.mu.Unlock()
	if owned != nil {
		go h.drain(owned)
	}
	h.RefreshDevice(deviceID)

	var once sync.Once
	return handle, func() {
		once.Do(func() {
			h.refreshMu.Lock()
			h.mu.Lock()
			deliveries := h.dispatchLocked(h.retireLocked(handle))
			h.mu.Unlock()
			sendAll(deliveries)
			h.refreshMu.Unlock()
			if owned != nil {
				owned.closeSink()
				<-owned.done
			}
		})
	}, nil
}

func (h *Hub) Refresh() {
	h.refreshMu.Lock()
	defer h.refreshMu.Unlock()
	h.mu.Lock()
	h.epoch++
	epoch := h.epoch
	identifiers := make([]string, 0, len(h.clients))
	for deviceID := range h.clients {
		identifiers = append(identifiers, deviceID)
	}
	h.mu.Unlock()
	for _, deviceID := range identifiers {
		h.refreshDeviceAtEpoch(deviceID, epoch)
	}
}

func (h *Hub) FailClosed() {
	h.refreshMu.Lock()
	defer h.refreshMu.Unlock()
	h.mu.Lock()
	h.epoch++
	seen := make(map[string]bool)
	var deliveries []delivery
	for deviceID, peers := range h.visible {
		for peerID, bits := range peers {
			key := deviceID + "\x00" + peerID
			reverseKey := peerID + "\x00" + deviceID
			if seen[key] || seen[reverseKey] {
				continue
			}
			seen[key] = true
			if bits&manualSource == 0 {
				continue
			}
			h.setSourceLocked(deviceID, peerID, manualSource, false)
			if bits&accountSource != 0 {
				continue
			}
			if client, online := h.clients[deviceID]; online {
				deliveries = append(deliveries, delivery{sink: client.sink, owned: client.owned,
					event: Event{Type: "presence", DeviceID: peerID, Availability: "offline"}})
			}
			if peer, online := h.clients[peerID]; online {
				deliveries = append(deliveries, delivery{sink: peer.sink, owned: peer.owned,
					event: Event{Type: "presence", DeviceID: deviceID, Availability: "offline"}})
			}
		}
	}
	deliveries = h.dispatchLocked(deliveries)
	h.mu.Unlock()
	sendAll(deliveries)
}

func (h *Hub) RefreshDevice(deviceID string) {
	h.refreshMu.Lock()
	defer h.refreshMu.Unlock()
	h.mu.Lock()
	h.epoch++
	epoch := h.epoch
	h.mu.Unlock()
	h.refreshDeviceAtEpoch(deviceID, epoch)
}

func (h *Hub) refreshDeviceAtEpoch(deviceID string, epoch uint64) {
	graphPeers := h.graph.DevicesInGraph(deviceID)
	allowed := make(map[string]bool, len(graphPeers))
	for _, peerID := range graphPeers {
		if peerID != deviceID {
			allowed[peerID] = true
		}
	}
	h.mu.Lock()
	if epoch != h.epoch {
		h.mu.Unlock()
		return
	}
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
		wasVisible := h.visible[deviceID][peerID] != 0
		h.setSourceLocked(deviceID, peerID, manualSource, allowed[peerID] && peerOnline)
		isVisible := h.visible[deviceID][peerID] != 0
		if wasVisible == isVisible {
			continue
		}
		availability := "offline"
		if isVisible {
			availability = "internet"
		}
		deliveries = append(deliveries, delivery{sink: client.sink, owned: client.owned, event: Event{Type: "presence", DeviceID: peerID, Availability: availability}})
		if peerOnline {
			deliveries = append(deliveries, delivery{sink: peer.sink, owned: peer.owned, event: Event{Type: "presence", DeviceID: deviceID, Availability: availability}})
		}
	}
	deliveries = h.dispatchLocked(deliveries)
	h.mu.Unlock()
	sendAll(deliveries)
}

func (h *Hub) setSourceLocked(left, right string, source sourceBits, enabled bool) {
	bits := h.visible[left][right]
	if enabled {
		bits |= source
	} else {
		bits &^= source
	}
	if bits == 0 {
		h.clearPairLocked(left, right)
		return
	}
	if h.visible[left] == nil {
		h.visible[left] = make(map[string]sourceBits)
	}
	if h.visible[right] == nil {
		h.visible[right] = make(map[string]sourceBits)
	}
	h.visible[left][right] = bits
	h.visible[right][left] = bits
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
		if item.close != nil {
			item.close.closeSink()
			continue
		}
		_ = item.sink.SendJSON(item.event)
	}
}
