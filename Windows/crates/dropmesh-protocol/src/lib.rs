//! Strict, fixture-compatible `DropMesh` protocol v1 primitives.

#![forbid(unsafe_code)]
#![allow(clippy::missing_errors_doc)]

mod cipher;
mod error;
mod frame;
mod json;

pub use cipher::{ChunkCipher, Direction, EncryptedTransferFrame};
pub use error::ProtocolError;
pub use frame::{
    Chunk, ChunkCoordinate, ChunkRange, EntryKind, ManifestEntry, RelativePath, RemoteError,
    ResumeMap, TransferFrame, TransferManifest, windows_path_collision_key,
};
pub use json::{PairingOffer, SignedEnvelope, UnverifiedPairingOffer};

pub const VERSION: u8 = 1;
pub const MAX_WIRE_FRAME_BYTES: usize = 65_536;
pub const ENCRYPTED_HEADER_BYTES: usize = 46;
pub const AUTH_TAG_BYTES: usize = 16;
pub const MAX_FRAME_PLAINTEXT_BYTES: usize =
    MAX_WIRE_FRAME_BYTES - ENCRYPTED_HEADER_BYTES - AUTH_TAG_BYTES;
pub const MAX_MANIFEST_ENTRIES: usize = 4_096;
pub const MAX_PATH_BYTES: usize = 4_096;
pub const MAX_RESUME_RANGES: usize = 4_096;
pub const MAX_TRANSFER_CHUNKS: u32 = 1_000_000;
pub const MAX_CHUNK_BYTES: usize = MAX_WIRE_FRAME_BYTES - 84;
pub const MAX_PAIRING_OFFER_JSON_BYTES: usize = 4 * 1_024;
pub const MAX_SIGNED_ENVELOPE_JSON_BYTES: usize = 96 * 1_024;
pub const MAX_SIGNED_ENVELOPE_PAYLOAD_BYTES: usize = 65_536;
