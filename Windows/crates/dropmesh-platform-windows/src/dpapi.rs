#![allow(unsafe_code)]

use std::slice;

use thiserror::Error;
use windows::Win32::Foundation::{HLOCAL, LocalFree};
use windows::Win32::Security::Cryptography::{
    CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
};
use windows::core::{Error as WindowsError, PCWSTR};
use zeroize::{Zeroize, Zeroizing};

/// DPAPI is intended here only for bounded tokens and small settings state.
pub const MAX_DPAPI_STATE_BYTES: usize = 64 * 1024;
const MAX_DPAPI_BLOB_BYTES: usize = 128 * 1024;

/// Protects small state to the current Windows user without showing UI.
///
/// # Errors
///
/// Returns [`DpapiError::InputTooLarge`] before FFI for oversized state, or a
/// bounded Windows error when protection fails.
pub fn protect_current_user(
    plaintext: &[u8],
    optional_entropy: Option<&[u8]>,
) -> Result<Vec<u8>, DpapiError> {
    check_len(plaintext, MAX_DPAPI_STATE_BYTES)?;
    let input = input_blob(plaintext)?;
    let entropy = optional_entropy.map(input_blob).transpose()?;
    let entropy_pointer = entropy
        .as_ref()
        .map(std::ptr::from_ref::<CRYPT_INTEGER_BLOB>);
    let mut output = CRYPT_INTEGER_BLOB::default();
    // SAFETY: all input blobs borrow live slices, optional pointers remain
    // valid for the call, and `output` is a valid out pointer. UI is disabled.
    unsafe {
        CryptProtectData(
            &raw const input,
            PCWSTR::null(),
            entropy_pointer,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &raw mut output,
        )
        .map_err(|error| dpapi_error("protect data", &error))?;
    }
    copy_and_free_output(output, MAX_DPAPI_BLOB_BYTES, false)
}

/// Unprotects state previously bound to the current Windows user.
///
/// # Errors
///
/// Returns a bounded validation or Windows error for malformed, oversized,
/// wrong-user, or wrong-entropy input.
pub fn unprotect_current_user(
    protected: &[u8],
    optional_entropy: Option<&[u8]>,
) -> Result<Zeroizing<Vec<u8>>, DpapiError> {
    if protected.is_empty() {
        return Err(DpapiError::InvalidProtectedBlob);
    }
    check_len(protected, MAX_DPAPI_BLOB_BYTES)?;
    let input = input_blob(protected)?;
    let entropy = optional_entropy.map(input_blob).transpose()?;
    let entropy_pointer = entropy
        .as_ref()
        .map(std::ptr::from_ref::<CRYPT_INTEGER_BLOB>);
    let mut output = CRYPT_INTEGER_BLOB::default();
    // SAFETY: all input blobs borrow live slices, optional pointers remain
    // valid for the call, and `output` is a valid out pointer. UI is disabled.
    unsafe {
        CryptUnprotectData(
            &raw const input,
            None,
            entropy_pointer,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &raw mut output,
        )
        .map_err(|error| dpapi_error("unprotect data", &error))?;
    }
    copy_and_free_output(output, MAX_DPAPI_STATE_BYTES, true).map(Zeroizing::new)
}

/// Failures from bounded current-user DPAPI operations.
#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum DpapiError {
    /// Input exceeded the small-state boundary.
    #[error("DPAPI input exceeds the small-state limit")]
    InputTooLarge,
    /// Protected bytes or DPAPI output were malformed.
    #[error("invalid DPAPI protected blob")]
    InvalidProtectedBlob,
    /// A Windows DPAPI operation failed.
    #[error("Windows DPAPI operation {operation} failed with HRESULT 0x{code:08x}")]
    Windows {
        /// The bounded operation name; no state bytes are included.
        operation: &'static str,
        /// The HRESULT as an unsigned value.
        code: u32,
    },
}

fn check_len(bytes: &[u8], maximum: usize) -> Result<(), DpapiError> {
    if bytes.len() > maximum {
        return Err(DpapiError::InputTooLarge);
    }
    Ok(())
}

fn input_blob(bytes: &[u8]) -> Result<CRYPT_INTEGER_BLOB, DpapiError> {
    Ok(CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(bytes.len()).map_err(|_| DpapiError::InputTooLarge)?,
        pbData: bytes.as_ptr().cast_mut(),
    })
}

fn copy_and_free_output(
    output: CRYPT_INTEGER_BLOB,
    maximum: usize,
    zero_before_free: bool,
) -> Result<Vec<u8>, DpapiError> {
    let owned = LocalBlob {
        blob: output,
        zero_before_free,
    };
    let length =
        usize::try_from(owned.blob.cbData).map_err(|_| DpapiError::InvalidProtectedBlob)?;
    if length > maximum || (length > 0 && owned.blob.pbData.is_null()) {
        return Err(DpapiError::InvalidProtectedBlob);
    }
    if length == 0 {
        return Ok(Vec::new());
    }
    // SAFETY: DPAPI returned `pbData` with exactly `cbData` initialized bytes,
    // and `owned` keeps the allocation alive until after the copy.
    let bytes = unsafe { slice::from_raw_parts(owned.blob.pbData, length) };
    Ok(bytes.to_vec())
}

struct LocalBlob {
    blob: CRYPT_INTEGER_BLOB,
    zero_before_free: bool,
}

impl Drop for LocalBlob {
    fn drop(&mut self) {
        if self.blob.pbData.is_null() {
            return;
        }
        if self.zero_before_free && self.blob.cbData > 0 {
            let length: usize = usize::try_from(self.blob.cbData).unwrap_or_default();
            // SAFETY: DPAPI reports an allocation of exactly `cbData` bytes.
            // The allocation is still uniquely owned and live until LocalFree.
            unsafe {
                slice::from_raw_parts_mut(self.blob.pbData, length).zeroize();
            }
        }
        // SAFETY: DPAPI allocated this pointer with LocalAlloc and ownership is
        // unique to this wrapper.
        unsafe {
            let _ = LocalFree(Some(HLOCAL(self.blob.pbData.cast())));
        }
    }
}

fn dpapi_error(operation: &'static str, error: &WindowsError) -> DpapiError {
    DpapiError::Windows {
        operation,
        code: error.code().0.cast_unsigned(),
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use zeroize::Zeroizing;

    use super::{DpapiError, MAX_DPAPI_STATE_BYTES, protect_current_user, unprotect_current_user};

    #[test]
    fn current_user_round_trip_and_entropy_binding() -> Result<(), Box<dyn Error>> {
        let protected = protect_current_user(b"small durable state", Some(b"DropMesh.v1"))?;
        assert_ne!(protected, b"small durable state");
        let clear = unprotect_current_user(&protected, Some(b"DropMesh.v1"))?;
        let _: &Zeroizing<Vec<u8>> = &clear;
        assert_eq!(&**clear, b"small durable state");
        assert!(unprotect_current_user(&protected, Some(b"wrong")).is_err());
        Ok(())
    }

    #[test]
    fn oversized_state_is_rejected_before_ffi() {
        let oversized = vec![0_u8; MAX_DPAPI_STATE_BYTES + 1];
        assert_eq!(
            protect_current_user(&oversized, None),
            Err(DpapiError::InputTooLarge)
        );
    }
}
