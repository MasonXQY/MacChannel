package ingress

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestConfiguration(t *testing.T) {
	for _, value := range []string{"", "127.0.0.1", "172.19.0.1", "::1", "2001:db8::1"} {
		if _, err := Parse(value); err != nil {
			t.Fatalf("valid %q: %v", value, err)
		}
	}
	for _, value := range []string{"secret.example", "127.0.0.0/8", " 127.0.0.1", "127.0.0.1 ", "127.0.0.1:80", "::", "0.0.0.0", "224.0.0.1", "ff02::1", "fe80::1%en0", "2001:0db8::1", "::ffff:127.0.0.1"} {
		if _, err := Parse(value); err == nil || strings.Contains(err.Error(), value) {
			t.Errorf("invalid %q: %v", value, err)
		}
	}
}

func TestDisabledPreservesRequest(t *testing.T) {
	a, _ := Parse("")
	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set(ClientIPHeader, "garbage")
	a.Wrap(http.HandlerFunc(func(w http.ResponseWriter, got *http.Request) {
		if got != r {
			t.Fatal("disabled adapter changed request")
		}
	})).ServeHTTP(httptest.NewRecorder(), r)
}

func TestTrustedSourceValidation(t *testing.T) {
	for _, tc := range []struct {
		name, proxy, peer string
		values            []string
		want              string
	}{
		{"v4", "127.0.0.1", "127.0.0.1:8765", []string{"198.51.100.7"}, "198.51.100.7:8765"},
		{"v6", "::1", "[::1]:8765", []string{"2001:db8::7"}, "[2001:db8::7]:8765"},
		{"mapped socket", "127.0.0.1", "[::ffff:127.0.0.1]:8765", []string{"198.51.100.7"}, "198.51.100.7:8765"},
		{"untrusted", "127.0.0.1", "127.0.0.2:8765", []string{"198.51.100.7"}, ""},
		{"missing", "127.0.0.1", "127.0.0.1:8765", nil, ""},
		{"duplicate", "127.0.0.1", "127.0.0.1:8765", []string{"198.51.100.7", "198.51.100.7"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, err := Parse(tc.proxy)
			if err != nil {
				t.Fatal(err)
			}
			r := httptest.NewRequest("GET", "https://example.test/path?x=y", nil)
			r.RemoteAddr = tc.peer
			r.Header[http.CanonicalHeaderKey(ClientIPHeader)] = tc.values
			r.Header.Set("Origin", "https://example.test")
			for _, h := range []string{"Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Forwarded-Port", "X-Real-IP"} {
				r.Header.Set(h, "attacker")
			}
			before := r.Clone(r.Context())
			called := false
			w := httptest.NewRecorder()
			a.Wrap(http.HandlerFunc(func(w http.ResponseWriter, got *http.Request) {
				called = true
				if got.RemoteAddr != tc.want {
					t.Errorf("source %q want %q", got.RemoteAddr, tc.want)
				}
				if got.Host != r.Host || got.URL.String() != r.URL.String() || got.Header.Get("Origin") != r.Header.Get("Origin") {
					t.Error("routing/origin changed")
				}
				for h := range got.Header {
					if strings.EqualFold(h, ClientIPHeader) || strings.EqualFold(h, "Forwarded") || strings.HasPrefix(strings.ToLower(h), "x-forwarded-") || strings.EqualFold(h, "X-Real-IP") {
						t.Errorf("retained %s", h)
					}
				}
			})).ServeHTTP(w, r)
			if called != (tc.want != "") || (tc.want == "" && w.Code != 403) {
				t.Errorf("called=%v status=%d", called, w.Code)
			}
			if !reflect.DeepEqual(before.Header, r.Header) || before.RemoteAddr != r.RemoteAddr {
				t.Error("mutated original request")
			}
		})
	}
}

func TestMalformedClientAndPeerRejected(t *testing.T) {
	a, _ := Parse("127.0.0.1")
	for _, value := range []string{"", " 198.51.100.7", "198.51.100.7 ", "198.51.100.7,198.51.100.8", "198.51.100.7:80", "[2001:db8::1]", "2001:0db8::1", "2001:DB8::1", "::ffff:198.51.100.7", "fe80::1%en0", "0.0.0.0", "::", "224.0.0.1", "ff02::1", "localhost"} {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = "127.0.0.1:80"
		r.Header.Set(ClientIPHeader, value)
		w := httptest.NewRecorder()
		a.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Errorf("accepted %q", value) })).ServeHTTP(w, r)
		if w.Code != 403 {
			t.Errorf("%q status %d", value, w.Code)
		}
	}
	for _, peer := range []string{"127.0.0.1", "localhost:80", "[::1%en0]:80", "bad"} {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = peer
		r.Header.Set(ClientIPHeader, "198.51.100.7")
		a.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Errorf("accepted peer %q", peer) })).ServeHTTP(httptest.NewRecorder(), r)
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "127.0.0.1:80"
	r.Header[ClientIPHeader] = []string{"198.51.100.7"}
	r.Header[strings.ToLower(ClientIPHeader)] = []string{"198.51.100.8"}
	a.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("accepted mixed case duplicate") })).ServeHTTP(httptest.NewRecorder(), r)
}

func TestWebSocketUpgradeKeepsHijacker(t *testing.T) {
	a, _ := Parse("127.0.0.1")
	s := httptest.NewServer(a.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := websocket.Upgrader{}
		c, err := u.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		if err := c.WriteMessage(websocket.TextMessage, []byte(r.RemoteAddr)); err != nil {
			t.Error(err)
		}
	})))
	defer s.Close()
	h := http.Header{}
	h.Set(ClientIPHeader, "2001:db8::7")
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(s.URL, "http"), h)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, message, err := c.ReadMessage()
	if err != nil || !strings.HasPrefix(string(message), "[2001:db8::7]:") {
		t.Fatalf("message=%q err=%v", message, err)
	}
}
