package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	ossignal "os/signal"
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
	verifier := auth.NewVerifier(auth.VerifierConfig{Clock: clock})
	pairingStore, registry, closeDatabase := configuredStores(clock)
	defer closeDatabase()

	handler := httpapi.NewRouter(httpapi.Config{
		Clock:      clock,
		Verifier:   verifier,
		Registry:   registry,
		Pairings:   pairingStore,
		Presence:   presence.NewHub(registry),
		Signals:    signal.NewHub(registry),
		PairingTTL: 5 * time.Minute,
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
	}

	shutdownContext, stop := ossignal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
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

func configuredStores(clock func() time.Time) (pairing.Store, *auth.TrustRegistry, func()) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Print("DATABASE_URL is unset; pairing sessions will not survive service restart")
		return pairing.NewMemoryStore(pairing.StoreConfig{Clock: clock}), auth.NewTrustRegistry(), func() {}
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := database.PingContext(ctx); err != nil {
		database.Close()
		log.Fatal(err)
	}
	registry, err := auth.NewPostgresTrustRegistry(ctx, database)
	if err != nil {
		database.Close()
		log.Fatal(err)
	}
	return pairing.NewPostgresStore(database, pairing.StoreConfig{Clock: clock}), registry, func() {
		if err := database.Close(); err != nil {
			log.Printf("close database: %v", err)
		}
	}
}
