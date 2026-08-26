BEGIN;

ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS session_expires_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS removed_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS encrypted_join_response BYTEA
    CHECK (encrypted_join_response IS NULL OR octet_length(encrypted_join_response) BETWEEN 1 AND 65536);
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS join_response_committed_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_reservation_expires_at TIMESTAMPTZ;
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS authorization_canceled_reservation_id UUID;

CREATE INDEX IF NOT EXISTS pairing_sessions_session_expiry_idx ON pairing_sessions (session_expires_at)
    WHERE session_expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS pairing_sessions_reservation_expiry_idx ON pairing_sessions (authorization_reservation_expires_at)
    WHERE authorization_reservation_expires_at IS NOT NULL;

COMMIT;
