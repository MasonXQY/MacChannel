pub(crate) const NTE_PERM_CODE: u32 = 0x8009_0010;

pub(crate) const fn is_expected_private_export_denial(code: u32) -> bool {
    code == NTE_PERM_CODE
}

#[cfg(test)]
mod tests {
    use super::is_expected_private_export_denial;

    #[test]
    fn only_nte_perm_is_accepted_as_policy_enforcement() {
        assert!(is_expected_private_export_denial(0x8009_0010));
        assert!(!is_expected_private_export_denial(0x8009_0029));
        assert!(!is_expected_private_export_denial(0));
    }
}
