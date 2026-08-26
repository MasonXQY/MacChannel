BEGIN;

-- Forward upgrade for deployments that already recorded migrations 001-004.
ALTER TABLE pairing_sessions ADD COLUMN IF NOT EXISTS handshake_expires_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS pairing_sessions_handshake_expiry_idx ON pairing_sessions (handshake_expires_at)
    WHERE handshake_expires_at IS NOT NULL;

-- Pre-005 pending sessions started their five-minute lifetime at join. Preserve
-- that bounded deadline so live rows remain usable and never become immortal.
UPDATE pairing_sessions
SET handshake_expires_at = COALESCE(session_expires_at, consumed_at + INTERVAL '5 minutes')
WHERE consumed_at IS NOT NULL AND handshake_expires_at IS NULL;

-- A response-committed legacy session can adopt the canonical response-derived
-- deadline deterministically from its durable commit timestamp.
UPDATE pairing_sessions
SET session_expires_at = join_response_committed_at + INTERVAL '5 minutes'
WHERE join_response_committed_at IS NOT NULL;

ALTER TABLE trust_pair_states ADD COLUMN IF NOT EXISTS unconfirmed_expires_at TIMESTAMPTZ;
ALTER TABLE trust_pair_states ADD COLUMN IF NOT EXISTS legacy_active BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE trust_pair_states ADD COLUMN IF NOT EXISTS established_pair BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE trust_pair_states ADD COLUMN IF NOT EXISTS pending_expired BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS trust_pair_states_unconfirmed_expiry_idx ON trust_pair_states (unconfirmed_expires_at)
    WHERE unconfirmed_expires_at IS NOT NULL;

-- Preserve only the exact reciprocal issuer-confirmed legacy records that were
-- routable before compact-state confirmation semantics. No signatures are made
-- or altered by this compatibility marker.
UPDATE trust_pair_states current_state
SET legacy_active = TRUE, established_pair = TRUE
FROM device_authorizations current_legacy
WHERE current_state.record_hash = current_legacy.record_hash
  AND current_legacy.issuer_confirmed_at IS NOT NULL
  AND EXISTS (
      SELECT 1
      FROM trust_pair_states reverse_state
      JOIN device_authorizations reverse_legacy
        ON reverse_legacy.record_hash = reverse_state.record_hash
      WHERE reverse_state.issuer_device_id = current_state.subject_device_id
        AND reverse_state.subject_device_id = current_state.issuer_device_id
        AND reverse_legacy.issuer_confirmed_at IS NOT NULL
  );

UPDATE trust_pair_states
SET established_pair = TRUE
WHERE action = 'authorize' AND issuer_confirmed AND subject_confirmed;

-- Admission belongs to the unordered relationship. Carry it to a participant's
-- reverse-direction revocation when the other compact row proves establishment.
UPDATE trust_pair_states current_state
SET established_pair = TRUE
WHERE EXISTS (
    SELECT 1 FROM trust_pair_states peer_state
    WHERE peer_state.issuer_device_id = current_state.subject_device_id
      AND peer_state.subject_device_id = current_state.issuer_device_id
      AND peer_state.established_pair
);

-- A pre-005 incomplete authorization may already carry an earlier revocation
-- barrier in the compact row. There is no trustworthy presentation timestamp
-- to resume its TTL, so retain it as an expired tombstone immediately. This
-- preserves both revocation_order and issuer high-water without allowing the
-- late second presentation to resurrect the authorization.
UPDATE trust_pair_states
SET issuer_confirmed = FALSE,
    subject_confirmed = FALSE,
    unconfirmed_expires_at = NULL,
    pending_expired = TRUE
WHERE action = 'authorize'
  AND revocation_order > 0
  AND NOT (issuer_confirmed AND subject_confirmed);

-- Old one-sided authorizations had no expiry. Give them a bounded grace period;
-- reciprocal compatibility and already-confirmed rows remain durable.
UPDATE trust_pair_states
SET unconfirmed_expires_at = NOW() + INTERVAL '10 minutes'
WHERE action = 'authorize'
  AND NOT established_pair
  AND revocation_order = 0
  AND NOT pending_expired
  AND unconfirmed_expires_at IS NULL;

-- Notify live replicas that compatibility/admission state may have changed.
UPDATE trust_state_version SET version = version + 1 WHERE singleton = TRUE;

COMMIT;
