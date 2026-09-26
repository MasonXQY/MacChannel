#![allow(unsafe_code)]

#[cfg(test)]
use std::mem::ManuallyDrop;
use std::sync::Mutex;

use dropmesh_identity::{
    DerEcdsaSignature, DeviceIdentity, IdentityError, IdentityMetadataError, IdentityMetadataStore,
    P256PublicKey, persist_or_validate_metadata,
};
use sha2::{Digest, Sha256};
use thiserror::Error;
use windows::Win32::Foundation::{
    NTE_BAD_KEYSET, NTE_EXISTS, NTE_NOT_FOUND, NTE_NOT_SUPPORTED, NTE_PERM,
};
use windows::Win32::Security::Cryptography::{
    BCRYPT_ECCPRIVATE_BLOB, BCRYPT_ECCPUBLIC_BLOB, BCRYPT_ECDH_PUBLIC_P256_MAGIC,
    BCRYPT_ECDSA_PUBLIC_P256_MAGIC, CERT_KEY_SPEC, MS_KEY_STORAGE_PROVIDER,
    NCRYPT_ECDH_P256_ALGORITHM, NCRYPT_ECDSA_P256_ALGORITHM, NCRYPT_EXPORT_POLICY_PROPERTY,
    NCRYPT_FLAGS, NCRYPT_KEY_HANDLE, NCRYPT_PERSIST_FLAG, NCRYPT_PROV_HANDLE, NCRYPT_SILENT_FLAG,
    NCryptCreatePersistedKey, NCryptDeleteKey, NCryptExportKey, NCryptFinalizeKey,
    NCryptFreeObject, NCryptGetProperty, NCryptOpenKey, NCryptOpenStorageProvider,
    NCryptSetProperty, NCryptSignHash,
};
use windows::Win32::Security::OBJECT_SECURITY_INFORMATION;
use windows::core::{Error as WindowsError, HRESULT, HSTRING};

use crate::export_policy::{
    NTE_NOT_SUPPORTED_CODE, NTE_PERM_CODE, is_expected_private_export_denial,
};

const ECC_BLOB_HEADER_LEN: usize = 8;
const P256_COORDINATE_LEN: usize = 32;
const P256_COORDINATE_LEN_U32: u32 = 32;
const P256_RAW_SIGNATURE_LEN: usize = 64;
const P256_RAW_SIGNATURE_LEN_U32: u32 = 64;

/// A current-user, persisted CNG device identity.
///
/// Both private keys remain inside the Microsoft Software Key Storage Provider.
/// Only public `X || Y` bytes and DER signatures cross this boundary.
pub struct WindowsCngIdentity {
    signing_handle: Mutex<CngKey>,
    agreement_handle: CngKey,
    signing_public: P256PublicKey,
    agreement_public: P256PublicKey,
}

impl WindowsCngIdentity {
    /// Loads or creates a named current-user identity.
    ///
    /// `key_name` names the signing key exactly. The agreement key uses the
    /// deterministic `<key_name>.agreement` companion name.
    ///
    /// # Errors
    ///
    /// Returns a bounded platform error if the name is invalid, CNG rejects an
    /// operation, public key material is malformed, or export is not blocked.
    pub fn load_or_create(key_name: &str) -> Result<Self, WindowsIdentityError> {
        validate_key_name(key_name)?;
        let provider = CngProvider::open()?;
        let signing_key = CngKey::load_or_create(
            &provider,
            key_name,
            NCRYPT_ECDSA_P256_ALGORITHM,
            BCRYPT_ECDSA_PUBLIC_P256_MAGIC,
        )?;
        let agreement_name = format!("{key_name}.agreement");
        let agreement_key = CngKey::load_or_create(
            &provider,
            &agreement_name,
            NCRYPT_ECDH_P256_ALGORITHM,
            BCRYPT_ECDH_PUBLIC_P256_MAGIC,
        )?;

        signing_key.verify_non_exportable()?;
        agreement_key.verify_non_exportable()?;
        let signing_public_key = signing_key.public_key()?;
        let agreement_public_key = agreement_key.public_key()?;

        Ok(Self {
            signing_handle: Mutex::new(signing_key),
            agreement_handle: agreement_key,
            signing_public: signing_public_key,
            agreement_public: agreement_public_key,
        })
    }

