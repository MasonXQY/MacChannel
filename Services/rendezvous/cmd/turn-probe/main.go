// Command turn-probe performs a real host-side TURN allocation and verifies
// the server's XOR-RELAYED-ADDRESS. It deliberately prints no credentials.
package main

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	credential "macchannel/rendezvous/internal/turn"
)

const (
	stunMagic                   uint32 = 0x2112a442
	stunAllocateRequest                = 0x0003
	stunAllocateSuccess                = 0x0103
	attributeUsername                  = 0x0006
	attributeMessageIntegrity          = 0x0008
	attributeErrorCode                 = 0x0009
	attributeRealm                     = 0x0014
	attributeNonce                     = 0x0015
	attributeXORRelayedAddress         = 0x0016
	attributeRequestedTransport        = 0x0019
)

type stunAttribute struct {
	kind  uint16
	value []byte
}

func main() {
	serverText := flag.String("server", "127.0.0.1:3478", "host-published TURN UDP endpoint")
	expectedText := flag.String("expected-ip", "", "expected advertised relay IPv4 address")
	minimumPort := flag.Int("min-port", 49160, "lowest host-published relay port")
	maximumPort := flag.Int("max-port", 49200, "highest host-published relay port")
	secretPath := flag.String("secret-file", "", "TURN REST shared-secret file")
	flag.Parse()
	if *expectedText == "" || *secretPath == "" {
		fatal("expected-ip and secret-file are required")
	}
	expected := net.ParseIP(*expectedText)
	if expected == nil || expected.To4() == nil || expected.IsLoopback() || expected.IsUnspecified() {
		fatal("expected-ip must be a non-loopback IPv4 address")
	}
	secret, err := readSecret(*secretPath)
	if err != nil {
		fatal(err.Error())
	}
	address, err := allocate(*serverText, credential.Mint("local-stack-probe", time.Now(), secret))
	if err != nil {
		fatal(err.Error())
	}
	if err := validateRelayAddress(address, expected, *minimumPort, *maximumPort); err != nil {
		fatal(err.Error())
	}
	fmt.Printf("XOR-RELAYED-ADDRESS verified as %s\n", address)
}

func validateRelayAddress(address *net.UDPAddr, expected net.IP, minimumPort, maximumPort int) error {
	if address == nil || !address.IP.Equal(expected) {
		return errors.New("XOR-RELAYED-ADDRESS does not match the configured host/deployment address")
	}
	if minimumPort < 1 || maximumPort > 65535 || minimumPort > maximumPort || address.Port < minimumPort || address.Port > maximumPort {
		return errors.New("XOR-RELAYED-ADDRESS port is outside the host-published relay range")
	}
	return nil
}

func readSecret(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("TURN secret is unavailable")
	}
	data = []byte(strings.TrimSpace(string(data)))
	if len(data) < 32 || len(data) > 4096 {
		return nil, errors.New("TURN secret has an invalid length")
	}
	return data, nil
}

func allocate(server string, credentials credential.Credential) (*net.UDPAddr, error) {
	remote, err := net.ResolveUDPAddr("udp4", server)
	if err != nil {
		return nil, errors.New("resolve TURN endpoint")
	}
	connection, err := net.DialUDP("udp4", nil, remote)
	if err != nil {
		return nil, errors.New("connect to host-published TURN endpoint")
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(8 * time.Second)); err != nil {
		return nil, errors.New("set TURN probe deadline")
	}

	firstTransaction, err := newTransaction()
	if err != nil {
		return nil, errors.New("create TURN transaction")
	}
	initial := stunPacket(stunAllocateRequest, firstTransaction, stunAttribute{
		kind: attributeRequestedTransport, value: []byte{17, 0, 0, 0},
	})
	challenge, err := exchange(connection, initial)
	if err != nil {
		return nil, err
	}
	challengeAttributes, err := parseAttributes(challenge, firstTransaction)
	if err != nil {
		return nil, errors.New("parse TURN authentication challenge")
	}
	if code := challengeAttributes[attributeErrorCode]; len(code) < 4 || int(code[2])*100+int(code[3]) != 401 {
		return nil, errors.New("TURN endpoint did not issue a 401 authentication challenge")
	}
	realm := challengeAttributes[attributeRealm]
	nonce := challengeAttributes[attributeNonce]
	if len(realm) == 0 || len(nonce) == 0 {
		return nil, errors.New("TURN challenge omitted realm or nonce")
	}

	secondTransaction, err := newTransaction()
	if err != nil {
		return nil, errors.New("create authenticated TURN transaction")
	}
	authenticated := authenticatedAllocatePacket(secondTransaction, credentials.Username, credentials.Credential, string(realm), nonce)
	response, err := exchange(connection, authenticated)
	if err != nil {
		return nil, err
	}
	return xorRelayedAddress(response, secondTransaction)
}

