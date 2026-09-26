#[test]
fn backend_availability_matches_the_build_target() {
    assert_eq!(
        dropmesh_platform_windows::is_windows_backend_available(),
        cfg!(windows)
    );
}
