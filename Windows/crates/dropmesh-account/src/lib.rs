use std::collections::{BTreeMap, btree_map::Entry};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use p256::ecdsa::{Signature, VerifyingKey, signature::Verifier as _};
use serde::Deserialize;
use serde::de::{self, MapAccess, Visitor};
use sha2::{Digest as _, Sha256};
use thiserror::Error;

const PURPOSE: &str = "dropmesh.account.group.event.v1";

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum AccountError {
    #[error("invalid account wire representation")]
    InvalidWire,
    #[error("invalid account cryptographic proof")]
    InvalidProof,
    #[error("invalid account group state")]
    InvalidState,
    #[error("invalid account group transition")]
    InvalidTransition,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GroupMember {
    pub device_id: String,
    pub public_key: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedEvent {
    payload: Vec<u8>,
    account_id: String,
    group_id: String,
    generation: u64,
    sequence: u64,
    previous_hash: [u8; 32],
    previous_hash_empty: bool,
    action: Action,
    actor: GroupMember,
    subject: GroupMember,
    epoch_milliseconds: i64,
    digest: [u8; 32],
}

impl VerifiedEvent {
    #[must_use]
    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    #[must_use]
    pub fn group_id(&self) -> &str {
        &self.group_id
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    #[must_use]
    pub const fn sequence(&self) -> u64 {
        self.sequence
    }

    #[must_use]
    pub const fn previous_hash(&self) -> [u8; 32] {
        self.previous_hash
    }

    #[must_use]
    pub const fn digest(&self) -> [u8; 32] {
        self.digest
    }

    #[must_use]
    pub const fn actor(&self) -> &GroupMember {
        &self.actor
    }

    #[must_use]
    pub const fn subject(&self) -> &GroupMember {
        &self.subject
    }

    #[must_use]
    pub const fn epoch_milliseconds(&self) -> i64 {
        self.epoch_milliseconds
    }

    #[must_use]
    pub fn canonical_payload(&self) -> &[u8] {
        &self.payload
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Action {
    Bootstrap,
    Approve,
    Remove,
}

#[derive(Clone, Debug)]
pub struct ApprovalDraft {
    payload: Vec<u8>,
    signature: Vec<u8>,
    parsed: ParsedEvent,
}

impl ApprovalDraft {
    /// Parses the exact two-field draft JSON and verifies the actor signature.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidWire`] for noncanonical input and
    /// [`AccountError::InvalidProof`] when the actor signature is invalid.
    pub fn decode_json_strict(bytes: &[u8]) -> Result<Self, AccountError> {
        if bytes.len() > 8_192 {
            return Err(AccountError::InvalidWire);
        }
        let wire: DraftWire =
            serde_json::from_slice(bytes).map_err(|_| AccountError::InvalidWire)?;
        let payload = canonical_base64(&wire.payload, 4_096)?;
        let signature = canonical_base64(&wire.signature, 108)?;
        let parsed = ParsedEvent::decode_canonical(&payload)?;
        if parsed.action != Action::Approve {
            return Err(AccountError::InvalidWire);
        }
        verify_signature(&parsed.actor.public_key, &payload, &signature)?;
        let value = Self {
            payload,
            signature,
            parsed,
        };
        if value.encode_json().as_slice() != bytes {
            return Err(AccountError::InvalidWire);
        }
        Ok(value)
    }

    #[must_use]
    pub fn canonical_payload_base64(&self) -> String {
        STANDARD.encode(&self.payload)
    }

    #[must_use]
    pub fn encode_json(&self) -> Vec<u8> {
        format!(
            "{{\"payload\":\"{}\",\"signature\":\"{}\"}}",
            STANDARD.encode(&self.payload),
            STANDARD.encode(&self.signature)
        )
        .into_bytes()
    }

    /// Adds and verifies the joining device's proof over the unchanged payload.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidProof`] for malformed or invalid proof.
    pub fn finalize_base64(&self, subject_signature: &str) -> Result<VerifiedEvent, AccountError> {
        let subject_signature =
            canonical_base64(subject_signature, 108).map_err(|_| AccountError::InvalidProof)?;
        verify_signature(
            &self.parsed.subject.public_key,
            &self.payload,
            &subject_signature,
        )?;
        Ok(self.parsed.clone().into_verified(self.payload.clone()))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    #[serde(rename = "accountID")]
    account_id: String,
    action: String,
    #[serde(rename = "actorDeviceID")]
    actor_device_id: String,
    #[serde(rename = "actorPublicKey")]
    actor_public_key: String,
    #[serde(rename = "epochMilliseconds")]
    epoch_milliseconds: i64,
    generation: u64,
    #[serde(rename = "groupID")]
    group_id: String,
    #[serde(rename = "previousHash")]
    previous_hash: String,
    purpose: String,
    sequence: u64,
    #[serde(rename = "subjectDeviceID")]
    subject_device_id: String,
    #[serde(rename = "subjectPublicKey")]
    subject_public_key: String,
}

#[derive(Clone, Debug)]
struct ParsedEvent {
    account_id: String,
    group_id: String,
    generation: u64,
    sequence: u64,
    previous_hash: [u8; 32],
    previous_hash_empty: bool,
    action: Action,
    actor: GroupMember,
    subject: GroupMember,
    epoch_milliseconds: i64,
}

impl ParsedEvent {
    fn decode_canonical(bytes: &[u8]) -> Result<Self, AccountError> {
        let payload: Payload =
            serde_json::from_slice(bytes).map_err(|_| AccountError::InvalidWire)?;
        let actor_key = canonical_base64(&payload.actor_public_key, 88)?;
        let subject_key = canonical_base64(&payload.subject_public_key, 88)?;
        validate_public_key(&actor_key)?;
        validate_public_key(&subject_key)?;
        let previous = canonical_base64(&payload.previous_hash, 44)?;
        let (previous_hash, previous_hash_empty) = if previous.is_empty() {
            ([0; 32], true)
        } else {
            let value: [u8; 32] = previous.try_into().map_err(|_| AccountError::InvalidWire)?;
            (value, false)
        };
        let action = match payload.action.as_str() {
            "bootstrap" => Action::Bootstrap,
            "approve" => Action::Approve,
            "remove" => Action::Remove,
            _ => return Err(AccountError::InvalidWire),
        };
        if payload.purpose != PURPOSE
            || !is_lower_uuid(&payload.account_id)
            || !is_lower_uuid(&payload.group_id)
            || payload.generation == 0
            || payload.generation > i64::MAX as u64
            || payload.sequence == 0
            || payload.sequence > i64::MAX as u64
            || payload.epoch_milliseconds <= 0
            || device_id(&actor_key) != payload.actor_device_id
            || device_id(&subject_key) != payload.subject_device_id
        {
            return Err(AccountError::InvalidWire);
        }
        match action {
            Action::Bootstrap
                if payload.sequence == 1
                    && previous_hash_empty
                    && payload.actor_device_id == payload.subject_device_id
                    && actor_key == subject_key => {}
            Action::Approve
                if payload.sequence >= 2
                    && !previous_hash_empty
                    && payload.actor_device_id != payload.subject_device_id => {}
            Action::Remove
                if payload.sequence >= 2
                    && !previous_hash_empty
                    && (payload.actor_device_id != payload.subject_device_id
                        || actor_key == subject_key) => {}
            _ => return Err(AccountError::InvalidWire),
        }
        let parsed = Self {
            account_id: payload.account_id,
            group_id: payload.group_id,
            generation: payload.generation,
            sequence: payload.sequence,
            previous_hash,
            previous_hash_empty,
            action,
            actor: GroupMember {
                device_id: payload.actor_device_id,
                public_key: actor_key,
            },
            subject: GroupMember {
                device_id: payload.subject_device_id,
                public_key: subject_key,
            },
            epoch_milliseconds: payload.epoch_milliseconds,
        };
        if parsed.canonical_payload() != bytes {
            return Err(AccountError::InvalidWire);
        }
        Ok(parsed)
    }

    fn canonical_payload(&self) -> Vec<u8> {
        let action = match self.action {
            Action::Bootstrap => "bootstrap",
            Action::Approve => "approve",
            Action::Remove => "remove",
        };
        let previous_hash = if self.previous_hash_empty {
            String::new()
        } else {
            STANDARD.encode(self.previous_hash)
        };
        format!(
            "{{\"accountID\":\"{}\",\"action\":\"{action}\",\"actorDeviceID\":\"{}\",\"actorPublicKey\":\"{}\",\"epochMilliseconds\":{},\"generation\":{},\"groupID\":\"{}\",\"previousHash\":\"{previous_hash}\",\"purpose\":\"{PURPOSE}\",\"sequence\":{},\"subjectDeviceID\":\"{}\",\"subjectPublicKey\":\"{}\"}}",
            self.account_id,
            self.actor.device_id,
            STANDARD.encode(&self.actor.public_key),
            self.epoch_milliseconds,
            self.generation,
            self.group_id,
            self.sequence,
            self.subject.device_id,
            STANDARD.encode(&self.subject.public_key),
        )
        .into_bytes()
    }

    fn into_verified(self, payload: Vec<u8>) -> VerifiedEvent {
        let digest = Sha256::digest(&payload).into();
        VerifiedEvent {
            payload,
            account_id: self.account_id,
            group_id: self.group_id,
            generation: self.generation,
            sequence: self.sequence,
            previous_hash: self.previous_hash,
            previous_hash_empty: self.previous_hash_empty,
            action: self.action,
            actor: self.actor,
            subject: self.subject,
            epoch_milliseconds: self.epoch_milliseconds,
            digest,
        }
    }
}

struct DraftWire {
    payload: String,
    signature: String,
}

impl<'de> Deserialize<'de> for DraftWire {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct DraftVisitor;

        impl<'de> Visitor<'de> for DraftVisitor {
            type Value = DraftWire;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an exact payload/signature object")
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: MapAccess<'de>,
            {
                let mut payload = None;
                let mut signature = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "payload" if payload.is_none() => payload = Some(map.next_value()?),
                        "signature" if signature.is_none() => signature = Some(map.next_value()?),
                        "payload" => return Err(de::Error::duplicate_field("payload")),
                        "signature" => return Err(de::Error::duplicate_field("signature")),
                        _ => return Err(de::Error::unknown_field(&key, &["payload", "signature"])),
                    }
                }
                Ok(DraftWire {
                    payload: payload.ok_or_else(|| de::Error::missing_field("payload"))?,
                    signature: signature.ok_or_else(|| de::Error::missing_field("signature"))?,
                })
            }
        }

        deserializer.deserialize_map(DraftVisitor)
    }
}

fn canonical_base64(value: &str, encoded_limit: usize) -> Result<Vec<u8>, AccountError> {
    if value.len() > encoded_limit {
        return Err(AccountError::InvalidWire);
    }
    let bytes = STANDARD
        .decode(value)
        .map_err(|_| AccountError::InvalidWire)?;
    if STANDARD.encode(&bytes) != value {
        return Err(AccountError::InvalidWire);
    }
    Ok(bytes)
}

fn validate_public_key(bytes: &[u8]) -> Result<(), AccountError> {
    let encoded = match bytes {
        bytes if bytes.len() == 64 => {
            let mut encoded = Vec::with_capacity(65);
            encoded.push(4);
            encoded.extend_from_slice(bytes);
            encoded
        }
        bytes if bytes.len() == 65 && bytes.first() == Some(&4) => bytes.to_vec(),
        _ => return Err(AccountError::InvalidWire),
    };
    VerifyingKey::from_sec1_bytes(&encoded)
        .map(|_| ())
        .map_err(|_| AccountError::InvalidWire)
}

fn verify_signature(key: &[u8], payload: &[u8], signature: &[u8]) -> Result<(), AccountError> {
    if signature.is_empty() || signature.len() > 80 {
        return Err(AccountError::InvalidProof);
    }
    let encoded = if key.len() == 64 {
        let mut encoded = Vec::with_capacity(65);
        encoded.push(4);
        encoded.extend_from_slice(key);
        encoded
    } else {
        key.to_vec()
    };
    let key = VerifyingKey::from_sec1_bytes(&encoded).map_err(|_| AccountError::InvalidProof)?;
    let signature = Signature::from_der(signature).map_err(|_| AccountError::InvalidProof)?;
    key.verify(payload, &signature)
        .map_err(|_| AccountError::InvalidProof)
}

fn device_id(public_key: &[u8]) -> String {
    let hex = hex::encode(&Sha256::digest(public_key)[..16]);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

fn is_lower_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(byte)
            }
        })
}

