package accountgroup

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"macchannel/rendezvous/internal/auth"
)

// Fixtures contain only public keys and signed events from ephemeral test keys.
type nativeGroupChain struct {
	Form       int      `json:"form"`
	AccountID  string   `json:"accountID"`
	GroupID    string   `json:"groupID"`
	Generation uint64   `json:"generation"`
	AnchorHash string   `json:"anchorHash"`
	Events     []string `json:"events"`
}

func nativeInteropDirectory(path string) (string, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || !strings.HasPrefix(filepath.Base(path), "dropmesh-group-interop-") {
		return "", fmt.Errorf("invalid fixture directory")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || resolved != path {
		return "", fmt.Errorf("symlink fixture directory")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", fmt.Errorf("invalid fixture directory")
	}
	return path, nil
}

func TestNativeGroupInterop(t *testing.T) {
	path := os.Getenv("DROPMESH_GROUP_INTEROP_DIR")
	if path == "" {
		t.Skip("opt-in native cryptographic interoperability")
	}
	dir, err := nativeInteropDirectory(path)
	if err != nil {
		t.Fatal(err)
	}
	switch os.Getenv("DROPMESH_GROUP_INTEROP_MODE") {
	case "export":
		var chains []nativeGroupChain
		for _, form := range []int{64, 65} {
			a, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			b, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			public := func(k *ecdsa.PrivateKey) []byte {
				raw := elliptic.Marshal(k.Curve, k.X, k.Y)
				if form == 64 {
					return raw[1:]
				}
				return raw
			}
			chain := nativeGroupChain{Form: form, AccountID: "11111111-1111-1111-1111-111111111111", GroupID: "22222222-2222-2222-2222-222222222222", Generation: 1}
			var previous []byte
			for index, action := range []Action{ActionBootstrap, ActionApprove, ActionRemove} {
				subject := b
				if index == 0 {
					subject = a
				}
				ak, sk := public(a), public(subject)
				event := Event{AccountID: chain.AccountID, GroupID: chain.GroupID, Generation: 1, Sequence: uint64(index + 1), PreviousHash: previous,
					Action: action, ActorDeviceID: auth.DeviceID(ak), ActorPublicKey: ak, SubjectDeviceID: auth.DeviceID(sk), SubjectPublicKey: sk,
					EpochMilliseconds: 1800000000000}
				payload, err := event.CanonicalPayload()
				if err != nil {
					t.Fatal(err)
				}
				digest := sha256.Sum256(payload)
				event.Signature, err = ecdsa.SignASN1(rand.Reader, a, digest[:])
				if err != nil {
					t.Fatal(err)
				}
				if action == ActionApprove {
					event.SubjectSignature, err = ecdsa.SignASN1(rand.Reader, b, digest[:])
					if err != nil {
						t.Fatal(err)
					}
				}
				wire, err := EncodeWireEvent(event)
				if err != nil {
					t.Fatal(err)
				}
				raw, err := json.Marshal(wire)
				if err != nil {
					t.Fatal(err)
				}
				chain.Events = append(chain.Events, string(raw))
				previous = append([]byte(nil), digest[:]...)
				if index == 0 {
					chain.AnchorHash = base64.StdEncoding.EncodeToString(digest[:])
				}
			}
			chains = append(chains, chain)
		}
		data, err := json.Marshal(chains)
		if err != nil {
			t.Fatal(err)
		}
		f, err := os.OpenFile(filepath.Join(dir, "go.json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write(data); err != nil {
			f.Close()
			t.Fatal(err)
		}
		if err := f.Close(); err != nil {
			t.Fatal(err)
		}
		t.Log("Go exported two signed P256 chains: 64-byte and 65-byte keys")
	case "verify":
		name := filepath.Join(dir, "swift.json")
		info, err := os.Lstat(name)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 32768 {
			t.Fatal("invalid fixture file")
		}
		data, err := os.ReadFile(name)
		if err != nil || len(data) > 32768 {
			t.Fatal("fixture read failed")
		}
		var chains []nativeGroupChain
		if err := json.Unmarshal(data, &chains); err != nil {
			t.Fatal(err)
		}
		if len(chains) != 2 {
			t.Fatal("expected two key forms")
		}
		for index, chain := range chains {
			if chain.Form != 64+index || len(chain.Events) != 3 {
				t.Fatal("missing key form or events")
			}
			var state *State
			for n, text := range chain.Events {
				if len(text) > 8192 {
					t.Fatal("oversized wire")
				}
				var wire WireEvent
				if err := json.Unmarshal([]byte(text), &wire); err != nil {
					t.Fatal(err)
				}
				e, err := DecodeWireEvent(wire)
				if err != nil {
					t.Fatal(err)
				}
				if len(e.ActorPublicKey) != chain.Form || len(e.SubjectPublicKey) != chain.Form {
					t.Fatal("key representation changed")
				}
				if n == 0 {
					raw, err := base64.StdEncoding.Strict().DecodeString(chain.AnchorHash)
					if err != nil || len(raw) != 32 {
						t.Fatal("invalid pin")
					}
					var hash [32]byte
					copy(hash[:], raw)
					state, err = NewState(e, chain.AccountID, chain.GroupID, chain.Generation, hash)
					if err != nil {
						t.Fatal(err)
					}
				} else if err := state.Apply(e); err != nil {
					t.Fatal(err)
				}
			}
			snapshot := state.Snapshot()
			if snapshot.Sequence != 3 || len(snapshot.Members) != 1 {
				t.Fatal("wrong final membership")
			}
		}
		t.Log("Go verified Swift signatures and applied both complete 64/65 chains")
	default:
		t.Fatal("invalid interop mode")
	}
}

func TestNativeGroupInteropDirectorySafety(t *testing.T) {
	parent := t.TempDir()
	good, err := os.MkdirTemp(parent, "dropmesh-group-interop-")
	if err != nil {
		t.Fatal(err)
	}
	good, err = filepath.EvalSymlinks(good)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := nativeInteropDirectory(good); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(parent, "dropmesh-group-interop-link")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"relative", parent, link, good + "/../" + filepath.Base(good)} {
		if _, err := nativeInteropDirectory(bad); err == nil {
			t.Fatalf("accepted unsafe directory %q", bad)
		}
	}
}
