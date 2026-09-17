package accountauth

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

const challengeDevice = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
const challengeOtherDevice = "11111111-2222-3333-4444-555555555555"
const challengeAudience = "com.example.synthetic"

func TestLoginChallengeConfiguration(t *testing.T) {
	db := &sql.DB{}
	for _, audiences := range [][]string{nil, {}, {""}, {"a", "a"}, {"a b"}, {"a\t"}, {"a\x00"}, {"a\u0085"}, {string([]byte{255})}, {strings.Repeat("a", 256)}, strings.Fields("a b c d e f g h i j k l m n o p q")} {
		if s, e := NewPostgresLoginChallenges(db, audiences); e != ErrLoginChallengeInvalid || s != nil {
			t.Fatalf("invalid config accepted: %q", audiences)
		}
	}
	if s, e := NewPostgresLoginChallenges(nil, []string{challengeAudience}); e != ErrLoginChallengeInvalid || s != nil {
		t.Fatal("nil DB accepted")
	}
	for _, audiences := range [][]string{{strings.Repeat("a", 255)}, {"应用.example"}, strings.Fields("a b c d e f g h i j k l m n o p")} {
		if _, e := NewPostgresLoginChallenges(db, audiences); e != nil {
			t.Fatal("valid audience boundary rejected", e)
		}
	}
}

func TestLoginChallengeInvalidInputs(t *testing.T) {
	s, _ := NewPostgresLoginChallenges(&sql.DB{}, []string{challengeAudience})
	for _, device := range []string{"", strings.ToUpper(challengeDevice), "{" + challengeDevice + "}", strings.ReplaceAll(challengeDevice, "-", ""), "gaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"} {
		if out, e := s.Issue(context.Background(), device, challengeAudience); e != ErrLoginChallengeInvalid || out != (LoginChallenge{}) {
			t.Fatalf("device accepted %q: %v", device, e)
		}
	}
	for _, id := range []string{"", strings.Repeat("a", 42), strings.Repeat("a", 44), strings.Repeat("a", 43) + "=", strings.Repeat("/", 43), strings.Repeat("a", 42) + "B"} {
		if out, e := s.Consume(context.Background(), id, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid || out.Nonce != "" {
			t.Fatalf("id accepted %q: %v", id, e)
		}
	}
	if _, e := s.Issue(context.Background(), challengeDevice, "wrong"); e != ErrLoginChallengeInvalid {
		t.Fatal("wrong audience accepted")
	}
	if _, e := s.Issue(nil, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid {
		t.Fatal("nil context accepted")
	}
	var absent *PostgresLoginChallenges
	if _, e := absent.Issue(context.Background(), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable {
		t.Fatal("nil receiver")
	}
	if _, e := absent.Consume(context.Background(), strings.Repeat("A", 43), challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable {
		t.Fatal("nil receiver consume")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if out, e := s.Issue(ctx, challengeDevice, challengeAudience); e == nil || out != (LoginChallenge{}) {
		t.Fatal("cancelled issue")
	}
	validID := strings.Repeat("A", 43)
	if out, e := s.Consume(nil, validID, challengeDevice, challengeAudience); e != ErrLoginChallengeInvalid || out.Nonce != "" {
		t.Fatal("nil context consume")
	}
	if out, e := s.Consume(ctx, validID, challengeDevice, challengeAudience); e != ErrLoginChallengeUnavailable || out.Nonce != "" {
		t.Fatal("cancelled consume")
	}
	if out, e := s.Consume(context.Background(), validID, strings.ToUpper(challengeDevice), challengeAudience); e != ErrLoginChallengeInvalid || out.Nonce != "" {
		t.Fatal("noncanonical consume device")
	}
	if out, e := s.Consume(context.Background(), validID, challengeDevice, "wrong"); e != ErrLoginChallengeInvalid || out.Nonce != "" {
		t.Fatal("invalid consume audience")
	}
}

func TestLoginChallengeExactTimeBoundary(t *testing.T) {
	now := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		created, expires time.Time
		live             bool
	}{
		{now, now.Add(5 * time.Minute), true},
		{now.Add(-5 * time.Minute), now, false},
		{now.Add(time.Nanosecond), now.Add(5 * time.Minute), false},
		{now.Add(-5 * time.Minute), now.Add(time.Nanosecond), true},
	} {
		if challengeLiveAt(test.created, test.expires, now) != test.live {
			t.Fatal("timestamp boundary mismatch", test)
		}
	}
}
