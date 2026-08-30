ALTER TABLE pairing_sessions
    ADD COLUMN IF NOT EXISTS authorization_rejected_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS pairing_sessions_authorization_rejected_idx
    ON pairing_sessions (authorization_rejected_at)
    WHERE authorization_rejected_at IS NOT NULL;
