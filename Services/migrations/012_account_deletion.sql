-- Status-only capability hashes survive completed account erasure for at most
-- 30 days. No device, audience, Apple subject, or provider payload is retained
-- in the completed receipt. Workers must purge expired receipts.
CREATE TABLE IF NOT EXISTS account_deletions (
 receipt_hash BYTEA PRIMARY KEY CHECK (octet_length(receipt_hash)=32),
 account_id UUID UNIQUE REFERENCES accounts(account_id),
 status TEXT NOT NULL CHECK (status IN ('pending','retrying','completed','completed_manual_revocation_required')),
 next_attempt_at TIMESTAMPTZ NOT NULL,
 lease_id UUID,
 lease_until TIMESTAMPTZ,
 completed_at TIMESTAMPTZ,
 expires_at TIMESTAMPTZ,
 CHECK ((lease_id IS NULL) = (lease_until IS NULL)),
 CHECK ((status IN ('completed','completed_manual_revocation_required') AND account_id IS NULL AND completed_at IS NOT NULL
          AND expires_at=completed_at+interval '30 days' AND lease_id IS NULL)
        OR (status IN ('pending','retrying') AND account_id IS NOT NULL AND completed_at IS NULL AND expires_at IS NULL))
);
CREATE INDEX IF NOT EXISTS account_deletions_due_idx ON account_deletions(next_attempt_at) WHERE account_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS account_deletions_expiry_idx ON account_deletions(expires_at) WHERE account_id IS NULL;

-- Only a nonce-verified Apple identity can create this subject-specific barrier.
-- A crashed exchange without a result is NOT deleted just because it expires:
-- expiry means an uncertain Apple outcome: data erasure uses the explicit
-- manual-provider-revocation-required fallback, never claims auto-revocation.
CREATE TABLE IF NOT EXISTS account_apple_exchanges (
 exchange_id UUID PRIMARY KEY,
 apple_subject TEXT NOT NULL CHECK (octet_length(apple_subject) BETWEEN 1 AND 255),
 device_id UUID NOT NULL,
 audience TEXT NOT NULL CHECK (octet_length(audience) BETWEEN 1 AND 255),
 encrypted_refresh BYTEA CHECK (octet_length(encrypted_refresh) BETWEEN 32 AND 20000),
 expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS account_apple_exchanges_subject_idx ON account_apple_exchanges(apple_subject);
