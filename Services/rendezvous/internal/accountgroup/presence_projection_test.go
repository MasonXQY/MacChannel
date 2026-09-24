package accountgroup

import (
	"context"
	"database/sql"
	"reflect"
	"testing"
)

func TestPresenceProjectionRejectsBeforeSQL(t *testing.T) {
	key := fixtureKey(t, true)
	valid := PresenceProjectionRequest{Actor: SessionActor{"11111111-2222-3333-4444-555555555555", groupSessionID, key.id, "com.example.app"}, PublicKey: key.public, GroupID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", Generation: 1}
	for _, kind := range []string{"nil store", "nil database", "nil context", "cancelled", "account", "device", "session", "audience", "key", "group", "zero generation", "overflow generation"} {
		t.Run(kind, func(t *testing.T) {
			r := valid
			s := &PostgresStore{db: new(sql.DB)} // Any attempted SQL is a test failure.
			ctx := context.Background()
			want := ErrGroupInvalid
			switch kind {
			case "nil store":
				s = nil
				want = ErrGroupUnavailable
			case "nil database":
				s.db = nil
				want = ErrGroupUnavailable
			case "nil context":
				ctx = nil
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
				want = ErrGroupUnavailable
			case "account":
				r.Actor.AccountID = "bad"
			case "device":
				r.Actor.DeviceID = "bad"
			case "session":
				r.Actor.SessionID = "bad"
				want = ErrGroupSessionInvalid
			case "audience":
				r.Actor.Audience = "bad audience"
				want = ErrGroupSessionInvalid
			case "key":
				r.PublicKey = []byte{1}
			case "group":
				r.GroupID = "bad"
			case "zero generation":
				r.Generation = 0
			case "overflow generation":
				r.Generation = 1 << 63
			}
			got, err := s.ProjectPresenceCandidates(ctx, r)
			if err != want || !reflect.DeepEqual(got, PresenceProjection{}) {
				t.Fatalf("projection=%+v error=%v, want empty/%v", got, err, want)
			}
		})
	}
}