    /// Loads or creates an identity and binds it to independently persisted
    /// public metadata, rejecting silent key replacement.
    ///
    /// # Errors
    ///
    /// Returns a CNG error or metadata-store mismatch/failure.
    pub fn load_or_create_with_metadata(
        key_name: &str,
        metadata_store: &dyn IdentityMetadataStore,
    ) -> Result<Self, WindowsIdentityError> {
        let identity = Self::load_or_create(key_name)?;
        persist_or_validate_metadata(metadata_store, &identity.metadata())?;
        Ok(identity)
    }

    /// Re-checks both export policies and attempts a private-key export probe.
    ///
    /// # Errors
    ///
    /// Returns an error if either export policy is nonzero, an export probe
    /// succeeds, or CNG cannot perform the check.
    pub fn verify_private_keys_non_exportable(&self) -> Result<(), WindowsIdentityError> {
        let signing = self
            .signing_handle
            .lock()
            .map_err(|_| WindowsIdentityError::KeyHandleUnavailable)?;
        signing.verify_non_exportable()?;
        self.agreement_handle.verify_non_exportable()
    }
}

impl DeviceIdentity for WindowsCngIdentity {
    fn signing_public_key(&self) -> P256PublicKey {
        self.signing_public
    }

    fn agreement_public_key(&self) -> P256PublicKey {
        self.agreement_public
    }

    fn sign(&self, message: &[u8]) -> Result<DerEcdsaSignature, IdentityError> {
        let signing = self
            .signing_handle
            .lock()
            .map_err(|_| IdentityError::SigningFailed)?;
        signing
            .sign(message)
            .map_err(|_| IdentityError::SigningFailed)
    }
}

/// Windows platform failures that occur while loading identity material.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum WindowsIdentityError {
    /// The key name was empty, too large, or contained a NUL.
    #[error("invalid CNG key name")]
    InvalidKeyName,
    /// The platform returned an invalid or unexpected public-key blob.
    #[error("invalid CNG P-256 public-key blob")]
    InvalidPublicKeyBlob,
    /// An existing key allowed private-key export.
    #[error("CNG private key export is not disabled")]
    PrivateKeyExportable,
    /// A key mutex was poisoned.
    #[error("CNG key handle is unavailable")]
    KeyHandleUnavailable,
    /// The durable public metadata did not match the CNG identity.
    #[error(transparent)]
    Metadata(#[from] IdentityMetadataError),
    /// A Windows CNG operation failed.
    #[error("Windows CNG operation {operation} failed with HRESULT 0x{code:08x}")]
    Cng {
        /// The bounded operation name; no secret data is included.
        operation: &'static str,
        /// The HRESULT as an unsigned value.
        code: u32,
    },
}

struct CngProvider(NCRYPT_PROV_HANDLE);

impl CngProvider {
    fn open() -> Result<Self, WindowsIdentityError> {
        let mut handle = NCRYPT_PROV_HANDLE::default();
        // SAFETY: `handle` is a valid out pointer and the provider name is a
        // static, NUL-terminated Windows string.
        unsafe {
            NCryptOpenStorageProvider(&raw mut handle, MS_KEY_STORAGE_PROVIDER, 0)
                .map_err(|error| cng_error("open storage provider", &error))?;
        }
        Ok(Self(handle))
    }
}

impl Drop for CngProvider {
    fn drop(&mut self) {
        // SAFETY: this wrapper uniquely owns the nonzero provider handle.
        unsafe {
            let _ = NCryptFreeObject(self.0.into());
        }
    }
}

struct CngKey(NCRYPT_KEY_HANDLE);

