-- Protected Apple credentials and opaque device-bound account sessions.
CREATE TABLE IF NOT EXISTS accounts (
    account_id UUID PRIMARY KEY,
    apple_subject TEXT NOT NULL UNIQUE CHECK (octet_length(apple_subject) BETWEEN 1 AND 255),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deleting')),
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS account_apple_credentials (
    credential_id UUID PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(account_id),
    device_id UUID NOT NULL,
    audience TEXT NOT NULL CHECK (octet_length(audience) BETWEEN 1 AND 255),
    encrypted_refresh BYTEA NOT NULL CHECK (octet_length(encrypted_refresh) BETWEEN 32 AND 20000),
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS account_session_families (
    family_id UUID PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(account_id),
    device_id UUID NOT NULL,
    audience TEXT NOT NULL CHECK (octet_length(audience) BETWEEN 1 AND 255),
    created_at TIMESTAMPTZ NOT NULL,
    absolute_expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    CHECK (absolute_expires_at > created_at),
    CHECK (absolute_expires_at = created_at + INTERVAL '90 days'),
    CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);
CREATE INDEX IF NOT EXISTS account_session_families_binding_idx
    ON account_session_families(account_id, device_id, audience);

CREATE TABLE IF NOT EXISTS account_sessions (
    session_id UUID PRIMARY KEY,
    family_id UUID NOT NULL UNIQUE REFERENCES account_session_families(family_id),
    generation BIGINT NOT NULL CHECK (generation >= 1),
    access_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(access_hash) = 32),
    refresh_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(refresh_hash) = 32),
    created_at TIMESTAMPTZ NOT NULL,
    access_expires_at TIMESTAMPTZ NOT NULL,
    refresh_expires_at TIMESTAMPTZ NOT NULL,
    CHECK (access_expires_at > created_at),
    CHECK (refresh_expires_at > created_at)
);

CREATE TABLE IF NOT EXISTS account_session_refresh_history (
    refresh_hash BYTEA PRIMARY KEY CHECK (octet_length(refresh_hash) = 32),
    family_id UUID NOT NULL REFERENCES account_session_families(family_id),
    consumed_at TIMESTAMPTZ NOT NULL,
    retain_until TIMESTAMPTZ NOT NULL,
    CHECK (retain_until > consumed_at)
);
CREATE INDEX IF NOT EXISTS account_session_refresh_history_family_idx
    ON account_session_refresh_history(family_id);
