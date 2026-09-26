use std::collections::{HashMap, HashSet};

use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

use crate::{
    MAX_CHUNK_BYTES, MAX_FRAME_PLAINTEXT_BYTES, MAX_MANIFEST_ENTRIES, MAX_PATH_BYTES,
    MAX_RESUME_RANGES, MAX_TRANSFER_CHUNKS, ProtocolError, VERSION,
};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct RelativePath(String);

impl RelativePath {
    pub fn new(value: impl Into<String>) -> Result<Self, ProtocolError> {
        let value = value.into();
        let bytes = value.as_bytes();
        let windows_drive = bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':';
        let safe_components = value
            .split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..");
        if value.is_empty()
            || value.contains('\0')
            || value.starts_with('/')
            || value.contains('\\')
            || windows_drive
            || !safe_components
            || value.nfc().ne(value.chars())
            || bytes.len() > MAX_PATH_BYTES
        {
            return Err(ProtocolError::InvalidRelativePath);
        }
        Ok(Self(value))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Produces the collision key used for Windows batch checks.
///
/// [`RelativePath::new`] first requires the wire spelling itself to be NFC and
/// to use `/` separators. This function then applies NFKC plus Unicode
/// lowercase to each component independently and rejoins the components with
/// `/`. Callers that materialize paths should use the same key before creating
/// files on a case-sensitive host.
#[must_use]
pub fn windows_path_collision_key(path: &RelativePath) -> String {
    let mut key = String::new();
    for (index, component) in path.as_str().split('/').enumerate() {
        if index != 0 {
            key.push('/');
        }
        key.extend(component.nfkc().flat_map(char::to_lowercase));
    }
    key
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum EntryKind {
    File = 1,
    Directory = 2,
}

impl TryFrom<u8> for EntryKind {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::File),
            2 => Ok(Self::Directory),
            _ => Err(ProtocolError::InvalidFrame),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ManifestEntry {
    pub relative_path: RelativePath,
    pub kind: EntryKind,
    pub size: u64,
    pub modification_time: f64,
    pub chunk_count: u32,
    pub digest: [u8; 32],
}

impl ManifestEntry {
    pub fn new(
        relative_path: RelativePath,
        kind: EntryKind,
        size: u64,
        modification_time: f64,
        chunk_count: u32,
        digest: [u8; 32],
    ) -> Result<Self, ProtocolError> {
        let value = Self {
            relative_path,
            kind,
            size,
            modification_time,
            chunk_count,
            digest,
        };
        value.validate()?;
        Ok(value)
    }

    fn validate(&self) -> Result<(), ProtocolError> {
        if !self.modification_time.is_finite() {
            return Err(ProtocolError::InvalidFrame);
        }
        match self.kind {
            EntryKind::Directory if self.size == 0 && self.chunk_count == 0 => Ok(()),
            EntryKind::File => {
                let chunk_size =
                    u64::try_from(MAX_CHUNK_BYTES).map_err(|_| ProtocolError::InvalidFrame)?;
                let expected =
                    self.size / chunk_size + u64::from(!self.size.is_multiple_of(chunk_size));
                if expected == u64::from(self.chunk_count) {
                    Ok(())
                } else {
                    Err(ProtocolError::InvalidFrame)
                }
            }
            EntryKind::Directory => Err(ProtocolError::InvalidFrame),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TransferManifest {
    pub id: Uuid,
    pub entries: Vec<ManifestEntry>,
}

impl TransferManifest {
    pub fn new(id: Uuid, entries: Vec<ManifestEntry>) -> Result<Self, ProtocolError> {
        let value = Self { id, entries };
        value.validate()?;
        Ok(value)
    }

    fn validate(&self) -> Result<(), ProtocolError> {
        if self.entries.len() > MAX_MANIFEST_ENTRIES {
            return Err(ProtocolError::ManifestTooLarge);
        }
        let mut paths = HashSet::with_capacity(self.entries.len());
        let mut windows_paths = HashMap::with_capacity(self.entries.len());
        let mut component_spellings = HashMap::new();
        let mut chunks = 0_u64;
        for entry in &self.entries {
            entry.validate()?;
            if !paths.insert(entry.relative_path.clone()) {
                return Err(ProtocolError::InvalidFrame);
            }
            let collision_key = windows_path_collision_key(&entry.relative_path);
            if windows_paths.insert(collision_key, entry.kind).is_some() {
                return Err(ProtocolError::InvalidFrame);
            }
            let mut parent_key = String::new();
            for component in entry.relative_path.as_str().split('/') {
                let spelling = component.nfc().collect::<String>();
                let component_key = component
                    .nfkc()
                    .flat_map(char::to_lowercase)
                    .collect::<String>();
                let identity = format!("{parent_key}\0{component_key}");
                if let Some(existing) = component_spellings.insert(identity, spelling.clone())
                    && existing != spelling
                {
                    return Err(ProtocolError::InvalidFrame);
                }
                if !parent_key.is_empty() {
                    parent_key.push('/');
                }
                parent_key.push_str(&component_key);
            }
            chunks = chunks
                .checked_add(u64::from(entry.chunk_count))
                .ok_or(ProtocolError::ManifestTooLarge)?;
            if chunks > u64::from(MAX_TRANSFER_CHUNKS) {
                return Err(ProtocolError::ManifestTooLarge);
            }
        }
        for path in windows_paths.keys() {
            let mut separator = path.rfind('/');
            while let Some(index) = separator {
                if windows_paths.get(&path[..index]) == Some(&EntryKind::File) {
                    return Err(ProtocolError::InvalidFrame);
                }
                separator = path[..index].rfind('/');
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct ChunkRange {
    pub entry_index: u32,
    pub lower_bound: u32,
    pub upper_bound: u32,
}

impl ChunkRange {
    pub fn new(
        entry_index: u32,
        lower_bound: u32,
        upper_bound: u32,
    ) -> Result<Self, ProtocolError> {
        if entry_index >= u32::try_from(MAX_MANIFEST_ENTRIES).unwrap_or(u32::MAX)
            || lower_bound >= upper_bound
            || upper_bound > MAX_TRANSFER_CHUNKS
        {
            return Err(ProtocolError::InvalidResumeMap);
        }
        Ok(Self {
            entry_index,
            lower_bound,
            upper_bound,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ResumeMap {
    pub ranges: Vec<ChunkRange>,
}

impl ResumeMap {
    pub fn new(mut ranges: Vec<ChunkRange>) -> Result<Self, ProtocolError> {
        ranges.sort_unstable();
        let mut merged: Vec<ChunkRange> = Vec::with_capacity(ranges.len());
        for range in ranges {
            if let Some(previous) = merged.last_mut()
                && previous.entry_index == range.entry_index
                && range.lower_bound <= previous.upper_bound
            {
                previous.upper_bound = previous.upper_bound.max(range.upper_bound);
            } else {
                merged.push(range);
            }
        }
        if merged.len() > MAX_RESUME_RANGES {
            return Err(ProtocolError::InvalidResumeMap);
        }
        Ok(Self { ranges: merged })
    }

    fn from_canonical(ranges: &[ChunkRange]) -> Result<Self, ProtocolError> {
        let canonical = Self::new(ranges.to_vec())?;
        if canonical.ranges == ranges {
            Ok(canonical)
        } else {
            Err(ProtocolError::InvalidResumeMap)
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ChunkCoordinate {
    pub entry_index: u32,
    pub chunk_index: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Chunk {
    pub coordinate: ChunkCoordinate,
    pub offset: u64,
    pub data: Vec<u8>,
}

impl Chunk {
    pub fn new(
        coordinate: ChunkCoordinate,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Self, ProtocolError> {
        if data.len() > MAX_CHUNK_BYTES
            || coordinate.entry_index >= u32::try_from(MAX_MANIFEST_ENTRIES).unwrap_or(u32::MAX)
            || coordinate.chunk_index >= MAX_TRANSFER_CHUNKS
        {
            return Err(ProtocolError::InvalidChunk);
        }
        Ok(Self {
            coordinate,
            offset,
            data,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum RemoteError {
    InvalidManifest = 1,
    InvalidChunk = 2,
    VerificationFailed = 3,
    ProtocolViolation = 4,
    DestinationUnavailable = 5,
    SourceUnavailable = 6,
}

impl TryFrom<u16> for RemoteError {
    type Error = ProtocolError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::InvalidManifest),
            2 => Ok(Self::InvalidChunk),
            3 => Ok(Self::VerificationFailed),
            4 => Ok(Self::ProtocolViolation),
            5 => Ok(Self::DestinationUnavailable),
            6 => Ok(Self::SourceUnavailable),
            _ => Err(ProtocolError::InvalidFrame),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum TransferFrame {
    Offer(TransferManifest),
    Accept(ResumeMap),
    Chunk(Chunk),
    AckRanges(ResumeMap),
    Pause,
    Resume,
    Cancel,
    Complete,
    Error(RemoteError),
}

impl TransferFrame {
    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() > MAX_FRAME_PLAINTEXT_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }
        let mut reader = Reader::new(input);
        if reader.u8()? != VERSION {
            return Err(ProtocolError::UnsupportedVersion);
        }
        let frame = match reader.u8()? {
            1 => Self::Offer(decode_manifest(&mut reader)?),
            2 => Self::Accept(reader.resume_map()?),
            3 => {
                let coordinate = ChunkCoordinate {
                    entry_index: reader.u32()?,
                    chunk_index: reader.u32()?,
                };
                let offset = reader.u64()?;
                let len =
                    usize::try_from(reader.u32()?).map_err(|_| ProtocolError::InvalidChunk)?;
                if len > MAX_CHUNK_BYTES {
                    return Err(ProtocolError::InvalidChunk);
                }
                let data = reader.take(len)?.to_vec();
                Self::Chunk(Chunk::new(coordinate, offset, data)?)
            }
            4 => Self::AckRanges(reader.resume_map()?),
            5 => Self::Pause,
            6 => Self::Resume,
            7 => Self::Cancel,
            8 => Self::Complete,
            9 => Self::Error(RemoteError::try_from(reader.u16()?)?),
            _ => return Err(ProtocolError::InvalidFrame),
        };
        if !reader.is_at_end() {
            return Err(ProtocolError::InvalidFrame);
        }
        Ok(frame)
    }

    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError> {
        let mut output = vec![VERSION];
        match self {
            Self::Offer(manifest) => encode_manifest(&mut output, manifest)?,
            Self::Accept(map) => {
                output.push(2);
                encode_resume_map(&mut output, map)?;
            }
            Self::Chunk(chunk) => {
                let chunk = Chunk::new(chunk.coordinate, chunk.offset, chunk.data.clone())?;
                output.push(3);
                put_u32(&mut output, chunk.coordinate.entry_index);
                put_u32(&mut output, chunk.coordinate.chunk_index);
                put_u64(&mut output, chunk.offset);
                put_u32(
                    &mut output,
                    u32::try_from(chunk.data.len()).map_err(|_| ProtocolError::InvalidChunk)?,
                );
                output.extend_from_slice(&chunk.data);
            }
            Self::AckRanges(map) => {
                output.push(4);
                encode_resume_map(&mut output, map)?;
            }
            Self::Pause => output.push(5),
            Self::Resume => output.push(6),
            Self::Cancel => output.push(7),
            Self::Complete => output.push(8),
            Self::Error(error) => {
                output.push(9);
                put_u16(&mut output, *error as u16);
            }
        }
        if output.len() > MAX_FRAME_PLAINTEXT_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }
        Ok(output)
    }

    #[must_use]
    pub const fn kind_name(&self) -> &'static str {
        match self {
            Self::Offer(_) => "offer",
            Self::Accept(_) => "accept",
            Self::Chunk(_) => "chunk",
            Self::AckRanges(_) => "ackRanges",
            Self::Pause => "pause",
            Self::Resume => "resume",
            Self::Cancel => "cancel",
            Self::Complete => "complete",
            Self::Error(_) => "error",
        }
    }
}

fn decode_manifest(reader: &mut Reader<'_>) -> Result<TransferManifest, ProtocolError> {
    let id = reader.uuid()?;
    let count = usize::try_from(reader.u32()?).map_err(|_| ProtocolError::ManifestTooLarge)?;
    if count > MAX_MANIFEST_ENTRIES {
        return Err(ProtocolError::ManifestTooLarge);
    }
    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        let path_len = usize::from(reader.u16()?);
        if path_len > MAX_PATH_BYTES {
            return Err(ProtocolError::InvalidRelativePath);
        }
        let path = std::str::from_utf8(reader.take(path_len)?)
            .map_err(|_| ProtocolError::InvalidRelativePath)?;
        let relative_path = RelativePath::new(path)?;
        let kind = EntryKind::try_from(reader.u8()?)?;
        let size = reader.u64()?;
        let modification_time = f64::from_bits(reader.u64()?);
        let chunk_count = reader.u32()?;
        let digest = reader
            .take(32)?
            .try_into()
            .map_err(|_| ProtocolError::InvalidFrame)?;
        entries.push(ManifestEntry::new(
            relative_path,
            kind,
            size,
            modification_time,
            chunk_count,
            digest,
        )?);
    }
    TransferManifest::new(id, entries)
}

fn encode_manifest(output: &mut Vec<u8>, manifest: &TransferManifest) -> Result<(), ProtocolError> {
    manifest.validate()?;
    output.push(1);
    output.extend_from_slice(manifest.id.as_bytes());
    put_u32(
        output,
        u32::try_from(manifest.entries.len()).map_err(|_| ProtocolError::ManifestTooLarge)?,
    );
    for entry in &manifest.entries {
        put_u16(
            output,
            u16::try_from(entry.relative_path.as_str().len())
                .map_err(|_| ProtocolError::ManifestTooLarge)?,
        );
        output.extend_from_slice(entry.relative_path.as_str().as_bytes());
        output.push(entry.kind as u8);
        put_u64(output, entry.size);
        put_u64(output, entry.modification_time.to_bits());
        put_u32(output, entry.chunk_count);
        output.extend_from_slice(&entry.digest);
    }
    Ok(())
}

fn encode_resume_map(output: &mut Vec<u8>, map: &ResumeMap) -> Result<(), ProtocolError> {
    if map.ranges.len() > MAX_RESUME_RANGES || ResumeMap::from_canonical(&map.ranges).is_err() {
        return Err(ProtocolError::InvalidResumeMap);
    }
    put_u32(
        output,
        u32::try_from(map.ranges.len()).map_err(|_| ProtocolError::InvalidResumeMap)?,
    );
    for range in &map.ranges {
        put_u32(output, range.entry_index);
        put_u32(output, range.lower_bound);
        put_u32(output, range.upper_bound);
    }
    Ok(())
}

fn put_u16(output: &mut Vec<u8>, value: u16) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn put_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn put_u64(output: &mut Vec<u8>, value: u64) {
    output.extend_from_slice(&value.to_be_bytes());
}

struct Reader<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    const fn new(input: &'a [u8]) -> Self {
        Self { input, offset: 0 }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], ProtocolError> {
        let end = self
            .offset
            .checked_add(count)
            .ok_or(ProtocolError::InvalidFrame)?;
        let value = self
            .input
            .get(self.offset..end)
            .ok_or(ProtocolError::InvalidFrame)?;
        self.offset = end;
        Ok(value)
    }

    fn u8(&mut self) -> Result<u8, ProtocolError> {
        self.take(1)?
            .first()
            .copied()
            .ok_or(ProtocolError::InvalidFrame)
    }

    fn u16(&mut self) -> Result<u16, ProtocolError> {
        Ok(u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| ProtocolError::InvalidFrame)?,
        ))
    }

    fn u32(&mut self) -> Result<u32, ProtocolError> {
        Ok(u32::from_be_bytes(
            self.take(4)?
                .try_into()
                .map_err(|_| ProtocolError::InvalidFrame)?,
        ))
    }

    fn u64(&mut self) -> Result<u64, ProtocolError> {
        Ok(u64::from_be_bytes(
            self.take(8)?
                .try_into()
                .map_err(|_| ProtocolError::InvalidFrame)?,
        ))
    }

    fn uuid(&mut self) -> Result<Uuid, ProtocolError> {
        Uuid::from_slice(self.take(16)?).map_err(|_| ProtocolError::InvalidFrame)
    }

    fn resume_map(&mut self) -> Result<ResumeMap, ProtocolError> {
        let count = usize::try_from(self.u32()?).map_err(|_| ProtocolError::InvalidResumeMap)?;
        if count > MAX_RESUME_RANGES || count > self.input.len().saturating_sub(self.offset) / 12 {
            return Err(ProtocolError::InvalidResumeMap);
        }
        let mut ranges = Vec::with_capacity(count);
        for _ in 0..count {
            ranges.push(ChunkRange::new(self.u32()?, self.u32()?, self.u32()?)?);
        }
        ResumeMap::from_canonical(&ranges)
    }

    const fn is_at_end(&self) -> bool {
        self.offset == self.input.len()
    }
}
