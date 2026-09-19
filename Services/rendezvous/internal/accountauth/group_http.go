package accountauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"
	"unicode/utf8"

	"macchannel/rendezvous/internal/accountgroup"
)

type AccountGroups interface {
	Events(context.Context, accountgroup.Actor, string) ([]accountgroup.Event, error)
}

const groupMaximumEvents = 8192
const groupPageSize = 16
const groupMaximumResponse = 64 * 1024

type groupRequest struct {
	audience, token, groupID, expectedHead string
	after                                  uint64
}

func decodeGroupPayload(data []byte) (groupRequest, error) {
	if len(data) == 0 || len(data) > accountMaximumPayload {
		return groupRequest{}, errPayloadMalformed
	}
	o, err := strictObject(data)
	if err != nil {
		return groupRequest{}, errPayloadMalformed
	}
	purpose, ok := o["purpose"].(string)
	if !ok || purpose == "" {
		return groupRequest{}, errPayloadMalformed
	}
	if purpose != "dropmesh.account.group.events.v1" {
		return groupRequest{}, errPayloadAuth
	}
	if !exactKeys(o, "purpose", "audience", "accessToken", "groupID", "afterSequence", "expectedHeadHash") {
		return groupRequest{}, errPayloadMalformed
	}
	f := make(map[string]string, len(o))
	for k, v := range o {
		s, ok := v.(string)
		if !ok || !utf8.ValidString(s) || (s == "" && k != "expectedHeadHash") {
			return groupRequest{}, errPayloadMalformed
		}
		f[k] = s
	}
	if !validCredential(f["audience"], 255) || !validToken(f["accessToken"]) {
		return groupRequest{}, errPayloadAuth
	}
	if !validUUID(f["groupID"]) {
		return groupRequest{}, errPayloadMalformed
	}
	after, err := strconv.ParseUint(f["afterSequence"], 10, 64)
	if err != nil || after > groupMaximumEvents || strconv.FormatUint(after, 10) != f["afterSequence"] {
		return groupRequest{}, errPayloadMalformed
	}
	head := f["expectedHeadHash"]
	if after == 0 {
		if head != "" {
			return groupRequest{}, errPayloadMalformed
		}
	} else {
		if len(head) != 44 {
			return groupRequest{}, errPayloadMalformed
		}
		decoded, err := base64.StdEncoding.Strict().DecodeString(head)
		if err != nil || len(decoded) != 32 || base64.StdEncoding.EncodeToString(decoded) != head {
			return groupRequest{}, errPayloadMalformed
		}
	}
	return groupRequest{f["audience"], f["accessToken"], f["groupID"], head, after}, nil
}

type groupResponse struct {
	GroupID       string                   `json:"groupID"`
	Generation    uint64                   `json:"generation"`
	HeadSequence  uint64                   `json:"headSequence"`
	HeadHash      string                   `json:"headHash"`
	AfterSequence uint64                   `json:"afterSequence"`
	NextSequence  uint64                   `json:"nextSequence"`
	HasMore       bool                     `json:"hasMore"`
	Events        []accountgroup.WireEvent `json:"events"`
}

func (h *accountHTTP) serveGroupEvents(w http.ResponseWriter, r *http.Request, device string, payload []byte) {
	f, err := decodeGroupPayload(payload)
	if err != nil {
		if errors.Is(err, errPayloadMalformed) {
			writeAccountError(w, http.StatusBadRequest, "invalid_request")
		} else {
			writeAccountError(w, http.StatusUnauthorized, "authentication_failed")
		}
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	unavailable := func() { writeAccountError(w, http.StatusServiceUnavailable, "service_unavailable") }
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
	events, err := h.groups.Events(ctx, accountgroup.Actor{AccountID: session.AccountID, DeviceID: session.DeviceID}, f.groupID)
	if ctx.Err() != nil {
		unavailable()
		return
	}
	if err != nil {
		if errors.Is(err, accountgroup.ErrGroupInvalid) {
			writeAccountError(w, http.StatusNotFound, "group_unavailable")
		} else {
			unavailable()
		}
		return
	}
	if len(events) == 0 || len(events) > groupMaximumEvents {
		unavailable()
		return
	}
	anchor := events[0]
	anchorHash, err := anchor.Digest()
	if err != nil {
		unavailable()
		return
	}
	// Self-pinning is only a server-side dependency-output consistency check.
	// Clients must supply their independently confirmed pin before trusting this
	// history; this read endpoint never grants membership or transfer authority.
	state, err := accountgroup.NewState(anchor, session.AccountID, f.groupID, anchor.Generation, anchorHash)
	if err != nil {
		unavailable()
		return
	}
	for _, event := range events[1:] {
		if ctx.Err() != nil || event.AccountID != session.AccountID || event.GroupID != f.groupID {
			unavailable()
			return
		}
		if state.Apply(event) != nil {
			unavailable()
			return
		}
	}
	if ctx.Err() != nil {
		unavailable()
		return
	}
	snapshot := state.Snapshot()
	head := base64.StdEncoding.EncodeToString(snapshot.HeadHash[:])
	if f.after > snapshot.Sequence || (f.after > 0 && f.expectedHead != head) {
		writeAccountError(w, http.StatusConflict, "group_changed")
		return
	}
	response := groupResponse{GroupID: f.groupID, Generation: snapshot.Generation, HeadSequence: snapshot.Sequence, HeadHash: head, AfterSequence: f.after, NextSequence: f.after, Events: make([]accountgroup.WireEvent, 0, groupPageSize)}
	for _, event := range events {
		if event.Sequence <= f.after {
			continue
		}
		if ctx.Err() != nil {
			unavailable()
			return
		}
		wire, err := accountgroup.EncodeWireEvent(event)
		if err != nil {
			unavailable()
			return
		}
		response.Events = append(response.Events, wire)
		response.NextSequence = event.Sequence
		if len(response.Events) == groupPageSize {
			break
		}
	}
	response.HasMore = response.NextSequence < response.HeadSequence
	body, err := json.Marshal(response)
	if err != nil || len(body) > groupMaximumResponse || ctx.Err() != nil {
		unavailable()
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}
