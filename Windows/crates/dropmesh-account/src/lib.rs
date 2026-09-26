use std::collections::{BTreeMap, btree_map::Entry};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use p256::ecdsa::{Signature, VerifyingKey, signature::Verifier as _};
use serde::Deserialize;
use serde::de::{self, MapAccess, Visitor};
use serde_json::value::RawValue;
use sha2::{Digest as _, Sha256};
use thiserror::Error;

const PURPOSE: &str = "dropmesh.account.group.event.v1";
const DISCOVERY_PURPOSE: &str = "dropmesh.account.group.discover.v1";
const HISTORY_PURPOSE: &str = "dropmesh.account.group.events.v1";

/// Creates the canonical inner payload for signed account-group discovery.
///
/// # Errors
///
/// Returns [`AccountError::InvalidWire`] when the audience or access token
/// cannot be accepted by the existing Swift/Go service contract.
pub fn encode_discovery_request(
    audience: &str,
    access_token: &str,
) -> Result<Vec<u8>, AccountError> {
    if !valid_credential(audience, 255) || !valid_token(access_token) {
        return Err(AccountError::InvalidWire);
    }
    let fields = BTreeMap::from([
        ("accessToken", access_token),
        ("audience", audience),
        ("purpose", DISCOVERY_PURPOSE),
    ]);
    serde_json::to_vec(&fields).map_err(|_| AccountError::InvalidWire)
}

/// Creates the canonical inner payload for one verified history page.
///
/// # Errors
///
/// Returns [`AccountError::InvalidWire`] for invalid credentials, identifiers,
/// counters, or a missing/mismatched pinned head.
pub fn encode_history_request(
    audience: &str,
    access_token: &str,
    group_id: &str,
    after_sequence: u64,
    expected_head_hash: Option<[u8; 32]>,
) -> Result<Vec<u8>, AccountError> {
    if !valid_credential(audience, 255)
        || !valid_token(access_token)
        || !is_lower_uuid(group_id)
        || after_sequence > 8_192
        || (after_sequence == 0) != expected_head_hash.is_none()
    {
        return Err(AccountError::InvalidWire);
    }
    let after_sequence = after_sequence.to_string();
    let expected_head_hash =
        expected_head_hash.map_or_else(String::new, |hash| STANDARD.encode(hash));
    let fields = BTreeMap::from([
        ("accessToken", access_token.to_owned()),
        ("afterSequence", after_sequence),
        ("audience", audience.to_owned()),
        ("expectedHeadHash", expected_head_hash),
        ("groupID", group_id.to_owned()),
        ("purpose", HISTORY_PURPOSE.to_owned()),
    ]);
    serde_json::to_vec(&fields).map_err(|_| AccountError::InvalidWire)
}

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
    /// Parses the exact three-field event JSON and verifies every required proof.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidWire`] for noncanonical input and
    /// [`AccountError::InvalidProof`] when an event signature is invalid.
    pub fn decode_json_strict(bytes: &[u8]) -> Result<Self, AccountError> {
        if bytes.len() > 8_192 {
            return Err(AccountError::InvalidWire);
        }
        let wire: EventWire =
            serde_json::from_slice(bytes).map_err(|_| AccountError::InvalidWire)?;
        let payload = canonical_base64(&wire.payload, 4_096)?;
        let signature = canonical_base64(&wire.signature, 108)?;
        let subject_signature = canonical_base64(&wire.subject_signature, 108)?;
        let parsed = ParsedEvent::decode_canonical(&payload)?;
        verify_signature(&parsed.actor.public_key, &payload, &signature)?;
        if parsed.action == Action::Approve {
            verify_signature(&parsed.subject.public_key, &payload, &subject_signature)?;
        } else if !subject_signature.is_empty() {
            return Err(AccountError::InvalidWire);
        }
        let canonical = format!(
            "{{\"payload\":\"{}\",\"signature\":\"{}\",\"subjectSignature\":\"{}\"}}",
            wire.payload, wire.signature, wire.subject_signature
        );
        if canonical.as_bytes() != bytes {
            return Err(AccountError::InvalidWire);
        }
        Ok(parsed.into_verified(payload))
    }

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

    #[must_use]
    pub const fn action(&self) -> &'static str {
        match self.action {
            Action::Bootstrap => "bootstrap",
            Action::Approve => "approve",
            Action::Remove => "remove",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Action {
    Bootstrap,
    Approve,
    Remove,
}

/// Untrusted account-group discovery metadata. A caller must still apply the
/// complete verified history and obtain local approval before granting trust.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AccountDiscovery {
    Absent,
    Present(Box<AccountDiscoveryMetadata>),
}

