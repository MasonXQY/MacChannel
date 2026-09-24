package accountauth

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"
	"unicode/utf8"

	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/accountinvite"
)

func invitationOperation(path string) (string, bool) {
	switch path {
	case "/v1/account/invitation/link/get":
		return "link/get", true
	case "/v1/account/invitation/link/rotate":
		return "link/rotate", true
	case "/v1/account/invitation/request":
		return "request", true
	case "/v1/account/invitation/get":
		return "get", true
	case "/v1/account/invitation/inbox":
		return "inbox", true
	case "/v1/account/invitation/outbox":
		return "outbox", true
	case "/v1/account/invitation/select":
		return "select", true
	case "/v1/account/invitation/countersign":
		return "countersign", true
	case "/v1/account/invitation/commit":
		return "commit", true
	case "/v1/account/invitation/reject":
		return "reject", true
	case "/v1/account/invitation/cancel":
		return "cancel", true
	case "/v1/account/invitation/revoke":
		return "revoke", true
	case "/v1/account/invitation/block":
		return "block", true
	}
	return "", false
}

type invitationInput struct {
	audience, token, id, cursor, blockedAccount, digest string
	revision                                            int64
	limit                                               int
	disconnect                                          bool
	link, signature                                     []byte
	request                                             accountinvite.RequestProof
	target                                              accountinvite.Endpoint
}

func decodeInvitation(data []byte, op string, key []byte) (invitationInput, error) {
	var f invitationInput
	o, err := strictObject(data)
	if err != nil || len(data) > accountMaximumPayload {
		return f, errPayloadMalformed
	}
	keys := []string{"purpose", "audience", "accessToken"}
	switch op {
	case "link/get":
	case "link/rotate":
		keys = append(keys, "linkToken")
	case "request":
		keys = append(keys, "requestPayload", "requestSignature")
	case "inbox", "outbox":
		keys = append(keys, "afterRequestID", "limit")
	case "block":
		keys = append(keys, "targetAccountID", "disconnectExisting")
	case "select":
		keys = append(keys, "requestID", "targetDeviceID", "targetGroupID", "targetGeneration", "targetPublicKey", "targetAudience")
	case "countersign":
		keys = append(keys, "requestID", "signature")
	case "get":
		keys = append(keys, "requestID")
	case "commit":
		keys = append(keys, "requestID", "proofDigest")
	case "reject", "cancel", "revoke":
		keys = append(keys, "requestID", "expectedRevision", "proofDigest")
	default:
		return f, errPayloadMalformed
	}
	if !exactKeys(o, keys...) {
		return f, errPayloadMalformed
	}
	values := map[string]string{}
	for k, v := range o {
		s, ok := v.(string)
		if !ok || !utf8.ValidString(s) || (s == "" && k != "afterRequestID" && k != "proofDigest") {
			return f, errPayloadMalformed
		}
		values[k] = s
	}
	purpose, _ := accountPurpose("/v1/account/invitation/" + op)
	f.audience, f.token, f.id = values["audience"], values["accessToken"], values["requestID"]
	if values["purpose"] != purpose || !validCredential(f.audience, 255) || !validToken(f.token) {
		return f, errPayloadAuth
	}
	if f.id != "" && !validUUID(f.id) {
		return f, errPayloadMalformed
	}
	switch op {
	case "commit", "reject", "cancel", "revoke":
		f.digest = values["proofDigest"]
		if f.digest != "" {
			digest, e := pendingBase64(f.digest, 32)
			if e != nil || len(digest) != 32 {
				return f, errPayloadMalformed
			}
		}
		if (op == "commit" || op == "revoke") && f.digest == "" {
			return f, errPayloadMalformed
		}
		if op != "commit" {
			f.revision, err = strconv.ParseInt(values["expectedRevision"], 10, 64)
			if err != nil || f.revision <= 0 || strconv.FormatInt(f.revision, 10) != values["expectedRevision"] {
				return f, errPayloadMalformed
			}
		}
	case "link/rotate":
		token := values["linkToken"]
		f.link, err = base64.RawURLEncoding.Strict().DecodeString(token)
		if err != nil || len(f.link) != 32 || base64.RawURLEncoding.EncodeToString(f.link) != token {
			return f, errPayloadMalformed
		}
	case "request":
		f.request, err = accountinvite.DecodeRequest(accountinvite.WireRequest{Payload: values["requestPayload"], Signature: values["requestSignature"]})
		if err != nil || !bytes.Equal(f.request.Pair.Sender.PublicKey, key) || f.request.Pair.Audience != f.audience {
			return f, errPayloadMalformed
		}
	case "inbox", "outbox":
		f.cursor = values["afterRequestID"]
		f.limit, err = strconv.Atoi(values["limit"])
		if err != nil || f.limit < 1 || f.limit > 50 || strconv.Itoa(f.limit) != values["limit"] || (f.cursor != "" && !validUUID(f.cursor)) {
			return f, errPayloadMalformed
		}
	case "select":
		generation, e := strconv.ParseInt(values["targetGeneration"], 10, 64)
		public, e2 := pendingBase64(values["targetPublicKey"], 65)
		if e != nil || generation <= 0 || strconv.FormatInt(generation, 10) != values["targetGeneration"] || e2 != nil || (len(public) != 64 && len(public) != 65) || !validUUID(values["targetGroupID"]) || !validUUID(values["targetDeviceID"]) || !validCredential(values["targetAudience"], 255) {
			return f, errPayloadMalformed
		}
		f.target = accountinvite.Endpoint{GroupID: values["targetGroupID"], DeviceID: values["targetDeviceID"], Generation: generation, PublicKey: public, Audience: values["targetAudience"]}
	case "countersign":
		f.signature, err = pendingBase64(values["signature"], 80)
		if err != nil || len(f.signature) < 8 {
			return f, errPayloadMalformed
		}
	case "block":
		f.blockedAccount = values["targetAccountID"]
		if !validUUID(f.blockedAccount) || (values["disconnectExisting"] != "true" && values["disconnectExisting"] != "false") {
			return f, errPayloadMalformed
		}
		f.disconnect = values["disconnectExisting"] == "true"
	}
	return f, nil
}

