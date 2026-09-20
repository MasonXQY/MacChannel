// Package routeauth provides an unwired connection queue and composite signal
// admission policy. Authenticated adapters and network draining are separate.
package routeauth

import (
	"crypto/elliptic"
	"errors"
	"math"
	"sync"
	"unicode"
	"unicode/utf8"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/signal"
)

// Resource ceilings for this unwired component, not deployment queue defaults.
// Callers choose an explicit queue size. Both queued payload and fixed queue
// metadata are bounded; no worker or drain goroutine is created.
const (
	MaximumQueueCapacity        = 16
	MaximumConnections          = 1024
	MaximumConnectionsPerSource = 32
	MaximumQueuedBytes          = 64 * 1024 * 1024
)

var (
	ErrConnectionUnavailable = errors.New("connection unavailable")
	ErrQueueCapacity         = errors.New("invalid queue capacity")
)

// ConnectionHandle is opaque and scoped to exactly one owner incarnation.
type ConnectionHandle struct {
	owner      *ConnectionOwner
	deviceID   string
	generation uint64
}

// AccountBinding is trusted server composition state supplied by a future
// authenticated adapter. Attaching it proves nothing and grants no authority.
// It contains no access token and must not be marshalled to a peer.
type AccountBinding struct {
	Actor      accountgroup.SessionActor
	GroupID    string
	Generation uint64
}

type connection struct {
	handle                   ConnectionHandle
	publicKey                []byte
	binding                  *AccountBinding
	bindingVersion           uint64
	source                   string
	queue                    []signal.Frame
	head, count, queuedBytes int
}
type connectionSnapshot struct {
	handle         ConnectionHandle
	publicKey      []byte
	binding        *AccountBinding
	bindingVersion uint64
}
type pairSnapshot struct{ from, to connectionSnapshot }

// ConnectionOwner owns identities, bindings and bounded queues. It performs no
// network or SQL I/O. Already-admitted frames may drain after binding revocation.
type ConnectionOwner struct {
	mu                              sync.Mutex
	connections                     map[string]*connection
	sources                         map[string]int
	nextGeneration                  uint64
	queueCapacity                   int
	maximumQueuedBytes, queuedBytes int
}
type QueueState uint8

const (
	QueueEmpty QueueState = iota
	QueueReady
	QueueClosed
	QueueBusy
)

func NewConnectionOwner(capacity int) (*ConnectionOwner, error) {
	if capacity < 1 || capacity > MaximumQueueCapacity {
		return nil, ErrQueueCapacity
	}
	return &ConnectionOwner{connections: make(map[string]*connection), sources: make(map[string]int), queueCapacity: capacity, maximumQueuedBytes: MaximumQueuedBytes}, nil
}

