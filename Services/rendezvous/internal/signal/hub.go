package signal

import (
	"errors"
	"sync"
)

var (
	ErrForbidden  = errors.New("devices do not share a trust graph")
	ErrOffline    = errors.New("target device is offline")
	ErrFrameLarge = errors.New("signaling frame is too large")
	ErrCapacity   = errors.New("signaling capacity reached")
)

const MaximumFrameSize = 64 * 1024

type TrustGraph interface {
	ShareGraph(left, right string) bool
}

type Sink interface {
	SendJSON(value any) error
}

type Frame struct {
	Type    string `json:"type"`
	From    string `json:"from"`
	Payload []byte `json:"payload"`
}

type Hub struct {
	mu             sync.RWMutex
	graph          TrustGraph
	clients        map[string]clientEntry
	sources        map[string]int
	globalLimit    int
	perSourceLimit int
	nextToken      uint64
}

type clientEntry struct {
	sink   Sink
	source string
	token  uint64
}

func NewHub(graph TrustGraph) *Hub {
	return &Hub{graph: graph, clients: make(map[string]clientEntry), sources: make(map[string]int), globalLimit: 1024, perSourceLimit: 32}
}

func (h *Hub) Register(deviceID, source string, sink Sink) (func(), error) {
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
	h.clients[deviceID] = clientEntry{sink: sink, source: source, token: token}
	h.sources[source]++
	h.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			h.mu.Lock()
			if current, ok := h.clients[deviceID]; ok && current.token == token {
				delete(h.clients, deviceID)
				h.sources[current.source]--
				if h.sources[current.source] == 0 {
					delete(h.sources, current.source)
				}
			}
			h.mu.Unlock()
		})
	}, nil
}

func (h *Hub) Route(from, to string, payload []byte) error {
	if len(payload) == 0 || len(payload) > MaximumFrameSize {
		return ErrFrameLarge
	}
	if !h.graph.ShareGraph(from, to) {
		return ErrForbidden
	}
	h.mu.RLock()
	target := h.clients[to].sink
	h.mu.RUnlock()
	if target == nil {
		return ErrOffline
	}
	return target.SendJSON(Frame{Type: "signal", From: from, Payload: append([]byte(nil), payload...)})
}

// Deliver sends a control frame only to explicitly selected connected devices.
// The router derives recipients from the trust graph before and after a signed
// trust transition; this hub never broadens that privacy boundary.
func (h *Hub) Deliver(recipients []string, value any) {
	h.mu.RLock()
	sinks := make([]Sink, 0, len(recipients))
	seen := make(map[string]bool, len(recipients))
	for _, deviceID := range recipients {
		if seen[deviceID] {
			continue
		}
		seen[deviceID] = true
		if client, ok := h.clients[deviceID]; ok {
			sinks = append(sinks, client.sink)
		}
	}
	h.mu.RUnlock()
	for _, sink := range sinks {
		_ = sink.SendJSON(value)
	}
}