func (h *accountHTTP) serveInvitation(w http.ResponseWriter, r *http.Request, device string, key []byte, op string, payload []byte) {
	f, err := decodeInvitation(payload, op, key)
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
	session, err := h.sessions.Authenticate(ctx, f.token, device, f.audience)
	if ctx.Err() != nil {
		writeAccountError(w, 503, "service_unavailable")
		return
	}
	if err != nil {
		h.writeDependencyError(w, err)
		return
	}
	if !validSession(session, device, f.audience) {
		writeAccountError(w, 503, "service_unavailable")
		return
	}
	actor := accountinvite.Actor{SessionActor: accountgroup.SessionActor{AccountID: session.AccountID, SessionID: session.SessionID, DeviceID: session.DeviceID, Audience: session.Audience}, PublicKey: append([]byte(nil), key...)}
	if op == "request" && (f.request.Pair.Sender.AccountID != actor.AccountID || f.request.Pair.Sender.DeviceID != actor.DeviceID) {
		writeAccountError(w, 400, "invalid_request")
		return
	}
	if !h.acquireCompletion(device) {
		writeAccountError(w, 429, "rate_limited")
		return
	}
	defer h.releaseCompletion(device)
	var response any
	switch op {
	case "link/get":
		response, err = h.invitations.GetLink(ctx, actor)
	case "link/rotate":
		response, err = h.invitations.RotateLink(ctx, actor, f.link)
	case "request":
		response, err = h.invitations.Request(ctx, actor, f.request)
	case "get":
		response, err = h.invitations.Get(ctx, actor, f.id)
	case "inbox", "outbox":
		var records []accountinvite.Record
		records, err = h.invitations.List(ctx, actor, op == "inbox", f.cursor, f.limit)
		if len(records) > f.limit {
			writeAccountError(w, 503, "service_unavailable")
			return
		}
		if records == nil {
			records = []accountinvite.Record{}
		}
		response = struct {
			Records []accountinvite.Record `json:"records"`
		}{records}
	case "select":
		f.target.AccountID = actor.AccountID
		response, err = h.invitations.Select(ctx, actor, f.id, f.target)
	case "countersign":
		response, err = h.invitations.Countersign(ctx, actor, f.id, f.signature)
	case "commit":
		response, err = h.invitations.Commit(ctx, actor, f.id, f.digest)
	case "reject", "cancel", "revoke":
		response, err = h.invitations.Transition(ctx, actor, f.id, op, f.revision, f.digest)
	case "block":
		err = h.invitations.Block(ctx, actor, f.blockedAccount, f.disconnect)
		response = struct {
			Blocked bool `json:"blocked"`
		}{true}
	}
	if ctx.Err() != nil {
		writeAccountError(w, 503, "service_unavailable")
		return
	}
	if err != nil {
		switch {
		case errors.Is(err, accountgroup.ErrGroupSessionInvalid):
			writeAccountError(w, 401, "authentication_failed")
		case errors.Is(err, accountinvite.ErrInvalid):
			writeAccountError(w, 409, "invitation_unavailable")
		default:
			writeAccountError(w, 503, "service_unavailable")
		}
		return
	}
	// Fixed wire models contain no tokens, private keys, or directory records.
	encoded, err := json.Marshal(response)
	if err != nil || len(encoded) > 1024*1024 {
		writeAccountError(w, 503, "service_unavailable")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	_, _ = w.Write(append(encoded, '\n'))
}
