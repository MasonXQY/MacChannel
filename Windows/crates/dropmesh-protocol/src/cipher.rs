use aes_gcm::{
    Aes256Gcm, KeyInit,
    aead::{Aead, Payload},
};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    AUTH_TAG_BYTES, ENCRYPTED_HEADER_BYTES, MAX_FRAME_PLAINTEXT_BYTES, MAX_WIRE_FRAME_BYTES,
    ProtocolError, VERSION,
};

const MAGIC: &[u8; 4] = b"MCXF";
const NONCE_LABEL: &[u8] = b"macchannel-transfer-nonce-v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Direction {
    SenderToReceiver = 1,
    ReceiverToSender = 2,
}

impl TryFrom<u8> for Direction {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::SenderToReceiver),
            2 => Ok(Self::ReceiverToSender),
            _ => Err(ProtocolError::InvalidFrame),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EncryptedTransferFrame {
    pub transfer_id: Uuid,
    pub sequence: u64,
    pub direction: Direction,
    pub nonce_epoch: [u8; 16],
    pub ciphertext: Vec<u8>,
    pub tag: [u8; AUTH_TAG_BYTES],
}

impl EncryptedTransferFrame {
    #[must_use]
    pub fn wire_data(&self) -> Vec<u8> {
        let mut output = wire_header(
            self.transfer_id,
            self.sequence,
            self.direction,
            self.nonce_epoch,
        );
        output.extend_from_slice(&self.ciphertext);
        output.extend_from_slice(&self.tag);
        output
    }
}

#[derive(Clone)]
pub struct ChunkCipher {
    key: [u8; 32],
}

impl ChunkCipher {
    #[must_use]
    pub const fn new(key: [u8; 32]) -> Self {
        Self { key }
    }

    pub fn seal(
        &self,
        plaintext: &[u8],
        transfer_id: Uuid,
        sequence: u64,
        direction: Direction,
        nonce_epoch: [u8; 16],
    ) -> Result<Vec<u8>, ProtocolError> {
        if plaintext.len() > MAX_FRAME_PLAINTEXT_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }
        let header = wire_header(transfer_id, sequence, direction, nonce_epoch);
        let nonce = nonce(&header);
        let cipher = Aes256Gcm::new_from_slice(&self.key)
            .map_err(|_| ProtocolError::AuthenticationFailed)?;
        let sealed = cipher
            .encrypt(
                (&nonce).into(),
                Payload {
                    msg: plaintext,
                    aad: &header,
                },
            )
            .map_err(|_| ProtocolError::AuthenticationFailed)?;
        let mut output = header;
        output.extend_from_slice(&sealed);
        if output.len() > MAX_WIRE_FRAME_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }
        Ok(output)
    }

    pub fn open_wire(
        &self,
        wire: &[u8],
        expected_transfer_id: Uuid,
        expected_sequence: u64,
        expected_direction: Direction,
    ) -> Result<Vec<u8>, ProtocolError> {
        if wire.len() < ENCRYPTED_HEADER_BYTES + AUTH_TAG_BYTES
            || wire.len() > MAX_WIRE_FRAME_BYTES
            || wire.get(..4) != Some(MAGIC)
            || wire.get(4).copied() != Some(VERSION)
        {
            return Err(ProtocolError::InvalidFrame);
        }
        let direction = Direction::try_from(wire[5])?;
        if direction != expected_direction {
            return Err(ProtocolError::InvalidFrame);
        }
        let transfer_id =
            Uuid::from_slice(&wire[6..22]).map_err(|_| ProtocolError::InvalidFrame)?;
        let sequence = u64::from_be_bytes(
            wire[22..30]
                .try_into()
                .map_err(|_| ProtocolError::InvalidFrame)?,
        );
        if transfer_id != expected_transfer_id || sequence != expected_sequence {
            return Err(ProtocolError::ReplayOrOutOfOrder);
        }
        let header = &wire[..ENCRYPTED_HEADER_BYTES];
        let nonce = nonce(header);
        let cipher = Aes256Gcm::new_from_slice(&self.key)
            .map_err(|_| ProtocolError::AuthenticationFailed)?;
        cipher
            .decrypt(
                (&nonce).into(),
                Payload {
                    msg: &wire[ENCRYPTED_HEADER_BYTES..],
                    aad: header,
                },
            )
            .map_err(|_| ProtocolError::AuthenticationFailed)
    }
}

fn wire_header(
    transfer_id: Uuid,
    sequence: u64,
    direction: Direction,
    nonce_epoch: [u8; 16],
) -> Vec<u8> {
    let mut output = Vec::with_capacity(ENCRYPTED_HEADER_BYTES);
    output.extend_from_slice(MAGIC);
    output.push(VERSION);
    output.push(direction as u8);
    output.extend_from_slice(transfer_id.as_bytes());
    output.extend_from_slice(&sequence.to_be_bytes());
    output.extend_from_slice(&nonce_epoch);
    output
}

fn nonce(header: &[u8]) -> [u8; 12] {
    let mut digest = Sha256::new();
    digest.update(NONCE_LABEL);
    digest.update(header);
    let hash = digest.finalize();
    let mut nonce = [0_u8; 12];
    nonce.copy_from_slice(&hash[..12]);
    nonce
}