impl AccountDiscovery {
    /// Parses and verifies the bounded discovery response returned by the
    /// existing Swift/Go account enrollment contract.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidWire`] for ambiguous, malformed, or
    /// inconsistently bound discovery metadata.
    pub fn decode_json_strict(
        bytes: &[u8],
        expected_account_id: &str,
    ) -> Result<Self, AccountError> {
        if bytes.len() > 65_536 || !is_lower_uuid(expected_account_id) {
            return Err(AccountError::InvalidWire);
        }
        let wire: DiscoveryWire =
            serde_json::from_slice(bytes).map_err(|_| AccountError::InvalidWire)?;
        if wire.status == "absent"
            && wire.group_id.is_none()
            && wire.generation.is_none()
            && wire.anchor.is_none()
            && wire.anchor_hash.is_none()
            && wire.head_sequence.is_none()
            && wire.head_hash.is_none()
        {
            return Ok(Self::Absent);
        }
        let (
            Some(group_id),
            Some(generation),
            Some(anchor),
            Some(anchor_hash),
            Some(head_sequence),
            Some(head_hash),
        ) = (
            wire.group_id,
            wire.generation,
            wire.anchor,
            wire.anchor_hash,
            wire.head_sequence,
            wire.head_hash,
        )
        else {
            return Err(AccountError::InvalidWire);
        };
        if wire.status != "present"
            || !is_lower_uuid(&group_id)
            || generation == 0
            || generation > i64::MAX as u64
            || !(1..=8_192).contains(&head_sequence)
        {
            return Err(AccountError::InvalidWire);
        }
        let anchor = VerifiedEvent::decode_json_strict(anchor.get().as_bytes())?;
        let anchor_hash: [u8; 32] = canonical_base64(&anchor_hash, 44)?
            .try_into()
            .map_err(|_| AccountError::InvalidWire)?;
        let head_hash: [u8; 32] = canonical_base64(&head_hash, 44)?
            .try_into()
            .map_err(|_| AccountError::InvalidWire)?;
        if anchor.action != Action::Bootstrap
            || anchor.account_id != expected_account_id
            || anchor.group_id != group_id
            || anchor.generation != generation
            || anchor.digest != anchor_hash
            || (head_sequence == 1 && head_hash != anchor_hash)
        {
            return Err(AccountError::InvalidWire);
        }
        Ok(Self::Present(Box::new(AccountDiscoveryMetadata {
            group_id,
            generation,
            anchor,
            anchor_hash,
            head_sequence,
            head_hash,
        })))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccountDiscoveryMetadata {
    group_id: String,
    generation: u64,
    anchor: VerifiedEvent,
    anchor_hash: [u8; 32],
    head_sequence: u64,
    head_hash: [u8; 32],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccountGroupPage {
    group_id: String,
    generation: u64,
    head_sequence: u64,
    head_hash: [u8; 32],
    after_sequence: u64,
    next_sequence: u64,
    has_more: bool,
    events: Vec<VerifiedEvent>,
}

impl AccountGroupPage {
    /// Strictly decodes one server page and verifies its signed hash chain.
    ///
    /// `expected_head_hash` and `expected_previous_hash` must both be absent
    /// for the initial page and present for every continuation page.
    ///
    /// # Errors
    ///
    /// Returns [`AccountError::InvalidWire`] for any schema, binding, proof,
    /// pagination, or hash-chain inconsistency.
    pub fn decode_json_strict(
        bytes: &[u8],
        expected_account_id: &str,
        expected_group_id: &str,
        expected_after_sequence: u64,
        expected_head_hash: Option<[u8; 32]>,
        expected_previous_hash: Option<[u8; 32]>,
    ) -> Result<Self, AccountError> {
        if bytes.len() > 65_536
            || !is_lower_uuid(expected_account_id)
            || !is_lower_uuid(expected_group_id)
            || expected_after_sequence > 8_192
            || (expected_after_sequence == 0)
                != (expected_head_hash.is_none() && expected_previous_hash.is_none())
        {
            return Err(AccountError::InvalidWire);
        }
        let wire: GroupPageWire =
            serde_json::from_slice(bytes).map_err(|_| AccountError::InvalidWire)?;
        if wire.group_id != expected_group_id
            || wire.generation == 0
            || wire.generation > i64::MAX as u64
            || !(1..=8_192).contains(&wire.head_sequence)
            || wire.after_sequence != expected_after_sequence
            || wire.next_sequence > 8_192
            || wire.events.is_empty()
            || wire.events.len() > 16
        {
            return Err(AccountError::InvalidWire);
        }
        let head_hash: [u8; 32] = canonical_base64(&wire.head_hash, 44)?
            .try_into()
            .map_err(|_| AccountError::InvalidWire)?;
        if expected_head_hash.is_some_and(|expected| expected != head_hash) {
            return Err(AccountError::InvalidWire);
        }
        let count = u64::try_from(wire.events.len()).map_err(|_| AccountError::InvalidWire)?;
        if wire.next_sequence != wire.after_sequence.saturating_add(count)
            || wire.next_sequence > wire.head_sequence
            || wire.has_more != (wire.next_sequence < wire.head_sequence)
        {
            return Err(AccountError::InvalidWire);
        }
        let mut previous_hash = expected_previous_hash.unwrap_or([0; 32]);
        let mut events = Vec::with_capacity(wire.events.len());
        for (offset, raw) in wire.events.into_iter().enumerate() {
            let event = VerifiedEvent::decode_json_strict(raw.get().as_bytes())?;
            let sequence = wire
                .after_sequence
                .checked_add(u64::try_from(offset).map_err(|_| AccountError::InvalidWire)?)
                .and_then(|value| value.checked_add(1))
                .ok_or(AccountError::InvalidWire)?;
            if event.account_id != expected_account_id
                || event.group_id != expected_group_id
                || event.generation != wire.generation
                || event.sequence != sequence
                || event.previous_hash != previous_hash
                || (sequence == 1 && event.action != Action::Bootstrap)
            {
                return Err(AccountError::InvalidWire);
            }
            previous_hash = event.digest;
            events.push(event);
        }
        if !wire.has_more && previous_hash != head_hash {
            return Err(AccountError::InvalidWire);
        }
        Ok(Self {
            group_id: wire.group_id,
            generation: wire.generation,
            head_sequence: wire.head_sequence,
            head_hash,
            after_sequence: wire.after_sequence,
            next_sequence: wire.next_sequence,
            has_more: wire.has_more,
            events,
        })
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
    pub const fn head_sequence(&self) -> u64 {
        self.head_sequence
    }
    #[must_use]
    pub const fn head_hash(&self) -> [u8; 32] {
        self.head_hash
    }
    #[must_use]
    pub const fn after_sequence(&self) -> u64 {
        self.after_sequence
    }
    #[must_use]
    pub const fn next_sequence(&self) -> u64 {
        self.next_sequence
    }
    #[must_use]
    pub const fn has_more(&self) -> bool {
        self.has_more
    }
    #[must_use]
    pub fn events(&self) -> &[VerifiedEvent] {
        &self.events
    }
}

impl AccountDiscoveryMetadata {
    #[must_use]
    pub fn group_id(&self) -> &str {
        &self.group_id
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    #[must_use]
    pub const fn anchor(&self) -> &VerifiedEvent {
        &self.anchor
    }

    #[must_use]
    pub const fn anchor_hash(&self) -> [u8; 32] {
        self.anchor_hash
    }

    #[must_use]
    pub const fn head_sequence(&self) -> u64 {
        self.head_sequence
    }

    #[must_use]
    pub const fn head_hash(&self) -> [u8; 32] {
        self.head_hash
    }
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

struct EventWire {
    payload: String,
    signature: String,
    subject_signature: String,
}

struct DiscoveryWire {
    status: String,
    group_id: Option<String>,
    generation: Option<u64>,
    anchor: Option<Box<RawValue>>,
    anchor_hash: Option<String>,
    head_sequence: Option<u64>,
    head_hash: Option<String>,
}

struct GroupPageWire {
    group_id: String,
    generation: u64,
    head_sequence: u64,
    head_hash: String,
    after_sequence: u64,
    next_sequence: u64,
    has_more: bool,
    events: Vec<Box<RawValue>>,
}

impl<'de> Deserialize<'de> for GroupPageWire {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct GroupPageVisitor;

        impl<'de> Visitor<'de> for GroupPageVisitor {
            type Value = GroupPageWire;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an exact bounded account group page")
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: MapAccess<'de>,
            {
                let mut group_id = None;
                let mut generation = None;
                let mut head_sequence = None;
                let mut head_hash = None;
                let mut after_sequence = None;
                let mut next_sequence = None;
                let mut has_more = None;
                let mut events = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "groupID" if group_id.is_none() => group_id = Some(map.next_value()?),
                        "generation" if generation.is_none() => {
                            generation = Some(map.next_value()?);
                        }
                        "headSequence" if head_sequence.is_none() => {
                            head_sequence = Some(map.next_value()?);
                        }
                        "headHash" if head_hash.is_none() => head_hash = Some(map.next_value()?),
                        "afterSequence" if after_sequence.is_none() => {
                            after_sequence = Some(map.next_value()?);
                        }
                        "nextSequence" if next_sequence.is_none() => {
                            next_sequence = Some(map.next_value()?);
                        }
                        "hasMore" if has_more.is_none() => has_more = Some(map.next_value()?),
                        "events" if events.is_none() => events = Some(map.next_value()?),
                        "groupID" => return Err(de::Error::duplicate_field("groupID")),
                        "generation" => return Err(de::Error::duplicate_field("generation")),
                        "headSequence" => return Err(de::Error::duplicate_field("headSequence")),
                        "headHash" => return Err(de::Error::duplicate_field("headHash")),
                        "afterSequence" => return Err(de::Error::duplicate_field("afterSequence")),
                        "nextSequence" => return Err(de::Error::duplicate_field("nextSequence")),
                        "hasMore" => return Err(de::Error::duplicate_field("hasMore")),
                        "events" => return Err(de::Error::duplicate_field("events")),
                        _ => {
                            return Err(de::Error::unknown_field(
                                &key,
                                &[
                                    "groupID",
                                    "generation",
                                    "headSequence",
                                    "headHash",
                                    "afterSequence",
                                    "nextSequence",
                                    "hasMore",
                                    "events",
                                ],
                            ));
                        }
                    }
                }
                Ok(GroupPageWire {
                    group_id: group_id.ok_or_else(|| de::Error::missing_field("groupID"))?,
                    generation: generation.ok_or_else(|| de::Error::missing_field("generation"))?,
                    head_sequence: head_sequence
                        .ok_or_else(|| de::Error::missing_field("headSequence"))?,
                    head_hash: head_hash.ok_or_else(|| de::Error::missing_field("headHash"))?,
                    after_sequence: after_sequence
                        .ok_or_else(|| de::Error::missing_field("afterSequence"))?,
                    next_sequence: next_sequence
                        .ok_or_else(|| de::Error::missing_field("nextSequence"))?,
                    has_more: has_more.ok_or_else(|| de::Error::missing_field("hasMore"))?,
                    events: events.ok_or_else(|| de::Error::missing_field("events"))?,
                })
            }
        }
        deserializer.deserialize_map(GroupPageVisitor)
    }
}

impl<'de> Deserialize<'de> for DiscoveryWire {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct DiscoveryVisitor;

        impl<'de> Visitor<'de> for DiscoveryVisitor {
            type Value = DiscoveryWire;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an exact bounded account discovery object")
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: MapAccess<'de>,
            {
                let mut status = None;
                let mut group_id = None;
                let mut generation = None;
                let mut anchor = None;
                let mut anchor_hash = None;
                let mut head_sequence = None;
                let mut head_hash = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "status" if status.is_none() => status = Some(map.next_value()?),
                        "groupID" if group_id.is_none() => group_id = Some(map.next_value()?),
                        "generation" if generation.is_none() => {
                            generation = Some(map.next_value()?);
                        }
                        "anchor" if anchor.is_none() => anchor = Some(map.next_value()?),
                        "anchorHash" if anchor_hash.is_none() => {
                            anchor_hash = Some(map.next_value()?);
                        }
                        "headSequence" if head_sequence.is_none() => {
                            head_sequence = Some(map.next_value()?);
                        }
                        "headHash" if head_hash.is_none() => head_hash = Some(map.next_value()?),
                        "status" => return Err(de::Error::duplicate_field("status")),
                        "groupID" => return Err(de::Error::duplicate_field("groupID")),
                        "generation" => return Err(de::Error::duplicate_field("generation")),
                        "anchor" => return Err(de::Error::duplicate_field("anchor")),
                        "anchorHash" => return Err(de::Error::duplicate_field("anchorHash")),
                        "headSequence" => {
                            return Err(de::Error::duplicate_field("headSequence"));
                        }
                        "headHash" => return Err(de::Error::duplicate_field("headHash")),
                        _ => {
                            return Err(de::Error::unknown_field(
                                &key,
                                &[
                                    "status",
                                    "groupID",
                                    "generation",
                                    "anchor",
                                    "anchorHash",
                                    "headSequence",
                                    "headHash",
                                ],
                            ));
                        }
                    }
                }
                Ok(DiscoveryWire {
                    status: status.ok_or_else(|| de::Error::missing_field("status"))?,
                    group_id,
                    generation,
                    anchor,
                    anchor_hash,
                    head_sequence,
                    head_hash,
                })
            }
        }

        deserializer.deserialize_map(DiscoveryVisitor)
    }
}