#[derive(Debug)]
pub struct AccountGroupState {
    account_id: String,
    group_id: String,
    generation: u64,
    sequence: u64,
    last_hash: [u8; 32],
    members: BTreeMap<String, GroupMember>,
}

impl AccountGroupState {
    /// Creates a state from a verified bootstrap event.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidTransition`] unless this is the initial
    /// bootstrap event with no previous hash.
    pub fn bootstrap(event: VerifiedEvent) -> Result<Self, AccountError> {
        if event.action != Action::Bootstrap || !event.previous_hash_empty {
            return Err(AccountError::InvalidTransition);
        }
        let mut members = BTreeMap::new();
        members.insert(event.subject.device_id.clone(), event.subject.clone());
        Ok(Self {
            account_id: event.account_id,
            group_id: event.group_id,
            generation: event.generation,
            sequence: event.sequence,
            last_hash: event.digest,
            members,
        })
    }

    /// Restores a previously authenticated group snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidState`] when identifiers, counters,
    /// membership keys, or members are structurally invalid.
    pub fn restore(
        account_id: impl Into<String>,
        group_id: impl Into<String>,
        generation: u64,
        sequence: u64,
        last_hash: [u8; 32],
        members: BTreeMap<String, GroupMember>,
    ) -> Result<Self, AccountError> {
        let account_id = account_id.into();
        let group_id = group_id.into();
        if account_id.is_empty()
            || group_id.is_empty()
            || generation == 0
            || sequence == 0
            || sequence == u64::MAX
            || members.is_empty()
            || members.iter().any(|(id, member)| {
                id != &member.device_id
                    || validate_public_key(&member.public_key).is_err()
                    || device_id(&member.public_key) != member.device_id
            })
        {
            return Err(AccountError::InvalidState);
        }
        Ok(Self {
            account_id,
            group_id,
            generation,
            sequence,
            last_hash,
            members,
        })
    }

