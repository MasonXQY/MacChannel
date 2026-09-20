package accountgroup

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"macchannel/rendezvous/internal/auth"
	"os"
	"strings"
	"testing"
)

func TestApprovalDraftRequiresActorOnlyAndFinalizesExactBytes(t *testing.T) {
	for _, raw := range []bool{true, false} {
		a, b := fixtureKey(t, raw), fixtureKey(t, !raw)
		e := baseEvent(a, b, ActionApprove)
		signBoth(t, &e, a.private, b.private)
		subject := append([]byte(nil), e.SubjectSignature...)
		e.SubjectSignature = nil
		d, err := NewApprovalDraft(e)
		if err != nil {
			t.Fatal(err)
		}
		if d.Event().Validate() == nil {
			t.Fatal("draft accepted as final")
		}
		w, err := EncodeWireApprovalDraft(d)
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := DecodeWireApprovalDraft(w)
		if err != nil {
			t.Fatal(err)
		}
		result, err := parsed.Finalize(subject)
		if err != nil {
			t.Fatal(err)
		}
		p, _ := e.CanonicalPayload()
		final, _ := result.CanonicalPayload()
		if !bytes.Equal(p, final) || !bytes.Equal(result.Signature, e.Signature) {
			t.Fatal("finalization replaced signed bytes")
		}
		if len(result.ActorPublicKey) != len(a.public) || len(result.SubjectPublicKey) != len(b.public) {
			t.Fatal("normalized key")
		}
		for _, sig := range [][]byte{nil, []byte{1}, e.Signature} {
			if _, err := d.Finalize(sig); err != ErrInvalidEvent {
				t.Fatal("invalid subject accepted")
			}
		}
		wrongDigest := sha256.Sum256([]byte("different canonical bytes"))
		wrongBytes, err := ecdsa.SignASN1(rand.Reader, b.private, wrongDigest[:])
		if err != nil {
			t.Fatal(err)
		}
		if _, err := d.Finalize(wrongBytes); err != ErrInvalidEvent {
			t.Fatal("subject signed different bytes")
		}
		encoded, _ := json.Marshal(w)
		strict, err := DecodeWireApprovalDraftJSON(encoded)
		if err != nil || strict != w {
			t.Fatal("raw decode", err)
		}
		for _, edit := range []func(*Event){func(v *Event) { v.Action = ActionRemove }, func(v *Event) { v.Signature = nil }, func(v *Event) { v.Signature = []byte{1} }, func(v *Event) { v.SubjectSignature = subject }} {
			bad := cloneEvent(e)
			edit(&bad)
			if _, err := NewApprovalDraft(bad); err != ErrInvalidEvent {
				t.Fatal("invalid draft accepted")
			}
		}
	}
	var zero ApprovalDraft
	if _, err := EncodeWireApprovalDraft(zero); err != ErrInvalidEvent {
		t.Fatal("encoded zero draft")
	}
	if _, err := zero.Finalize([]byte{1}); err != ErrInvalidEvent {
		t.Fatal("finalized zero draft")
	}
}

func TestApprovalDraftSyntheticCrossLanguageFixture(t *testing.T) {
	data, err := os.ReadFile("../../../../Fixtures/account-group-approval-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Fixtures []struct{ Name, CanonicalPayload, DraftJSON, SubjectSignature, FinalizedDigest string }
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Fixtures) != 2 {
		t.Fatal("expected both exact key representations")
	}
	for _, f := range fixture.Fixtures {
		t.Run(f.Name, func(t *testing.T) {
			w, err := DecodeWireApprovalDraftJSON([]byte(f.DraftJSON))
			if err != nil {
				t.Fatal(err)
			}
			d, err := DecodeWireApprovalDraft(w)
			if err != nil {
				t.Fatal(err)
			}
			p, err := d.Event().CanonicalPayload()
			if err != nil || base64.StdEncoding.EncodeToString(p) != f.CanonicalPayload {
				t.Fatal("fixture payload mismatch", err)
			}
			encoded, err := EncodeWireApprovalDraft(d)
			if err != nil || encoded != w {
				t.Fatal("changed fixture wire", err)
			}
			raw, _ := json.Marshal(encoded)
			if string(raw) != f.DraftJSON {
				t.Fatal("changed fixture JSON")
			}
			sig, err := base64.StdEncoding.DecodeString(f.SubjectSignature)
			if err != nil {
				t.Fatal(err)
			}
			final, err := d.Finalize(sig)
			if err != nil {
				t.Fatal(err)
			}
			digest, err := final.Digest()
			if err != nil || hex.EncodeToString(digest[:]) != f.FinalizedDigest {
				t.Fatal("fixture digest mismatch", err)
			}
		})
	}
}