impl<'de> Deserialize<'de> for EventWire {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct EventVisitor;

        impl<'de> Visitor<'de> for EventVisitor {
            type Value = EventWire;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an exact payload/signature/subjectSignature object")
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: MapAccess<'de>,
            {
                let mut payload = None;
                let mut signature = None;
                let mut subject_signature = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "payload" if payload.is_none() => payload = Some(map.next_value()?),
                        "signature" if signature.is_none() => signature = Some(map.next_value()?),
                        "subjectSignature" if subject_signature.is_none() => {
                            subject_signature = Some(map.next_value()?);
                        }
                        "payload" => return Err(de::Error::duplicate_field("payload")),
                        "signature" => return Err(de::Error::duplicate_field("signature")),
                        "subjectSignature" => {
                            return Err(de::Error::duplicate_field("subjectSignature"));
                        }
                        _ => {
                            return Err(de::Error::unknown_field(
                                &key,
                                &["payload", "signature", "subjectSignature"],
                            ));
                        }
                    }
                }
                Ok(EventWire {
                    payload: payload.ok_or_else(|| de::Error::missing_field("payload"))?,
                    signature: signature.ok_or_else(|| de::Error::missing_field("signature"))?,
                    subject_signature: subject_signature
                        .ok_or_else(|| de::Error::missing_field("subjectSignature"))?,
                })
            }
        }

        deserializer.deserialize_map(EventVisitor)
    }
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

fn valid_credential(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_bytes
        && !value.chars().any(char::is_whitespace)
        && !value.chars().any(char::is_control)
}

fn valid_token(value: &str) -> bool {
    if value.len() != 43 {
        return false;
    }
    let Ok(bytes) = URL_SAFE_NO_PAD.decode(value) else {
        return false;
    };
    bytes.len() == 32 && URL_SAFE_NO_PAD.encode(bytes) == value
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
