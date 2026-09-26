//! Strict rendezvous wire codecs shared by the Windows headless client.
//!
//! Networking is deliberately kept outside this crate. These routines bound
//! every server-controlled allocation, reject duplicate/unknown JSON fields,
//! and reproduce the existing Swift/Go authentication envelope byte-for-byte.

#![allow(clippy::missing_errors_doc)]

use std::collections::BTreeMap;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use dropmesh_identity::DeviceIdentity;
use dropmesh_protocol::SignedEnvelope;
use serde::{
    Serialize,
    de::{Deserializer as _, MapAccess, Visitor},
};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

pub const SUBPROTOCOL: &str = "macchannel.auth.v1";
pub const AUTHENTICATION_PAYLOAD: &[u8] = br#"{"type":"websocket-auth-v1"}"#;
pub const MAX_SIGNAL_PAYLOAD_BYTES: usize = 64 * 1_024;
pub const MAX_FRAME_BYTES: usize = 128 * 1_024;
pub const MAX_HTTP_PAYLOAD_BYTES: usize = 24 * 1_024;
pub const MAX_HTTP_BODY_BYTES: usize = 64 * 1_024;

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RendezvousError {
    #[error("invalid rendezvous frame")]
    InvalidFrame,
    #[error("rendezvous frame exceeds the configured bound")]
    FrameTooLarge,
    #[error("device identity could not sign the rendezvous envelope")]
    SigningFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Challenge {
    pub nonce: [u8; 32],
    pub expires_at_milliseconds: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ServerFrame {
    Authenticated {
        device_id: String,
    },
    Presence {
        device_id: String,
        online: bool,
    },
    Signal {
        from: String,
        payload: Vec<u8>,
    },
    SignalError {
        code: String,
        target: Option<String>,
    },
    ProtocolError {
        code: String,
    },
    TrustAccepted,
    TrustRejected,
}

struct ObjectVisitor;

impl<'de> Visitor<'de> for ObjectVisitor {
    type Value = BTreeMap<String, Value>;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a JSON object with unique keys")
    }

    fn visit_map<A>(self, mut access: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut object = BTreeMap::new();
        while let Some(key) = access.next_key::<String>()? {
            let value = access.next_value::<Value>()?;
            if object.insert(key, value).is_some() {
                return Err(serde::de::Error::custom("duplicate key"));
            }
        }
        Ok(object)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthenticationWire<'a> {
    envelope: Value,
    trust_records: &'a [Value],
}

/// Produces the first client frame expected by `/v1/ws` after its challenge.
/// Trust records are empty for a newly installed Windows identity; membership
/// catch-up occurs only after authenticated account-route binding.
pub fn encode_authentication(
    identity: &dyn DeviceIdentity,
    challenge: &Challenge,
    epoch_milliseconds: i64,
) -> Result<Vec<u8>, RendezvousError> {
    if epoch_milliseconds <= 0 || epoch_milliseconds >= challenge.expires_at_milliseconds {
        return Err(RendezvousError::InvalidFrame);
    }
    let public_key = identity.signing_public_key();
    let mut envelope = SignedEnvelope {
        device_id: identity.device_id().to_string(),
        epoch_milliseconds,
        nonce: challenge.nonce.to_vec(),
        payload: AUTHENTICATION_PAYLOAD.to_vec(),
        public_key: public_key.as_raw_xy().to_vec(),
        signature: Vec::new(),
    };
    let canonical = envelope
        .canonical_payload()
        .map_err(|_| RendezvousError::InvalidFrame)?;
    envelope.signature = identity
        .sign(&canonical)
        .map_err(|_| RendezvousError::SigningFailed)?
        .as_bytes()
        .to_vec();
    let encoded = envelope
        .encode_canonical_json()
        .map_err(|_| RendezvousError::InvalidFrame)?;
    let value = serde_json::from_slice(&encoded).map_err(|_| RendezvousError::InvalidFrame)?;
    let frame = serde_json::to_vec(&AuthenticationWire {
        envelope: value,
        trust_records: &[],
    })
    .map_err(|_| RendezvousError::InvalidFrame)?;
    if frame.len() > MAX_FRAME_BYTES {
        return Err(RendezvousError::FrameTooLarge);
    }
    Ok(frame)
}

/// Wraps an account or pairing payload in the exact signed HTTP envelope used
/// by the Swift client and Go services. Entropy and time are explicit so the
/// caller can use the OS RNG and a test can reproduce a request deterministically.
pub fn encode_signed_http_body(
    identity: &dyn DeviceIdentity,
    nonce: &[u8; 32],
    payload: &[u8],
    epoch_milliseconds: i64,
) -> Result<Vec<u8>, RendezvousError> {
    if payload.is_empty() {
        return Err(RendezvousError::InvalidFrame);
    }
    if payload.len() > MAX_HTTP_PAYLOAD_BYTES {
        return Err(RendezvousError::FrameTooLarge);
    }
    let public_key = identity.signing_public_key();
    let mut envelope = SignedEnvelope {
        device_id: identity.device_id().to_string(),
        epoch_milliseconds,
        nonce: nonce.to_vec(),
        payload: payload.to_vec(),
        public_key: public_key.as_raw_xy().to_vec(),
        signature: Vec::new(),
    };
    let canonical = envelope
        .canonical_payload()
        .map_err(|_| RendezvousError::InvalidFrame)?;
    envelope.signature = identity
        .sign(&canonical)
        .map_err(|_| RendezvousError::SigningFailed)?
        .as_bytes()
        .to_vec();
    let body = envelope
        .encode_canonical_json()
        .map_err(|_| RendezvousError::InvalidFrame)?;
    if body.len() > MAX_HTTP_BODY_BYTES {
        return Err(RendezvousError::FrameTooLarge);
    }
    Ok(body)
}

pub fn decode_challenge(bytes: &[u8], now_milliseconds: i64) -> Result<Challenge, RendezvousError> {
    let object = strict_object(bytes)?;
    require_keys(&object, &["expiresAt", "nonce", "type"])?;
    if string(&object, "type")? != "challenge" || now_milliseconds <= 0 {
        return Err(RendezvousError::InvalidFrame);
    }
    let expires_at = integer(&object, "expiresAt")?;
    if expires_at <= now_milliseconds {
        return Err(RendezvousError::InvalidFrame);
    }
    let nonce: [u8; 32] = decode_base64(string(&object, "nonce")?, 32)?
        .try_into()
        .map_err(|_| RendezvousError::InvalidFrame)?;
    Ok(Challenge {
        nonce,
        expires_at_milliseconds: expires_at,
    })
}

pub fn decode_server_frame(bytes: &[u8]) -> Result<ServerFrame, RendezvousError> {
    let object = strict_object(bytes)?;
    let frame_type = string(&object, "type")?;
    match frame_type {
        "auth-ok" => {
            require_keys(&object, &["deviceID", "type"])?;
            Ok(ServerFrame::Authenticated {
                device_id: device_id(&object, "deviceID")?,
            })
        }
        "presence" => {
            require_keys(&object, &["availability", "deviceID", "type"])?;
            let availability = string(&object, "availability")?;
            let online = match availability {
                "internet" => true,
                "offline" => false,
                _ => return Err(RendezvousError::InvalidFrame),
            };
            Ok(ServerFrame::Presence {
                device_id: device_id(&object, "deviceID")?,
                online,
            })
        }
        "signal" => {
            require_keys(&object, &["from", "payload", "type"])?;
            let payload = decode_base64(string(&object, "payload")?, MAX_SIGNAL_PAYLOAD_BYTES)?;
            if payload.is_empty() {
                return Err(RendezvousError::InvalidFrame);
            }
            Ok(ServerFrame::Signal {
                from: device_id(&object, "from")?,
                payload,
            })
        }
        "signal-error" => {
            if object.contains_key("to") {
                require_keys(&object, &["code", "to", "type"])?;
            } else {
                require_keys(&object, &["code", "type"])?;
            }
            Ok(ServerFrame::SignalError {
                code: bounded_code(&object)?,
                target: object
                    .get("to")
                    .map(|_| device_id(&object, "to"))
                    .transpose()?,
            })
        }
        "protocol-error" => {
            require_keys(&object, &["code", "type"])?;
            Ok(ServerFrame::ProtocolError {
                code: bounded_code(&object)?,
            })
        }
        "trust-ok" => {
            require_keys(&object, &["type"])?;
            Ok(ServerFrame::TrustAccepted)
        }
        "trust-error" => {
            require_keys(&object, &["type"])?;
            Ok(ServerFrame::TrustRejected)
        }
        _ => Err(RendezvousError::InvalidFrame),
    }
}

#[derive(Serialize)]
struct SignalWire<'a> {
    payload: String,
    to: &'a str,
    #[serde(rename = "type")]
    frame_type: &'static str,
}

pub fn encode_signal(target: &str, payload: &[u8]) -> Result<Vec<u8>, RendezvousError> {
    valid_device_id(target)?;
    if payload.is_empty() {
        return Err(RendezvousError::InvalidFrame);
    }
    if payload.len() > MAX_SIGNAL_PAYLOAD_BYTES {
        return Err(RendezvousError::FrameTooLarge);
    }
    let frame = serde_json::to_vec(&SignalWire {
        payload: STANDARD.encode(payload),
        to: target,
        frame_type: "signal",
    })
    .map_err(|_| RendezvousError::InvalidFrame)?;
    if frame.len() > MAX_FRAME_BYTES {
        return Err(RendezvousError::FrameTooLarge);
    }
    Ok(frame)
}

fn strict_object(bytes: &[u8]) -> Result<BTreeMap<String, Value>, RendezvousError> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME_BYTES {
        return Err(if bytes.len() > MAX_FRAME_BYTES {
            RendezvousError::FrameTooLarge
        } else {
            RendezvousError::InvalidFrame
        });
    }
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let object = deserializer
        .deserialize_map(ObjectVisitor)
        .map_err(|_| RendezvousError::InvalidFrame)?;
    deserializer
        .end()
        .map_err(|_| RendezvousError::InvalidFrame)?;
    Ok(object)
}

