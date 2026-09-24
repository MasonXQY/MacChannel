// Package accountinvite defines selected-device cross-account invitations.
// A valid signature is not current authority: the SQL store must recheck both
// account incarnations, sessions and membership before activation or use.
package accountinvite

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"macchannel/rendezvous/internal/auth"
	"math"
	"net/url"
	"strconv"
	"strings"
)

var ErrInvalid = errors.New("invitation unavailable")

type Endpoint struct {
	AccountID, GroupID, DeviceID string
	Generation                   int64
	PublicKey                    []byte
	Audience                     string
}
type Pair struct {
	Audience, Origin, RequestID, GrantID                     string
	LinkVersion, IssuedAtMilliseconds, ExpiresAtMilliseconds int64
	Sender, Target                                           Endpoint
	TargetLinkHash                                           []byte
}

const RequestLifetimeMilliseconds int64 = 86400000
const PairPurpose = "dropmesh.account.invitation.pair.v1"
const RequestPurpose = "dropmesh.account.invitation.request.v1"

func uuid(s string) bool {
	if len(s) != 36 || s == "00000000-0000-0000-0000-000000000000" {
		return false
	}
	for i, c := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func audience(s string) bool {
	if len(s) < 1 || len(s) > 255 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}
func origin(s string) bool {
	u, e := url.Parse(s)
	if e != nil || len(s) > 255 || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.Port() != "" || s != "https://"+u.Host {
		return false
	}
	for _, c := range u.Host {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}
func public(raw []byte) (*ecdsa.PublicKey, error) {
	if len(raw) == 64 {
		raw = append([]byte{4}, raw...)
	}
	if len(raw) != 65 || raw[0] != 4 {
		return nil, ErrInvalid
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), raw)
	if x == nil {
		return nil, ErrInvalid
	}
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, nil
}
func (e Endpoint) valid() bool {
	_, err := public(e.PublicKey)
	return err == nil && audience(e.Audience) && uuid(e.AccountID) && uuid(e.GroupID) && e.Generation > 0 && auth.DeviceID(e.PublicKey) == e.DeviceID
}
func (p Pair) common() bool {
	return audience(p.Audience) && p.Audience == p.Sender.Audience && origin(p.Origin) && uuid(p.RequestID) && uuid(p.GrantID) && p.RequestID != p.GrantID && p.IssuedAtMilliseconds > 0 && p.IssuedAtMilliseconds <= math.MaxInt64-RequestLifetimeMilliseconds && p.ExpiresAtMilliseconds == p.IssuedAtMilliseconds+RequestLifetimeMilliseconds && p.Sender.valid()
}
func addEndpoint(m map[string]string, prefix string, e Endpoint) {
	m[prefix+"Audience"] = e.Audience
	m[prefix+"AccountID"] = e.AccountID
	m[prefix+"GroupID"] = e.GroupID
	m[prefix+"Generation"] = strconv.FormatInt(e.Generation, 10)
	m[prefix+"DeviceID"] = e.DeviceID
	m[prefix+"PublicKey"] = base64.StdEncoding.EncodeToString(e.PublicKey)
}
func (p Pair) fields(purpose string) map[string]string {
	m := map[string]string{"purpose": purpose, "audience": p.Audience, "origin": p.Origin, "requestID": p.RequestID, "grantID": p.GrantID, "linkVersion": strconv.FormatInt(p.LinkVersion, 10), "issuedAtMilliseconds": strconv.FormatInt(p.IssuedAtMilliseconds, 10), "expiresAtMilliseconds": strconv.FormatInt(p.ExpiresAtMilliseconds, 10)}
	addEndpoint(m, "sender", p.Sender)
	return m
}
func (p Pair) CanonicalPayload() ([]byte, error) {
	if !p.common() || p.LinkVersion <= 0 || len(p.TargetLinkHash) != 32 || !p.Target.valid() || p.Sender.AccountID == p.Target.AccountID || p.Sender.DeviceID == p.Target.DeviceID {
		return nil, ErrInvalid
	}
	m := p.fields(PairPurpose)
	addEndpoint(m, "target", p.Target)
	m["targetLinkHash"] = base64.StdEncoding.EncodeToString(p.TargetLinkHash)
	return json.Marshal(m)
}
func verify(payload, key, sig []byte) error {
	k, e := public(key)
	if e != nil || len(sig) < 8 || len(sig) > 80 {
		return ErrInvalid
	}
	h := sha256.Sum256(payload)
	if !ecdsa.VerifyASN1(k, h[:], sig) {
		return ErrInvalid
	}
	return nil
}
func (p Pair) Verify(sender, target []byte) error {
	b, e := p.CanonicalPayload()
	if e != nil || verify(b, p.Sender.PublicKey, sender) != nil || verify(b, p.Target.PublicKey, target) != nil {
		return ErrInvalid
	}
	return nil
}

// RequestProof names only the high-entropy link hash, never a target directory.
type RequestProof struct {
	Pair           Pair
	TargetLinkHash []byte
	Signature      []byte
}

func (r RequestProof) CanonicalPayload() ([]byte, error) {
	if !r.Pair.common() || len(r.TargetLinkHash) != 32 {
		return nil, ErrInvalid
	}
	m := r.Pair.fields(RequestPurpose)
	delete(m, "linkVersion")
	m["targetLinkHash"] = base64.StdEncoding.EncodeToString(r.TargetLinkHash)
	return json.Marshal(m)
}
func (r RequestProof) Validate() error {
	b, e := r.CanonicalPayload()
	if e != nil {
		return e
	}
	return verify(b, r.Pair.Sender.PublicKey, r.Signature)
}

type WirePair struct {
	Payload         string `json:"payload"`
	SenderSignature string `json:"senderSignature"`
	TargetSignature string `json:"targetSignature"`
}

type WireRequest struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

func EncodeRequest(r RequestProof) (WireRequest, error) {
	b, e := r.CanonicalPayload()
	if e != nil || r.Validate() != nil {
		return WireRequest{}, ErrInvalid
	}
	return WireRequest{base64.StdEncoding.EncodeToString(b), base64.StdEncoding.EncodeToString(r.Signature)}, nil
}
func DecodeRequest(w WireRequest) (RequestProof, error) {
	b, e := decode64(w.Payload, 5464)
	if e != nil || len(b) > 4096 {
		return RequestProof{}, ErrInvalid
	}
	var m map[string]string
	if json.Unmarshal(b, &m) != nil || m["purpose"] != RequestPurpose {
		return RequestProof{}, ErrInvalid
	}
	hash, e := decode64(m["targetLinkHash"], 44)
	if e != nil {
		return RequestProof{}, ErrInvalid
	}
	sig, e := decode64(w.Signature, 108)
	if e != nil {
		return RequestProof{}, ErrInvalid
	}
	p := Pair{Audience: m["audience"], Origin: m["origin"], RequestID: m["requestID"], GrantID: m["grantID"], LinkVersion: integer(m["linkVersion"]), IssuedAtMilliseconds: integer(m["issuedAtMilliseconds"]), ExpiresAtMilliseconds: integer(m["expiresAtMilliseconds"]), Sender: endpoint(m, "sender")}
	r := RequestProof{p, hash, sig}
	canonical, e := r.CanonicalPayload()
	if e != nil || !bytes.Equal(b, canonical) || r.Validate() != nil {
		return RequestProof{}, ErrInvalid
	}
	return r, nil
}

func EncodePair(p Pair, sender, target []byte) (WirePair, error) {
	b, e := p.CanonicalPayload()
	if e != nil || p.Verify(sender, target) != nil {
		return WirePair{}, ErrInvalid
	}
	return WirePair{base64.StdEncoding.EncodeToString(b), base64.StdEncoding.EncodeToString(sender), base64.StdEncoding.EncodeToString(target)}, nil
}
func decode64(s string, max int) ([]byte, error) {
	if len(s) > max {
		return nil, ErrInvalid
	}
	b, e := base64.StdEncoding.Strict().DecodeString(s)
	if e != nil || base64.StdEncoding.EncodeToString(b) != s {
		return nil, ErrInvalid
	}
	return b, nil
}
func integer(s string) int64 {
	n, e := strconv.ParseInt(s, 10, 64)
	if e != nil || n <= 0 || strconv.FormatInt(n, 10) != s {
		return 0
	}
	return n
}
func endpoint(m map[string]string, prefix string) Endpoint {
	b, _ := decode64(m[prefix+"PublicKey"], 88)
	return Endpoint{m[prefix+"AccountID"], m[prefix+"GroupID"], m[prefix+"DeviceID"], integer(m[prefix+"Generation"]), b, m[prefix+"Audience"]}
}
func DecodePairPayload(b []byte) (Pair, error) {
	if len(b) > 4096 {
		return Pair{}, ErrInvalid
	}
	var m map[string]string
	if json.Unmarshal(b, &m) != nil || m["purpose"] != PairPurpose {
		return Pair{}, ErrInvalid
	}
	hash, _ := decode64(m["targetLinkHash"], 44)
	p := Pair{m["audience"], m["origin"], m["requestID"], m["grantID"], integer(m["linkVersion"]), integer(m["issuedAtMilliseconds"]), integer(m["expiresAtMilliseconds"]), endpoint(m, "sender"), endpoint(m, "target"), hash}
	canonical, e := p.CanonicalPayload()
	if e != nil || !bytes.Equal(b, canonical) {
		return Pair{}, ErrInvalid
	}
	return p, nil
}
func DecodePair(w WirePair) (Pair, error) {
	b, e := decode64(w.Payload, 5464)
	if e != nil {
		return Pair{}, ErrInvalid
	}
	p, e := DecodePairPayload(b)
	if e != nil {
		return Pair{}, ErrInvalid
	}
	s, e := decode64(w.SenderSignature, 108)
	if e != nil {
		return Pair{}, ErrInvalid
	}
	t, e := decode64(w.TargetSignature, 108)
	if e != nil || p.Verify(s, t) != nil {
		return Pair{}, ErrInvalid
	}
	return p, nil
}

// Raw boundaries reject duplicate/unknown/missing envelope keys by exact key
// counting; canonical payload equality rejects all internal JSON variations.
func DecodePairJSON(b []byte) (WirePair, error) {
	if len(b) > 6000 {
		return WirePair{}, ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(b))
	tok, e := d.Token()
	if e != nil || tok != json.Delim('{') {
		return WirePair{}, ErrInvalid
	}
	m := map[string]string{}
	for d.More() {
		tok, e = d.Token()
		if e != nil {
			return WirePair{}, ErrInvalid
		}
		k, ok := tok.(string)
		if !ok || (k != "payload" && k != "senderSignature" && k != "targetSignature") {
			return WirePair{}, ErrInvalid
		}
		if _, ok = m[k]; ok {
			return WirePair{}, ErrInvalid
		}
		var s string
		if d.Decode(&s) != nil {
			return WirePair{}, ErrInvalid
		}
		m[k] = s
	}
	if tok, e = d.Token(); e != nil || tok != json.Delim('}') || len(m) != 3 {
		return WirePair{}, ErrInvalid
	}
	if strings.TrimSpace(string(b[d.InputOffset():])) != "" {
		return WirePair{}, ErrInvalid
	}
	w := WirePair{m["payload"], m["senderSignature"], m["targetSignature"]}
	if _, e = DecodePair(w); e != nil {
		return WirePair{}, e
	}
	return w, nil
}
