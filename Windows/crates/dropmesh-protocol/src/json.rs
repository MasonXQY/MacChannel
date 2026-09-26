use base64::{Engine as _, engine::general_purpose::STANDARD};
use p256::{
    PublicKey,
    ecdsa::{Signature, VerifyingKey, signature::Verifier},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use uuid::Uuid;

use crate::{
    MAX_PAIRING_OFFER_JSON_BYTES, MAX_SIGNED_ENVELOPE_JSON_BYTES,
    MAX_SIGNED_ENVELOPE_PAYLOAD_BYTES, ProtocolError,
};

const MAX_SAFE_JSON_INTEGER: i64 = 9_007_199_254_740_991;
const MAX_SIGNED_ENVELOPE_NONCE_BYTES: usize = 64;
const MAX_SIGNED_ENVELOPE_SIGNATURE_BYTES: usize = 80;

fn decode_base64_bounded(
    value: &str,
    max_decoded_bytes: usize,
    error: ProtocolError,
) -> Result<Vec<u8>, ProtocolError> {
    let max_encoded_bytes = max_decoded_bytes.div_ceil(3) * 4;
    if value.len() > max_encoded_bytes {
        return Err(error);
    }
    let decoded = STANDARD.decode(value).map_err(|_| error)?;
    if decoded.len() > max_decoded_bytes || STANDARD.encode(&decoded) != value {
        return Err(error);
    }
    Ok(decoded)
}

fn validate_raw_p256_key(key: &[u8; 64]) -> Result<(), ProtocolError> {
    let mut sec1 = [0_u8; 65];
    sec1[0] = 4;
    sec1[1..].copy_from_slice(key);
    PublicKey::from_sec1_bytes(&sec1)
        .map(|_| ())
        .map_err(|_| ProtocolError::InvalidPairingOffer)
}

fn device_id_for_exact_key_bytes(key: &[u8]) -> Uuid {
    let digest = Sha256::digest(key);
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    Uuid::from_bytes(bytes)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingOffer {
    code: String,
    expires_at_milliseconds: i64,
    host_id: Uuid,
    host_identity_public_key: [u8; 64],
    host_ephemeral_public_key: [u8; 64],
    host_display_name: String,
    challenge: [u8; 32],
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct PairingOfferJson {
    challenge: String,
    code: String,
    #[serde(rename = "expiresAt")]
    expires_at: i64,
    #[serde(rename = "hostDisplayName")]
    host_display_name: String,
    #[serde(rename = "hostEphemeralPublicKey")]
    host_ephemeral_public_key: String,
    #[serde(rename = "hostID")]
    host_id: String,
    #[serde(rename = "hostIdentityPublicKey")]
    host_identity_public_key: String,
}

/// A canonical pairing message whose fixed-size fields have been decoded but
/// whose P-256 coordinates have not yet been trusted.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnverifiedPairingOffer {
    pub code: String,
    pub expires_at_milliseconds: i64,
    pub host_id: Uuid,
    pub host_identity_public_key: [u8; 64],
    pub host_ephemeral_public_key: [u8; 64],
    pub host_display_name: String,
    pub challenge: [u8; 32],
}

impl UnverifiedPairingOffer {
    pub fn decode_canonical_json(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() > MAX_PAIRING_OFFER_JSON_BYTES {
            return Err(ProtocolError::InvalidPairingOffer);
        }
        let wire: PairingOfferJson =
            serde_json::from_slice(input).map_err(|_| ProtocolError::InvalidPairingOffer)?;
        let value = Self {
            code: wire.code,
            expires_at_milliseconds: wire.expires_at,
            host_id: Uuid::parse_str(&wire.host_id)
                .map_err(|_| ProtocolError::InvalidPairingOffer)?,
            host_identity_public_key: decode_base64_bounded(
                &wire.host_identity_public_key,
                64,
                ProtocolError::InvalidPairingOffer,
            )?
            .try_into()
            .map_err(|_| ProtocolError::InvalidPairingOffer)?,
            host_ephemeral_public_key: decode_base64_bounded(
                &wire.host_ephemeral_public_key,
                64,
                ProtocolError::InvalidPairingOffer,
            )?
            .try_into()
            .map_err(|_| ProtocolError::InvalidPairingOffer)?,
            host_display_name: wire.host_display_name,
            challenge: decode_base64_bounded(
                &wire.challenge,
                32,
                ProtocolError::InvalidPairingOffer,
            )?
            .try_into()
            .map_err(|_| ProtocolError::InvalidPairingOffer)?,
        };
        value.validate()?;
        if value.encode_canonical_json()?.as_slice() != input {
            return Err(ProtocolError::InvalidPairingOffer);
        }
        Ok(value)
    }

    pub fn encode_canonical_json(&self) -> Result<Vec<u8>, ProtocolError> {
        self.validate()?;
        let bytes = serde_json::to_vec(&PairingOfferJson {
            challenge: STANDARD.encode(self.challenge),
            code: self.code.clone(),
            expires_at: self.expires_at_milliseconds,
            host_display_name: self.host_display_name.clone(),
            host_ephemeral_public_key: STANDARD.encode(self.host_ephemeral_public_key),
            host_id: self.host_id.to_string().to_uppercase(),
            host_identity_public_key: STANDARD.encode(self.host_identity_public_key),
        })
        .map_err(|_| ProtocolError::InvalidPairingOffer)?;
        if bytes.len() > MAX_PAIRING_OFFER_JSON_BYTES {
            return Err(ProtocolError::InvalidPairingOffer);
        }
        Ok(bytes)
    }

    fn validate(&self) -> Result<(), ProtocolError> {
        if self.code.len() != 6
            || !self.code.bytes().all(|byte| byte.is_ascii_digit())
            || !(1..=MAX_SAFE_JSON_INTEGER).contains(&self.expires_at_milliseconds)
            || self.host_display_name.is_empty()
            || self.host_display_name.len() > 256
            || self.host_display_name.contains('\0')
        {
            return Err(ProtocolError::InvalidPairingOffer);
        }
        Ok(())
    }

    /// Validates both raw X || Y values as non-identity P-256 public points.
    pub fn verify(self) -> Result<PairingOffer, ProtocolError> {
        self.validate()?;
        validate_raw_p256_key(&self.host_identity_public_key)?;
        validate_raw_p256_key(&self.host_ephemeral_public_key)?;
        if self.host_id != device_id_for_exact_key_bytes(&self.host_identity_public_key) {
            return Err(ProtocolError::InvalidPairingOffer);
        }
        Ok(PairingOffer {
            code: self.code,
            expires_at_milliseconds: self.expires_at_milliseconds,
            host_id: self.host_id,
            host_identity_public_key: self.host_identity_public_key,
            host_ephemeral_public_key: self.host_ephemeral_public_key,
            host_display_name: self.host_display_name,
            challenge: self.challenge,
        })
    }
}

impl PairingOffer {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        code: String,
        expires_at_milliseconds: i64,
        host_id: Uuid,
        host_identity_public_key: [u8; 64],
        host_ephemeral_public_key: [u8; 64],
        host_display_name: String,
        challenge: [u8; 32],
    ) -> Result<Self, ProtocolError> {
        UnverifiedPairingOffer {
            code,
            expires_at_milliseconds,
            host_id,
            host_identity_public_key,
            host_ephemeral_public_key,
            host_display_name,
            challenge,
        }
        .verify()
    }

    pub fn decode_canonical_json(input: &[u8]) -> Result<Self, ProtocolError> {
        UnverifiedPairingOffer::decode_canonical_json(input)?.verify()
    }

    pub fn encode_canonical_json(&self) -> Result<Vec<u8>, ProtocolError> {
        validate_raw_p256_key(&self.host_identity_public_key)?;
        validate_raw_p256_key(&self.host_ephemeral_public_key)?;
        UnverifiedPairingOffer {
            code: self.code.clone(),
            expires_at_milliseconds: self.expires_at_milliseconds,
            host_id: self.host_id,
            host_identity_public_key: self.host_identity_public_key,
            host_ephemeral_public_key: self.host_ephemeral_public_key,
            host_display_name: self.host_display_name.clone(),
            challenge: self.challenge,
        }
        .encode_canonical_json()
    }

    #[must_use]
    pub fn code(&self) -> &str {
        &self.code
    }

    #[must_use]
    pub const fn expires_at_milliseconds(&self) -> i64 {
        self.expires_at_milliseconds
    }

    #[must_use]
    pub const fn host_id(&self) -> Uuid {
        self.host_id
    }

    #[must_use]
    pub const fn host_identity_public_key(&self) -> &[u8; 64] {
        &self.host_identity_public_key
    }

    #[must_use]
    pub const fn host_ephemeral_public_key(&self) -> &[u8; 64] {
        &self.host_ephemeral_public_key
    }

    #[must_use]
    pub fn host_display_name(&self) -> &str {
        &self.host_display_name
    }

    #[must_use]
    pub const fn challenge(&self) -> &[u8; 32] {
        &self.challenge
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignedEnvelope {
    pub device_id: String,
    pub epoch_milliseconds: i64,
    pub nonce: Vec<u8>,
    pub payload: Vec<u8>,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

#[derive(Serialize)]
struct CanonicalEnvelope<'a> {
    #[serde(rename = "deviceID")]
    device_id: &'a str,
    #[serde(rename = "epochMilliseconds")]
    epoch_milliseconds: i64,
    nonce: String,
    payload: String,
    #[serde(rename = "publicKey")]
    public_key: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SignedEnvelopeWire {
    #[serde(rename = "deviceID")]
    device_id: String,
    #[serde(rename = "epochMilliseconds")]
    epoch_milliseconds: i64,
    nonce: String,
    payload: String,
    #[serde(rename = "publicKey")]
    public_key: String,
    signature: String,
}

impl SignedEnvelope {
    pub fn decode_canonical_json(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() > MAX_SIGNED_ENVELOPE_JSON_BYTES {
            return Err(ProtocolError::InvalidSignedEnvelope);
        }
        let wire: SignedEnvelopeWire =
            serde_json::from_slice(input).map_err(|_| ProtocolError::InvalidSignedEnvelope)?;
        let value = Self::from_base64_fields(
            &wire.device_id,
            wire.epoch_milliseconds,
            &wire.nonce,
            &wire.payload,
            &wire.public_key,
            &wire.signature,
        )?;
        if value.encode_canonical_json()?.as_slice() != input {
            return Err(ProtocolError::InvalidSignedEnvelope);
        }
        Ok(value)
    }

    pub fn from_base64_fields(
        device_id: &str,
        epoch_milliseconds: i64,
        nonce: &str,
        payload: &str,
        public_key: &str,
        signature: &str,
    ) -> Result<Self, ProtocolError> {
        let value = Self {
            device_id: device_id.to_owned(),
            epoch_milliseconds,
            nonce: decode_base64_bounded(
                nonce,
                MAX_SIGNED_ENVELOPE_NONCE_BYTES,
                ProtocolError::InvalidSignedEnvelope,
            )?,
            payload: decode_base64_bounded(
                payload,
                MAX_SIGNED_ENVELOPE_PAYLOAD_BYTES,
                ProtocolError::InvalidSignedEnvelope,
            )?,
            public_key: decode_base64_bounded(
                public_key,
                65,
                ProtocolError::InvalidSignedEnvelope,
            )?,
            signature: decode_base64_bounded(
                signature,
                MAX_SIGNED_ENVELOPE_SIGNATURE_BYTES,
                ProtocolError::InvalidSignedEnvelope,
            )?,
        };
        value.validate()?;
        Ok(value)
    }

    pub fn canonical_payload(&self) -> Result<Vec<u8>, ProtocolError> {
        self.validate()?;
        let device_id = self.device_id.to_lowercase();
        serde_json::to_vec(&CanonicalEnvelope {
            device_id: &device_id,
            epoch_milliseconds: self.epoch_milliseconds,
            nonce: STANDARD.encode(&self.nonce),
            payload: STANDARD.encode(&self.payload),
            public_key: STANDARD.encode(&self.public_key),
        })
        .map_err(|_| ProtocolError::InvalidSignedEnvelope)
    }

    pub fn encode_canonical_json(&self) -> Result<Vec<u8>, ProtocolError> {
        self.validate()?;
        let bytes = serde_json::to_vec(&SignedEnvelopeWire {
            device_id: self.device_id.clone(),
            epoch_milliseconds: self.epoch_milliseconds,
            nonce: STANDARD.encode(&self.nonce),
            payload: STANDARD.encode(&self.payload),
            public_key: STANDARD.encode(&self.public_key),
            signature: STANDARD.encode(&self.signature),
        })
        .map_err(|_| ProtocolError::InvalidSignedEnvelope)?;
        if bytes.len() > MAX_SIGNED_ENVELOPE_JSON_BYTES {
            return Err(ProtocolError::InvalidSignedEnvelope);
        }
        Ok(bytes)
    }

    pub fn verify(&self) -> Result<(), ProtocolError> {
        let key_bytes = match self.public_key.len() {
            64 => {
                let mut bytes = Vec::with_capacity(65);
                bytes.push(4);
                bytes.extend_from_slice(&self.public_key);
                bytes
            }
            65 if self.public_key.first() == Some(&4) => self.public_key.clone(),
            _ => return Err(ProtocolError::InvalidSignedEnvelope),
        };
        let key = VerifyingKey::from_sec1_bytes(&key_bytes)
            .map_err(|_| ProtocolError::InvalidSignedEnvelope)?;
        let signature = Signature::from_der(&self.signature)
            .map_err(|_| ProtocolError::InvalidSignedEnvelope)?;
        if signature.to_der().as_bytes() != self.signature {
            return Err(ProtocolError::InvalidSignedEnvelope);
        }
        key.verify(&self.canonical_payload()?, &signature)
            .map_err(|_| ProtocolError::AuthenticationFailed)
    }

    fn validate(&self) -> Result<(), ProtocolError> {
        if Uuid::parse_str(&self.device_id).is_err()
            || self.device_id != self.device_id.to_lowercase()
            || !(1..=MAX_SAFE_JSON_INTEGER).contains(&self.epoch_milliseconds)
            || self.nonce.is_empty()
            || self.payload.is_empty()
            || self.nonce.len() > MAX_SIGNED_ENVELOPE_NONCE_BYTES
            || self.payload.len() > MAX_SIGNED_ENVELOPE_PAYLOAD_BYTES
            || !matches!(self.public_key.len(), 64 | 65)
            || self.signature.is_empty()
            || self.signature.len() > MAX_SIGNED_ENVELOPE_SIGNATURE_BYTES
            || Uuid::parse_str(&self.device_id).ok()
                != Some(device_id_for_exact_key_bytes(&self.public_key))
        {
            return Err(ProtocolError::InvalidSignedEnvelope);
        }
        Ok(())
    }
}
