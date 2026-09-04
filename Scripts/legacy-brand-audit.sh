#!/usr/bin/env bash

macchannel_clipboard_legacy_line_is_allowed() {
    local source_line="$1"
    [[ "$source_line" == *'appendingPathComponent("MacChannel", isDirectory: true)'* ]]
}

macchannel_clipboard_cache_compatibility_source_is_valid() {
    local source_text="$1"
    local source_line
    local saw_compatibility_line=0

    while IFS= read -r source_line; do
        saw_compatibility_line=1
        macchannel_clipboard_legacy_line_is_allowed "$source_line" || return 1
    done < <(printf '%s\n' "$source_text" | \
        rg --no-heading '"[^"\n]*(Mac 通道|MacChannel)' || true)

    [[ "$saw_compatibility_line" -eq 1 ]]
}
