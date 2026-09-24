package presence

import (
	"math"
	"sync"
)

// These are infrastructure ceilings, not deployment settings. Reservations and
// published events both count against the same limits.
const (
	MaximumPendingPerConnection = 64
	MaximumPendingEvents        = 4096
	MaximumAccountPairs         = 4096
)

// OwnedSink.Close must interrupt an in-flight SendJSON. ConnectOwned transfers
// close ownership to the hub. Legacy Connect never closes its sink.
type OwnedSink interface {
	Sink
	Close() error
}
type ConnectionHandle struct {
	hub      *Hub
	deviceID string
	token    uint64
}

func (ConnectionHandle) String() string     { return "<presence.ConnectionHandle>" }
func (h ConnectionHandle) GoString() string { return h.String() }

type sourceBits uint8

const (
	manualSource sourceBits = 1 << iota
	accountSource
)

type pairKey struct{ left, right uint64 }
type accountPair struct {
	left, right ConnectionHandle
	epoch       uint64
	reserved    *AccountBatch
	consumed    bool
}
type queuedEvent struct {
	event Event
	peer  ConnectionHandle
}
type ownedConnection struct {
	handle    ConnectionHandle
	sink      OwnedSink
	queue     []queuedEvent
	reserved  int
	stopped   bool
	wake      chan struct{}
	done      chan struct{}
	closeOnce sync.Once
}

func (c *ownedConnection) closeSink() { c.closeOnce.Do(func() { _ = c.sink.Close() }) }
func (c *ownedConnection) notify() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// AccountBatch is an opaque, single-consumption reservation. It is not an
// authorization claim. Only the admission callback may reserve; its caller
// publishes after admission returns, including uncertain gate cleanup.
type AccountBatch struct {
	hub     *Hub
	pair    *accountPair
	epoch   uint64
	visible bool
	active  bool
}

func (*AccountBatch) String() string     { return "<presence.AccountBatch>" }
func (b *AccountBatch) GoString() string { return b.String() }

func (h *Hub) ConnectOwned(deviceID, source string, sink OwnedSink) (ConnectionHandle, func(), error) {
	if sink == nil {
		return ConnectionHandle{}, nil, ErrCapacity
	}
	c := &ownedConnection{sink: sink, wake: make(chan struct{}, 1), done: make(chan struct{})}
	return h.connect(deviceID, source, sink, c)
}
func (h *Hub) current(handle ConnectionHandle) (clientEntry, bool) {
	c, ok := h.clients[handle.deviceID]
	return c, ok && handle.hub == h && handle.token != 0 && c.token == handle.token
}
func (h *Hub) pairCurrent(l, r ConnectionHandle) bool {
	lc, lok := h.current(l)
	rc, rok := h.current(r)
	return lok && rok && l.token != r.token && lc.owned != nil && rc.owned != nil
}
func keyFor(l, r ConnectionHandle) pairKey {
	if l.token > r.token {
		l, r = r, l
	}
	return pairKey{l.token, r.token}
}

// BeginAccountPair fences an older refresh of this exact pair. It grants no
// visibility. Caller must also check its own binding versions inside admission.
func (h *Hub) BeginAccountPair(l, r ConnectionHandle) (uint64, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.pairCurrent(l, r) || h.nextAccountEpoch == math.MaxUint64 {
		return 0, false
	}
	key := keyFor(l, r)
	p := h.accountPairs[key]
	if p == nil {
		if len(h.accountPairs) >= MaximumAccountPairs {
			return 0, false
		}
		p = &accountPair{left: l, right: r}
		h.accountPairs[key] = p
	}
	h.retireBatchLocked(p.reserved)
	h.nextAccountEpoch++
	p.epoch = h.nextAccountEpoch
	p.consumed = false
	return p.epoch, true
}

