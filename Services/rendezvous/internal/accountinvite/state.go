package accountinvite

const (
	Requested = "requested"
	Selected  = "selected"
	Active    = "active"
	Rejected  = "rejected"
	Cancelled = "cancelled"
	Expired   = "expired"
	Revoked   = "revoked"
)

func terminal(state string) bool {
	return state == Rejected || state == Cancelled || state == Expired || state == Revoked
}
func transition(state, action string, sender bool, now, expires int64) (string, error) {
	if terminal(state) {
		return "", ErrInvalid
	}
	if state != Active && now >= expires {
		return Expired, nil
	}
	switch action {
	case "select":
		if state == Requested && !sender {
			return Selected, nil
		}
	case "commit":
		if state == Selected {
			return Active, nil
		}
	case "reject":
		if !sender && state != Active {
			return Rejected, nil
		}
	case "cancel":
		if sender && state != Active {
			return Cancelled, nil
		}
	case "revoke":
		if state == Active {
			return Revoked, nil
		}
	}
	return "", ErrInvalid
}
