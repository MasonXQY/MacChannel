-- Standalone pre-account login bindings. Possession of device_id is established
-- by the future authenticated caller, so account membership is not required.
CREATE TABLE IF NOT EXISTS account_login_challenges (
    challenge_hash BYTEA PRIMARY KEY CHECK (octet_length(challenge_hash) = 32),
    device_id UUID NOT NULL,
    audience TEXT NOT NULL CHECK (octet_length(audience) BETWEEN 1 AND 255),
    nonce BYTEA NOT NULL CHECK (octet_length(nonce) = 32),
    created_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    CHECK (expires_at > created_at),
    CHECK (expires_at = created_at + INTERVAL '5 minutes')
);

CREATE INDEX IF NOT EXISTS account_login_challenges_device_id_idx
    ON account_login_challenges (device_id);
CREATE INDEX IF NOT EXISTS account_login_challenges_expires_at_idx
    ON account_login_challenges (expires_at);
