package main

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"macchannel/rendezvous/internal/accountauth"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/auth"
)

var errStartup = errors.New("account service startup failed")

var requiredTables = []string{
	"auth_challenges", "auth_replay_nonces", "account_login_challenges", "accounts",
	"account_apple_credentials", "account_session_families", "account_session_token_issuance",
	"account_sessions", "account_session_refresh_history",
}

func buildService(ctx context.Context, cfg config) (http.Handler, func(), error) {
	database, err := sql.Open("pgx", cfg.databaseDSN)
	if err != nil {
		return nil, nil, errStartup
	}
	closed := false
	closeDatabase := func() {
		if !closed {
			closed = true
			_ = database.Close()
		}
	}
	fail := func() (http.Handler, func(), error) { closeDatabase(); return nil, nil, errStartup }
	database.SetMaxOpenConns(8)
	database.SetMaxIdleConns(8)
	startup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := database.PingContext(startup); err != nil {
		return fail()
	}
	if err := checkSchema(startup, database); err != nil {
		return fail()
	}
	if cfg.groupsEnabled {
		if err := checkTables(startup, database, []string{"account_groups", "account_group_events"}); err != nil {
			return fail()
		}
	}
	audiences := []string{cfg.audience}
	secrets, err := accountauth.NewAppleClientSecrets(cfg.teamID, cfg.keyID, cfg.applePrivateKey, audiences)
	if err != nil {
		return fail()
	}
	challenges, err := accountauth.NewPostgresLoginChallenges(database, audiences)
	if err != nil {
		return fail()
	}
	login, err := accountauth.NewAppleLogin(challenges, secrets, accountauth.NewAppleKeyProvider(), audiences)
	if err != nil {
		return fail()
	}
	protector, err := accountauth.NewAppleCredentialProtector("dev_v1", map[string][]byte{"dev_v1": cfg.credentialKey})
	if err != nil {
		return fail()
	}
	sessions, err := accountauth.NewPostgresSessions(database, protector, audiences)
	if err != nil {
		return fail()
	}
	verifier := auth.NewVerifier(auth.VerifierConfig{ReplayStore: auth.NewPostgresReplayStore(database)})
	httpConfig := accountauth.AccountHTTPConfig{Verifier: verifier, Challenges: challenges, Login: login, Sessions: sessions}
	if cfg.groupsEnabled {
		groups, err := accountgroup.NewPostgresStore(database)
		if err != nil {
			return fail()
		}
		httpConfig.Groups = groups
		httpConfig.Enrollment = groups
	}
	accountHandler, err := accountauth.NewAccountHTTP(httpConfig)
	if err != nil {
		return fail()
	}
	return cfg.ingress.Wrap(newServiceMux(accountHandler, database.PingContext, cfg.groupsEnabled)), closeDatabase, nil
}

func checkSchema(ctx context.Context, database *sql.DB) error {
	return checkTables(ctx, database, requiredTables)
}

func checkTables(ctx context.Context, database *sql.DB, tables []string) error {
	for _, table := range tables {
		var present bool
		if err := database.QueryRowContext(ctx, `SELECT to_regclass($1) IS NOT NULL`, "public."+table).Scan(&present); err != nil || !present {
			return errStartup
		}
	}
	return nil
}

func newServiceMux(account http.Handler, health func(context.Context) error, groupsEnabled bool) http.Handler {
	mux := http.NewServeMux()
	for _, path := range []string{"/v1/account/login/challenge", "/v1/account/login/complete", "/v1/account/session/status", "/v1/account/session/refresh", "/v1/account/session/logout"} {
		mux.Handle(path, account)
	}
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		if health(ctx) != nil {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	registerGroupRoutes(mux, account, groupsEnabled)
	return mux
}

func registerGroupRoutes(mux *http.ServeMux, account http.Handler, enabled bool) {
	if !enabled {
		return
	}
	for _, path := range []string{"/v1/account/group/discover", "/v1/account/group/bootstrap", "/v1/account/group/events"} {
		mux.Handle(path, account)
	}
}

func serveHTTP(ctx context.Context, listener net.Listener, handler http.Handler) error {
	server := newHTTPServer(handler)
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	select {
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
			return err
		}
		err := <-done
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func newHTTPServer(handler http.Handler) *http.Server {
	return &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024, ErrorLog: log.New(io.Discard, "", 0)}
}
