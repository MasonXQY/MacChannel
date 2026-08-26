package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
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
	clock := time.Now
	pairingStore, registry, verifier, closeDatabase, err := configuredStores(clock)
	if err != nil {
		log.Fatal(err)
	}
	defer closeDatabase()

	handler := httpapi.NewRouter(httpapi.Config{
		Clock:                   clock,
		Verifier:                verifier,
		Registry:                registry,
		Pairings:                pairingStore,
		Presence:                presence.NewHub(registry),
		Signals:                 signal.NewHub(registry),
		PairingTTL:              5 * time.Minute,
		AllowedWebSocketOrigins: splitCommaSeparated(os.Getenv("MACCHANNEL_ALLOWED_WS_ORIGINS")),
	})
	address := os.Getenv("RENDEZVOUS_ADDR")
	if address == "" {
		address = ":8080"
	}
	server := &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}

	shutdownContext, stop := ossignal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go cleanupExpired(shutdownContext, pairingStore, registry, verifier, clock, time.Minute)
	go func() {
		<-shutdownContext.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			log.Printf("rendezvous shutdown: %v", err)
		}
	}()

	log.Printf("rendezvous listening on %s", address)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
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
	databaseURL := os.Getenv("DATABASE_URL")
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
