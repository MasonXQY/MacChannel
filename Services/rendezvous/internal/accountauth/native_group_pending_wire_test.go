package accountauth

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
	"time"

	"macchannel/rendezvous/internal/accountgroup"
)

// Immutable public synthetic proofs, shared byte-for-byte with Swift. No server,
// session, database, device key, or consent authority is involved in this test.
func TestNativePendingWire(t *testing.T) {
	raw, err := os.ReadFile("../../../../Fixtures/account-group-pending-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Fixtures []struct {
			Name, CanonicalPayload, DraftDigest, FinalizedDigest, ListJSON string
			Records                                                        []struct{ Status, JSON string }
		}
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Fixtures) != 2 {
		t.Fatal("fixture count")
	}
	for _, f := range fixture.Fixtures {
		t.Run(f.Name, func(t *testing.T) {
			if len(f.Records) != 8 {
				t.Fatal("record count")
			}
			for _, r := range f.Records {
				var wrapper struct {
					Request pendingRecordWire `json:"request"`
				}
				if err := json.Unmarshal([]byte(r.JSON), &wrapper); err != nil {
					t.Fatal(err)
				}
				w := wrapper.Request
				key, err := base64.StdEncoding.DecodeString(w.PublicKey)
				if err != nil {
					t.Fatal(err)
				}
				p := accountgroup.PendingJoin{RequestID: w.RequestID, AccountID: w.AccountID, GroupID: w.GroupID,
					Generation: w.Generation, DeviceID: w.DeviceID, PublicKey: key, Status: w.Status,
					CreatedAt: time.UnixMilli(w.CreatedAt), ExpiresAt: time.UnixMilli(w.ExpiresAt), Draft: w.Draft, Event: w.Event}
				if w.EventHash != nil {
					p.EventHash, err = base64.StdEncoding.DecodeString(*w.EventHash)
					if err != nil {
						t.Fatal(err)
					}
				}
				if p.Status != r.Status {
					t.Fatal("status mismatch")
				}
				if p.Draft != nil {
					d, err := accountgroup.DecodeWireApprovalDraft(*p.Draft)
					if err != nil {
						t.Fatal("draft invalid")
					}
					event := d.Event()
					payload, err := event.CanonicalPayload()
					if err != nil || base64.StdEncoding.EncodeToString(payload) != f.CanonicalPayload {
						t.Fatal("canonical payload mismatch")
					}
					hash := sha256.Sum256(payload)
					if hex.EncodeToString(hash[:]) != f.DraftDigest {
						t.Fatal("draft digest mismatch")
					}
				}
				if p.Event != nil {
					event, err := accountgroup.DecodeWireEvent(*p.Event)
					if err != nil {
						t.Fatal("final event invalid")
					}
					digest, err := event.Digest()
					if err != nil || hex.EncodeToString(digest[:]) != f.FinalizedDigest {
						t.Fatal("final digest mismatch")
					}
				}
				// This is the production HTTP response serializer, not a parallel
				// test model or independently regenerated signature.
				actual, err := pendingWire(p, p.AccountID)
				if err != nil {
					t.Fatal("production serializer rejected fixture")
				}
				encoded, err := json.Marshal(struct {
					Request pendingRecordWire `json:"request"`
				}{actual})
				if err != nil || !bytes.Equal(encoded, []byte(r.JSON)) {
					t.Fatal("literal full response bytes differ")
				}
				t.Logf("%s full response bytes=%d sha256=%x", r.Status, len(encoded), sha256.Sum256(encoded))
			}
			var list struct {
				Requests []pendingSummary `json:"requests"`
			}
			if err := json.Unmarshal([]byte(f.ListJSON), &list); err != nil {
				t.Fatal(err)
			}
			if len(list.Requests) != 3 {
				t.Fatal("list count")
			}
			var actual []pendingSummary
			for i, s := range list.Requests {
				// Reuse corresponding full proof state so list metadata is also
				// validated by the real serializer before proofs are omitted.
				var full struct {
					Request pendingRecordWire `json:"request"`
				}
				if err := json.Unmarshal([]byte(f.Records[i].JSON), &full); err != nil {
					t.Fatal(err)
				}
				key, _ := base64.StdEncoding.DecodeString(s.PublicKey)
				p := accountgroup.PendingJoin{RequestID: s.RequestID, AccountID: s.AccountID, GroupID: s.GroupID,
					Generation: s.Generation, DeviceID: s.DeviceID, PublicKey: key, Status: s.Status,
					CreatedAt: time.UnixMilli(s.CreatedAt), ExpiresAt: time.UnixMilli(s.ExpiresAt), Draft: full.Request.Draft, Event: full.Request.Event}
				w, err := pendingWire(p, p.AccountID)
				if err != nil {
					t.Fatal("production summary rejected fixture")
				}
				actual = append(actual, w.pendingSummary)
			}
			encoded, err := json.Marshal(struct {
				Requests []pendingSummary `json:"requests"`
			}{actual})
			if err != nil || !bytes.Equal(encoded, []byte(f.ListJSON)) {
				t.Fatal("literal summary response bytes differ")
			}
			t.Logf("list bytes=%d sha256=%x signed digest=%s", len(encoded), sha256.Sum256(encoded), f.FinalizedDigest)
		})
	}
}
