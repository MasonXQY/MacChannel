package accountauth

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"macchannel/rendezvous/internal/accountgroup"
	"math"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPendingInvalidDependencyOutput(t *testing.T) {
	cases := []struct {
		name   string
		change func(*accountgroup.PendingJoin)
	}{
		{"request binding", func(p *accountgroup.PendingJoin) { p.RequestID = testGroup }},
		{"account binding", func(p *accountgroup.PendingJoin) { p.AccountID = testGroup }},
		{"group uuid", func(p *accountgroup.PendingJoin) { p.GroupID = strings.ToUpper(testGroup) }},
		{"generation zero", func(p *accountgroup.PendingJoin) { p.Generation = 0 }},
		{"generation overflow", func(p *accountgroup.PendingJoin) { p.Generation = math.MaxUint64 }},
		{"device binding", func(p *accountgroup.PendingJoin) { p.DeviceID = testGroup }},
		{"key", func(p *accountgroup.PendingJoin) { p.PublicKey = bytes.Repeat([]byte{0}, 65) }},
		{"time zero", func(p *accountgroup.PendingJoin) { p.CreatedAt = time.UnixMilli(0) }},
		{"time overflow", func(p *accountgroup.PendingJoin) { p.CreatedAt = time.Unix(1<<62, 0) }},
		{"time safe integer", func(p *accountgroup.PendingJoin) { p.ExpiresAt = time.UnixMilli(9007199254740992) }},
		{"ttl", func(p *accountgroup.PendingJoin) { p.ExpiresAt = p.ExpiresAt.Add(time.Millisecond) }},
		{"status", func(p *accountgroup.PendingJoin) { p.Status = "member" }},
		{"requested proof", func(p *accountgroup.PendingJoin) { p.Status = "requested" }},
		{"missing draft", func(p *accountgroup.PendingJoin) { p.Draft = nil }},
		{"missing event", func(p *accountgroup.PendingJoin) { p.Event = nil }},
		{"corrupt draft", func(p *accountgroup.PendingJoin) { p.Draft.Payload = "AA==" }},
		{"corrupt event", func(p *accountgroup.PendingJoin) { p.Event.SubjectSignature = "AA==" }},
		{"hash mismatch", func(p *accountgroup.PendingJoin) { p.EventHash = bytes.Repeat([]byte{1}, 32) }},
		{"terminal hash", func(p *accountgroup.PendingJoin) { p.Status = "expired" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h, _, f, a, id := pendingFixture(t)
			e := pendingApproval(t, f, a, id)
			digest, _ := e.Digest()
			f.record.Status = "committed"
			f.record.EventHash = digest[:]
			tc.change(&f.record)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/group/join/get", pendingFields("get"), 1))
			if w.Code != 503 || w.Body.String() != "{\"error\":\"service_unavailable\"}\n" {
				t.Fatal("invalid output escaped", w.Code)
			}
		})
	}
}

func TestPendingListsBoundedAndUnique(t *testing.T) {
	for _, kind := range []string{"empty", "32", "33", "duplicate", "terminal", "corrupt proof"} {
		t.Run(kind, func(t *testing.T) {
			h, _, f, a, id := pendingFixture(t)
			n := 32
			want := 200
			if kind == "empty" {
				n = 0
			}
			if kind == "33" {
				n = 33
				want = 503
			}
			if kind == "duplicate" || kind == "terminal" || kind == "corrupt proof" {
				want = 503
			}
			for i := 0; i < n; i++ {
				p := f.record
				p.RequestID = fmt.Sprintf("%08x-1234-4567-8901-abcdefabcdef", i)
				f.records = append(f.records, p)
			}
			switch kind {
			case "duplicate":
				f.records[1] = f.records[0]
			case "terminal":
				f.records[0].Status = "expired"
			case "corrupt proof":
				pendingApproval(t, f, a, id)
				f.records[0] = f.record
				f.records[0].Draft.Payload = "AA=="
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, id.request(t, "/v1/account/group/join/list", pendingFields("list"), 1))
			if w.Code != want || w.Body.Len() > 64*1024 {
				t.Fatal(w.Code, w.Body.Len())
			}
			if want == 200 && strings.Contains(w.Body.String(), "draft") {
				t.Fatal("summary has proof")
			}
		})
	}
}
func TestPendingWireProofAndMilliseconds(t *testing.T) {
	_, _, f, a, id := pendingFixture(t)
	e := pendingApproval(t, f, a, id)
	hash, _ := e.Digest()
	f.record.EventHash = hash[:]
	f.record.Status = "committed"
	f.record.CreatedAt = f.record.CreatedAt.Add(123456 * time.Microsecond)
	f.record.ExpiresAt = f.record.CreatedAt.Add(5 * time.Minute)
	wire, err := pendingWire(f.record, f.record.AccountID)
	if err != nil || wire.ExpiresAt-wire.CreatedAt != 300000 || wire.CreatedAt != f.record.CreatedAt.UnixMilli() {
		t.Fatal("millisecond normalization")
	}
	raw, _ := json.Marshal(wire)
	var fields map[string]any
	json.Unmarshal(raw, &fields)
	if len(fields) != 12 {
		t.Fatal("wire field count", len(fields))
	}
	for _, status := range []string{"cancelled", "rejected", "expired", "invalidated"} {
		p := f.record
		p.Status = status
		p.EventHash = nil
		if _, err := pendingWire(p, p.AccountID); err != nil {
			t.Fatal("terminal retained proof rejected", status)
		}
	}
	// A valid second actor signature over the same payload still must equal the
	// draft's immutable signature inside a record.
	signGroup(t, &e, a, id)
	other, _ := accountgroup.EncodeWireEvent(e)
	f.record.Event = &other
	if _, err := pendingWire(f.record, f.record.AccountID); err == nil {
		t.Fatal("mismatched actor signatures accepted")
	}
}

func TestPendingMutationResultBindings(t *testing.T) {
	for _, op := range []string{"create", "propose", "countersign", "commit", "cancel", "reject"} {
		t.Run(op, func(t *testing.T) {
			h, _, f, a, id := pendingFixture(t)
			fields := pendingFields(op)
			signer := id
			switch op {
			case "create":
				fields["groupID"] = testGroup
				fields["generation"] = "2"
				fields["publicKey"] = base64.StdEncoding.EncodeToString(id.public)
			case "propose", "countersign", "commit":
				e := pendingApproval(t, f, a, id)
				hash, _ := e.Digest()
				if op == "propose" {
					raw, _ := json.Marshal(f.record.Draft)
					fields["draft"] = base64.StdEncoding.EncodeToString(raw)
					signer = a
					f.record.Draft = nil
					f.record.Event = nil
					f.record.Status = "requested"
				} else {
					fields["draftHash"] = base64.StdEncoding.EncodeToString(hash[:])
					if op == "countersign" {
						fields["subjectSignature"] = base64.StdEncoding.EncodeToString(e.SubjectSignature)
						f.record.Event = nil
						f.record.Status = "proposed"
					} else {
						signer = a
					}
				}
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, signer.request(t, "/v1/account/group/join/"+op, fields, 1))
			if w.Code != 503 {
				t.Fatal("impossible mutation output accepted", w.Code)
			}
		})
	}
}
