// Package ingress restores source addresses from one explicitly trusted proxy.
package ingress

import (
	"errors"
	"net"
	"net/http"
	"net/netip"
	"strings"
)

const ClientIPHeader = "X-DropMesh-Client-IP"

// Adapter's zero value leaves direct requests unchanged.
type Adapter struct{ peer netip.Addr }

// Parse accepts an empty (disabled) setting or one canonical unzoned IP.
func Parse(value string) (Adapter, error) {
	if value == "" {
		return Adapter{}, nil
	}
	ip, ok := canonicalIP(value)
	if !ok {
		return Adapter{}, errors.New("invalid trusted ingress configuration")
	}
	return Adapter{peer: ip}, nil
}

func canonicalIP(value string) (netip.Addr, bool) {
	ip, err := netip.ParseAddr(value)
	return ip, err == nil && ip.Zone() == "" && !ip.Is4In6() && !ip.IsUnspecified() && !ip.IsMulticast() && ip.String() == value
}

func (a Adapter) Wrap(next http.Handler) http.Handler {
	if !a.peer.IsValid() {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		peer, err := netip.ParseAddrPort(r.RemoteAddr)
		if err != nil || peer.Addr().Zone() != "" || peer.Addr().Unmap() != a.peer {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		var values []string
		for key, entries := range r.Header {
			if strings.EqualFold(key, ClientIPHeader) {
				values = append(values, entries...)
			}
		}
		if len(values) != 1 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		client, ok := canonicalIP(values[0])
		if !ok {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		forwarded := r.Clone(r.Context())
		_, port, _ := net.SplitHostPort(r.RemoteAddr)
		forwarded.RemoteAddr = net.JoinHostPort(client.String(), port)
		for key := range forwarded.Header {
			lower := strings.ToLower(key)
			if strings.EqualFold(key, ClientIPHeader) || lower == "forwarded" || strings.HasPrefix(lower, "x-forwarded-") || lower == "x-real-ip" {
				delete(forwarded.Header, key)
			}
		}
		next.ServeHTTP(w, forwarded)
	})
}
