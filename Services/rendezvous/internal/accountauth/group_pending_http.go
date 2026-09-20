package accountauth

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"time"
	"unicode/utf8"

	"macchannel/rendezvous/internal/accountgroup"
)

type AccountGroupPending interface {
	CreateJoin(context.Context, accountgroup.SessionActor, accountgroup.JoinIntent) (accountgroup.PendingJoin, error)
	GetJoin(context.Context, accountgroup.SessionActor, string) (accountgroup.PendingJoin, error)
	ListJoins(context.Context, accountgroup.SessionActor) ([]accountgroup.PendingJoin, error)
	ProposeJoin(context.Context, accountgroup.SessionActor, string, accountgroup.ApprovalDraft) (accountgroup.PendingJoin, error)
	CountersignJoin(context.Context, accountgroup.SessionActor, string, []byte, []byte) (accountgroup.PendingJoin, error)
	CommitJoin(context.Context, accountgroup.SessionActor, string, []byte) (accountgroup.PendingJoin, error)
	CancelJoin(context.Context, accountgroup.SessionActor, string) (accountgroup.PendingJoin, error)
	RejectJoin(context.Context, accountgroup.SessionActor, string) (accountgroup.PendingJoin, error)
}

func pendingOperation(path string) (string, bool) {
	switch path {
	case "/v1/account/group/join/create":
		return "create", true
	case "/v1/account/group/join/get":
		return "get", true
	case "/v1/account/group/join/list":
		return "list", true
	case "/v1/account/group/join/propose":
		return "propose", true
	case "/v1/account/group/join/countersign":
		return "countersign", true
	case "/v1/account/group/join/commit":
		return "commit", true
	case "/v1/account/group/join/cancel":
		return "cancel", true
	case "/v1/account/group/join/reject":
		return "reject", true
	}
	return "", false
}

type pendingInput struct {
	audience, token, id string
	intent              accountgroup.JoinIntent
	draft               accountgroup.ApprovalDraft
	hash, signature     []byte
}

func pendingBase64(s string, maximum int) ([]byte, error) {
	if len(s) == 0 || len(s) > base64.StdEncoding.EncodedLen(maximum) {
		return nil, errPayloadMalformed
	}
	b, err := base64.StdEncoding.Strict().DecodeString(s)
	if err != nil || len(b) > maximum || base64.StdEncoding.EncodeToString(b) != s {
		return nil, errPayloadMalformed
	}
	return b, nil
}

func decodePending(data []byte, op string, key []byte) (pendingInput, error) {
	var f pendingInput
	if len(data) == 0 || len(data) > accountMaximumPayload {
		return f, errPayloadMalformed
	}
	o, err := strictObject(data)
	if err != nil {
		return f, errPayloadMalformed
	}
	keys := []string{"purpose", "audience", "accessToken"}
	if op != "list" {
		keys = append(keys, "requestID")
	}
	switch op {
	case "create":
		keys = append(keys, "groupID", "generation", "publicKey")
	case "propose":
		keys = append(keys, "draft")
	case "countersign":
		keys = append(keys, "draftHash", "subjectSignature")
	case "commit":
		keys = append(keys, "draftHash")
	}
	if !exactKeys(o, keys...) {
		return f, errPayloadMalformed
	}
	fields := make(map[string]string, len(o))
	for k, v := range o {
		s, ok := v.(string)
		if !ok || s == "" || !utf8.ValidString(s) {
			return f, errPayloadMalformed
		}
		fields[k] = s
	}
	if fields["purpose"] != "dropmesh.account.group.join."+op+".v1" {
		return f, errPayloadAuth
	}
	f.audience, f.token, f.id = fields["audience"], fields["accessToken"], fields["requestID"]
	if !validCredential(f.audience, 255) || !validToken(f.token) {
		return f, errPayloadAuth
	}
	if op != "list" && !validUUID(f.id) {
		return f, errPayloadMalformed
	}
	switch op {
	case "create":
		generation, e := strconv.ParseUint(fields["generation"], 10, 64)
		public, e2 := pendingBase64(fields["publicKey"], 65)
		if e != nil || generation == 0 || generation > math.MaxInt64 || strconv.FormatUint(generation, 10) != fields["generation"] || !validUUID(fields["groupID"]) || e2 != nil || !bytes.Equal(public, key) {
			return f, errPayloadMalformed
		}
		f.intent = accountgroup.JoinIntent{RequestID: f.id, GroupID: fields["groupID"], Generation: generation, PublicKey: public}
	case "propose":
		raw, e := pendingBase64(fields["draft"], 4096)
		if e != nil {
			return f, e
		}
		wire, e := accountgroup.DecodeWireApprovalDraftJSON(raw)
		if e != nil {
			return f, errPayloadMalformed
		}
		f.draft, e = accountgroup.DecodeWireApprovalDraft(wire)
		if e != nil || !bytes.Equal(f.draft.Event().ActorPublicKey, key) {
			return f, errPayloadMalformed
		}
	case "countersign", "commit":
		f.hash, err = pendingBase64(fields["draftHash"], 32)
		if err != nil || len(f.hash) != 32 {
			return f, errPayloadMalformed
		}
		if op == "countersign" {
			f.signature, err = pendingBase64(fields["subjectSignature"], 80)
			public := key
			if len(public) == 64 {
				public = append([]byte{4}, public...)
			}
			x, y := elliptic.Unmarshal(elliptic.P256(), public)
			// The envelope key is the subject key. Verify the DER proof against the
			// claimed canonical draft digest before allowing malformed proofs to mutate.
			if err != nil || x == nil || !ecdsa.VerifyASN1(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, f.hash, f.signature) {
				return f, errPayloadMalformed
			}
		}
	}
	return f, nil
}

