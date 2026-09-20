-- Original session IDs are historical consent bindings, deliberately not FKs:
-- session rotation must invalidate consent, never block refresh or cascade it.
CREATE TABLE IF NOT EXISTS account_group_pending (
 request_id UUID PRIMARY KEY,
 account_id UUID NOT NULL REFERENCES accounts(account_id),
 group_id UUID NOT NULL,
 generation BIGINT NOT NULL CHECK (generation > 0),
 subject_device UUID NOT NULL,
 subject_key BYTEA NOT NULL CHECK (octet_length(subject_key) IN (64,65)),
 subject_session UUID NOT NULL,
 subject_audience TEXT NOT NULL CHECK (octet_length(subject_audience) BETWEEN 1 AND 255),
 created_at TIMESTAMPTZ NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 status TEXT NOT NULL CHECK (status IN ('requested','proposed','countersigned','committed','rejected','cancelled','expired','invalidated')),
 actor_session UUID,
 actor_device UUID,
 actor_audience TEXT CHECK (octet_length(actor_audience) BETWEEN 1 AND 255),
 draft_data BYTEA CHECK (octet_length(draft_data) BETWEEN 1 AND 8192),
 event_data BYTEA CHECK (octet_length(event_data) BETWEEN 1 AND 8192),
 payload_digest BYTEA CHECK (octet_length(payload_digest)=32),
 CHECK (expires_at=created_at+interval '5 minutes'),
 CHECK ((actor_session IS NULL AND actor_device IS NULL AND actor_audience IS NULL AND draft_data IS NULL AND payload_digest IS NULL) OR
        (actor_session IS NOT NULL AND actor_device IS NOT NULL AND actor_audience IS NOT NULL AND draft_data IS NOT NULL AND payload_digest IS NOT NULL)),
 CHECK (status NOT IN ('proposed','countersigned','committed') OR draft_data IS NOT NULL),
 CHECK (status NOT IN ('countersigned','committed') OR event_data IS NOT NULL),
 CHECK (event_data IS NULL OR draft_data IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS account_group_pending_active_idx ON account_group_pending(account_id,status,expires_at);
CREATE INDEX IF NOT EXISTS account_group_pending_created_idx ON account_group_pending(account_id,created_at);