fn require_keys(
    object: &BTreeMap<String, Value>,
    expected: &[&str],
) -> Result<(), RendezvousError> {
    if object.len() == expected.len() && expected.iter().all(|key| object.contains_key(*key)) {
        Ok(())
    } else {
        Err(RendezvousError::InvalidFrame)
    }
}

fn string<'a>(object: &'a BTreeMap<String, Value>, key: &str) -> Result<&'a str, RendezvousError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or(RendezvousError::InvalidFrame)
}

fn integer(object: &BTreeMap<String, Value>, key: &str) -> Result<i64, RendezvousError> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .ok_or(RendezvousError::InvalidFrame)
}

fn device_id(object: &BTreeMap<String, Value>, key: &str) -> Result<String, RendezvousError> {
    let value = string(object, key)?;
    valid_device_id(value)?;
    Ok(value.to_owned())
}

fn valid_device_id(value: &str) -> Result<(), RendezvousError> {
    let parsed = Uuid::parse_str(value).map_err(|_| RendezvousError::InvalidFrame)?;
    if parsed.to_string() == value {
        Ok(())
    } else {
        Err(RendezvousError::InvalidFrame)
    }
}

fn bounded_code(object: &BTreeMap<String, Value>) -> Result<String, RendezvousError> {
    let code = string(object, "code")?;
    if code.is_empty() || code.len() > 128 || !code.is_ascii() {
        return Err(RendezvousError::InvalidFrame);
    }
    Ok(code.to_owned())
}

fn decode_base64(value: &str, maximum: usize) -> Result<Vec<u8>, RendezvousError> {
    if value.len() > maximum.div_ceil(3) * 4 {
        return Err(RendezvousError::FrameTooLarge);
    }
    let decoded = STANDARD
        .decode(value)
        .map_err(|_| RendezvousError::InvalidFrame)?;
    if decoded.len() > maximum {
        return Err(RendezvousError::FrameTooLarge);
    }
    if STANDARD.encode(&decoded) != value {
        return Err(RendezvousError::InvalidFrame);
    }
    Ok(decoded)
}
