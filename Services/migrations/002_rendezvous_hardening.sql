BEGIN;

-- Sessions created by the pre-hardening service do not identify their host and
-- cannot safely participate in the authenticated two-party protocol. Clear only
-- on that one-way upgrade; reapplying this migration must not erase new sessions.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'pairing_sessions'
          AND column_name = 'host_device_id'
    ) THEN
        TRUNCATE pairing_sessions;
    END IF;
END
$$;

ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS session_id UUID;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS host_device_id UUID;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS joiner_device_id UUID;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS encrypted_join_payload BYTEA
    CHECK (encrypted_join_payload IS NULL OR octet_length(encrypted_join_payload) BETWEEN 1 AND 65536);
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS session_expires_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS removed_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS encrypted_join_response BYTEA
    CHECK (encrypted_join_response IS NULL OR octet_length(encrypted_join_response) BETWEEN 1 AND 65536);
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS join_response_committed_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_reservation_id UUID;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_canceled_reservation_id UUID;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_reserved_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_reservation_expires_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS encrypted_authorization BYTEA
    CHECK (encrypted_authorization IS NULL OR octet_length(encrypted_authorization) BETWEEN 1 AND 65536);
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_committed_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_retrieved_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_expires_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ALTER COLUMN host_device_id SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS pairing_sessions_session_id_idx ON pairing_sessions (session_id)
    WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pairing_sessions_authorization_expiry_idx ON pairing_sessions (authorization_expires_at)
    WHERE authorization_expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS pairing_sessions_session_expiry_idx ON pairing_sessions (session_expires_at)
    WHERE session_expires_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS pairing_creation_events (
    source_hash CHAR(64) NOT NULL,
    device_id UUID NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS pairing_creation_events_source_idx ON pairing_creation_events (source_hash, occurred_at);
CREATE INDEX IF NOT EXISTS pairing_creation_events_device_idx ON pairing_creation_events (device_id, occurred_at);

CREATE TABLE IF NOT EXISTS pairing_attempt_failures (
    source_hash CHAR(64) NOT NULL,
    code_hash BYTEA NOT NULL CHECK (octet_length(code_hash) = 32),
    device_id UUID NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS pairing_attempt_failures_source_idx ON pairing_attempt_failures (source_hash, occurred_at);
CREATE INDEX IF NOT EXISTS pairing_attempt_failures_code_idx ON pairing_attempt_failures (code_hash, occurred_at);
CREATE INDEX IF NOT EXISTS pairing_attempt_failures_device_idx ON pairing_attempt_failures (device_id, occurred_at);

CREATE TABLE IF NOT EXISTS pairing_attempt_reservations (
    reservation_id UUID PRIMARY KEY,
    source_hash CHAR(64) NOT NULL,
    code_hash BYTEA NOT NULL CHECK (octet_length(code_hash) = 32),
    device_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS pairing_attempt_reservations_source_idx ON pairing_attempt_reservations (source_hash, expires_at);
CREATE INDEX IF NOT EXISTS pairing_attempt_reservations_code_idx ON pairing_attempt_reservations (code_hash, expires_at);
CREATE INDEX IF NOT EXISTS pairing_attempt_reservations_device_idx ON pairing_attempt_reservations (device_id, expires_at);

CREATE TABLE IF NOT EXISTS auth_challenges (
    challenge_hash CHAR(64) PRIMARY KEY,
    source_hash CHAR(64) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS auth_challenges_source_idx ON auth_challenges (source_hash, expires_at);
CREATE INDEX IF NOT EXISTS auth_challenges_expiry_idx ON auth_challenges (expires_at);

CREATE TABLE IF NOT EXISTS auth_replay_nonces (
    nonce_hash CHAR(64) PRIMARY KEY,
    source_hash CHAR(64) NOT NULL,
    device_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS auth_replay_nonces_source_idx ON auth_replay_nonces (source_hash, expires_at);
CREATE INDEX IF NOT EXISTS auth_replay_nonces_device_idx ON auth_replay_nonces (device_id, expires_at);
CREATE INDEX IF NOT EXISTS auth_replay_nonces_expiry_idx ON auth_replay_nonces (expires_at);

COMMIT;