func TestApprovalDraftStrictRawJSONAndCanonicalPayload(t *testing.T) {
	a, b := fixtureKey(t, true), fixtureKey(t, false)
	e := baseEvent(a, b, ActionApprove)
	signActor(t, &e, a.private)
	d, _ := NewApprovalDraft(e)
	w, _ := EncodeWireApprovalDraft(d)
	data, _ := json.Marshal(w)
	valid := string(data)
	for _, bad := range []string{
		valid + "{}", valid + "x", "null", "[]", "{}", strings.Repeat(" ", 8193),
		strings.Replace(valid, `{`, `{"payload":"",`, 1), strings.Replace(valid, `{`, `{"pay\u006coad":"",`, 1),
		strings.Replace(valid, `{`, `{"extra":"",`, 1), strings.Replace(valid, `{`, `{"subjectSignature":"",`, 1),
		`{"payload":null,"signature":""}`, `{"payload":1,"signature":""}`, `{"payload":[],"signature":""}`,
		`{"payload":""}`, `{"Payload":"","signature":""}`, `{"payload":"\q","signature":""}`,
		`{"payload":"Zh==","signature":""}`, `{"payload":"","signature":"Zg"}`,
		`{"payload":"` + strings.Repeat("A", 4097) + `","signature":""}`,
		`{"payload":"","signature":"` + strings.Repeat("A", 109) + `"}`,
	} {
		if _, err := DecodeWireApprovalDraftJSON([]byte(bad)); err != ErrInvalidEvent {
			t.Fatalf("accepted raw %q", bad[:min(len(bad), 100)])
		}
	}
	p, _ := e.CanonicalPayload()
	source := string(p)
	for _, bad := range []string{
		source + " ", " " + source, source + "{}", strings.Replace(source, `{`, `{"extra":null,`, 1),
		strings.Replace(source, `"sequence":2`, `"sequence":2,"sequence":2`, 1),
		strings.Replace(source, `"sequence":2`, `"sequence":2e0`, 1), strings.Replace(source, `"sequence":2`, `"sequence":2.0`, 1),
		strings.Replace(source, `"sequence":2,`, "", 1), strings.Replace(source, `"sequence":2`, `"sequence":null`, 1),
		strings.Replace(source, `"generation":1,`, `"generation":1.0,`, 1),
		strings.Replace(source, `"accountID":`, `"AccountID":`, 1),
		strings.Replace(source, `"generation":1,"groupID":"`+e.GroupID+`"`, `"groupID":"`+e.GroupID+`","generation":1`, 1),
	} {
		badWire := w
		badWire.Payload = base64.StdEncoding.EncodeToString([]byte(bad))
		// Re-sign malformed bytes so rejection proves canonical/schema checks.
		digest := sha256.Sum256([]byte(bad))
		signature, err := ecdsa.SignASN1(rand.Reader, a.private, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		badWire.Signature = base64.StdEncoding.EncodeToString(signature)
		if _, err := DecodeWireApprovalDraft(badWire); err != ErrInvalidEvent {
			t.Fatalf("accepted payload %q", bad)
		}
	}
	for _, edit := range []func(*WireApprovalDraft){func(v *WireApprovalDraft) { v.Payload += "\n" }, func(v *WireApprovalDraft) { v.Signature += "\n" }, func(v *WireApprovalDraft) { v.Signature = "" }, func(v *WireApprovalDraft) { v.Signature = "Zh==" }} {
		bad := w
		edit(&bad)
		if _, err := DecodeWireApprovalDraft(bad); err != ErrInvalidEvent {
			t.Fatal("accepted wire mutation")
		}
	}
	// Finalized wire always requires a joining proof, even with an empty field.
	if _, err := DecodeWireEvent(WireEvent{w.Payload, w.Signature, ""}); err != ErrInvalidEvent {
		t.Fatal("draft became final")
	}
}

func TestApprovalDraftRejectsStructureAndRepresentationSubstitution(t *testing.T) {
	a, b := fixtureKey(t, true), fixtureKey(t, true)
	e := baseEvent(a, b, ActionApprove)
	signActor(t, &e, a.private)
	for _, edit := range []func(*Event){
		func(v *Event) { v.Sequence = 1 }, func(v *Event) { v.PreviousHash = nil }, func(v *Event) { v.Generation = 0 },
		func(v *Event) { v.ActorDeviceID = v.SubjectDeviceID }, func(v *Event) { v.SubjectDeviceID = v.ActorDeviceID },
		func(v *Event) { v.ActorPublicKey = make([]byte, 64); v.ActorDeviceID = auth.DeviceID(v.ActorPublicKey) },
		func(v *Event) {
			v.SubjectPublicKey = make([]byte, 65)
			v.SubjectDeviceID = auth.DeviceID(v.SubjectPublicKey)
		},
		func(v *Event) {
			v.ActorPublicKey = append([]byte{4}, v.ActorPublicKey...)
			v.ActorDeviceID = auth.DeviceID(v.ActorPublicKey)
		},
		func(v *Event) {
			v.SubjectPublicKey = append([]byte{4}, v.SubjectPublicKey...)
			v.SubjectDeviceID = auth.DeviceID(v.SubjectPublicKey)
		},
		func(v *Event) { v.PreviousHash[0] ^= 1 }, func(v *Event) { v.Signature[3] ^= 1 },
	} {
		bad := cloneEvent(e)
		edit(&bad)
		if _, err := NewApprovalDraft(bad); err != ErrInvalidEvent {
			t.Fatal("accepted structure/representation mutation")
		}
	}
	bootstrap := baseEvent(a, a, ActionBootstrap)
	bootstrap.Sequence = 1
	bootstrap.PreviousHash = nil
	signActor(t, &bootstrap, a.private)
	if _, err := NewApprovalDraft(bootstrap); err != ErrInvalidEvent {
		t.Fatal("bootstrap draft")
	}
	h, _ := bootstrap.Digest()
	state, err := NewState(bootstrap, bootstrap.AccountID, bootstrap.GroupID, bootstrap.Generation, h)
	if err != nil {
		t.Fatal(err)
	}
	e.PreviousHash = h[:]
	signActor(t, &e, a.private)
	d, err := NewApprovalDraft(e)
	if err != nil {
		t.Fatal(err)
	}
	before := state.Snapshot()
	if err := state.Apply(d.Event()); err == nil {
		t.Fatal("draft advanced history")
	}
	after := state.Snapshot()
	if after.Sequence != before.Sequence || after.HeadHash != before.HeadHash {
		t.Fatal("draft changed state")
	}
}

func TestApprovalDraftOwnsEveryBuffer(t *testing.T) {
	a, b := fixtureKey(t, true), fixtureKey(t, false)
	e := baseEvent(a, b, ActionApprove)
	signBoth(t, &e, a.private, b.private)
	sig := e.SubjectSignature
	e.SubjectSignature = nil
	d, err := NewApprovalDraft(e)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := EncodeWireApprovalDraft(d)
	corrupt := func(v Event) {
		for _, p := range [][]byte{v.ActorPublicKey, v.SubjectPublicKey, v.PreviousHash, v.Signature, v.SubjectSignature} {
			if len(p) > 0 {
				p[0] ^= 1
			}
		}
	}
	corrupt(e)
	corrupt(d.Event())
	final, err := d.Finalize(sig)
	if err != nil {
		t.Fatal(err)
	}
	corrupt(final)
	sig[0] ^= 1
	got, err := EncodeWireApprovalDraft(d)
	if err != nil || got != want {
		t.Fatal("draft aliases caller/accessor/final buffers", err)
	}
}
