package main

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"macchannel/rendezvous/internal/accountauth"
	"macchannel/rendezvous/internal/accountgroup"
	"macchannel/rendezvous/internal/accountinvite"
	"macchannel/rendezvous/internal/auth"
	"macchannel/rendezvous/internal/httpapi"
	"macchannel/rendezvous/internal/presence"
	"macchannel/rendezvous/internal/routeauth"
	"macchannel/rendezvous/internal/signal"
)

var errStartup = errors.New("account service startup failed")

var requiredTables = []string{
	"auth_challenges", "auth_replay_nonces", "account_login_challenges", "accounts",
	"account_apple_credentials", "account_session_families", "account_session_token_issuance",
	"account_sessions", "account_session_refresh_history",
}

var groupTables = []string{"account_groups", "account_group_events", "account_group_pending"}
var invitationTables = []string{"account_invitation_link_issuance", "account_invitation_links", "account_invitation_blocks", "account_invitations"}
var deletionTables = []string{"account_deletions", "account_apple_exchanges"}

func buildService(ctx context.Context, cfg config) (http.Handler, func(), error) {
	database, err := sql.Open("pgx", cfg.databaseDSN)
	if err != nil {
		return nil, nil, errStartup
	}
	var closeOnce sync.Once
	var routes *routeauth.ConnectionRouter
	var stopDeletion context.CancelFunc
	var deletionDone chan struct{}
	closeDatabase := func() {
		closeOnce.Do(func() {
			if stopDeletion != nil {
				stopDeletion()
				<-deletionDone
			}
			if routes != nil {
				routes.Shutdown()
			}
			_ = database.Close()
		})
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
	if err := checkTablePrivileges(startup, database, requiredTables); err != nil {
		return fail()
	}
	if cfg.groupsEnabled {
		if err := checkTables(startup, database, groupTables); err != nil {
			return fail()
		}
		if err := checkTablePrivileges(startup, database, groupTables); err != nil {
			return fail()
		}
	}
	audiences := append([]string(nil), cfg.audiences...)
	if len(audiences) == 0 {
		audiences = []string{cfg.audience}
	}
	if cfg.invitationsEnabled {
		if !cfg.groupsEnabled || !validInvitationOrigin(cfg.origin) || checkTables(startup, database, invitationTables) != nil || checkTablePrivileges(startup, database, invitationTables) != nil {
			return fail()
		}
	}
	if cfg.deletionEnabled {
		if !cfg.groupsEnabled || checkTables(startup, database, deletionTables) != nil || checkTablePrivileges(startup, database, deletionTables) != nil {
			return fail()
		}
	}
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
	if cfg.webLoginEnabled {
		webLogin, webErr := accountauth.NewWebLoginBroker(challenges, login, sessions, cfg.origin, audiences)
		if webErr != nil {
			return fail()
		}
		httpConfig.WebLogin = webLogin
	}
	var deletion *accountauth.PostgresDeletion
	if cfg.deletionEnabled {
		revoker, revokerErr := accountauth.NewAppleRevoker(secrets, audiences)
		if revokerErr != nil {
			return fail()
		}
		deletion, err = accountauth.NewPostgresDeletion(database, protector, login, revoker, audiences)
		if err != nil {
			return fail()
		}
		httpConfig.Deletion = deletion
	}
	var groups *accountgroup.PostgresStore
	if cfg.groupsEnabled {
		groups, err = accountgroup.NewPostgresStore(database)
		if err != nil {
			return fail()
		}
		httpConfig.Groups = groups
		httpConfig.Enrollment = groups
		httpConfig.Pending = groups
	}
	if cfg.transferEnabled {
		if groups == nil {
			return fail()
		}
		httpConfig.TURN = &accountauth.AccountTURNConfig{Issuer: groups, SharedSecret: cfg.turnSecret, URLs: cfg.turnURLs}
	}
	if cfg.invitationsEnabled {
		invitations, invitationError := accountinvite.NewPostgresStore(database, audiences, cfg.origin)
		if invitationError != nil {
			return fail()
		}
		httpConfig.Invitations = invitations
	}
	accountHandler, err := accountauth.NewAccountHTTP(httpConfig)
	if err != nil {
		return fail()
	}
	var transfer http.Handler
	if cfg.transferEnabled {
		graph := accountOnlyGraph{}
		hub := presence.NewHub(graph)
		routes, err = routeauth.NewCompositeConnectionRouterWithPresence(16, graph, routeauth.NewPostgresAccountGate(groups), routeauth.AccountPresenceConfig{
			Hub: hub, Projection: groups, CandidatesPerTurn: 8, WorkTimeout: 5 * time.Second, RefreshInterval: 30 * time.Second,
		})
		if err != nil {
			return fail()
		}
		transfer = httpapi.NewRouter(httpapi.Config{Verifier: verifier, Presence: hub, Signals: signal.NewHub(graph),
			AccountRoutes: &httpapi.AccountRouteConfig{Routes: routes, Sessions: sessions},
		})
	}
	if deletion != nil {
		var workerContext context.Context
		workerContext, stopDeletion = context.WithCancel(ctx)
		deletionDone = make(chan struct{})
		go func() { defer close(deletionDone); _ = deletion.Run(workerContext) }()
	}
	return cfg.ingress.Wrap(newServiceMuxWithWebLogin(accountHandler, database.PingContext, cfg.groupsEnabled,
		transfer, cfg.deletionEnabled, cfg.invitationsEnabled, cfg.webLoginEnabled)), closeDatabase, nil
}

// Candidate trust is exclusively checked by SQL route admission. Uploaded
// manual proofs cannot authorize this plane, even when identity auth accepts them.
type accountOnlyGraph struct{}

func (accountOnlyGraph) ShareGraph(string, string) bool { return false }
func (accountOnlyGraph) DevicesInGraph(string) []string { return nil }

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

func checkTablePrivileges(ctx context.Context, database *sql.DB, tables []string) error {
	for _, table := range tables {
		var allowed bool
		if err := database.QueryRowContext(ctx,
			`SELECT has_table_privilege(current_user, $1, 'SELECT, INSERT, UPDATE, DELETE')`,
			"public."+table).Scan(&allowed); err != nil || !allowed {
			return errStartup
		}
	}
	return nil
}

func newServiceMux(account http.Handler, health func(context.Context) error, groupsEnabled bool) http.Handler {
	return newServiceMuxWithTransfer(account, health, groupsEnabled, nil)
}

func newServiceMuxWithTransfer(account http.Handler, health func(context.Context) error, groupsEnabled bool, transfer http.Handler) http.Handler {
	return newServiceMuxWithCapabilities(account, health, groupsEnabled, transfer, false)
}

func newServiceMuxWithCapabilities(account http.Handler, health func(context.Context) error, groupsEnabled bool, transfer http.Handler, deletionEnabled bool) http.Handler {
	return newServiceMuxWithInvitations(account, health, groupsEnabled, transfer, deletionEnabled, false)
}

func newServiceMuxWithInvitations(account http.Handler, health func(context.Context) error, groupsEnabled bool, transfer http.Handler, deletionEnabled, invitationsEnabled bool) http.Handler {
	return newServiceMuxWithWebLogin(account, health, groupsEnabled, transfer, deletionEnabled, invitationsEnabled, false)
}

func newServiceMuxWithWebLogin(account http.Handler, health func(context.Context) error, groupsEnabled bool, transfer http.Handler, deletionEnabled, invitationsEnabled, webLoginEnabled bool) http.Handler {
	mux := http.NewServeMux()
	if webLoginEnabled {
		for _, path := range []string{"/v1/account/login/web/start", "/v1/account/login/web/result", "/v1/account/login/web/callback"} {
			mux.Handle(path, account)
		}
	}
	if invitationsEnabled && groupsEnabled {
		for _, operation := range []string{"link/get", "link/rotate", "request", "get", "inbox", "outbox", "select", "countersign", "commit", "reject", "cancel", "revoke", "block"} {
			mux.Handle("/v1/account/invitation/"+operation, account)
		}
	}
	if deletionEnabled {
		mux.Handle("/v1/account/deletion/begin", account)
		mux.Handle("/v1/account/deletion/status", account)
		mux.Handle("/v1/account/deletion/recover", account)
	}
	if transfer != nil {
		mux.Handle("/v1/ws", transfer)
		mux.Handle("/v1/account/turn-credentials", account)
	}
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
	for _, op := range []string{"create", "get", "list", "propose", "countersign", "commit", "cancel", "reject"} {
		mux.Handle("/v1/account/group/join/"+op, account)
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