// AdvanceAccountSource is a local withdrawal/invalidation, used on bind,
// rebind or unbind before new projection work. It never modifies manual trust.
func (h *Hub) AdvanceAccountSource(handle ConnectionHandle) bool {
	h.mu.Lock()
	if _, ok := h.current(handle); !ok {
		h.mu.Unlock()
		return false
	}
	var out []delivery
	for key, p := range h.accountPairs {
		if p.left == handle || p.right == handle {
			h.retireBatchLocked(p.reserved)
			out = append(out, h.accountTransitionLocked(p, false)...)
			delete(h.accountPairs, key)
		}
	}
	out = h.dispatchLocked(out)
	h.mu.Unlock()
	sendAll(out)
	return true
}

// WithdrawAccountPair is called outside SQL admission when a current refresh
// is denied or cannot reserve capacity. It removes only that exact pair epoch.
// Retirement releases the pair slot; repeated or stale withdrawal returns false.
// BeginAccountPair uses a hub-wide increasing epoch, so recreating this pair
// cannot make any previously retired reservation or epoch current again.
func (h *Hub) WithdrawAccountPair(l, r ConnectionHandle, epoch uint64) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	p := h.accountPairs[keyFor(l, r)]
	if !h.pairCurrent(l, r) || p == nil || epoch == 0 || p.epoch != epoch {
		h.mu.Unlock()
		return false
	}
	h.retireBatchLocked(p.reserved)
	p.consumed = true
	delete(h.accountPairs, keyFor(l, r))
	out := h.dispatchLocked(h.accountTransitionLocked(p, false))
	h.mu.Unlock()
	sendAll(out)
	return true
}

// ReserveAccountPair is bounded and nonblocking: no network, SQL, graph lookup,
// channel wait or sink callback occurs here. Both slots are reserved or neither.
func (h *Hub) ReserveAccountPair(l, r ConnectionHandle, epoch uint64, visible bool) (*AccountBatch, bool) {
	if h == nil || !h.mu.TryLock() {
		return nil, false
	}
	defer h.mu.Unlock()
	if !h.pairCurrent(l, r) {
		return nil, false
	}
	p := h.accountPairs[keyFor(l, r)]
	if p == nil || p.epoch != epoch || epoch == 0 || p.reserved != nil || p.consumed {
		return nil, false
	}
	lc, _ := h.current(l)
	rc, _ := h.current(r)
	if len(lc.owned.queue)+lc.owned.reserved >= MaximumPendingPerConnection || len(rc.owned.queue)+rc.owned.reserved >= MaximumPendingPerConnection || h.pending+2 > MaximumPendingEvents {
		return nil, false
	}
	b := &AccountBatch{hub: h, pair: p, epoch: epoch, visible: visible, active: true}
	p.reserved = b
	p.consumed = true
	lc.owned.reserved++
	rc.owned.reserved++
	h.pending += 2
	return b, true
}
func (h *Hub) retireBatchLocked(b *AccountBatch) {
	if b == nil || !b.active {
		return
	}
	b.active = false
	b.pair.reserved = nil
	for _, handle := range []ConnectionHandle{b.pair.left, b.pair.right} {
		if c, ok := h.current(handle); ok {
			c.owned.reserved--
		}
	}
	h.pending -= 2
}
func (b *AccountBatch) Publish() bool {
	if b == nil || b.hub == nil {
		return false
	}
	h := b.hub
	h.mu.Lock()
	p := b.pair
	if !b.active || p.reserved != b || p.epoch != b.epoch || !h.pairCurrent(p.left, p.right) {
		h.mu.Unlock()
		return false
	}
	h.retireBatchLocked(b)
	out := h.dispatchLocked(h.accountTransitionLocked(p, b.visible))
	h.mu.Unlock()
	sendAll(out)
	return true
}
func (h *Hub) accountTransitionLocked(p *accountPair, visible bool) []delivery {
	l, r := p.left.deviceID, p.right.deviceID
	before := h.visible[l][r] != 0
	h.setSourceLocked(l, r, accountSource, visible)
	after := h.visible[l][r] != 0
	if before == after {
		return nil
	}
	availability := "offline"
	if after {
		availability = "internet"
	}
	lc, _ := h.current(p.left)
	rc, _ := h.current(p.right)
	return []delivery{{sink: lc.sink, owned: lc.owned, event: Event{"presence", r, availability}}, {sink: rc.sink, owned: rc.owned, event: Event{"presence", l, availability}}}
}

