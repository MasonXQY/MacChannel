use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroizing;

pub(crate) const MAX_DURABLE_PAYLOAD_BYTES: usize = 60 * 1024;

const STATE_MAGIC: &[u8; 8] = b"DMSSTATE";
const ANCHOR_MAGIC: &[u8; 8] = b"DMSANCHR";
const STATE_HEADER_LEN: usize = STATE_MAGIC.len() + 8 + 4;
const ANCHOR_LEN: usize = ANCHOR_MAGIC.len() + 8 + 32;

#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub(crate) enum FormatError {
    #[error("durable state payload exceeds the bounded limit")]
    PayloadTooLarge,
    #[error("durable state encoding is invalid")]
    InvalidEncoding,
    #[error("durable state generation was rolled back")]
    GenerationRollback,
    #[error("durable anchor generation was rolled back")]
    AnchorRollback,
    #[error("protected durable state does not match its anchor")]
    ProtectedBlobMismatch,
    #[error("durable state recovery journal is inconsistent")]
    InvalidRecoveryJournal,
    #[error("durable state writer used a stale generation")]
    StaleGeneration,
    #[error("durable state generation overflowed")]
    GenerationOverflow,
}

pub(crate) struct StateEnvelope<'a> {
    pub(crate) generation: u64,
    pub(crate) payload: &'a [u8],
}

