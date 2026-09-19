-- Signed proofs only; no private keys, tokens, or mutable membership cache.
CREATE TABLE IF NOT EXISTS account_groups (
 account_id UUID PRIMARY KEY REFERENCES accounts(account_id),
 group_id UUID NOT NULL UNIQUE,
 generation BIGINT NOT NULL CHECK (generation > 0),
 anchor_hash BYTEA NOT NULL CHECK (octet_length(anchor_hash) = 32)
);
CREATE TABLE IF NOT EXISTS account_group_events (
 account_id UUID NOT NULL REFERENCES account_groups(account_id),
 sequence BIGINT NOT NULL CHECK (sequence > 0),
 event_hash BYTEA NOT NULL CHECK (octet_length(event_hash) = 32),
 event_data BYTEA NOT NULL CHECK (octet_length(event_data) BETWEEN 1 AND 4096),
 PRIMARY KEY (account_id, sequence),
 UNIQUE (account_id, event_hash)
);
