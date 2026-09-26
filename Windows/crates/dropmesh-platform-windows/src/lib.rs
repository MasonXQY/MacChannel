//! Windows-specific identity and small-state protection adapters.

/// Reports whether the real CNG/DPAPI backend is present in this build.
///
/// Non-Windows builds intentionally expose no substitute implementation.
#[must_use]
pub const fn is_windows_backend_available() -> bool {
    cfg!(windows)
}

#[cfg(any(windows, test))]
mod durable_state_format;
#[cfg(any(windows, test))]
mod export_policy;

#[cfg(windows)]
mod cng_identity;
#[cfg(windows)]
mod dpapi;
#[cfg(windows)]
mod durable_state;

#[cfg(windows)]
pub use cng_identity::{WindowsCngIdentity, WindowsIdentityError};
#[cfg(windows)]
pub use dpapi::{DpapiError, MAX_DPAPI_STATE_BYTES, protect_current_user, unprotect_current_user};
#[cfg(windows)]
pub use durable_state::{
    DpapiDurableStateStore, DurableStateError, DurableStateSnapshot, MAX_DURABLE_PAYLOAD_BYTES,
};