impl CngKey {
    fn load_or_create(
        provider: &CngProvider,
        key_name: &str,
        algorithm: windows::core::PCWSTR,
        expected_public_magic: u32,
    ) -> Result<Self, WindowsIdentityError> {
        let name = HSTRING::from(key_name);
        match Self::open(provider, &name) {
            Ok(key) => {
                key.ensure_public_magic(expected_public_magic)?;
                Ok(key)
            }
            Err(WindowsIdentityError::Cng { code, .. }) if is_key_not_found(code) => {
                match Self::create(provider, &name, algorithm) {
                    Ok(key) => {
                        key.ensure_public_magic(expected_public_magic)?;
                        Ok(key)
                    }
                    Err(WindowsIdentityError::Cng { code, .. })
                        if code == NTE_EXISTS.0.cast_unsigned() =>
                    {
                        let key = Self::open(provider, &name)?;
                        key.ensure_public_magic(expected_public_magic)?;
                        Ok(key)
                    }
                    Err(error) => Err(error),
                }
            }
            Err(error) => Err(error),
        }
    }

    fn open(provider: &CngProvider, name: &HSTRING) -> Result<Self, WindowsIdentityError> {
        let mut handle = NCRYPT_KEY_HANDLE::default();
        // SAFETY: provider is live, `handle` is a valid out pointer, and
        // `name` remains alive for the duration of the call.
        unsafe {
            NCryptOpenKey(
                provider.0,
                &raw mut handle,
                name,
                CERT_KEY_SPEC(0),
                NCRYPT_SILENT_FLAG,
            )
            .map_err(|error| cng_error("open persisted key", &error))?;
        }
        Ok(Self(handle))
    }

    fn create(
        provider: &CngProvider,
        name: &HSTRING,
        algorithm: windows::core::PCWSTR,
    ) -> Result<Self, WindowsIdentityError> {
        Self::create_with_export_policy(provider, name, algorithm, 0)
    }

    fn create_with_export_policy(
        provider: &CngProvider,
        name: &HSTRING,
        algorithm: windows::core::PCWSTR,
        export_policy: u32,
    ) -> Result<Self, WindowsIdentityError> {
        let mut handle = NCRYPT_KEY_HANDLE::default();
        // SAFETY: provider is live, `handle` is a valid out pointer, and both
        // Windows string arguments remain alive for the duration of the call.
        unsafe {
            NCryptCreatePersistedKey(
                provider.0,
                &raw mut handle,
                algorithm,
                name,
                CERT_KEY_SPEC(0),
                NCRYPT_SILENT_FLAG,
            )
            .map_err(|error| cng_error("create persisted key", &error))?;
        }

        let export_policy = export_policy.to_ne_bytes();
        // SAFETY: `handle` was returned by CNG; the property input is a valid
        // four-byte DWORD for the duration of the call.
        let configure_result = unsafe {
            NCryptSetProperty(
                handle.into(),
                NCRYPT_EXPORT_POLICY_PROPERTY,
                &export_policy,
                NCRYPT_PERSIST_FLAG,
            )
            .map_err(|error| cng_error("disable private key export", &error))
            .and_then(|()| {
                NCryptFinalizeKey(handle, NCRYPT_SILENT_FLAG)
                    .map_err(|error| cng_error("finalize persisted key", &error))
            })
        };

        if let Err(error) = configure_result {
            // SAFETY: deleting an unreturned key rolls back partial creation;
            // NCryptDeleteKey releases the handle on success.
            unsafe {
                let _ = NCryptDeleteKey(handle, 0);
            }
            return Err(error);
        }
        Ok(Self(handle))
    }

    fn public_key(&self) -> Result<P256PublicKey, WindowsIdentityError> {
        let blob = self.export_public_blob()?;
        if blob.len() != ECC_BLOB_HEADER_LEN + (2 * P256_COORDINATE_LEN) {
            return Err(WindowsIdentityError::InvalidPublicKeyBlob);
        }
        let coordinate_size = u32::from_ne_bytes(
            blob[4..8]
                .try_into()
                .map_err(|_| WindowsIdentityError::InvalidPublicKeyBlob)?,
        );
        if coordinate_size != P256_COORDINATE_LEN_U32 {
            return Err(WindowsIdentityError::InvalidPublicKeyBlob);
        }
        let mut raw_xy = [0_u8; 64];
        raw_xy.copy_from_slice(&blob[ECC_BLOB_HEADER_LEN..]);
        P256PublicKey::from_raw_xy(raw_xy).map_err(|_| WindowsIdentityError::InvalidPublicKeyBlob)
    }

