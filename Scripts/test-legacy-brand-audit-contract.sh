#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/test-legacy-brand-audit-support.sh"

valid_source='    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }'

expect_rejected() {
    local case_name="$1"
    local source_text="$2"
    if macchannel_clipboard_cache_compatibility_source_is_valid "$source_text"; then
        echo "clipboard legacy-brand mutation unexpectedly allowed: $case_name" >&2
        exit 1
    fi
}

macchannel_clipboard_cache_compatibility_source_is_valid "$valid_source"

expect_rejected same-line-suffix '    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true); let userVisible = "MacChannel consumer branding"
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }'

expect_rejected same-line-prefix '    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        let userVisible = "MacChannel consumer branding"; return cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }'

expect_rejected adjacent-expression '    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        let userVisible = "MacChannel consumer branding"
        return cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }'

expect_rejected adjacent-multiline-literal '    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }

    private static let userVisible = """
    MacChannel consumer branding
    """'

expect_rejected missing-clipboard-component '    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
    }'

expect_rejected duplicate-chain "$valid_source
$valid_source"

expect_rejected alternate-function '    private static func consumerVisibleName() -> String {
        "MacChannel"
    }

    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }'

echo "legacy brand audit contract PASS"
