package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"

	credential "macchannel/rendezvous/internal/turn"
)

func TestXORRelayedAddressParsesAdvertisedIPv4(t *testing.T) {
	transaction := [12]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	address := net.ParseIP("192.0.2.44").To4()
	value := make([]byte, 8)
	value[1] = 1
	binary.BigEndian.PutUint16(value[2:4], 49160^uint16(stunMagic>>16))
	binary.BigEndian.PutUint32(value[4:8], binary.BigEndian.Uint32(address)^stunMagic)
	packet := stunPacket(stunAllocateSuccess, transaction, stunAttribute{kind: attributeXORRelayedAddress, value: value})

	got, err := xorRelayedAddress(packet, transaction)
	if err != nil {
		t.Fatal(err)
	}
	if got.String() != "192.0.2.44:49160" {
		t.Fatalf("relayed address = %s", got)
	}
}

func TestXORRelayedAddressRejectsMissingAttribute(t *testing.T) {
	transaction := [12]byte{1, 2, 3}
	packet := stunPacket(stunAllocateSuccess, transaction)
	if _, err := xorRelayedAddress(packet, transaction); err == nil {
		t.Fatal("accepted response without XOR-RELAYED-ADDRESS")
	}
}

func TestAllocateCompletesLongTermAuthenticationAndReturnsHostRelay(t *testing.T) {
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	serverErrors := make(chan error, 1)
	go func() {
		buffer := make([]byte, 2048)
		count, client, readError := server.ReadFromUDP(buffer)
		if readError != nil {
			serverErrors <- readError
			return
		}
		first := append([]byte(nil), buffer[:count]...)
		var firstTransaction [12]byte
		copy(firstTransaction[:], first[8:20])
		challenge := stunPacket(0x0113, firstTransaction,
			stunAttribute{kind: attributeErrorCode, value: []byte{0, 0, 4, 1}},
			stunAttribute{kind: attributeRealm, value: []byte("localhost")},
			stunAttribute{kind: attributeNonce, value: []byte("nonce-value")},
		)
		if _, writeError := server.WriteToUDP(challenge, client); writeError != nil {
			serverErrors <- writeError
			return
		}
		count, client, readError = server.ReadFromUDP(buffer)
		if readError != nil {
			serverErrors <- readError
			return
		}
		second := append([]byte(nil), buffer[:count]...)
		var secondTransaction [12]byte
		copy(secondTransaction[:], second[8:20])
		want := authenticatedAllocatePacket(secondTransaction, "1700:opaque", "rest-password", "localhost", []byte("nonce-value"))
		if !bytes.Equal(second, want) {
			serverErrors <- &probeTestError{"authenticated TURN request does not match RFC long-term authentication"}
			return
		}
		address := net.ParseIP("192.0.2.44").To4()
		value := make([]byte, 8)
		value[1] = 1
		binary.BigEndian.PutUint16(value[2:4], 49160^uint16(stunMagic>>16))
		binary.BigEndian.PutUint32(value[4:8], binary.BigEndian.Uint32(address)^stunMagic)
		response := stunPacket(stunAllocateSuccess, secondTransaction,
			stunAttribute{kind: attributeXORRelayedAddress, value: value})
		_, writeError := server.WriteToUDP(response, client)
		serverErrors <- writeError
	}()

	got, err := allocate(server.LocalAddr().String(), credential.Credential{
		Username: "1700:opaque", Credential: "rest-password",
	})
	if err != nil {
		t.Fatal(err)
	}
	if serverError := <-serverErrors; serverError != nil {
		t.Fatal(serverError)
	}
	if got.String() != "192.0.2.44:49160" {
		t.Fatalf("relay = %s", got)
	}
}

type probeTestError struct{ message string }

func (e *probeTestError) Error() string { return e.message }
