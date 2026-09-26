use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProtocolError {
    #[error("unsupportedVersion")]
    UnsupportedVersion,
    #[error("invalidFrame")]
    InvalidFrame,
    #[error("invalidResumeMap")]
    InvalidResumeMap,
    #[error("invalidChunk")]
    InvalidChunk,
    #[error("invalidRelativePath")]
    InvalidRelativePath,
    #[error("manifestTooLarge")]
    ManifestTooLarge,
    #[error("frameTooLarge")]
    FrameTooLarge,
    #[error("authenticationFailed")]
    AuthenticationFailed,
    #[error("replayOrOutOfOrder")]
    ReplayOrOutOfOrder,
    #[error("invalidPairingOffer")]
    InvalidPairingOffer,
    #[error("invalidSignedEnvelope")]
    InvalidSignedEnvelope,
}
