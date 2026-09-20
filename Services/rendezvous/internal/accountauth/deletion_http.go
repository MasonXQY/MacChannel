package accountauth

import (
	"errors"
	"net/http"
)

func deletionOperation(path string) (string, bool) {
	switch path {
	case "/v1/account/deletion/begin":
		return "begin", true
	case "/v1/account/deletion/status":
		return "status", true
	}
	return "", false
}

func (h *accountHTTP) serveDeletion(w http.ResponseWriter, r *http.Request, device, op string, payload []byte) {
	o, err := strictObject(payload)
	keys := []string{"purpose", "audience", "receipt"}
	if op == "begin" {
		keys = append(keys, "accessToken", "challengeID", "code", "identityToken", "confirmation")
	}
	if err != nil || !exactKeys(o, keys...) {
		writeAccountError(w, 400, "invalid_request")
		return
	}
	f := map[string]string{}
	for k, v := range o {
		if k == "confirmation" {
			continue
		}
		s, ok := v.(string)
		if !ok {
			writeAccountError(w, 400, "invalid_request")
			return
		}
		f[k] = s
	}
	if f["purpose"] != "dropmesh.account.deletion."+op+".v1" || !validCredential(f["audience"], 255) || !validToken(f["receipt"]) {
		writeAccountError(w, 401, "authentication_failed")
		return
	}
	var out DeletionStatus
	if op == "begin" {
		confirmation, ok := o["confirmation"].(bool)
		if !ok || !confirmation || !validToken(f["accessToken"]) || !validToken(f["challengeID"]) || !validCredential(f["code"], 4096) || !validCredential(f["identityToken"], maxIdentityTokenBytes) {
			writeAccountError(w, 401, "authentication_failed")
			return
		}
		if !h.acquireCompletion(device) {
			writeAccountError(w, 429, "rate_limited")
			return
		}
		defer h.releaseCompletion(device)
		out, err = h.deletion.Begin(r.Context(), DeletionRequest{AccessToken: f["accessToken"], Receipt: f["receipt"], DeviceID: device, Audience: f["audience"], ChallengeID: f["challengeID"], Code: f["code"], IdentityToken: f["identityToken"], Confirmation: confirmation})
	} else {
		out, err = h.deletion.Status(r.Context(), f["receipt"], device, f["audience"])
	}
	if err != nil {
		if errors.Is(err, ErrDeletionInvalid) {
			writeAccountError(w, 401, "authentication_failed")
		} else {
			writeAccountError(w, 503, "service_unavailable")
		}
		return
	}
	if out.Status != "pending" && out.Status != "retrying" && out.Status != "completed" && out.Status != "completed_manual_revocation_required" {
		writeAccountError(w, 503, "service_unavailable")
		return
	}
	writeAccountJSON(w, 200, out)
}
