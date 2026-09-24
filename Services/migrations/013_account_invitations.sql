-- Selected cross-account pairs only. No plaintext link tokens or device list.
-- Hash-only issuance tombstones prevent a deleted/rotated link being reassigned
-- to a different account incarnation. They contain no owner or provider data.
CREATE TABLE IF NOT EXISTS account_invitation_link_issuance (
 link_hash BYTEA PRIMARY KEY CHECK(octet_length(link_hash)=32)
);
CREATE TABLE IF NOT EXISTS account_invitation_links (
 account_id UUID PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
 link_hash BYTEA NOT NULL UNIQUE REFERENCES account_invitation_link_issuance(link_hash),
 version BIGINT NOT NULL CHECK(version>0)
);
CREATE TABLE IF NOT EXISTS account_invitation_blocks (
 owner_id UUID NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 blocked_id UUID NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 PRIMARY KEY(owner_id,blocked_id),CHECK(owner_id<>blocked_id)
);
CREATE TABLE IF NOT EXISTS account_invitations (
 request_id UUID PRIMARY KEY,
 grant_id UUID NOT NULL UNIQUE,
 sender_id UUID NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 recipient_id UUID NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 sender_device UUID NOT NULL,
 link_version BIGINT NOT NULL CHECK(link_version>0),
 request_payload BYTEA NOT NULL CHECK(octet_length(request_payload) BETWEEN 1 AND 4096),
 request_signature BYTEA NOT NULL CHECK(octet_length(request_signature) BETWEEN 8 AND 80),
 pair_payload BYTEA CHECK(octet_length(pair_payload) BETWEEN 1 AND 4096),
 sender_signature BYTEA CHECK(octet_length(sender_signature) BETWEEN 8 AND 80),
 target_signature BYTEA CHECK(octet_length(target_signature) BETWEEN 8 AND 80),
 state TEXT NOT NULL CHECK(state IN('requested','selected','active','rejected','cancelled','expired','revoked')),
 revision BIGINT NOT NULL CHECK(revision>0),
 created_at TIMESTAMPTZ NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 CHECK(sender_id<>recipient_id),CHECK(request_id<>grant_id),
 CHECK(expires_at=created_at+INTERVAL '24 hours'),
 CHECK(state<>'active' OR (pair_payload IS NOT NULL AND sender_signature IS NOT NULL AND target_signature IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS account_invitations_sender_idx ON account_invitations(sender_id,request_id);
CREATE INDEX IF NOT EXISTS account_invitations_recipient_idx ON account_invitations(recipient_id,request_id);
ALTER TABLE account_invitations ADD COLUMN IF NOT EXISTS sender_sequence BIGINT NOT NULL DEFAULT 0 CHECK(sender_sequence>=0);
ALTER TABLE account_invitations ADD COLUMN IF NOT EXISTS target_sequence BIGINT NOT NULL DEFAULT 0 CHECK(target_sequence>=0);