// dispatchLocked preserves one ordered queue for owned manual/account events.
// An ordinary transition that cannot fit retires the slow socket; it cannot
// silently lose an offline event while leaving that socket live.
func (h *Hub) dispatchLocked(work []delivery) []delivery {
	var direct []delivery
	for len(work) > 0 {
		d := work[0]
		work = work[1:]
		if d.close != nil || d.owned == nil {
			direct = append(direct, d)
			continue
		}
		c := d.owned
		if c.stopped {
			continue
		}
		if len(c.queue)+c.reserved >= MaximumPendingPerConnection || h.pending >= MaximumPendingEvents {
			work = append(work, h.retireLocked(c.handle)...)
			continue
		}
		peer := ConnectionHandle{}
		if p, ok := h.clients[d.event.DeviceID]; ok {
			peer = ConnectionHandle{h, d.event.DeviceID, p.token}
		}
		c.queue = append(c.queue, queuedEvent{d.event, peer})
		h.pending++
		c.notify()
	}
	return direct
}
func (h *Hub) retireLocked(handle ConnectionHandle) []delivery {
	c, ok := h.current(handle)
	if !ok {
		return nil
	}
	for key, p := range h.accountPairs {
		if p.left == handle || p.right == handle {
			h.retireBatchLocked(p.reserved)
			delete(h.accountPairs, key)
		}
	}
	delete(h.clients, handle.deviceID)
	h.sources[c.source]--
	if h.sources[c.source] == 0 {
		delete(h.sources, c.source)
	}
	var out []delivery
	if c.owned != nil {
		c.owned.stopped = true
		h.pending -= len(c.owned.queue)
		c.owned.queue = nil
		c.owned.notify()
		out = append(out, delivery{close: c.owned})
	}
	for peerID := range h.visible[handle.deviceID] {
		if peer, ok := h.clients[peerID]; ok {
			out = append(out, delivery{sink: peer.sink, owned: peer.owned, event: Event{"presence", handle.deviceID, "offline"}})
		}
	}
	h.clearVisibilityLocked(handle.deviceID)
	return out
}
func (h *Hub) drain(c *ownedConnection) {
	defer close(c.done)
	// Only this worker accesses observed. Entries are removed on withdrawal;
	// stale disconnected entries are bounded by the pending event ceiling.
	observed := make(map[string]ConnectionHandle)
	for {
		h.mu.Lock()
		if c.stopped {
			h.mu.Unlock()
			c.closeSink()
			return
		}
		if len(c.queue) == 0 {
			h.mu.Unlock()
			<-c.wake
			continue
		}
		item := c.queue[0]
		c.queue[0] = queuedEvent{}
		c.queue = c.queue[1:]
		h.pending--
		_, peerCurrent := h.current(item.peer)
		stillVisible := h.visible[c.handle.deviceID][item.event.DeviceID] != 0
		h.mu.Unlock()
		if item.event.Availability == "internet" && (!peerCurrent || !stillVisible) {
			continue
		}
		if item.event.Availability == "offline" && stillVisible {
			continue
		}
		if item.event.Availability == "internet" && observed[item.event.DeviceID] == item.peer {
			continue
		}
		if err := c.sink.SendJSON(item.event); err != nil {
			h.mu.Lock()
			out := h.dispatchLocked(h.retireLocked(c.handle))
			h.mu.Unlock()
			sendAll(out)
			return
		}
		if item.event.Availability == "internet" {
			observed[item.event.DeviceID] = item.peer
		} else {
			delete(observed, item.event.DeviceID)
		}
	}
}