// Register requires an already-authenticated identity. Key bytes are validated
// and copied exactly: raw P-256 X||Y and deployed SEC1 uncompressed forms retain
// their byte-derived device IDs; neither is silently normalized.
func (o *ConnectionOwner) Register(id string, key []byte, source string) (ConnectionHandle, error) {
	if o == nil || !validIdentity(id, key) || !validLabel(source) {
		return ConnectionHandle{}, ErrConnectionUnavailable
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.connections == nil || o.queueCapacity < 1 || len(o.connections) >= MaximumConnections || o.sources[source] >= MaximumConnectionsPerSource || o.connections[id] != nil || o.nextGeneration == math.MaxUint64 {
		return ConnectionHandle{}, ErrConnectionUnavailable
	}
	o.nextGeneration++
	h := ConnectionHandle{o, id, o.nextGeneration}
	o.connections[id] = &connection{handle: h, publicKey: append([]byte(nil), key...), source: source, queue: make([]signal.Frame, o.queueCapacity)}
	o.sources[source]++
	return h, nil
}
func (o *ConnectionOwner) Bind(h ConnectionHandle, b AccountBinding) error {
	if o == nil || !validBinding(b, h.deviceID) {
		return ErrConnectionUnavailable
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	c := o.current(h)
	if c == nil {
		return ErrConnectionUnavailable
	}
	if c.bindingVersion == math.MaxUint64 {
		// Retire account binding on exhaustion, preserving independent manual
		// routing while ensuring old snapshots cannot retain account authority.
		c.binding = nil
		return ErrConnectionUnavailable
	}
	c.bindingVersion++
	c.binding = &b
	return nil
}
func (o *ConnectionOwner) Unbind(h ConnectionHandle) error {
	if o == nil {
		return ErrConnectionUnavailable
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	c := o.current(h)
	if c == nil {
		return ErrConnectionUnavailable
	}
	if c.bindingVersion == math.MaxUint64 {
		c.binding = nil
		return ErrConnectionUnavailable
	}
	c.bindingVersion++
	c.binding = nil
	return nil
}
func (o *ConnectionOwner) Close(h ConnectionHandle) error {
	if o == nil {
		return ErrConnectionUnavailable
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	c := o.current(h)
	if c == nil {
		return ErrConnectionUnavailable
	}
	o.queuedBytes -= c.queuedBytes
	delete(o.connections, h.deviceID)
	o.sources[c.source]--
	if o.sources[c.source] == 0 {
		delete(o.sources, c.source)
	}
	return nil
}

// TryDequeue transfers a frame to the caller without blocking. Close discards
// pending frames; it never closes a concurrently used channel.
func (o *ConnectionOwner) TryDequeue(h ConnectionHandle) (signal.Frame, QueueState) {
	if o == nil {
		return signal.Frame{}, QueueClosed
	}
	if !o.mu.TryLock() {
		return signal.Frame{}, QueueBusy
	}
	defer o.mu.Unlock()
	c := o.current(h)
	if c == nil {
		return signal.Frame{}, QueueClosed
	}
	if c.count == 0 {
		return signal.Frame{}, QueueEmpty
	}
	f := c.queue[c.head]
	c.queue[c.head] = signal.Frame{}
	c.head = (c.head + 1) % len(c.queue)
	c.count--
	c.queuedBytes -= len(f.Payload)
	o.queuedBytes -= len(f.Payload)
	return f, QueueReady
}
func (o *ConnectionOwner) snapshot(h ConnectionHandle, target string, bound bool) (pairSnapshot, bool) {
	if o == nil || !canonicalUUID(target) || h.deviceID == target {
		return pairSnapshot{}, false
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	from := o.current(h)
	to := o.connections[target]
	if from == nil || to == nil || (bound && (from.binding == nil || to.binding == nil)) {
		return pairSnapshot{}, false
	}
	return pairSnapshot{snapshotConnection(from), snapshotConnection(to)}, true
}

// enqueue consumes a policy-owned frame. Its only lock is nonblocking; checks
// and insertion together form the final SQL callback's owner boundary.
func (o *ConnectionOwner) enqueue(pair pairSnapshot, frame signal.Frame, bound bool) bool {
	if o == nil || len(frame.Payload) == 0 || len(frame.Payload) > signal.MaximumFrameSize || !o.mu.TryLock() {
		return false
	}
	defer o.mu.Unlock()
	from, to := o.current(pair.from.handle), o.current(pair.to.handle)
	if from == nil || to == nil || from == to {
		return false
	}
	if bound && (!sameBinding(from, pair.from) || !sameBinding(to, pair.to)) {
		return false
	}
	if to.count == len(to.queue) || len(frame.Payload) > o.maximumQueuedBytes-o.queuedBytes {
		return false
	}
	to.queue[(to.head+to.count)%len(to.queue)] = frame
	to.count++
	to.queuedBytes += len(frame.Payload)
	o.queuedBytes += len(frame.Payload)
	return true
}

// current is called only with mu held.
func (o *ConnectionOwner) current(h ConnectionHandle) *connection {
	if h.owner != o || h.generation == 0 {
		return nil
	}
	c := o.connections[h.deviceID]
	if c == nil || c.handle != h {
		return nil
	}
	return c
}
func snapshotConnection(c *connection) connectionSnapshot {
	s := connectionSnapshot{handle: c.handle, publicKey: append([]byte(nil), c.publicKey...), bindingVersion: c.bindingVersion}
	if c.binding != nil {
		b := *c.binding
		s.binding = &b
	}
	return s
}
func sameBinding(c *connection, s connectionSnapshot) bool {
	return c.binding != nil && s.binding != nil && c.bindingVersion == s.bindingVersion && *c.binding == *s.binding
}
func validIdentity(id string, key []byte) bool {
	if (len(key) != 64 && len(key) != 65) || !canonicalUUID(id) || auth.DeviceID(key) != id {
		return false
	}
	encoded := key
	if len(key) == 64 {
		encoded = append([]byte{4}, key...)
	} else if len(key) != 65 || key[0] != 4 {
		return false
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), encoded)
	return x != nil && y != nil
}
func validBinding(b AccountBinding, deviceID string) bool {
	return canonicalUUID(b.Actor.AccountID) && canonicalUUID(b.Actor.SessionID) && canonicalUUID(b.Actor.DeviceID) && b.Actor.DeviceID == deviceID && validLabel(b.Actor.Audience) && canonicalUUID(b.GroupID) && b.Generation > 0 && b.Generation <= math.MaxInt64
}
func validLabel(s string) bool {
	if len(s) < 1 || len(s) > 255 || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return false
		}
	}
	return true
}
func canonicalUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := range len(s) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if s[i] != '-' {
				return false
			}
		} else if !(s[i] >= '0' && s[i] <= '9' || s[i] >= 'a' && s[i] <= 'f') {
			return false
		}
	}
	return true
}
func (ConnectionHandle) String() string     { return "<routeauth.ConnectionHandle>" }
func (h ConnectionHandle) GoString() string { return h.String() }
func (AccountBinding) String() string       { return "<routeauth.AccountBinding>" }
func (b AccountBinding) GoString() string   { return b.String() }
func (AccountBinding) MarshalJSON() ([]byte, error) {
	return nil, errors.New("account binding is internal")
}
func (*ConnectionOwner) String() string     { return "<routeauth.ConnectionOwner>" }
func (o *ConnectionOwner) GoString() string { return o.String() }
