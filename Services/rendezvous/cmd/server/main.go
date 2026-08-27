package main

import (
	"context"
	"crypto/tls"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	ossignal "os/signal"
	"strings"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/httpapi"
	"macchannel/rendezvous/internal/pairing"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/signal"
)

func main() {
	if err := run(); err != nil {
		log.Printf("rendezvous stopped: %v", err)
		os.Exit(1)
	}
}

func run() error {
	clock := time.Now
	pairingStore, registry, verifier, closeDatabase, err := configuredStores(clock)
	if err != nil {
		return err
	}
	defer closeDatabase()
	turnSecret, turnURLs, err := configuredTURN()
	if err != nil {
		return err
	}
	listeners, err := configuredListeners()
	if err != nil {
		return err
	}

	handler := httpapi.NewRouter(httpapi.Config{
		Clock:                   clock,
		Verifier:                verifier,
		Registry:                registry,
		Pairings:                pairingStore,
		Presence:                presence.NewHub(registry),
		Signals:                 signal.NewHub(registry),
		PairingTTL:              5 * time.Minute,
		AllowedWebSocketOrigins: splitCommaSeparated(os.Getenv("MACCHANNEL_ALLOWED_WS_ORIGINS")),
		TURNSharedSecret:        turnSecret,
		TURNURLs:                turnURLs,
	})
	servers := []configuredServer{{server: hardenedHTTPServer(listeners.HTTPAddress, handler)}}
	if listeners.TLSAddress != "" {
		servers = append(servers, configuredServer{
			server: hardenedHTTPServer(listeners.TLSAddress, handler),
			cert:   listeners.TLSCertFile,
			key:    listeners.TLSKeyFile,
		})
	}

	shutdownContext, stop := ossignal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go cleanupExpired(shutdownContext, pairingStore, registry, verifier, clock, time.Minute)
	for _, configured := range servers {
		scheme := "http"
		if configured.cert != "" {
			scheme = "https"
		}
		log.Printf("rendezvous listening on %s://%s", scheme, configured.server.Addr)
	}
	return serve(shutdownContext, servers)
}

type configuredServer struct {
	server *http.Server
	cert   string
	key    string
}

type activeServer struct {
	server   *http.Server
	listener net.Listener
}

func hardenedHTTPServer(address string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
}

func serve(ctx context.Context, servers []configuredServer) error {
	active := make([]activeServer, 0, len(servers))
	for _, configured := range servers {
		listener, err := net.Listen("tcp", configured.server.Addr)
		if err != nil {
			closeListeners(active)
			return err
		}
		if configured.cert != "" {
			certificate, err := tls.LoadX509KeyPair(configured.cert, configured.key)
			if err != nil {
				_ = listener.Close()
				closeListeners(active)
				return err
			}
			listener = tls.NewListener(listener, &tls.Config{
				Certificates: []tls.Certificate{certificate},
				MinVersion:   tls.VersionTLS12,
			})
		}
		active = append(active, activeServer{server: configured.server, listener: listener})
	}

	results := make(chan error, len(servers))
	for _, running := range active {
		go func(item activeServer) {
			err := item.server.Serve(item.listener)
			if errors.Is(err, http.ErrServerClosed) {
				err = nil
			}
			results <- err
		}(running)
	}

	completed := 0
	var firstError error
	select {
	case firstError = <-results:
		completed++
	case <-ctx.Done():
	}
	shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	shutdownResults := make(chan error, len(servers))
	for _, configured := range servers {
		go func(server *http.Server) {
			err := server.Shutdown(shutdownContext)
			if err != nil {
				_ = server.Close()
			}
			shutdownResults <- err
		}(configured.server)
	}
	for range servers {
		if err := <-shutdownResults; err != nil && firstError == nil {
			firstError = fmt.Errorf("rendezvous shutdown: %w", err)
		}
	}
	for completed < len(servers) {
		if err := <-results; err != nil && firstError == nil {
			firstError = err
		}
		completed++
	}
	return firstError
}

func closeListeners(servers []activeServer) {
	for _, item := range servers {
		_ = item.listener.Close()
	}
}

func cleanupExpired(ctx context.Context, pairings pairing.Store, registry *auth.TrustRegistry, verifier *auth.Verifier, clock func() time.Time, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			cleanupContext, cancel := context.WithTimeout(ctx, 10*time.Second)
			now := clock()
			if err := pairings.Cleanup(cleanupContext, now); err != nil {
				log.Printf("rendezvous pairing cleanup: %v", err)
			}
			if err := registry.Cleanup(cleanupContext, now); err != nil {
				log.Printf("rendezvous trust cleanup: %v", err)
			}
			if err := verifier.Cleanup(cleanupContext, now); err != nil {
				log.Printf("rendezvous authentication cleanup: %v", err)
			}
			cancel()
		case <-ctx.Done():
			return
		}
	}
}

func splitCommaSeparated(value string) []string {
	var result []string
	for _, item := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(item); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

func configuredStores(clock func() time.Time) (pairing.Store, *auth.TrustRegistry, *auth.Verifier, func(), error) {
	databaseURL, err := configuredDatabaseURL()
	if err != nil {
		return nil, nil, nil, nil, err
	}
	if databaseURL == "" {
		if os.Getenv("MACCHANNEL_DEV_IN_MEMORY") != "true" {
			return nil, nil, nil, nil, errors.New("DATABASE_URL is required unless MACCHANNEL_DEV_IN_MEMORY=true")
		}
		log.Print("rendezvous storage mode: explicit development in-memory (non-durable)")
		return pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock}), auth.NewTrustRegistry(),
			auth.NewVerifier(auth.VerifierConfig{Clock: clock}), func() {}, nil
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := database.PingContext(ctx); err != nil {
		database.Close()
		return nil, nil, nil, nil, err
	}
	registry, err := auth.NewPostgresTrustRegistry(ctx, database)
	if err != nil {
		database.Close()
		return nil, nil, nil, nil, err
	}
	log.Print("rendezvous storage mode: PostgreSQL durable")
	return pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock}), registry,
		auth.NewVerifier(auth.VerifierConfig{Clock: clock, ReplayStore: auth.NewPostgresReplayStore(database)}), func() {
			if err := database.Close(); err != nil {
				log.Printf("close database: %v", err)
			}
		}, nil
}
