#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
tools_root="$repo_root/.build/tools"
tool_directory="$tools_root/Sparkle-2.9.6"
download_url="https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz"
expected_sha256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"

mkdir -p "$tools_root"
archive_path="$(mktemp "${TMPDIR:-/tmp}/Sparkle-2.9.6.XXXXXX.tar.xz")"
extraction_directory="$(mktemp -d "$tools_root/.Sparkle-2.9.6.XXXXXX")"
previous_directory=""

cleanup() {
    rm -f "$archive_path"
    rm -rf "$extraction_directory"
    if [[ -n "$previous_directory" && -d "$previous_directory" ]]; then
        if [[ ! -e "$tool_directory" ]]; then
            mv "$previous_directory" "$tool_directory"
        else
            rm -rf "$previous_directory"
        fi
    fi
}
trap cleanup EXIT

curl --fail --location --proto '=https' --tlsv1.2 --output "$archive_path" "$download_url"
actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "Sparkle tools SHA-256 mismatch" >&2
    exit 1
fi

tar -xJf "$archive_path" --strip-components 1 -C "$extraction_directory"
test -x "$extraction_directory/bin/generate_keys"

if [[ -e "$tool_directory" ]]; then
    previous_directory="$(mktemp -d "$tools_root/.Sparkle-2.9.6.previous.XXXXXX")"
    rmdir "$previous_directory"
    mv "$tool_directory" "$previous_directory"
fi
mv "$extraction_directory" "$tool_directory"
extraction_directory=""
if [[ -n "$previous_directory" ]]; then
    rm -rf "$previous_directory"
    previous_directory=""
fi

echo "Sparkle 2.9.6 tools installed at $tool_directory"
