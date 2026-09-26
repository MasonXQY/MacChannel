pub(crate) const NTE_PERM_CODE: u32 = 0x8009_0010;
pub(crate) const NTE_NOT_SUPPORTED_CODE: u32 = 0x8009_0029;

pub(crate) const fn is_expected_private_export_denial(code: u32) -> bool {
    code == NTE_PERM_CODE || code == NTE_NOT_SUPPORTED_CODE
}

#[cfg(test)]
mod tests {
    use super::is_expected_private_export_denial;

    #[test]
    fn software_ksp_private_export_denials_are_accepted() {
        assert!(is_expected_private_export_denial(0x8009_0010));
        assert!(is_expected_private_export_denial(0x8009_0029));
        assert!(!is_expected_private_export_denial(0));
        assert!(!is_expected_private_export_denial(0x8009_0003));
    }
}
