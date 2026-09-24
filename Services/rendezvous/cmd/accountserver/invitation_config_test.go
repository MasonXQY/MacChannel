package main

import "testing"

func TestInvitationCapabilityRequiresGroupAndCanonicalOrigin(t *testing.T) {
	for _, tc := range []struct {
		flag, groups, origin string
		valid                bool
	}{
		{"", "", "", true}, {"0", "", "", true}, {"1", "1", "https://account.example", true},
		{"true", "1", "https://account.example", false}, {"1", "", "https://account.example", false},
		{"1", "1", "", false}, {"1", "1", "http://account.example", false},
		{"1", "1", "https://user@account.example", false}, {"1", "1", "https://account.example/path", false},
		{"1", "1", "https://account.example?x=1", false}, {"1", "1", "https://account.example:443", false},
	} {
		env := validEnvironment(t)
		env["DROPMESH_ACCOUNT_INVITATIONS_ENABLED"] = tc.flag
		env["DROPMESH_ACCOUNT_GROUPS_ENABLED"] = tc.groups
		env["DROPMESH_ACCOUNT_ORIGIN"] = tc.origin
		_, err := loadConfig(mapGetter(env))
		if (err == nil) != tc.valid {
			t.Fatalf("flag %q groups %q origin %q: %v", tc.flag, tc.groups, tc.origin, err)
		}
	}
}