    fn ensure_public_magic(&self, expected: u32) -> Result<(), WindowsIdentityError> {
        let blob = self.export_public_blob()?;
        let actual = u32::from_ne_bytes(
            blob.get(0..4)
                .ok_or(WindowsIdentityError::InvalidPublicKeyBlob)?
                .try_into()
                .map_err(|_| WindowsIdentityError::InvalidPublicKeyBlob)?,
        );
        if actual != expected {
            return Err(WindowsIdentityError::InvalidPublicKeyBlob);
        }
        Ok(())
    }

    fn export_public_blob(&self) -> Result<Vec<u8>, WindowsIdentityError> {
        let mut required = 0_u32;
        // SAFETY: the key is live and `required` is a valid out pointer. A null
        // output buffer is the documented size-query form.
        unsafe {
            NCryptExportKey(
                self.0,
                None,
                BCRYPT_ECCPUBLIC_BLOB,
                None,
                None,
                &raw mut required,
                NCRYPT_FLAGS(0),
            )
            .map_err(|error| cng_error("query public key size", &error))?;
        }
        let size =
            usize::try_from(required).map_err(|_| WindowsIdentityError::InvalidPublicKeyBlob)?;
        let mut output = vec![0_u8; size];
        let mut written = 0_u32;
        // SAFETY: `output` is writable for its full length and all pointers are
        // valid for the duration of the call.
        unsafe {
            NCryptExportKey(
                self.0,
                None,
                BCRYPT_ECCPUBLIC_BLOB,
                None,
                Some(&mut output),
                &raw mut written,
                NCRYPT_FLAGS(0),
            )
            .map_err(|error| cng_error("export public key", &error))?;
        }
        let written =
            usize::try_from(written).map_err(|_| WindowsIdentityError::InvalidPublicKeyBlob)?;
        if written > output.len() {
            return Err(WindowsIdentityError::InvalidPublicKeyBlob);
        }
        output.truncate(written);
        Ok(output)
    }

    fn verify_non_exportable(&self) -> Result<(), WindowsIdentityError> {
        let mut policy = [0_u8; 4];
        let mut written = 0_u32;
        // SAFETY: the key is live, the four-byte output buffer is writable, and
        // `written` is a valid out pointer.
        unsafe {
            NCryptGetProperty(
                self.0.into(),
                NCRYPT_EXPORT_POLICY_PROPERTY,
                Some(&mut policy),
                &raw mut written,
                OBJECT_SECURITY_INFORMATION::default(),
            )
            .map_err(|error| cng_error("read export policy", &error))?;
        }
        if written != 4 || u32::from_ne_bytes(policy) != 0 {
            return Err(WindowsIdentityError::PrivateKeyExportable);
        }

        let export_result = self.probe_private_export();
        match export_result {
            Ok(()) => Err(WindowsIdentityError::PrivateKeyExportable),
            Err(error) => {
                let code = error.code().0.cast_unsigned();
                debug_assert_eq!(NTE_PERM.0.cast_unsigned(), NTE_PERM_CODE);
                debug_assert_eq!(NTE_NOT_SUPPORTED.0.cast_unsigned(), NTE_NOT_SUPPORTED_CODE);
                if is_expected_private_export_denial(code) {
                    Ok(())
                } else {
                    Err(cng_error("probe private key export", &error))
                }
            }
        }
    }

    fn probe_private_export(&self) -> windows::core::Result<()> {
        let mut private_size = 0_u32;
        // SAFETY: this is a size-only export probe using the native ECC private
        // blob documented for the Microsoft Software KSP.
        unsafe {
            NCryptExportKey(
                self.0,
                None,
                BCRYPT_ECCPRIVATE_BLOB,
                None,
                None,
                &raw mut private_size,
                NCRYPT_SILENT_FLAG,
            )
        }
    }

