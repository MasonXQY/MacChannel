package signal

import (
	"errors"
	"sync"
)

var (
	ErrForbidden  = errors.New("devices do not share a trust graph")
	ErrOffline    = errors.New("target device is offline")
	ErrFrameLarge = errors.New("signaling frame is too large")
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
	mu      sync.RWMutex
	graph   TrustGraph
	clients map[string]Sink
}

func NewHub(graph TrustGraph) *Hub {
	return &Hub{graph: graph, clients: make(map[string]Sink)}
}

func (h *Hub) Register(deviceID string, sink Sink) func() {
	h.mu.Lock()
	h.clients[deviceID] = sink
	h.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			h.mu.Lock()
			if current, ok := h.clients[deviceID]; ok && current == sink {
				delete(h.clients, deviceID)
			}
			h.mu.Unlock()
		})
	}
}

func (h *Hub) Route(from, to string, payload []byte) error {
	if len(payload) == 0 || len(payload) > MaximumFrameSize {
		return ErrFrameLarge
	}
	if !h.graph.ShareGraph(from, to) {
		return ErrForbidden
	}
	h.mu.RLock()
	target := h.clients[to]
	h.mu.RUnlock()
	if target == nil {
		return ErrOffline
	}
	return target.SendJSON(Frame{Type: "signal", From: from, Payload: append([]byte(nil), payload...)})
}