func exchange(connection *net.UDPConn, request []byte) ([]byte, error) {
	if _, err := connection.Write(request); err != nil {
		return nil, errors.New("send TURN allocation")
	}
	response := make([]byte, 2048)
	count, err := connection.Read(response)
	if err != nil {
		return nil, errors.New("receive TURN allocation")
	}
	return response[:count], nil
}

func newTransaction() ([12]byte, error) {
	var transaction [12]byte
	_, err := rand.Read(transaction[:])
	return transaction, err
}

func authenticatedAllocatePacket(transaction [12]byte, username, password, realm string, nonce []byte) []byte {
	attributes := []stunAttribute{
		{kind: attributeUsername, value: []byte(username)},
		{kind: attributeRealm, value: []byte(realm)},
		{kind: attributeNonce, value: nonce},
		{kind: attributeRequestedTransport, value: []byte{17, 0, 0, 0}},
	}
	body := encodeAttributes(attributes)
	packet := make([]byte, 20+len(body))
	binary.BigEndian.PutUint16(packet[0:2], stunAllocateRequest)
	// RFC 5389 requires the header length to include MESSAGE-INTEGRITY while the
	// HMAC input ends immediately before that attribute.
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(body)+24))
	binary.BigEndian.PutUint32(packet[4:8], stunMagic)
	copy(packet[8:20], transaction[:])
	copy(packet[20:], body)
	longTermKey := md5.Sum([]byte(username + ":" + realm + ":" + password))
	mac := hmac.New(sha1.New, longTermKey[:])
	_, _ = mac.Write(packet)
	return append(packet, encodeAttributes([]stunAttribute{{kind: attributeMessageIntegrity, value: mac.Sum(nil)}})...)
}

func stunPacket(messageType uint16, transaction [12]byte, attributes ...stunAttribute) []byte {
	body := encodeAttributes(attributes)
	packet := make([]byte, 20+len(body))
	binary.BigEndian.PutUint16(packet[0:2], messageType)
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(body)))
	binary.BigEndian.PutUint32(packet[4:8], stunMagic)
	copy(packet[8:20], transaction[:])
	copy(packet[20:], body)
	return packet
}

func encodeAttributes(attributes []stunAttribute) []byte {
	var result []byte
	for _, attribute := range attributes {
		paddedLength := (len(attribute.value) + 3) &^ 3
		start := len(result)
		result = append(result, make([]byte, 4+paddedLength)...)
		binary.BigEndian.PutUint16(result[start:start+2], attribute.kind)
		binary.BigEndian.PutUint16(result[start+2:start+4], uint16(len(attribute.value)))
		copy(result[start+4:], attribute.value)
	}
	return result
}

func parseAttributes(packet []byte, transaction [12]byte) (map[uint16][]byte, error) {
	if len(packet) < 20 || binary.BigEndian.Uint32(packet[4:8]) != stunMagic || string(packet[8:20]) != string(transaction[:]) {
		return nil, errors.New("invalid STUN header")
	}
	messageLength := int(binary.BigEndian.Uint16(packet[2:4]))
	if messageLength > len(packet)-20 {
		return nil, errors.New("truncated STUN packet")
	}
	attributes := make(map[uint16][]byte)
	for offset := 20; offset < 20+messageLength; {
		if offset+4 > len(packet) {
			return nil, errors.New("truncated STUN attribute")
		}
		kind := binary.BigEndian.Uint16(packet[offset : offset+2])
		length := int(binary.BigEndian.Uint16(packet[offset+2 : offset+4]))
		if offset+4+length > 20+messageLength {
			return nil, errors.New("invalid STUN attribute length")
		}
		attributes[kind] = append([]byte(nil), packet[offset+4:offset+4+length]...)
		offset += 4 + ((length + 3) &^ 3)
	}
	return attributes, nil
}

func xorRelayedAddress(packet []byte, transaction [12]byte) (*net.UDPAddr, error) {
	if len(packet) < 2 || binary.BigEndian.Uint16(packet[0:2]) != stunAllocateSuccess {
		return nil, errors.New("authenticated TURN allocation failed")
	}
	attributes, err := parseAttributes(packet, transaction)
	if err != nil {
		return nil, err
	}
	value := attributes[attributeXORRelayedAddress]
	if len(value) < 8 || value[1] != 1 {
		return nil, errors.New("TURN response omitted a supported XOR-RELAYED-ADDRESS")
	}
	port := binary.BigEndian.Uint16(value[2:4]) ^ uint16(stunMagic>>16)
	address := binary.BigEndian.Uint32(value[4:8]) ^ stunMagic
	ip := make(net.IP, net.IPv4len)
	binary.BigEndian.PutUint32(ip, address)
	return &net.UDPAddr{IP: ip, Port: int(port)}, nil
}

func fatal(message string) {
	_, _ = fmt.Fprintln(os.Stderr, "turn-probe:", message)
	os.Exit(1)
}
