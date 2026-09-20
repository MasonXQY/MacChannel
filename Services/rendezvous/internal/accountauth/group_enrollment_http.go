package accountauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"time"
	"unicode/utf8"

	"macchannel/rendezvous/internal/accountgroup"
)

type AccountGroupEnrollment interface {
	Discover(context.Context, accountgroup.Actor) ([]accountgroup.Event, error)
	Bootstrap(context.Context, accountgroup.Actor, accountgroup.Event) error
}

type enrollmentRequest struct {
	audience, token string
	event           accountgroup.Event
}

func decodeEnrollmentPayload(data []byte, purpose string, bootstrap bool) (enrollmentRequest, error) {
	bad := func() (enrollmentRequest, error) { return enrollmentRequest{}, errPayloadMalformed }
	if len(data) == 0 || len(data) > accountMaximumPayload {
		return bad()
	}
	o, err := strictObject(data)
	if err != nil {
		return bad()
	}
	keys := []string{"purpose", "audience", "accessToken"}
	if bootstrap {
		keys = append(keys, "confirmation", "event")
	}
	if !exactKeys(o, keys...) {
		return bad()
	}
	f := make(map[string]string, len(o))
	for k, v := range o {
		s, ok := v.(string)
		if !ok || s == "" || !utf8.ValidString(s) {
			return bad()
		}
		f[k] = s
	}
	if f["purpose"] != purpose || !validCredential(f["audience"], 255) || !validToken(f["accessToken"]) {
		return enrollmentRequest{}, errPayloadAuth
	}
	result := enrollmentRequest{audience: f["audience"], token: f["accessToken"]}
	if bootstrap {
		// An API intent marker, not evidence that native consent UI was displayed.
		if f["confirmation"] != "join_this_device" || len(f["event"]) > base64.StdEncoding.EncodedLen(4096) {
			return bad()
		}
		raw, err := base64.StdEncoding.Strict().DecodeString(f["event"])
		if err != nil || len(raw) == 0 || len(raw) > 4096 || base64.StdEncoding.EncodeToString(raw) != f["event"] {
			return bad()
		}
		// DecodeWireEvent is the shared exported codec. Strictly decode its outer
		// JSON too, rejecting duplicate, unknown, missing and non-string fields.
		wire, err := strictObject(raw)
		if err != nil || !exactKeys(wire, "payload", "signature", "subjectSignature") {
			return bad()
		}
		p, pok := wire["payload"].(string)
		s, sok := wire["signature"].(string)
		ss, ssok := wire["subjectSignature"].(string)
		if !pok || !sok || !ssok {
			return bad()
		}
		result.event, err = accountgroup.DecodeWireEvent(accountgroup.WireEvent{Payload: p, Signature: s, SubjectSignature: ss})
		if err != nil || result.event.Action != accountgroup.ActionBootstrap {
			return bad()
		}
	}
	return result, nil
}

func (h *accountHTTP) serveGroupEnrollment(w http.ResponseWriter, r *http.Request, device, purpose string, payload []byte) {
	bootstrap := r.URL.Path == "/v1/account/group/bootstrap"
	f, err := decodeEnrollmentPayload(payload, purpose, bootstrap)
	if err != nil {
		if errors.Is(err, errPayloadMalformed) {
			writeAccountError(w, 400, "invalid_request")
		} else {
			writeAccountError(w, 401, "authentication_failed")
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
		if errors.Is(err, ErrSessionInvalid) {
			writeAccountError(w, http.StatusUnauthorized, "authentication_failed")
		} else {
			unavailable()
		}
		return
	}
	if !validSession(session, device, f.audience) {
		unavailable()
		return
	}
	actor := accountgroup.Actor{AccountID: session.AccountID, DeviceID: session.DeviceID}
	groupError := func(err error) {
		if errors.Is(err, accountgroup.ErrGroupInvalid) {
			writeAccountError(w, 409, "group_conflict")
		} else {
			unavailable()
		}
	}
	success := func(value any) {
		body, err := json.Marshal(value)
		if err != nil || len(body) > groupMaximumResponse || ctx.Err() != nil {
			unavailable()
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		_, _ = w.Write(body)
	}
	if bootstrap {
		// The shared codec verified the signature and derived device ID from the key.
		if f.event.ActorDeviceID != device || f.event.AccountID != session.AccountID {
			writeAccountError(w, 401, "authentication_failed")
			return
		}
		digest, err := f.event.Digest()
		if err != nil {
			writeAccountError(w, 400, "invalid_request")
			return
		}
		err = h.enrollment.Bootstrap(ctx, actor, f.event)
		if ctx.Err() != nil {
			unavailable()
			return
		}
		if err != nil {
			groupError(err)
			return
		}
		// A historical identical retry records this event, not current membership.
		success(struct {
			Status     string `json:"status"`
			GroupID    string `json:"groupID"`
			Generation uint64 `json:"generation"`
			EventHash  string `json:"eventHash"`
		}{"recorded", f.event.GroupID, f.event.Generation, base64.StdEncoding.EncodeToString(digest[:])})
		return
	}
	events, err := h.enrollment.Discover(ctx, actor)
	if ctx.Err() != nil {
		unavailable()
		return
	}
	if err != nil {
		groupError(err)
		return
	}
	if events == nil {
		success(struct {
			Status string `json:"status"`
		}{"absent"})
		return
	}
	if len(events) == 0 || len(events) > groupMaximumEvents {
		unavailable()
		return
	}
	anchor := events[0]
	digest, err := anchor.Digest()
	if err != nil {
		unavailable()
		return
	}
	// Self-pinning here validates dependency output only. Native trust requires
	// independent explicit consent; this returned pin never authorizes itself.
	state, err := accountgroup.NewState(anchor, session.AccountID, anchor.GroupID, anchor.Generation, digest)
	if err != nil {
		unavailable()
		return
	}
	for _, event := range events[1:] {
		if ctx.Err() != nil || state.Apply(event) != nil {
			unavailable()
			return
		}
	}
	wire, err := accountgroup.EncodeWireEvent(anchor)
	if err != nil {
		unavailable()
		return
	}
	snapshot := state.Snapshot()
	success(struct {
		Status       string                 `json:"status"`
		GroupID      string                 `json:"groupID"`
		Generation   uint64                 `json:"generation"`
		Anchor       accountgroup.WireEvent `json:"anchor"`
		AnchorHash   string                 `json:"anchorHash"`
		HeadSequence uint64                 `json:"headSequence"`
		HeadHash     string                 `json:"headHash"`
	}{"present", snapshot.GroupID, snapshot.Generation, wire, base64.StdEncoding.EncodeToString(digest[:]), snapshot.Sequence, base64.StdEncoding.EncodeToString(snapshot.HeadHash[:])})
}
