#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
version="${MACCHANNEL_VERSION:-1.1.3}"
build_number="${MACCHANNEL_BUILD_NUMBER:-5}"
notary_profile="${MACCHANNEL_NOTARY_PROFILE:-}"
volume_name="Mac 通道"
dist_root="$repo_root/dist"

mkdir -p "$dist_root"
chmod 700 "$dist_root"
rm -f \
    "$dist_root/MacChannel.dmg" \
    "$dist_root/MacChannel.manifest.json" \
    "$dist_root/.MacChannel.dmg.new" \
    "$dist_root/.MacChannel.manifest.json.new"

fail_usage() {
    echo "$1" >&2
    exit 2
}

[[ -n "$identity" ]] || fail_usage "MACCHANNEL_CODESIGN_IDENTITY is required"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
    fail_usage "MACCHANNEL_VERSION must be a release SemVer such as 1.2.3"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || \
    fail_usage "MACCHANNEL_BUILD_NUMBER must be a positive integer"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    fail_usage "distribution builds require a clean Git worktree"
fi

if ! security find-identity -v -p codesigning | grep -F "\"$identity\"" >/dev/null; then
    fail_usage "the requested Developer ID identity is not installed"
fi
[[ "$identity" == "Developer ID Application: "* ]] || \
    fail_usage "MACCHANNEL_CODESIGN_IDENTITY must name a Developer ID Application identity"

team_id="$(sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/' <<<"$identity")"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail_usage "could not derive the signing Team ID"

build_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-distribution.XXXXXX")"
chmod 700 "$build_root"
app_path="$build_root/MacChannel.app"
stage_path="$build_root/stage"
image_path="$build_root/MacChannel.dmg"
manifest_path="$build_root/MacChannel.manifest.json"
mount_path="$build_root/mounted"
mounted=0
published=0

cleanup() {
    local status=$?
    if [[ "$mounted" -eq 1 ]]; then
        hdiutil detach "$mount_path" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$build_root"
    if [[ "$published" -ne 1 ]]; then
        rm -f \
            "$dist_root/MacChannel.dmg" \
            "$dist_root/MacChannel.manifest.json" \
            "$dist_root/.MacChannel.dmg.new" \
            "$dist_root/.MacChannel.manifest.json.new"
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM HUP

inject_failure() {
    local checkpoint="$1"
    if [[ "${MACCHANNEL_DISTRIBUTION_TESTING:-}" == 1 && \
        "${MACCHANNEL_DISTRIBUTION_FAIL_AT:-}" == "$checkpoint" ]]; then
        echo "injected distribution failure at $checkpoint" >&2
        exit 70
    fi
}

MACCHANNEL_BUILD_CONFIGURATION=release \
MACCHANNEL_CODESIGN_IDENTITY="$identity" \
MACCHANNEL_VERSION="$version" \
MACCHANNEL_BUILD_NUMBER="$build_number" \
MACCHANNEL_APP_OUTPUT="$app_path" \
    bash Scripts/build-app.sh
inject_failure app-built

codesign --verify --deep --strict --verbose=2 "$app_path"
app_details="$(codesign -dvvv "$app_path" 2>&1)"
grep -F "Authority=$identity" <<<"$app_details" >/dev/null
grep -F "TeamIdentifier=$team_id" <<<"$app_details" >/dev/null
grep -E 'flags=.*runtime' <<<"$app_details" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")" = \
    com.mason.macchannel
test "$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")" = \
    "$version"
test "$(plutil -extract CFBundleVersion raw -o - "$app_path/Contents/Info.plist")" = \
    "$build_number"
inject_failure app-verified

mkdir -p "$stage_path"
chmod 755 "$stage_path"
ditto --noextattr --noqtn "$app_path" "$stage_path/MacChannel.app"
ln -s /Applications "$stage_path/Applications"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build_number/g" \
    Distribution/README.txt >"$stage_path/README.txt"
chmod 644 "$stage_path/README.txt"
xattr -cr "$stage_path"

source_epoch="$(git show -s --format=%ct HEAD)"
timestamp="$(date -r "$source_epoch" +%Y%m%d%H%M.%S)"
while IFS= read -r stage_entry; do
    touch -h -t "$timestamp" "$stage_entry"
done < <(find "$stage_path" -depth -print | LC_ALL=C sort)

normalized_stage="$build_root/normalized-stage"
ditto --noextattr --noqtn "$stage_path" "$normalized_stage"
codesign --remove-signature \
    "$normalized_stage/MacChannel.app/Contents/MacOS/WebRTC.framework" >/dev/null 2>&1
codesign --remove-signature \
    "$normalized_stage/MacChannel.app/Contents/MacOS/MacChannelApp" >/dev/null 2>&1
codesign --remove-signature "$normalized_stage/MacChannel.app" >/dev/null 2>&1

