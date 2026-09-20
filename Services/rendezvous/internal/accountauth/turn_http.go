package accountauth

import (
	"context"
	"errors"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/turn"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type AccountTURNIssuer interface {
	IssueTURNCredential(context.Context, accountgroup.PresenceProjectionRequest, []byte) (turn.Credential, error)
}

// AccountTURNConfig is opt-in and is copied by NewAccountHTTP.
type AccountTURNConfig struct {
	Issuer       AccountTURNIssuer
	SharedSecret []byte
	URLs         []string
}

func validAccountTURNConfig(c *AccountTURNConfig) bool {
	if nilInterface(c.Issuer) || len(c.SharedSecret) < 32 || len(c.SharedSecret) > 4096 || len(c.URLs) == 0 || len(c.URLs) > 8 {
		return false
	}
	for _, raw := range c.URLs {
		if !validCredential(raw, 2048) {
			return false
		}
		scheme, rest, ok := strings.Cut(raw, ":")
		if !ok || (scheme != "turn" && scheme != "turns") || strings.HasPrefix(rest, "//") {
			return false
		}
		u, err := url.Parse(scheme + "://" + rest)
		if err != nil || u.Hostname() == "" || u.User != nil || u.Path != "" || u.Fragment != "" {
			return false
		}
		if port := u.Port(); port != "" {
			n, err := strconv.Atoi(port)
			if err != nil || n < 1 || n > 65535 {
				return false
			}
		}
		if u.RawQuery != "" && u.RawQuery != "transport=udp" && u.RawQuery != "transport=tcp" {
			return false
		}
	}
	return true
}

func (h *accountHTTP) serveAccountTURN(w http.ResponseWriter, r *http.Request, device string, key, payload []byte) {
	o, err := strictObject(payload)
	if err != nil || !exactKeys(o, "purpose", "audience", "accessToken", "groupID", "generation") {
		writeAccountError(w, 400, "invalid_request")
		return
	}
	f := make(map[string]string, len(o))
	for k, v := range o {
		s, ok := v.(string)
		if !ok || s == "" {
			writeAccountError(w, 400, "invalid_request")
			return
		}
		f[k] = s
	}
	if f["purpose"] != "dropmesh.account.turn.credentials.v1" || !validCredential(f["audience"], 255) || !validToken(f["accessToken"]) {
		writeAccountError(w, 401, "authentication_failed")
		return
	}
	generation, err := strconv.ParseUint(f["generation"], 10, 64)
	if err != nil || generation == 0 || generation > math.MaxInt64 || strconv.FormatUint(generation, 10) != f["generation"] || !validUUID(f["groupID"]) {
		writeAccountError(w, 400, "invalid_request")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	session, err := h.sessions.Authenticate(ctx, f["accessToken"], device, f["audience"])
	delete(f, "accessToken")
	if err != nil {
		h.writeDependencyError(w, err)
		return
	}
	if !validSession(session, device, f["audience"]) || ctx.Err() != nil {
		writeAccountError(w, 503, "service_unavailable")
		return
	}
	credential, err := h.turn.Issuer.IssueTURNCredential(ctx, accountgroup.PresenceProjectionRequest{Actor: accountgroup.SessionActor{AccountID: session.AccountID, SessionID: session.SessionID, DeviceID: session.DeviceID, Audience: session.Audience}, PublicKey: append([]byte(nil), key...), GroupID: f["groupID"], Generation: generation}, h.turn.SharedSecret)
	if err != nil {
		if errors.Is(err, accountgroup.ErrGroupUnavailable) || ctx.Err() != nil {
			writeAccountError(w, 503, "service_unavailable")
		} else {
			writeAccountError(w, 401, "authentication_failed")
		}
		return
	}
	if ctx.Err() != nil || credential.ExpiresAt.Nanosecond() != 0 || !turn.Verify(credential, h.turn.SharedSecret) {
		writeAccountError(w, 503, "service_unavailable")
		return
	}
	writeAccountJSON(w, 200, struct {
		URLs []string `json:"urls"`
		turn.Credential
	}{h.turn.URLs, credential})
}
