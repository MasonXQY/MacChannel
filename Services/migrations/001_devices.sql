BEGIN;

CREATE TABLE pairing_sessions (
    code_hash BYTEA PRIMARY KEY CHECK (octet_length(code_hash) = 32),
    session_id UUID,
    host_device_id UUID NOT NULL,
    joiner_device_id UUID,
    encrypted_session_payload BYTEA NOT NULL CHECK (octet_length(encrypted_session_payload) BETWEEN 1 AND 65536),
    encrypted_join_payload BYTEA CHECK (encrypted_join_payload IS NULL OR octet_length(encrypted_join_payload) BETWEEN 1 AND 65536),
    expires_at TIMESTAMPTZ NOT NULL,
    session_expires_at TIMESTAMPTZ,
    consumed_at TIMESTAMPTZ,
    removed_at TIMESTAMPTZ,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0 AND attempt_count <= 20),
    encrypted_join_response BYTEA CHECK (encrypted_join_response IS NULL OR octet_length(encrypted_join_response) BETWEEN 1 AND 65536),
    join_response_committed_at TIMESTAMPTZ,
    authorization_reservation_id UUID,
    authorization_canceled_reservation_id UUID,
    authorization_reserved_at TIMESTAMPTZ,
    authorization_reservation_expires_at TIMESTAMPTZ,
    encrypted_authorization BYTEA CHECK (encrypted_authorization IS NULL OR octet_length(encrypted_authorization) BETWEEN 1 AND 65536),
    authorization_committed_at TIMESTAMPTZ,
    authorization_retrieved_at TIMESTAMPTZ,
    authorization_expires_at TIMESTAMPTZ
);

CREATE INDEX pairing_sessions_expiry_idx ON pairing_sessions (expires_at);
CREATE INDEX pairing_sessions_session_expiry_idx ON pairing_sessions (session_expires_at)
    WHERE session_expires_at IS NOT NULL;
CREATE UNIQUE INDEX pairing_sessions_session_id_idx ON pairing_sessions (session_id)
    WHERE session_id IS NOT NULL;
CREATE INDEX pairing_sessions_authorization_expiry_idx ON pairing_sessions (authorization_expires_at)
    WHERE authorization_expires_at IS NOT NULL;

CREATE TABLE pairing_creation_events (
    source_hash CHAR(64) NOT NULL,
    device_id UUID NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX pairing_creation_events_source_idx ON pairing_creation_events (source_hash, occurred_at);
CREATE INDEX pairing_creation_events_device_idx ON pairing_creation_events (device_id, occurred_at);

CREATE TABLE pairing_attempt_failures (
    source_hash CHAR(64) NOT NULL,
    code_hash BYTEA NOT NULL CHECK (octet_length(code_hash) = 32),
    device_id UUID NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX pairing_attempt_failures_source_idx ON pairing_attempt_failures (source_hash, occurred_at);
CREATE INDEX pairing_attempt_failures_code_idx ON pairing_attempt_failures (code_hash, occurred_at);
CREATE INDEX pairing_attempt_failures_device_idx ON pairing_attempt_failures (device_id, occurred_at);

CREATE TABLE pairing_attempt_reservations (
    reservation_id UUID PRIMARY KEY,
    source_hash CHAR(64) NOT NULL,
    code_hash BYTEA NOT NULL CHECK (octet_length(code_hash) = 32),
    device_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX pairing_attempt_reservations_source_idx ON pairing_attempt_reservations (source_hash, expires_at);
CREATE INDEX pairing_attempt_reservations_code_idx ON pairing_attempt_reservations (code_hash, expires_at);
CREATE INDEX pairing_attempt_reservations_device_idx ON pairing_attempt_reservations (device_id, expires_at);

CREATE TABLE auth_challenges (
    challenge_hash CHAR(64) PRIMARY KEY,
    source_hash CHAR(64) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX auth_challenges_source_idx ON auth_challenges (source_hash, expires_at);
CREATE INDEX auth_challenges_expiry_idx ON auth_challenges (expires_at);

CREATE TABLE auth_replay_nonces (
    nonce_hash CHAR(64) PRIMARY KEY,
    source_hash CHAR(64) NOT NULL,
    device_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX auth_replay_nonces_source_idx ON auth_replay_nonces (source_hash, expires_at);
CREATE INDEX auth_replay_nonces_device_idx ON auth_replay_nonces (device_id, expires_at);
CREATE INDEX auth_replay_nonces_expiry_idx ON auth_replay_nonces (expires_at);

CREATE TABLE device_authorizations (
    record_hash BYTEA PRIMARY KEY CHECK (octet_length(record_hash) = 32),
    issuer_device_id UUID NOT NULL,
    subject_device_id UUID NOT NULL,
    issuer_sequence NUMERIC(20, 0) NOT NULL CHECK (issuer_sequence >= 0),
    signed_record BYTEA NOT NULL,
    issuer_confirmed_at TIMESTAMPTZ,
    subject_confirmed_at TIMESTAMPTZ,
    UNIQUE (issuer_device_id, issuer_sequence)
);

CREATE INDEX device_authorizations_subject_idx ON device_authorizations (subject_device_id);

CREATE TABLE device_revocations (
    record_hash BYTEA PRIMARY KEY CHECK (octet_length(record_hash) = 32),
    issuer_device_id UUID NOT NULL,
    subject_device_id UUID NOT NULL,
    issuer_sequence NUMERIC(20, 0) NOT NULL CHECK (issuer_sequence >= 0),
    signed_record BYTEA NOT NULL,
    issuer_confirmed_at TIMESTAMPTZ,
    subject_confirmed_at TIMESTAMPTZ,
    UNIQUE (issuer_device_id, issuer_sequence)
);

CREATE INDEX device_revocations_subject_idx ON device_revocations (subject_device_id);


CREATE SEQUENCE trust_event_order_seq;

CREATE TABLE trust_issuer_states (
    issuer_device_id UUID PRIMARY KEY,
    high_water NUMERIC(20, 0) NOT NULL CHECK (high_water >= 0),
    rate_window_started_at TIMESTAMPTZ NOT NULL,
    rate_window_updates INTEGER NOT NULL CHECK (rate_window_updates >= 0)
);

CREATE TABLE trust_pair_states (
    issuer_device_id UUID NOT NULL,
    subject_device_id UUID NOT NULL,
    record_hash BYTEA NOT NULL CHECK (octet_length(record_hash) = 32),
    issuer_sequence NUMERIC(20, 0) NOT NULL CHECK (issuer_sequence >= 0),
    action TEXT NOT NULL CHECK (action IN ('authorize', 'revoke')),
    signed_record BYTEA NOT NULL,
    issuer_confirmed BOOLEAN NOT NULL,
    subject_confirmed BOOLEAN NOT NULL,
    accepted_order BIGINT NOT NULL CHECK (accepted_order > 0),
    revocation_order BIGINT NOT NULL DEFAULT 0 CHECK (revocation_order >= 0),
    PRIMARY KEY (issuer_device_id, subject_device_id),
    UNIQUE (record_hash)
);

CREATE INDEX trust_pair_states_subject_idx ON trust_pair_states (subject_device_id);

CREATE TABLE trust_state_version (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    version BIGINT NOT NULL CHECK (version >= 0)
);

INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0);


COMMIT;
