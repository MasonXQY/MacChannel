package httpapi

import (
	"errors"

	"macchannel/rendezvous/internal/auth"
)

// Only fixed categories may reach logs: errors can contain private storage or
// authentication details, so never log their text or the authentication frame.
func envelopeRejectionCategory(err error) string {
	switch {
	case errors.Is(err, auth.ErrInvalidEnvelope):
		return "envelope_invalid"
	case errors.Is(err, auth.ErrStaleEnvelope):
		return "envelope_stale"
	case errors.Is(err, auth.ErrRepeatedNonce):
		return "envelope_replay"
	case errors.Is(err, auth.ErrReplayCapacity):
		return "envelope_capacity"
	case errors.Is(err, auth.ErrInvalidChallenge):
		return "envelope_challenge"
	default:
		return "envelope_internal"
	}
}

func trustRejectionCategory(err error) string {
	switch {
	case errors.Is(err, auth.ErrInvalidTrust):
		return "trust_invalid"
	case errors.Is(err, auth.ErrTrustCapacity):
		return "trust_capacity"
	case errors.Is(err, auth.ErrTrustRateLimit):
		return "trust_rate_limit"
	default:
		return "trust_internal"
	}
}