func (h *accountHTTP) servePending(w http.ResponseWriter, r *http.Request, device string, key []byte, op string, payload []byte) {
	f, err := decodePending(payload, op, key)
	if err != nil {
		if errors.Is(err, errPayloadAuth) {
			writeAccountError(w, 401, "authentication_failed")
		} else {
			writeAccountError(w, 400, "invalid_request")
		}
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	unavailable := func() { writeAccountError(w, 503, "service_unavailable") }
	if ctx.Err() != nil {
		unavailable()
		return
	}
	session, err := h.sessions.Authenticate(ctx, f.token, device, f.audience)
	if ctx.Err() != nil {
		unavailable()
		return
	}
	if err != nil {
		h.writeDependencyError(w, err)
		return
	}
	if !validSession(session, device, f.audience) {
		unavailable()
		return
	}
	actor := accountgroup.SessionActor{AccountID: session.AccountID, SessionID: session.SessionID, DeviceID: session.DeviceID, Audience: session.Audience}
	if op == "propose" {
		e := f.draft.Event()
		if e.AccountID != actor.AccountID || e.ActorDeviceID != actor.DeviceID {
			writeAccountError(w, 400, "invalid_request")
			return
		}
	}
	var records []accountgroup.PendingJoin
	var record accountgroup.PendingJoin
	if ctx.Err() != nil {
		unavailable()
		return
	}
	switch op {
	case "create":
		record, err = h.pending.CreateJoin(ctx, actor, f.intent)
	case "get":
		record, err = h.pending.GetJoin(ctx, actor, f.id)
	case "list":
		records, err = h.pending.ListJoins(ctx, actor)
	case "propose":
		record, err = h.pending.ProposeJoin(ctx, actor, f.id, f.draft)
	case "countersign":
		record, err = h.pending.CountersignJoin(ctx, actor, f.id, f.hash, f.signature)
	case "commit":
		record, err = h.pending.CommitJoin(ctx, actor, f.id, f.hash)
	case "cancel":
		record, err = h.pending.CancelJoin(ctx, actor, f.id)
	case "reject":
		record, err = h.pending.RejectJoin(ctx, actor, f.id)
	}
	if ctx.Err() != nil {
		unavailable()
		return
	}
	if err != nil {
		switch {
		case errors.Is(err, accountgroup.ErrGroupSessionInvalid):
			writeAccountError(w, 401, "authentication_failed")
		case errors.Is(err, accountgroup.ErrGroupInvalid):
			writeAccountError(w, 409, "group_conflict")
		default:
			unavailable()
		}
		return
	}
	var response any
	if op == "list" {
		if len(records) > 32 {
			unavailable()
			return
		}
		summaries := make([]pendingSummary, 0, len(records))
		seen := map[string]bool{}
		for _, p := range records {
			wire, e := pendingWire(p, actor.AccountID)
			if e != nil || seen[p.RequestID] || !pendingActive(p.Status) {
				unavailable()
				return
			}
			seen[p.RequestID] = true
			summaries = append(summaries, wire.pendingSummary)
		}
		response = struct {
			Requests []pendingSummary `json:"requests"`
		}{summaries}
	} else {
		wire, e := pendingWire(record, actor.AccountID)
		if e != nil || record.RequestID != f.id || !pendingResultMatches(record, f, op, actor, key) {
			unavailable()
			return
		}
		response = struct {
			Request pendingRecordWire `json:"request"`
		}{wire}
	}
	body, err := json.Marshal(response)
	if err != nil || len(body) > groupMaximumResponse || ctx.Err() != nil {
		unavailable()
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	_, _ = w.Write(body)
}
