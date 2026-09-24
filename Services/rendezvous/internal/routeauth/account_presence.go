package routeauth

import (
	"context"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/signal"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

// PresenceProjector returns candidates only; every pair requires fresh admission.
// Providers must honor cancellation. Shutdown joins outstanding provider work.
type PresenceProjector interface {
	ProjectPresenceCandidates(context.Context, accountgroup.PresenceProjectionRequest) (accountgroup.PresenceProjection, error)
}
type AccountPresenceConfig struct {
	Hub               *presence.Hub
	Projection        PresenceProjector
	CandidatesPerTurn int
	WorkTimeout       time.Duration
	// RefreshInterval enables best-effort refresh, not a wall-clock revocation
	// guarantee. Zero preserves event-only behavior; per-frame admission remains
	// authoritative. Providers must still honor WorkTimeout cancellation.
	RefreshInterval time.Duration
	refreshTicks    <-chan time.Time // private deterministic clock override
}

// PresenceHub identifies the immutable hub configured for owned presence.
// A nil result preserves the legacy HTTP presence lifecycle.
func (r *ConnectionRouter) PresenceHub() *presence.Hub {
	if r == nil || r.presence == nil {
		return nil
	}
	return r.presence.config.Hub
}

type presenceAttachment struct {
	handle  presence.ConnectionHandle
	cleanup func()
}
type presenceJob struct {
	handle  ConnectionHandle
	version uint64
}
type presencePairKey struct{ left, right ConnectionHandle }
type presencePair struct {
	snapshot    pairSnapshot
	left, right *presenceAttachment
	epoch       uint64
}
type accountPresence struct {
	mu           sync.Mutex // lifecycle and bookkeeping only; never acquired by SQL callback
	router       *ConnectionRouter
	config       AccountPresenceConfig
	ctx          context.Context
	cancel       context.CancelFunc
	done, wake   chan struct{}
	refreshDone  chan struct{}
	shutdownDone chan struct{}
	closing      sync.WaitGroup
	stopped      bool
	queue        []presenceJob
	pending      map[ConnectionHandle]bool
	pairs        map[presencePairKey]presencePair
}

func NewCompositeConnectionRouterWithPresence(capacity int, graph signal.TrustGraph, gate AccountGate, config AccountPresenceConfig) (*ConnectionRouter, error) {
	if config.Hub == nil || config.Projection == nil || gate == nil || config.CandidatesPerTurn < 1 || config.CandidatesPerTurn > 63 || config.WorkTimeout <= 0 || config.WorkTimeout > 5*time.Second || config.RefreshInterval < 0 || config.RefreshInterval > 60*time.Second {
		return nil, ErrConnectionUnavailable
	}
	r, err := NewCompositeConnectionRouter(capacity, graph, gate)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	p := &accountPresence{router: r, config: config, ctx: ctx, cancel: cancel, done: make(chan struct{}), shutdownDone: make(chan struct{}), wake: make(chan struct{}, 1), pending: make(map[ConnectionHandle]bool), pairs: make(map[presencePairKey]presencePair)}
	r.presence = p
	p.refreshDone = make(chan struct{})
	if config.RefreshInterval == 0 {
		close(p.refreshDone)
	} else {
		go p.refresh()
	}
	go p.run()
	return r, nil
}

// refresh only queues exact current route versions. The single worker owns all
// projection/admission work, including when ticks outpace a blocked provider.
func (p *accountPresence) refresh() {
	defer close(p.refreshDone)
	ticks := p.config.refreshTicks
	if ticks == nil {
		ticker := time.NewTicker(p.config.RefreshInterval)
		defer ticker.Stop()
		ticks = ticker.C
	}
	for {
		select {
		case <-p.ctx.Done():
			return
		case _, ok := <-ticks:
			if !ok {
				return
			}
		}
		p.mu.Lock()
		if p.stopped {
			p.mu.Unlock()
			return
		}
		o := p.router.owner
		o.mu.Lock()
		for _, c := range o.connections {
			if c.presence != nil && c.binding != nil {
				p.enqueue(presenceJob{handle: c.handle, version: c.bindingVersion})
			}
		}
		o.mu.Unlock()
		p.mu.Unlock()
	}
}

// AttachPresence must follow successful auth-ok delivery. It transfers sink
// ownership only on success. Close/Shutdown joins the exact owned subscription.
// Register alone never emits presence, and a handle can attach only once.
func (r *ConnectionRouter) AttachPresence(h ConnectionHandle, sink presence.OwnedSink) error {
	if r == nil || r.presence == nil || sink == nil {
		return ErrConnectionUnavailable
	}
	p := r.presence
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stopped {
		return ErrConnectionUnavailable
	}
	r.owner.mu.Lock()
	c := r.owner.current(h)
	if c == nil || c.presence != nil {
		r.owner.mu.Unlock()
		return ErrConnectionUnavailable
	}
	source := c.source
	r.owner.mu.Unlock()
	ph, cleanup, err := p.config.Hub.ConnectOwned(h.deviceID, source, sink)
	if err != nil {
		return ErrConnectionUnavailable
	}
	r.owner.mu.Lock()
	c.presence = &presenceAttachment{ph, cleanup}
	s := snapshotConnection(c)
	r.owner.mu.Unlock()
	p.scheduleGroup(s.binding)
	return nil
}

func (p *accountPresence) change(h ConnectionHandle, b *AccountBinding, closeConnection bool) error {
	p.mu.Lock()
	if p.stopped {
		p.mu.Unlock()
		return ErrConnectionUnavailable
	}
	o := p.router.owner
	o.mu.Lock()
	c := o.current(h)
	if c == nil {
		o.mu.Unlock()
		p.mu.Unlock()
		return ErrConnectionUnavailable
	}
	old := snapshotConnection(c)
	attachment := c.presence
	o.mu.Unlock()
	var err error
	if closeConnection {
		err = o.Close(h)
	} else if b != nil {
		err = o.Bind(h, *b)
	} else {
		err = o.Unbind(h)
	}
	// Even version exhaustion clears the binding and must withdraw old authority.
	if attachment != nil {
		p.config.Hub.AdvanceAccountSource(attachment.handle)
		p.forget(h)
	}
	p.scheduleGroup(old.binding)
	if b != nil && err == nil {
		p.scheduleGroup(b)
	}
	if closeConnection {
		delete(p.pending, h)
		for i := 0; i < len(p.queue); i++ {
			if p.queue[i].handle == h {
				p.queue = append(p.queue[:i], p.queue[i+1:]...)
				break
			}
		}
	}
	if closeConnection && attachment != nil {
		p.closing.Add(1)
	}
	p.mu.Unlock()
	if closeConnection && attachment != nil {
		attachment.cleanup()
		p.closing.Done()
	}
	return err
}
func (p *accountPresence) forget(h ConnectionHandle) {
	for k := range p.pairs {
		if k.left == h || k.right == h {
			delete(p.pairs, k)
		}
	}
}
func sameGroup(a, b *AccountBinding) bool {
	return a != nil && b != nil && a.Actor.AccountID == b.Actor.AccountID && a.GroupID == b.GroupID && a.Generation == b.Generation
}
func (p *accountPresence) scheduleGroup(b *AccountBinding) {
	if b == nil {
		return
	}
	o := p.router.owner
	o.mu.Lock()
	defer o.mu.Unlock()
	for _, c := range o.connections {
		if c.presence != nil && sameGroup(c.binding, b) {
			p.enqueue(presenceJob{handle: c.handle, version: c.bindingVersion})
		}
	}
}
func (p *accountPresence) enqueue(j presenceJob) {
	if p.stopped {
		return
	}
	if p.pending[j.handle] {
		for i := range p.queue {
			if p.queue[i].handle == j.handle {
				p.queue[i] = j
				break
			}
		}
		return
	}
	if len(p.queue) >= MaximumConnections {
		return
	}
	p.pending[j.handle] = true
	p.queue = append(p.queue, j)
	select {
	case p.wake <- struct{}{}:
	default:
	}
}
func (p *accountPresence) run() {
	defer close(p.done)
	for {
		p.mu.Lock()
		if p.stopped {
			p.mu.Unlock()
			return
		}
		if len(p.queue) == 0 {
			p.mu.Unlock()
			select {
			case <-p.ctx.Done():
				return
			case <-p.wake:
			}
			continue
		}
		j := p.queue[0]
		p.queue = p.queue[1:]
		delete(p.pending, j.handle)
		p.mu.Unlock()
		p.turn(j)
	}
}
func (p *accountPresence) source(j presenceJob) (connectionSnapshot, bool) {
	o := p.router.owner
	o.mu.Lock()
	defer o.mu.Unlock()
	c := o.current(j.handle)
	if c == nil || c.presence == nil || c.binding == nil || c.bindingVersion != j.version {
		return connectionSnapshot{}, false
	}
	return snapshotConnection(c), true
}
func pairKeyFor(a, b ConnectionHandle) presencePairKey {
	if a.generation > b.generation {
		a, b = b, a
	}
	return presencePairKey{a, b}
}
func (p *accountPresence) validPair(pair presencePair) bool {
	o := p.router.owner
	o.mu.Lock()
	defer o.mu.Unlock()
	return p.validPairLocked(pair)
}
func (p *accountPresence) validPairLocked(pair presencePair) bool {
	o := p.router.owner
	a, b := o.current(pair.snapshot.from.handle), o.current(pair.snapshot.to.handle)
	return a != nil && b != nil && a.presence == pair.left && b.presence == pair.right && sameBinding(a, pair.snapshot.from) && sameBinding(b, pair.snapshot.to)
}
func (p *accountPresence) turn(j presenceJob) {
	s, ok := p.source(j)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(p.ctx, p.config.WorkTimeout)
	defer cancel()
	projection, err := p.config.Projection.ProjectPresenceCandidates(ctx, accountgroup.PresenceProjectionRequest{Actor: s.binding.Actor, PublicKey: s.publicKey, GroupID: s.binding.GroupID, Generation: s.binding.Generation})
	valid := err == nil && ctx.Err() == nil && projection.GroupID == s.binding.GroupID && projection.Generation == s.binding.Generation && len(projection.DeviceIDs) <= 63
	var ids []string
	if valid {
		ids = append([]string(nil), projection.DeviceIDs...)
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if !canonicalUUID(id) || id == j.handle.deviceID || seen[id] {
			valid = false
		}
		seen[id] = true
	}
	p.mu.Lock()
	_, current := p.source(j)
	if p.stopped || !current {
		p.mu.Unlock()
		return
	}
	if !valid {
		o := p.router.owner
		o.mu.Lock()
		a := o.current(j.handle).presence
		o.mu.Unlock()
		p.config.Hub.AdvanceAccountSource(a.handle)
		p.forget(j.handle)
		p.mu.Unlock()
		return
	}
	for k, old := range p.pairs {
		if k.left == j.handle || k.right == j.handle {
			peer := k.left
			if peer == j.handle {
				peer = k.right
			}
			if !seen[peer.deviceID] || !p.validPair(old) {
				p.config.Hub.WithdrawAccountPair(old.left.handle, old.right.handle, old.epoch)
				delete(p.pairs, k)
			}
		}
	}
	p.mu.Unlock()
	// Keep one stable projection and one source deadline. Yield between bounded
	// candidate turns without retaining a projection for every queued source.
	for start := 0; start < len(ids) && ctx.Err() == nil; start += p.config.CandidatesPerTurn {
		if _, ok := p.source(j); !ok {
			return
		}
		end := start + p.config.CandidatesPerTurn
		if end > len(ids) {
			end = len(ids)
		}
		for i := start; i < end && ctx.Err() == nil; i++ {
			p.admit(ctx, j, ids[i])
		}
		runtime.Gosched()
	}
	if ctx.Err() != nil {
		p.mu.Lock()
		if !p.stopped {
			if _, ok := p.source(j); ok {
				o := p.router.owner
				o.mu.Lock()
				a := o.current(j.handle).presence
				o.mu.Unlock()
				p.config.Hub.AdvanceAccountSource(a.handle)
				p.forget(j.handle)
			}
		}
		p.mu.Unlock()
	}
}
func (p *accountPresence) admit(ctx context.Context, j presenceJob, target string) {
	p.mu.Lock()
	if p.stopped {
		p.mu.Unlock()
		return
	}
	s, ok := p.router.owner.snapshot(j.handle, target, true)
	if !ok || s.from.bindingVersion != j.version || !sameGroup(s.from.binding, s.to.binding) {
		p.mu.Unlock()
		return
	}
	o := p.router.owner
	o.mu.Lock()
	a, b := o.current(s.from.handle), o.current(s.to.handle)
	if a == nil || b == nil || a.presence == nil || b.presence == nil {
		o.mu.Unlock()
		p.mu.Unlock()
		return
	}
	pair := presencePair{snapshot: s, left: a.presence, right: b.presence}
	o.mu.Unlock()
	key := pairKeyFor(s.from.handle, s.to.handle)
	if _, exists := p.pairs[key]; !exists && len(p.pairs) >= presence.MaximumAccountPairs {
		p.mu.Unlock()
		return
	}
	epoch, ok := p.config.Hub.BeginAccountPair(pair.left.handle, pair.right.handle)
	if !ok {
		p.mu.Unlock()
		return
	}
	pair.epoch = epoch
	p.pairs[key] = pair
	p.mu.Unlock()
	req := accountgroup.RouteAdmissionRequest{From: accountgroup.RouteEndpoint{Actor: s.from.binding.Actor, PublicKey: s.from.publicKey, ConnectionGeneration: s.from.handle.generation}, To: accountgroup.RouteEndpoint{Actor: s.to.binding.Actor, PublicKey: s.to.publicKey, ConnectionGeneration: s.to.handle.generation}, GroupID: s.from.binding.GroupID, Generation: s.from.binding.Generation}
	var state atomic.Uint32
	var batch atomic.Pointer[presence.AccountBatch]
	p.router.policy.account.Admit(ctx, req, func() bool {
		if !state.CompareAndSwap(0, 1) || ctx.Err() != nil || !o.mu.TryLock() {
			return false
		}
		defer o.mu.Unlock()
		if !p.validPairLocked(pair) {
			return false
		}
		b, ok := p.config.Hub.ReserveAccountPair(pair.left.handle, pair.right.handle, epoch, true)
		if ok {
			batch.Store(b)
		}
		return ok
	})
	state.CompareAndSwap(0, 2)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stopped || !p.validPair(pair) {
		return
	}
	if b := batch.Load(); b != nil {
		b.Publish()
	} else {
		p.config.Hub.WithdrawAccountPair(pair.left.handle, pair.right.handle, epoch)
	}
}

// Shutdown is idempotent and waits for this adapter's worker and owned sinks.
// A provider ignoring context or a sink violating OwnedSink.Close can delay it.
// Routers built with the legacy constructor have no adapter to shut down;
// their explicit per-connection Close lifecycle is unchanged.
func (r *ConnectionRouter) Shutdown() {
	if r == nil || r.presence == nil {
		return
	}
	p := r.presence
	p.mu.Lock()
	if p.stopped {
		p.mu.Unlock()
		<-p.shutdownDone
		return
	}
	p.stopped = true
	p.cancel()
	p.queue = nil
	p.pending = nil
	o := r.owner
	o.mu.Lock()
	var attachments []*presenceAttachment
	for _, c := range o.connections {
		if c.presence != nil {
			attachments = append(attachments, c.presence)
			c.presence = nil
		}
		close(c.notifications)
	}
	// Retire attached and not-yet-attached route generations atomically. Paused
	// signal admissions recheck these handles before enqueueing.
	clear(o.connections)
	clear(o.sources)
	o.queuedBytes = 0
	o.mu.Unlock()
	for _, a := range attachments {
		p.config.Hub.AdvanceAccountSource(a.handle)
	}
	p.pairs = nil
	p.mu.Unlock()
	for _, a := range attachments {
		a.cleanup()
	}
	<-p.refreshDone
	<-p.done
	p.closing.Wait()
	close(p.shutdownDone)
}