    fn sign(&self, message: &[u8]) -> Result<DerEcdsaSignature, WindowsIdentityError> {
        let digest = Sha256::digest(message);
        let mut raw_signature = [0_u8; P256_RAW_SIGNATURE_LEN];
        let mut written = 0_u32;
        // SAFETY: the key is a live ECDSA handle, digest and output buffers are
        // valid slices, and `written` is a valid out pointer.
        unsafe {
            NCryptSignHash(
                self.0,
                None,
                digest.as_slice(),
                Some(&mut raw_signature),
                &raw mut written,
                NCRYPT_FLAGS(0),
            )
            .map_err(|error| cng_error("sign SHA-256 digest", &error))?;
        }
        if written != P256_RAW_SIGNATURE_LEN_U32 {
            return Err(WindowsIdentityError::Cng {
                operation: "validate signature length",
                code: 0,
            });
        }
        DerEcdsaSignature::from_fixed_width(&raw_signature).map_err(|_| WindowsIdentityError::Cng {
            operation: "convert signature to DER",
            code: 0,
        })
    }

    #[cfg(test)]
    fn delete(self) -> Result<(), WindowsIdentityError> {
        let this = ManuallyDrop::new(self);
        // SAFETY: this consumes the unique wrapper. NCryptDeleteKey deletes the
        // persisted key and releases the handle on success.
        unsafe {
            NCryptDeleteKey(this.0, NCRYPT_SILENT_FLAG.0)
                .map_err(|error| cng_error("delete test key", &error))
        }
    }
}

impl Drop for CngKey {
    fn drop(&mut self) {
        // SAFETY: this wrapper uniquely owns the key handle.
        unsafe {
            let _ = NCryptFreeObject(self.0.into());
        }
    }
}

fn validate_key_name(key_name: &str) -> Result<(), WindowsIdentityError> {
    if key_name.is_empty() || key_name.len() > 200 || key_name.contains('\0') {
        return Err(WindowsIdentityError::InvalidKeyName);
    }
    Ok(())
}

fn cng_error(operation: &'static str, error: &WindowsError) -> WindowsIdentityError {
    WindowsIdentityError::Cng {
        operation,
        code: error.code().0.cast_unsigned(),
    }
}

fn is_key_not_found(code: u32) -> bool {
    code == hresult_code(NTE_BAD_KEYSET) || code == hresult_code(NTE_NOT_FOUND)
}

const fn hresult_code(code: HRESULT) -> u32 {
    code.0.cast_unsigned()
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::time::{SystemTime, UNIX_EPOCH};

    use dropmesh_identity::DeviceIdentity;

    use windows::Win32::Security::Cryptography::{
        NCRYPT_ALLOW_EXPORT_FLAG, NCRYPT_ALLOW_PLAINTEXT_EXPORT_FLAG,
        NCRYPT_ECDSA_P256_ALGORITHM,
    };
    use windows::core::HSTRING;

    use super::{CngKey, CngProvider, WindowsCngIdentity};

    #[test]
    fn persisted_identity_is_stable_signs_and_blocks_private_export() -> Result<(), Box<dyn Error>>
    {
        let suffix = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let name = format!("DropMesh.Identity.Test.{}.{}", std::process::id(), suffix);
        let provider = CngProvider::open()?;
        let control_name = HSTRING::from(format!("{name}.export-control"));
        let exportable = CngKey::create_with_export_policy(
            &provider,
            &control_name,
            NCRYPT_ECDSA_P256_ALGORITHM,
            NCRYPT_ALLOW_EXPORT_FLAG | NCRYPT_ALLOW_PLAINTEXT_EXPORT_FLAG,
        )?;
        let control_probe = exportable.probe_private_export();
        let control_cleanup = exportable.delete();
        control_probe?;
        control_cleanup?;

        let first = WindowsCngIdentity::load_or_create(&name)?;
        let first_metadata = first.metadata();
        first.verify_private_keys_non_exportable()?;
        let signature = first.sign(b"windows-cng-test")?;
        first
            .signing_public_key()
            .verify_der(b"windows-cng-test", &signature)?;
        drop(first);

        let second = WindowsCngIdentity::load_or_create(&name)?;
        assert_eq!(first_metadata, second.metadata());
        let signing = second
            .signing_handle
            .into_inner()
            .map_err(|_| "signing key mutex was poisoned")?;
        signing.delete()?;
        second.agreement_handle.delete()?;
        Ok(())
    }
}