stage_listing="$build_root/stage.list"
: >"$stage_listing"
while IFS= read -r relative_entry; do
    full_entry="$normalized_stage/$relative_entry"
    if [[ -L "$full_entry" ]]; then
        printf 'link\t%s\t%s\n' "$relative_entry" "$(readlink "$full_entry")" >>"$stage_listing"
    elif [[ -f "$full_entry" ]]; then
        printf 'file\t%s\t%s\t%s\t%s\n' \
            "$relative_entry" \
            "$(stat -f %Lp "$full_entry")" \
            "$(stat -f %z "$full_entry")" \
            "$(shasum -a 256 "$full_entry" | awk '{print $1}')" >>"$stage_listing"
    elif [[ -d "$full_entry" ]]; then
        printf 'dir\t%s\t%s\n' "$relative_entry" "$(stat -f %Lp "$full_entry")" \
            >>"$stage_listing"
    fi
done < <(cd "$normalized_stage" && find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort)
stage_sha="$(shasum -a 256 "$stage_listing" | awk '{print $1}')"
inject_failure stage-ready

hdiutil create \
    -srcfolder "$stage_path" \
    -volname "$volume_name" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$image_path" >/dev/null
codesign --force --sign "$identity" --timestamp "$image_path"
inject_failure image-created

codesign --verify --strict --verbose=2 "$image_path"
mkdir -p "$mount_path"
hdiutil attach "$image_path" -nobrowse -readonly -mountpoint "$mount_path" -quiet
mounted=1
test "$(diskutil info -plist "$mount_path" | plutil -extract VolumeName raw -o - -)" = "$volume_name"
find "$mount_path" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort \
    >"$build_root/actual-entries"
printf '%s\n' Applications MacChannel.app README.txt | LC_ALL=C sort \
    >"$build_root/expected-entries"
cmp "$build_root/expected-entries" "$build_root/actual-entries"
test -L "$mount_path/Applications"
test "$(readlink "$mount_path/Applications")" = /Applications
codesign --verify --deep --strict --verbose=2 "$mount_path/MacChannel.app"
hdiutil detach "$mount_path" -quiet
mounted=0
inject_failure image-verified

release_state=internalSignedNotNotarized
if [[ -n "$notary_profile" ]]; then
    notary_result="$build_root/notary-result.json"
    xcrun notarytool submit "$image_path" \
        --keychain-profile "$notary_profile" \
        --wait \
        --output-format json >"$notary_result"
    test "$(plutil -extract status raw -o - "$notary_result")" = Accepted
    xcrun stapler staple "$image_path"
    xcrun stapler validate "$image_path"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image_path"
    release_state=notarized
fi

dmg_sha="$(shasum -a 256 "$image_path" | awk '{print $1}')"
git_commit="$(git rev-parse HEAD)"
created_at="$(date -u -r "$source_epoch" +%Y-%m-%dT%H:%M:%SZ)"
plutil -create xml1 "$manifest_path"
plutil -insert product -string MacChannel "$manifest_path"
plutil -insert bundleIdentifier -string com.mason.macchannel "$manifest_path"
plutil -insert version -string "$version" "$manifest_path"
plutil -insert build -string "$build_number" "$manifest_path"
plutil -insert gitCommit -string "$git_commit" "$manifest_path"
plutil -insert teamID -string "$team_id" "$manifest_path"
plutil -insert signingIdentity -string "$identity" "$manifest_path"
plutil -insert releaseState -string "$release_state" "$manifest_path"
plutil -insert volumeName -string "$volume_name" "$manifest_path"
plutil -insert stagedFilesystemSHA256 -string "$stage_sha" "$manifest_path"
plutil -insert dmgSHA256 -string "$dmg_sha" "$manifest_path"
plutil -insert sourceDateEpoch -integer "$source_epoch" "$manifest_path"
plutil -insert createdAt -string "$created_at" "$manifest_path"
plutil -insert containerReproducibility -string \
    "The signature-normalized staged filesystem is deterministic; Developer ID timestamps and UDIF metadata may change raw DMG bytes between builds." \
    "$manifest_path"
plutil -convert json "$manifest_path"
inject_failure manifest-ready

mv "$image_path" "$dist_root/.MacChannel.dmg.new"
mv "$manifest_path" "$dist_root/.MacChannel.manifest.json.new"
mv "$dist_root/.MacChannel.dmg.new" "$dist_root/MacChannel.dmg"
if ! mv "$dist_root/.MacChannel.manifest.json.new" "$dist_root/MacChannel.manifest.json"; then
    rm -f "$dist_root/MacChannel.dmg" "$dist_root/.MacChannel.manifest.json.new"
    exit 1
fi
published=1

echo "created $dist_root/MacChannel.dmg"
echo "created $dist_root/MacChannel.manifest.json ($release_state)"
