package routeauth

import (
	"bytes"
	"crypto/elliptic"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"sync"
	"testing"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/signal"
)

func identity(n int, raw bool) (string, []byte) {
	x, y := elliptic.P256().ScalarBaseMult([]byte{byte(n >> 8), byte(n)})
	key := elliptic.Marshal(elliptic.P256(), x, y)
	if raw {
		key = key[1:]
	}
	return auth.DeviceID(key), key
}

func ownerFixture(t *testing.T, capacity int) (*ConnectionOwner, ConnectionHandle, ConnectionHandle) {
	t.Helper()
	o, err := NewConnectionOwner(capacity)
	if err != nil {
		t.Fatal(err)
	}
	a, ak := identity(1, true)
	b, bk := identity(2, false)
	from, err := o.Register(a, ak, "source-a")
	if err != nil {
		t.Fatal(err)
	}
	to, err := o.Register(b, bk, "source-b")
	if err != nil {
		t.Fatal(err)
	}
	return o, from, to
}

func bindingFor(h ConnectionHandle) AccountBinding {
	return AccountBinding{Actor: accountgroup.SessionActor{AccountID: "11111111-2222-3333-4444-555555555555", SessionID: fmt.Sprintf("%08x-1111-2222-3333-444444444444", h.generation), DeviceID: h.deviceID, Audience: "com.example.app"}, GroupID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", Generation: 1}
}

func TestOwnerRegistrationAndExactCleanup(t *testing.T) {
	o, from, to := ownerFixture(t, 1)
	id, key := identity(1, true)
	if _, err := o.Register(id, key, "another-source"); err != ErrConnectionUnavailable {
		t.Fatal("duplicate live registration", err)
	}
	if err := o.Bind(from, bindingFor(from)); err != nil {
		t.Fatal(err)
	}
	if err := o.Close(from); err != nil {
		t.Fatal(err)
	}
	replacement, err := o.Register(id, key, "source-a")
	if err != nil {
		t.Fatal(err)
	}
	if replacement == from || replacement.generation <= from.generation {
		t.Fatal("reused connection handle")
	}
	if err := o.Bind(replacement, bindingFor(replacement)); err != nil {
		t.Fatal(err)
	}
	if err := o.Bind(to, bindingFor(to)); err != nil {
		t.Fatal(err)
	}
	for _, op := range []func() error{func() error { return o.Close(from) }, func() error { return o.Unbind(from) }, func() error { return o.Bind(from, bindingFor(from)) }} {
		if err := op(); err != ErrConnectionUnavailable {
			t.Fatal("stale lifecycle accepted", err)
		}
	}
	pair, ok := o.snapshot(replacement, to.deviceID, true)
	if !ok || pair.from.binding == nil {
		t.Fatal("old cleanup cleared replacement binding")
	}
	if _, state := o.TryDequeue(from); state != QueueClosed {
		t.Fatal("old handle still live", state)
	}
}

func TestOwnerValidationAndInputOwnership(t *testing.T) {
	for _, kind := range []string{"bad uuid", "uppercase uuid", "wrong id", "short key", "off curve", "wrong prefix", "representation mismatch", "empty source", "long source"} {
		t.Run(kind, func(t *testing.T) {
			o, _ := NewConnectionOwner(1)
			id, key := identity(1, true)
			source := "source"
			switch kind {
			case "bad uuid":
				id = "bad"
			case "uppercase uuid":
				id = strings.ToUpper(id)
			case "wrong id":
				id, _ = identity(2, true)
			case "short key":
				key = key[:63]
			case "off curve":
				key = make([]byte, 64)
				id = auth.DeviceID(key)
			case "wrong prefix":
				_, key = identity(1, false)
				key[0] = 3
				id = auth.DeviceID(key)
			case "representation mismatch":
				_, key = identity(1, false)
			case "empty source":
				source = ""
			case "long source":
				source = strings.Repeat("x", 256)
			}
			if _, err := o.Register(id, key, source); err != ErrConnectionUnavailable {
				t.Fatal("invalid identity", err)
			}
		})
	}
	o, _ := NewConnectionOwner(1)
	id, key := identity(1, true)
	want := append([]byte(nil), key...)
	h, err := o.Register(id, key, "source")
	if err != nil {
		t.Fatal(err)
	}
	key[0] ^= 1
	b, bk := identity(2, true)
	to, err := o.Register(b, bk, "other")
	if err != nil {
		t.Fatal(err)
	}
	binding := bindingFor(h)
	if err := o.Bind(h, binding); err != nil {
		t.Fatal(err)
	}
	binding.Actor.SessionID = "changed"
	pair, ok := o.snapshot(h, to.deviceID, false)
	if !ok || !bytes.Equal(pair.from.publicKey, want) || pair.from.binding.Actor.SessionID == "changed" {
		t.Fatal("borrowed registration/binding input")
	}
	pair.from.publicKey[0] ^= 1
	pair.from.binding.Actor.SessionID = "changed"
	again, ok := o.snapshot(h, to.deviceID, false)
	if !ok || !bytes.Equal(again.from.publicKey, want) || again.from.binding.Actor.SessionID == "changed" {
		t.Fatal("snapshot exposed owned state")
	}
}

func TestOwnerBindingValidationAndVersions(t *testing.T) {
	for _, kind := range []string{"account", "session", "device", "audience empty", "audience space", "audience control", "audience invalid utf8", "audience long", "group", "zero generation", "overflow generation"} {
		t.Run(kind, func(t *testing.T) {
			o, h, _ := ownerFixture(t, 1)
			b := bindingFor(h)
			switch kind {
			case "account":
				b.Actor.AccountID = "bad"
			case "session":
				b.Actor.SessionID = "bad"
			case "device":
				b.Actor.DeviceID, _ = identity(8, true)
			case "audience empty":
				b.Actor.Audience = ""
			case "audience space":
				b.Actor.Audience = "a b"
			case "audience control":
				b.Actor.Audience = "a\x00"
			case "audience invalid utf8":
				b.Actor.Audience = string([]byte{255})
			case "audience long":
				b.Actor.Audience = strings.Repeat("a", 256)
			case "group":
				b.GroupID = "bad"
			case "zero generation":
				b.Generation = 0
			case "overflow generation":
				b.Generation = 1 << 63
			}
			if err := o.Bind(h, b); err != ErrConnectionUnavailable {
				t.Fatal("invalid binding", err)
			}
		})
	}
	o, h, to := ownerFixture(t, 1)
	b := bindingFor(h)
	if err := o.Bind(h, b); err != nil {
		t.Fatal(err)
	}
	pair, _ := o.snapshot(h, to.deviceID, false)
	if err := o.Unbind(h); err != nil {
		t.Fatal(err)
	}
	if err := o.Bind(h, b); err != nil {
		t.Fatal(err)
	}
	after, _ := o.snapshot(h, to.deviceID, false)
	if after.from.bindingVersion <= pair.from.bindingVersion || *after.from.binding != *pair.from.binding {
		t.Fatal("binding ABA not versioned")
	}
	o.mu.Lock()
	o.connections[h.deviceID].bindingVersion = math.MaxUint64
	o.mu.Unlock()
	if o.Bind(h, b) != ErrConnectionUnavailable || o.Unbind(h) != ErrConnectionUnavailable {
		t.Fatal("binding version overflow")
	}
	if pair, _ := o.snapshot(h, to.deviceID, false); pair.from.binding != nil {
		t.Fatal("exhausted binding version retained account authority")
	}
}

func TestOwnerCapacityAndCounterExhaustion(t *testing.T) {
	for _, n := range []int{0, -1, MaximumQueueCapacity + 1} {
		if _, err := NewConnectionOwner(n); err != ErrQueueCapacity {
			t.Fatal("invalid queue capacity", n, err)
		}
	}
	for _, limit := range []string{"source", "global"} {
		t.Run(limit, func(t *testing.T) {
			o, _ := NewConnectionOwner(1)
			count := MaximumConnectionsPerSource
			if limit == "global" {
				count = MaximumConnections
			}
			var first ConnectionHandle
			for n := 1; n <= count; n++ {
				id, key := identity(n, true)
				source := "shared"
				if limit == "global" {
					source = fmt.Sprint(n)
				}
				h, err := o.Register(id, key, source)
				if err != nil {
					t.Fatal(n, err)
				}
				if n == 1 {
					first = h
				}
			}
			id, key := identity(count+1, true)
			source := "shared"
			if limit == "global" {
				source = "extra"
			}
			if _, err := o.Register(id, key, source); err != ErrConnectionUnavailable {
				t.Fatal("capacity exceeded", err)
			}
			if err := o.Close(first); err != nil {
				t.Fatal(err)
			}
			if _, err := o.Register(id, key, source); err != nil {
				t.Fatal("capacity not released", err)
			}
		})
	}
	o, _ := NewConnectionOwner(1)
	o.nextGeneration = math.MaxUint64 - 1
	id, key := identity(1, true)
	h, err := o.Register(id, key, "source")
	if err != nil || h.generation != math.MaxUint64 {
		t.Fatal("last generation", err)
	}
	o.Close(h)
	if _, err := o.Register(id, key, "source"); err != ErrConnectionUnavailable {
		t.Fatal("counter wrapped", err)
	}
}

func TestOwnerIndependentAndRedacted(t *testing.T) {
	o, h, to := ownerFixture(t, 1)
	other, _, _ := ownerFixture(t, 1)
	if other.Bind(h, bindingFor(h)) != ErrConnectionUnavailable || other.Close(h) != ErrConnectionUnavailable {
		t.Fatal("foreign owner accepted handle")
	}
	if _, ok := other.snapshot(h, to.deviceID, false); ok {
		t.Fatal("foreign owner snapshot")
	}
	b := bindingFor(h)
	for _, value := range []any{h, &h, b, &b, o} {
		for _, format := range []string{"%v", "%+v", "%#v"} {
			s := fmt.Sprintf(format, value)
			for _, secret := range []string{h.deviceID, b.Actor.AccountID, b.Actor.SessionID, b.GroupID, b.Actor.Audience} {
				if strings.Contains(s, secret) {
					t.Fatal("unredacted diagnostic", format)
				}
			}
		}
	}
	if _, err := json.Marshal(b); err == nil {
		t.Fatal("account binding serialized")
	}
}

func TestOwnerQueueBoundBusyOwnershipAndClose(t *testing.T) {
	o, from, to := ownerFixture(t, 1)
	pair, ok := o.snapshot(from, to.deviceID, false)
	if !ok {
		t.Fatal("snapshot")
	}
	payload := []byte("owned")
	if !o.enqueue(pair, signal.Frame{Type: "signal", From: from.deviceID, Payload: payload}, false) {
		t.Fatal("enqueue")
	}
	if o.enqueue(pair, signal.Frame{Payload: []byte("second")}, false) {
		t.Fatal("queue overflow")
	}
	frame, state := o.TryDequeue(to)
	if state != QueueReady || string(frame.Payload) != "owned" {
		t.Fatal("dequeue", state)
	}
	if _, state := o.TryDequeue(to); state != QueueEmpty {
		t.Fatal("not empty")
	}
	o.mu.Lock()
	if o.enqueue(pair, signal.Frame{Payload: []byte("busy")}, false) {
		t.Fatal("busy enqueue")
	}
	if _, state := o.TryDequeue(to); state != QueueBusy {
		t.Fatal("busy dequeue")
	}
	o.mu.Unlock()
	o.maximumQueuedBytes = 2
	if o.enqueue(pair, signal.Frame{Payload: []byte("abc")}, false) {
		t.Fatal("global byte cap")
	}
	if !o.enqueue(pair, signal.Frame{Payload: []byte("ab")}, false) {
		t.Fatal("within byte cap")
	}
	if err := o.Close(to); err != nil {
		t.Fatal(err)
	}
	if o.queuedBytes != 0 {
		t.Fatal("closed queue retained byte budget")
	}
	if _, state := o.TryDequeue(to); state != QueueClosed {
		t.Fatal("closed dequeue")
	}
}

func TestOwnerConcurrentCloseRegistration(t *testing.T) {
	o, _ := NewConnectionOwner(1)
	id, key := identity(1, true)
	h, err := o.Register(id, key, "source")
	if err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	var wg sync.WaitGroup
	results := make(chan ConnectionHandle, 32)
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_ = o.Close(h)
			if next, err := o.Register(id, key, "source"); err == nil {
				results <- next
			}
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	var live ConnectionHandle
	count := 0
	for h := range results {
		live = h
		count++
	}
	if count != 1 {
		t.Fatal("replacement winners", count)
	}
	if o.Close(h) != ErrConnectionUnavailable || o.Bind(live, bindingFor(live)) != nil {
		t.Fatal("stale close erased replacement")
	}
}

func TestOwnerGlobalByteBudgetAndRingReuse(t *testing.T) {
	o, from, to := ownerFixture(t, 2)
	cid, ck := identity(3, true)
	other, err := o.Register(cid, ck, "other")
	if err != nil {
		t.Fatal(err)
	}
	o.maximumQueuedBytes = 2
	a, _ := o.snapshot(from, to.deviceID, false)
	b, _ := o.snapshot(from, other.deviceID, false)
	if !o.enqueue(a, signal.Frame{Payload: []byte("ab")}, false) || o.enqueue(b, signal.Frame{Payload: []byte("c")}, false) || o.queuedBytes != 2 {
		t.Fatal("budget is not global")
	}
	if _, state := o.TryDequeue(to); state != QueueReady || o.queuedBytes != 0 {
		t.Fatal("dequeue retained reservation")
	}
	if !o.enqueue(b, signal.Frame{Payload: []byte("c")}, false) {
		t.Fatal("budget not reusable")
	}
	if err := o.Close(other); err != nil || o.queuedBytes != 0 {
		t.Fatal("close retained reservation", err)
	}
	for _, payload := range []string{"1", "2"} {
		if !o.enqueue(a, signal.Frame{Payload: []byte(payload)}, false) {
			t.Fatal("ring enqueue")
		}
	}
	if f, state := o.TryDequeue(to); state != QueueReady || string(f.Payload) != "1" {
		t.Fatal("ring first")
	}
	if !o.enqueue(a, signal.Frame{Payload: []byte("3")}, false) {
		t.Fatal("ring reuse")
	}
	for _, want := range []string{"2", "3"} {
		if f, state := o.TryDequeue(to); state != QueueReady || string(f.Payload) != want {
			t.Fatal("ring order")
		}
	}
	if o.queuedBytes != 0 {
		t.Fatal("ring retained reservation")
	}
}

func TestOwnerConcurrentCloseEnqueueDequeue(t *testing.T) {
	for range 32 {
		o, from, to := ownerFixture(t, 2)
		pair, _ := o.snapshot(from, to.deviceID, false)
		start := make(chan struct{})
		var wg sync.WaitGroup
		for _, fn := range []func(){func() { o.enqueue(pair, signal.Frame{Payload: []byte("frame")}, false) }, func() { o.Close(to) }, func() { o.TryDequeue(to) }} {
			wg.Add(1)
			go func(fn func()) { defer wg.Done(); <-start; fn() }(fn)
		}
		close(start)
		wg.Wait()
		if o.queuedBytes != 0 {
			t.Fatal("close/send retained queue memory")
		}
		if _, state := o.TryDequeue(to); state != QueueClosed {
			t.Fatal("closed connection remained drainable")
		}
	}
}
