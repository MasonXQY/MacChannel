package accountauth

import (
	"database/sql"
	"fmt"
	"strings"
	"testing"
)

func TestAccountSessionTokensRedactFormatting(t *testing.T) {
	tokens := SessionTokens{AccessToken: "access-secret", RefreshToken: "refresh-secret"}
	for _, formatted := range []string{fmt.Sprint(tokens), fmt.Sprintf("%#v", tokens)} {
		if formatted != "SessionTokens{redacted}" {
			t.Fatalf("unexpected formatting %q", formatted)
		}
	}
}

func TestAccountSessionConstructorRejectsInvalidInputs(t *testing.T) {
	protector, _ := NewAppleCredentialProtector("key", map[string][]byte{"key": make([]byte, 32)})
	db := &sql.DB{}
	for _, test := range []struct {
		db        *sql.DB
		protector *AppleCredentialProtector
		audiences []string
	}{
		{nil, protector, []string{sessionAudience}},
		{db, nil, []string{sessionAudience}},
		{db, protector, nil},
		{db, protector, []string{sessionAudience, sessionAudience}},
		{db, protector, []string{strings.Repeat("a", 256)}},
	} {
		if got, err := NewPostgresSessions(test.db, test.protector, test.audiences); err != ErrSessionInvalid || got != nil {
			t.Fatalf("invalid constructor = %#v, %v", got, err)
		}
	}
}
