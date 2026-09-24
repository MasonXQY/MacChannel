package auth

import (
	"context"
	"encoding/hex"
	"strconv"
	"strings"
)

// Optional so record-only stores retain their existing source contract.
type issuerHighWaterStore interface {
	LoadIssuerHighWater(context.Context) (map[string]uint64, error)
}

func loadTrustSnapshot(ctx context.Context, store TrustRecordStore) ([]PersistedTrustRecord, map[string]uint64, error) {
	records, err := store.Load(ctx)
	if err != nil {
		return nil, nil, err
	}
	var highWater map[string]uint64
	if metadata, ok := store.(issuerHighWaterStore); ok {
		highWater, err = metadata.LoadIssuerHighWater(ctx)
		if err != nil {
			return nil, nil, err
		}
	}
	return records, highWater, nil
}

// Called only on a fresh, unpublished registry. Metadata raises replay barriers
// but cannot create a pinned public key or an authorized edge.
func (r *TrustRegistry) restoreTrustSnapshot(records []PersistedTrustRecord, highWater map[string]uint64) error {
	for _, item := range records {
		if err := item.Record.Validate(); err != nil {
			return err
		}
	}
	for issuer := range highWater {
		if !validTrustIssuerID(issuer) {
			return ErrInvalidTrust
		}
	}
	pending, err := r.prepareRestoreLocked(records)
	if err != nil {
		return err
	}
	r.applyPendingLocked(pending)
	for issuer, sequence := range highWater {
		issuer = strings.ToLower(issuer)
		r.durableIssuers[issuer] = true
		if sequence > r.issuerSequence[issuer] {
			r.issuerSequence[issuer] = sequence
		}
	}
	return nil
}

func validTrustIssuerID(issuer string) bool {
	if len(issuer) != 36 || issuer[8] != '-' || issuer[13] != '-' || issuer[18] != '-' || issuer[23] != '-' {
		return false
	}
	raw := strings.ReplaceAll(issuer, "-", "")
	decoded, err := hex.DecodeString(raw)
	return err == nil && len(decoded) == 16
}

func (s *PostgresTrustRecordStore) LoadIssuerHighWater(ctx context.Context) (map[string]uint64, error) {
	rows, err := s.database.QueryContext(ctx, `SELECT issuer_device_id, high_water FROM trust_issuer_states`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make(map[string]uint64)
	for rows.Next() {
		var issuer, raw string
		if err := rows.Scan(&issuer, &raw); err != nil {
			return nil, err
		}
		sequence, err := strconv.ParseUint(raw, 10, 64)
		if err != nil || !validTrustIssuerID(issuer) {
			return nil, ErrInvalidTrust
		}
		issuer = strings.ToLower(issuer)
		if _, exists := result[issuer]; exists {
			return nil, ErrInvalidTrust
		}
		result[issuer] = sequence
	}
	return result, rows.Err()
}
