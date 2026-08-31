ALTER TABLE pairing_sessions
    ADD COLUMN IF NOT EXISTS encrypted_peer_authorization BYTEA
        CHECK (encrypted_peer_authorization IS NULL
            OR octet_length(encrypted_peer_authorization) BETWEEN 1 AND 65536),
    ADD COLUMN IF NOT EXISTS peer_authorization_committed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS peer_authorization_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS peer_authorization_resolved_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS peer_authorization_accepted BOOLEAN;

CREATE INDEX IF NOT EXISTS pairing_sessions_peer_authorization_expiry_idx
    ON pairing_sessions (peer_authorization_expires_at)
    WHERE peer_authorization_expires_at IS NOT NULL;
