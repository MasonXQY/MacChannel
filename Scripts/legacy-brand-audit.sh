#!/usr/bin/env bash

macchannel_clipboard_legacy_line_is_allowed() {
    local source_line="$1"
    [[ "$source_line" == \
        '            .appendingPathComponent("MacChannel", isDirectory: true)' ]]
}

macchannel_clipboard_cache_compatibility_source_is_valid() {
    local source_text="$1"
    local expected_block='    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }'
    local remainder

    [[ "$source_text" == *"$expected_block"* ]] || return 1
    remainder="${source_text/"$expected_block"/}"
    [[ "$remainder" != *"$expected_block"* ]] || return 1

    ! printf '%s\n' "$remainder" | rg -q --no-heading 'Mac 通道|MacChannel'
}
