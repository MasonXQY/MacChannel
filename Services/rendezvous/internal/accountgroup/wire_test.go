package accountgroup

import (
	"encoding/base64"
	"reflect"
	"strings"
	"testing"
)

func TestWireRoundtrip(t *testing.T) {
	for _, raw := range []bool{true, false} {
		actor, subject := fixtureKey(t, raw), fixtureKey(t, !raw)
		for _, action := range []Action{ActionBootstrap, ActionApprove, ActionRemove} {
			e := baseEvent(actor, subject, action)
			if action == ActionBootstrap {
				e = baseEvent(actor, actor, action)
				e.Sequence = 1
				e.PreviousHash = nil
			}
			signActor(t, &e, actor.private)
			if action == ActionApprove {
				signBoth(t, &e, actor.private, subject.private)
			}
			w, err := EncodeWireEvent(e)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			p, _ := e.CanonicalPayload()
			if w.Payload != base64.StdEncoding.EncodeToString(p) {
				t.Fatal("payload changed")
			}
			got, err := DecodeWireEvent(w)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			d, _ := e.Digest()
			d2, _ := got.Digest()
			if d != d2 {
				t.Fatal("digest changed")
			}
			signActor(t, &e, actor.private)
			if action == ActionApprove {
				signBoth(t, &e, actor.private, subject.private)
			}
			w2, _ := EncodeWireEvent(e)
			if w2.Payload != w.Payload {
				t.Fatal("signature changed identity")
			}
			got.ActorPublicKey[0] ^= 1
			if e.Validate() != nil {
				t.Fatal("buffers aliased")
			}
		}
	}
}

func TestWireRejectMalformed(t *testing.T) {
	a, b := fixtureKey(t, true), fixtureKey(t, false)
	e := baseEvent(a, b, ActionApprove)
	signBoth(t, &e, a.private, b.private)
	e.Generation = 7
	signBoth(t, &e, a.private, b.private)
	w, _ := EncodeWireEvent(e)
	p, _ := e.CanonicalPayload()
	mutations := []string{"", string(p) + "\n", string(p) + "{}", "null", strings.Replace(string(p), `"generation":7`, `"generation":null`, 1), strings.Replace(string(p), `"sequence":2`, `"sequence":2.0`, 1), strings.Replace(string(p), `"sequence":2`, `"sequence":18446744073709551616`, 1), strings.Replace(string(p), `"purpose":`, `"extra":null,"purpose":`, 1), strings.Replace(string(p), `"purpose":`, `"purpose":"x","purpose":`, 1), strings.Replace(string(p), "dropmesh.account.group.event.v1", "other", 1), strings.Replace(string(p), `"action":"approve"`, `"action":"remove"`, 1), strings.Replace(string(p), `"accountID":`, `"AccountID":`, 1), string(p) + "\x00"}
	for _, payload := range mutations {
		bad := w
		bad.Payload = base64.StdEncoding.EncodeToString([]byte(payload))
		got, err := DecodeWireEvent(bad)
		if err != ErrInvalidEvent || !reflect.DeepEqual(got, Event{}) {
			t.Fatalf("accepted %q", payload)
		}
	}
	for _, edit := range []func(*WireEvent){func(v *WireEvent) { v.Payload += "\n" }, func(v *WireEvent) { v.Payload = strings.Repeat("A", 4097) }, func(v *WireEvent) { v.Signature = "" }, func(v *WireEvent) { v.Signature = strings.Repeat("A", 109) }, func(v *WireEvent) { v.SubjectSignature = "" }, func(v *WireEvent) { v.SubjectSignature = "!!!!" }, func(v *WireEvent) { v.Signature += "\n" }} {
		bad := w
		edit(&bad)
		got, err := DecodeWireEvent(bad)
		if err != ErrInvalidEvent || !reflect.DeepEqual(got, Event{}) {
			t.Fatal("accepted malformed wire")
		}
	}
	e.Signature = nil
	got, err := EncodeWireEvent(e)
	if err != ErrInvalidEvent || got != (WireEvent{}) {
		t.Fatal("encoded unsigned")
	}
}
