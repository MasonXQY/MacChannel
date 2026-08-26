BEGIN;

CREATE SEQUENCE IF NOT EXISTS trust_event_order_seq;

CREATE TABLE IF NOT EXISTS trust_issuer_states (
    issuer_device_id UUID PRIMARY KEY,
    high_water NUMERIC(20, 0) NOT NULL CHECK (high_water >= 0),
    rate_window_started_at TIMESTAMPTZ NOT NULL,
    rate_window_updates INTEGER NOT NULL CHECK (rate_window_updates >= 0)
);

CREATE TABLE IF NOT EXISTS trust_pair_states (
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

CREATE INDEX IF NOT EXISTS trust_pair_states_subject_idx ON trust_pair_states (subject_device_id);

ALTER TABLE trust_pair_states
    ADD COLUMN IF NOT EXISTS revocation_order BIGINT NOT NULL DEFAULT 0 CHECK (revocation_order >= 0);

CREATE TABLE IF NOT EXISTS trust_state_version (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    version BIGINT NOT NULL CHECK (version >= 0)
);

INSERT INTO trust_state_version (singleton, version) VALUES (TRUE, 0)
ON CONFLICT (singleton) DO NOTHING;

WITH historical AS (
    SELECT record_hash, issuer_device_id, subject_device_id, issuer_sequence,
           'authorize'::TEXT AS action, signed_record,
           issuer_confirmed_at IS NOT NULL AS issuer_confirmed,
           subject_confirmed_at IS NOT NULL AS subject_confirmed,
           GREATEST(issuer_confirmed_at, subject_confirmed_at) AS observed_at
    FROM device_authorizations
    UNION ALL
    SELECT record_hash, issuer_device_id, subject_device_id, issuer_sequence,
           'revoke'::TEXT AS action, signed_record,
           issuer_confirmed_at IS NOT NULL AS issuer_confirmed,
           FALSE AS subject_confirmed,
           issuer_confirmed_at AS observed_at
    FROM device_revocations
), latest AS (
    SELECT DISTINCT ON (issuer_device_id, subject_device_id) *
    FROM historical
    ORDER BY issuer_device_id, subject_device_id, issuer_sequence DESC
), ordered AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY observed_at NULLS FIRST, issuer_device_id, issuer_sequence) AS event_order
    FROM latest
)
INSERT INTO trust_pair_states (issuer_device_id, subject_device_id, record_hash, issuer_sequence,
    action, signed_record, issuer_confirmed, subject_confirmed, accepted_order, revocation_order)
SELECT issuer_device_id, subject_device_id, record_hash, issuer_sequence,
       action, signed_record, issuer_confirmed, subject_confirmed, event_order,
       CASE WHEN action = 'revoke' THEN event_order ELSE 0 END
FROM ordered
ON CONFLICT (issuer_device_id, subject_device_id) DO NOTHING;

INSERT INTO trust_issuer_states (issuer_device_id, high_water, rate_window_started_at, rate_window_updates)
SELECT issuer_device_id, MAX(issuer_sequence), NOW(), 0
FROM trust_pair_states GROUP BY issuer_device_id
ON CONFLICT (issuer_device_id) DO UPDATE SET high_water = GREATEST(trust_issuer_states.high_water, EXCLUDED.high_water);

SELECT setval('trust_event_order_seq', GREATEST(
    1,
    COALESCE((SELECT MAX(accepted_order) FROM trust_pair_states), 0),
    (SELECT last_value FROM trust_event_order_seq)
), TRUE);
UPDATE trust_state_version SET version = GREATEST(
    version,
    COALESCE((SELECT MAX(accepted_order) FROM trust_pair_states), 0)
)
WHERE singleton = TRUE;

COMMIT;
