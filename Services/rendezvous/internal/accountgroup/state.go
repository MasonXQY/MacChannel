package accountgroup

import (
	"bytes"
	"errors"
	"math"
	"sort"
	"sync"
)

// ErrInvalidTransition is returned when an event cannot advance the pinned
// membership history. It intentionally does not reveal which admission check
// failed.
var ErrInvalidTransition = errors.New("invalid account group transition")

const maxMembers = 64

type Member struct {
	DeviceID  string
	PublicKey []byte
}

type Snapshot struct {
	AccountID  string
	GroupID    string
	Generation uint64
	Sequence   uint64
	HeadHash   [32]byte
	Members    []Member
}

type State struct {
	mu          sync.RWMutex
	initialized bool
	accountID   string
	groupID     string
	generation  uint64
	sequence    uint64
	headHash    [32]byte
	members     map[string][]byte
}

// NewState creates state only from a bootstrap event whose identity and digest
// exactly match values independently pinned by an explicit owner-confirmed
// native flow. A server-returned bootstrap must never supply its own expected
// values: doing so would turn signature validity into membership authority.
func NewState(anchor Event, expectedAccountID, expectedGroupID string, expectedGeneration uint64, expectedAnchorHash [32]byte) (*State, error) {
	owned := copyStateEvent(anchor)
	if owned.Validate() != nil || owned.Action != ActionBootstrap || owned.Sequence != 1 ||
		owned.AccountID != expectedAccountID || owned.GroupID != expectedGroupID ||
		owned.Generation != expectedGeneration {
		return nil, ErrInvalidTransition
	}
	digest, err := owned.Digest()
	if err != nil || digest != expectedAnchorHash {
		return nil, ErrInvalidTransition
	}
	return &State{
		initialized: true,
		accountID:   owned.AccountID,
		groupID:     owned.GroupID,
		generation:  owned.Generation,
		sequence:    owned.Sequence,
		headHash:    digest,
		members:     map[string][]byte{owned.ActorDeviceID: append([]byte(nil), owned.ActorPublicKey...)},
	}, nil
}

// Apply is safe to call concurrently with Apply and Snapshot. The event buffers
// are copied before validation and retention; callers must not mutate them while
// this method is executing.
func (s *State) Apply(event Event) error {
	if s == nil {
		return ErrInvalidTransition
	}
	owned := copyStateEvent(event)
	if owned.Validate() != nil {
		return ErrInvalidTransition
	}
	digest, err := owned.Digest()
	if err != nil {
		return ErrInvalidTransition
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.initialized || owned.Action == ActionBootstrap || s.sequence >= math.MaxInt64 ||
		owned.AccountID != s.accountID || owned.GroupID != s.groupID || owned.Generation != s.generation ||
		owned.Sequence != s.sequence+1 || !bytes.Equal(owned.PreviousHash, s.headHash[:]) {
		return ErrInvalidTransition
	}
	actorKey, active := s.members[owned.ActorDeviceID]
	if !active || !bytes.Equal(actorKey, owned.ActorPublicKey) {
		return ErrInvalidTransition
	}

	switch owned.Action {
	case ActionApprove:
		if _, present := s.members[owned.SubjectDeviceID]; present || len(s.members) >= maxMembers {
			return ErrInvalidTransition
		}
	case ActionRemove:
		subjectKey, present := s.members[owned.SubjectDeviceID]
		if !present || !bytes.Equal(subjectKey, owned.SubjectPublicKey) {
			return ErrInvalidTransition
		}
	default:
		return ErrInvalidTransition
	}

	if owned.Action == ActionApprove {
		s.members[owned.SubjectDeviceID] = append([]byte(nil), owned.SubjectPublicKey...)
	} else {
		delete(s.members, owned.SubjectDeviceID)
	}
	s.sequence = owned.Sequence
	s.headHash = digest
	return nil
}

// Snapshot returns a deterministic, deep copy safe for caller mutation.
func (s *State) Snapshot() Snapshot {
	if s == nil {
		return Snapshot{}
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if !s.initialized {
		return Snapshot{}
	}
	members := make([]Member, 0, len(s.members))
	for id, key := range s.members {
		members = append(members, Member{DeviceID: id, PublicKey: append([]byte(nil), key...)})
	}
	sort.Slice(members, func(i, j int) bool { return members[i].DeviceID < members[j].DeviceID })
	return Snapshot{AccountID: s.accountID, GroupID: s.groupID, Generation: s.generation, Sequence: s.sequence, HeadHash: s.headHash, Members: members}
}

func copyStateEvent(event Event) Event {
	event.PreviousHash = append([]byte(nil), event.PreviousHash...)
	event.ActorPublicKey = append([]byte(nil), event.ActorPublicKey...)
	event.SubjectPublicKey = append([]byte(nil), event.SubjectPublicKey...)
	event.Signature = append([]byte(nil), event.Signature...)
	event.SubjectSignature = append([]byte(nil), event.SubjectSignature...)
	return event
}