    /// Applies the exact next cryptographically verified event.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidTransition`] for a chain mismatch,
    /// unauthorized actor, duplicate approval, or nonexistent removal.
    pub fn apply(&mut self, event: VerifiedEvent) -> Result<(), AccountError> {
        let expected_sequence = self
            .sequence
            .checked_add(1)
            .ok_or(AccountError::InvalidTransition)?;
        if event.account_id != self.account_id
            || event.group_id != self.group_id
            || event.generation != self.generation
            || event.sequence != expected_sequence
            || event.previous_hash_empty
            || event.previous_hash != self.last_hash
            || self.members.get(&event.actor.device_id) != Some(&event.actor)
        {
            return Err(AccountError::InvalidTransition);
        }
        match event.action {
            Action::Approve => match self.members.entry(event.subject.device_id.clone()) {
                Entry::Vacant(entry) => {
                    entry.insert(event.subject);
                }
                Entry::Occupied(_) => return Err(AccountError::InvalidTransition),
            },
            Action::Remove => {
                if self.members.remove(&event.subject.device_id).is_none() {
                    return Err(AccountError::InvalidTransition);
                }
            }
            Action::Bootstrap => return Err(AccountError::InvalidTransition),
        }
        self.sequence = event.sequence;
        self.last_hash = event.digest;
        Ok(())
    }

    #[must_use]
    pub const fn sequence(&self) -> u64 {
        self.sequence
    }

    #[must_use]
    pub fn member(&self, device_id: &str) -> Option<&GroupMember> {
        self.members.get(device_id)
    }
}
