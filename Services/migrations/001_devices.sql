BEGIN;

CREATE TABLE pairing_sessions (
    code_hash BYTEA PRIMARY KEY CHECK (octet_length(code_hash) = 32),
    encrypted_session_payload BYTEA NOT NULL CHECK (octet_length(encrypted_session_payload) BETWEEN 1 AND 65536),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0 AND attempt_count <= 20)
);

CREATE INDEX pairing_sessions_expiry_idx ON pairing_sessions (expires_at);

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

COMMIT;
