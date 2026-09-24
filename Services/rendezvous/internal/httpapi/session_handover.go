package httpapi

import (
	"context"
	"sync"
	"time"
)

// Only the fully verified WebSocket path may enter this handover gate. Pending
// reservations reject competing replacements rather than accumulating waiters.
type authenticatedSessions struct {
	mu      sync.Mutex
	devices map[string]*authenticatedSession
}

type authenticatedSession struct {
	close   func()
	done    chan struct{}
	pending bool
}

func (s *authenticatedSessions) acquire(ctx context.Context, source, device string,
	closeSocket func(), limiter *connectionLimiter) (func(), error) {
	s.mu.Lock()
	if s.devices == nil {
		s.devices = make(map[string]*authenticatedSession)
	}
	previous := s.devices[device]
	if previous != nil && previous.pending {
		s.mu.Unlock()
		return nil, errConnectionCapacity
	}
	reservation := &authenticatedSession{close: closeSocket, done: make(chan struct{}), pending: true}
	s.devices[device] = reservation
	s.mu.Unlock()
	abandon := func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.devices[device] == reservation {
			delete(s.devices, device)
		}
	}
	if previous != nil {
		previous.close()
		timer := time.NewTimer(webSocketAuthTTL)
		defer timer.Stop()
		select {
		case <-previous.done:
		case <-ctx.Done():
			abandon()
			return nil, errConnectionCapacity
		case <-timer.C:
			abandon()
			return nil, errConnectionCapacity
		}
	}
	if err := ctx.Err(); err != nil {
		abandon()
		return nil, errConnectionCapacity
	}
	release, err := limiter.Acquire(source, device)
	if err != nil {
		abandon()
		return nil, err
	}
	s.mu.Lock()
	reservation.pending = false
	s.mu.Unlock()
	var once sync.Once
	// The router defers this before all hub-registration cleanups: they finish
	// first. A later owner cannot activate until this completion is signalled.
	return func() {
		once.Do(func() {
			release()
			s.mu.Lock()
			if s.devices[device] == reservation {
				delete(s.devices, device)
			}
			close(reservation.done)
			s.mu.Unlock()
		})
	}, nil
}