pub(crate) struct AnchorEnvelope {
    pub(crate) generation: u64,
    pub(crate) protected_blob_hash: [u8; 32],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RecoveryAction {
    AbortPrepared,
    RollForward,
    CleanupCommitted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InitialRecoveryAction {
    AbortPrepared,
    RollForward,
}

pub(crate) fn encode_state(
    generation: u64,
    payload: &[u8],
) -> Result<Zeroizing<Vec<u8>>, FormatError> {
    if generation == 0 || payload.len() > MAX_DURABLE_PAYLOAD_BYTES {
        return Err(if generation == 0 {
            FormatError::InvalidEncoding
        } else {
            FormatError::PayloadTooLarge
        });
    }
    let payload_len = u32::try_from(payload.len()).map_err(|_| FormatError::PayloadTooLarge)?;
    let mut encoded = Zeroizing::new(Vec::with_capacity(STATE_HEADER_LEN + payload.len()));
    encoded.extend_from_slice(STATE_MAGIC);
    encoded.extend_from_slice(&generation.to_be_bytes());
    encoded.extend_from_slice(&payload_len.to_be_bytes());
    encoded.extend_from_slice(payload);
    Ok(encoded)
}

pub(crate) fn decode_state(bytes: &[u8]) -> Result<StateEnvelope<'_>, FormatError> {
    if bytes.len() < STATE_HEADER_LEN || bytes.get(..STATE_MAGIC.len()) != Some(STATE_MAGIC) {
        return Err(FormatError::InvalidEncoding);
    }
    let generation = u64::from_be_bytes(
        bytes[8..16]
            .try_into()
            .map_err(|_| FormatError::InvalidEncoding)?,
    );
    let payload_len = u32::from_be_bytes(
        bytes[16..20]
            .try_into()
            .map_err(|_| FormatError::InvalidEncoding)?,
    );
    let payload_len = usize::try_from(payload_len).map_err(|_| FormatError::InvalidEncoding)?;
    if generation == 0
        || payload_len > MAX_DURABLE_PAYLOAD_BYTES
        || bytes.len() != STATE_HEADER_LEN + payload_len
    {
        return Err(FormatError::InvalidEncoding);
    }
    Ok(StateEnvelope {
        generation,
        payload: &bytes[STATE_HEADER_LEN..],
    })
}

pub(crate) fn encode_anchor(generation: u64, protected_blob_hash: [u8; 32]) -> [u8; ANCHOR_LEN] {
    let mut encoded = [0_u8; ANCHOR_LEN];
    encoded[..8].copy_from_slice(ANCHOR_MAGIC);
    encoded[8..16].copy_from_slice(&generation.to_be_bytes());
    encoded[16..].copy_from_slice(&protected_blob_hash);
    encoded
}

pub(crate) fn decode_anchor(bytes: &[u8]) -> Result<AnchorEnvelope, FormatError> {
    if bytes.len() != ANCHOR_LEN || bytes.get(..ANCHOR_MAGIC.len()) != Some(ANCHOR_MAGIC) {
        return Err(FormatError::InvalidEncoding);
    }
    let generation = u64::from_be_bytes(
        bytes[8..16]
            .try_into()
            .map_err(|_| FormatError::InvalidEncoding)?,
    );
    let protected_blob_hash = bytes[16..]
        .try_into()
        .map_err(|_| FormatError::InvalidEncoding)?;
    if generation == 0 {
        return Err(FormatError::InvalidEncoding);
    }
    Ok(AnchorEnvelope {
        generation,
        protected_blob_hash,
    })
}

pub(crate) fn validate_pair(
    state: &StateEnvelope<'_>,
    anchor: &AnchorEnvelope,
    protected_state: &[u8],
) -> Result<(), FormatError> {
    if state.generation < anchor.generation {
        return Err(FormatError::GenerationRollback);
    }
    if state.generation > anchor.generation {
        return Err(FormatError::AnchorRollback);
    }
    let actual_hash: [u8; 32] = Sha256::digest(protected_state).into();
    if actual_hash != anchor.protected_blob_hash {
        return Err(FormatError::ProtectedBlobMismatch);
    }
    Ok(())
}

pub(crate) fn classify_recovery(
    state: &StateEnvelope<'_>,
    anchor: &AnchorEnvelope,
    next: &AnchorEnvelope,
    protected_state: &[u8],
) -> Result<RecoveryAction, FormatError> {
    let actual_hash: [u8; 32] = Sha256::digest(protected_state).into();

    if state.generation == anchor.generation {
        if anchor.protected_blob_hash != actual_hash {
            return Err(FormatError::ProtectedBlobMismatch);
        }
        if next.generation == state.generation && next.protected_blob_hash == actual_hash {
            return Ok(RecoveryAction::CleanupCommitted);
        }
        if state.generation.checked_add(1) == Some(next.generation) {
            return Ok(RecoveryAction::AbortPrepared);
        }
        return Err(FormatError::InvalidRecoveryJournal);
    }

    if anchor.generation.checked_add(1) == Some(state.generation) {
        if next.generation != state.generation {
            return Err(FormatError::InvalidRecoveryJournal);
        }
        if next.protected_blob_hash != actual_hash {
            return Err(FormatError::ProtectedBlobMismatch);
        }
        return Ok(RecoveryAction::RollForward);
    }

    Err(FormatError::InvalidRecoveryJournal)
}

pub(crate) fn classify_initial_recovery(
    state: Option<(&StateEnvelope<'_>, &[u8])>,
    next: &AnchorEnvelope,
) -> Result<InitialRecoveryAction, FormatError> {
    if next.generation != 1 {
        return Err(FormatError::InvalidRecoveryJournal);
    }

    let Some((state, protected_state)) = state else {
        return Ok(InitialRecoveryAction::AbortPrepared);
    };
    if state.generation != 1 {
        return Err(FormatError::InvalidRecoveryJournal);
    }
    let actual_hash: [u8; 32] = Sha256::digest(protected_state).into();
    if next.protected_blob_hash != actual_hash {
        return Err(FormatError::ProtectedBlobMismatch);
    }
    Ok(InitialRecoveryAction::RollForward)
}

pub(crate) fn next_generation(expected: u64, current: u64) -> Result<u64, FormatError> {
    if expected != current {
        return Err(FormatError::StaleGeneration);
    }
    current
        .checked_add(1)
        .ok_or(FormatError::GenerationOverflow)
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use sha2::{Digest, Sha256};

    use super::{
        FormatError, InitialRecoveryAction, RecoveryAction, classify_initial_recovery,
        classify_recovery, decode_anchor, decode_state, encode_anchor, encode_state,
        next_generation, validate_pair,
    };

    #[test]
    fn a_rolled_back_state_blob_is_rejected_against_the_high_water_anchor()
    -> Result<(), Box<dyn Error>> {
        let old_blob = b"protected generation two";
        let current_blob = b"protected generation three";
        let encoded_old = encode_state(2, b"old")?;
        let old_state = decode_state(&encoded_old)?;
        let anchor = decode_anchor(&encode_anchor(3, Sha256::digest(current_blob).into()))?;

        assert_eq!(
            validate_pair(&old_state, &anchor, old_blob),
            Err(FormatError::GenerationRollback)
        );
        Ok(())
    }

    #[test]
    fn state_and_anchor_must_match_generation_and_exact_protected_blob_hash()
    -> Result<(), Box<dyn Error>> {
        let protected = b"protected state blob";
        let encoded = encode_state(7, b"payload")?;
        let state = decode_state(&encoded)?;
        assert_eq!(state.payload, b"payload");
        let matching = decode_anchor(&encode_anchor(7, Sha256::digest(protected).into()))?;
        let wrong_hash = decode_anchor(&encode_anchor(7, [9_u8; 32]))?;

        assert_eq!(validate_pair(&state, &matching, protected), Ok(()));
        assert_eq!(
            validate_pair(&state, &wrong_hash, protected),
            Err(FormatError::ProtectedBlobMismatch)
        );
        Ok(())
    }

    #[test]
    fn stale_writer_cannot_advance_generation() {
        assert_eq!(next_generation(4, 4), Ok(5));
        assert_eq!(next_generation(3, 4), Err(FormatError::StaleGeneration));
        assert_eq!(
            next_generation(u64::MAX, u64::MAX),
            Err(FormatError::GenerationOverflow)
        );
    }

    #[test]
    fn paired_rollback_is_indistinguishable_without_an_external_anchor()
    -> Result<(), Box<dyn Error>> {
        let old_protected = b"old protected state";
        let encoded_old = encode_state(2, b"old")?;
        let old_state = decode_state(&encoded_old)?;
        let old_anchor = decode_anchor(&encode_anchor(2, Sha256::digest(old_protected).into()))?;

        assert_eq!(
            validate_pair(&old_state, &old_anchor, old_protected),
            Ok(())
        );
        Ok(())
    }

    #[test]
    fn recovery_classifies_every_atomic_commit_stage() -> Result<(), Box<dyn Error>> {
        let old_protected = b"old protected state";
        let new_protected = b"new protected state";
        let old_encoded = encode_state(8, b"old")?;
        let new_encoded = encode_state(9, b"new")?;
        let old_state = decode_state(&old_encoded)?;
        let new_state = decode_state(&new_encoded)?;
        let old_anchor = decode_anchor(&encode_anchor(8, Sha256::digest(old_protected).into()))?;
        let new_anchor = decode_anchor(&encode_anchor(9, Sha256::digest(new_protected).into()))?;

        assert_eq!(
            classify_recovery(&old_state, &old_anchor, &new_anchor, old_protected),
            Ok(RecoveryAction::AbortPrepared)
        );
        let same_hash_next =
            decode_anchor(&encode_anchor(9, Sha256::digest(old_protected).into()))?;
        assert_eq!(
            classify_recovery(&old_state, &old_anchor, &same_hash_next, old_protected),
            Ok(RecoveryAction::AbortPrepared)
        );
        assert_eq!(
            classify_recovery(&new_state, &old_anchor, &new_anchor, new_protected),
            Ok(RecoveryAction::RollForward)
        );
        assert_eq!(
            classify_recovery(&new_state, &new_anchor, &new_anchor, new_protected),
            Ok(RecoveryAction::CleanupCommitted)
        );
        Ok(())
    }

    #[test]
    fn initial_recovery_accepts_only_authenticated_generation_one_transactions()
    -> Result<(), Box<dyn Error>> {
        let protected = b"initial protected state";
        let state_bytes = encode_state(1, b"first")?;
        let state = decode_state(&state_bytes)?;
        let matching_next = decode_anchor(&encode_anchor(1, Sha256::digest(protected).into()))?;

        assert_eq!(
            classify_initial_recovery(None, &matching_next),
            Ok(InitialRecoveryAction::AbortPrepared)
        );
        assert_eq!(
            classify_initial_recovery(Some((&state, protected)), &matching_next),
            Ok(InitialRecoveryAction::RollForward)
        );

        let generation_two_next = decode_anchor(&encode_anchor(2, [7_u8; 32]))?;
        assert_eq!(
            classify_initial_recovery(None, &generation_two_next),
            Err(FormatError::InvalidRecoveryJournal)
        );
        let wrong_hash = decode_anchor(&encode_anchor(1, [8_u8; 32]))?;
        assert_eq!(
            classify_initial_recovery(Some((&state, protected)), &wrong_hash),
            Err(FormatError::ProtectedBlobMismatch)
        );
        let generation_two_state_bytes = encode_state(2, b"second")?;
        let generation_two_state = decode_state(&generation_two_state_bytes)?;
        assert_eq!(
            classify_initial_recovery(Some((&generation_two_state, protected)), &matching_next),
            Err(FormatError::InvalidRecoveryJournal)
        );
        Ok(())
    }

    #[test]
    fn forged_or_rolled_back_recovery_anchor_fails_closed() -> Result<(), Box<dyn Error>> {
        let protected = b"generation eleven state";
        let encoded = encode_state(11, b"payload")?;
        let state = decode_state(&encoded)?;
        let old_anchor = decode_anchor(&encode_anchor(10, [3_u8; 32]))?;
        let forged_next = decode_anchor(&encode_anchor(11, [4_u8; 32]))?;
        let rolled_back_next = decode_anchor(&encode_anchor(9, [5_u8; 32]))?;

        assert_eq!(
            classify_recovery(&state, &old_anchor, &forged_next, protected),
            Err(FormatError::ProtectedBlobMismatch)
        );
        assert_eq!(
            classify_recovery(&state, &old_anchor, &rolled_back_next, protected),
            Err(FormatError::InvalidRecoveryJournal)
        );
        Ok(())
    }
}
