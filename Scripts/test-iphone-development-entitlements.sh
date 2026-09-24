#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_yml="$repo_root/iPhone/project.yml"
project_file="$repo_root/iPhone/DropMesh.xcodeproj/project.pbxproj"
main_entitlements="$repo_root/iPhone/Shared/DropMeshMainDevelopment.entitlements"
share_entitlements="$repo_root/iPhone/Shared/DropMeshDevelopment.entitlements"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f "$main_entitlements" ]] || fail "main development entitlements file is missing"
[[ -f "$share_entitlements" ]] || fail "Share development entitlements file is missing"

main_group=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$main_entitlements" 2>/dev/null) || fail "main App Group is missing"
[[ "$main_group" == "group.com.zensystech.dropmesh.iphone.dev" ]] || fail "main App Group changed"
main_apple_login=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin:0' "$main_entitlements" 2>/dev/null) || fail "main Apple login entitlement is missing"
[[ "$main_apple_login" == "Default" ]] || fail "main Apple login entitlement is not Default"

share_group=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$share_entitlements" 2>/dev/null) || fail "Share App Group is missing"
[[ "$share_group" == "group.com.zensystech.dropmesh.iphone.dev" ]] || fail "Share App Group changed"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$share_entitlements" >/dev/null 2>&1; then
  fail "Share unexpectedly has Apple login entitlement"
fi

main_yml_reference_count=$(grep -c 'CODE_SIGN_ENTITLEMENTS: Shared/DropMeshMainDevelopment.entitlements' "$project_yml" || true)
[[ "$main_yml_reference_count" -eq 1 ]] || fail "project.yml must reference the main entitlements exactly once"
share_yml_reference_count=$(grep -c 'CODE_SIGN_ENTITLEMENTS: Shared/DropMeshDevelopment.entitlements' "$project_yml" || true)
[[ "$share_yml_reference_count" -eq 1 ]] || fail "project.yml must keep the Share entitlements reference exactly once"

main_project_reference_count=$(grep -c 'CODE_SIGN_ENTITLEMENTS = Shared/DropMeshMainDevelopment.entitlements;' "$project_file" || true)
[[ "$main_project_reference_count" -eq 2 ]] || fail "generated project must use the main entitlements in Debug and Release"
share_project_reference_count=$(grep -c 'CODE_SIGN_ENTITLEMENTS = Shared/DropMeshDevelopment.entitlements;' "$project_file" || true)
[[ "$share_project_reference_count" -eq 2 ]] || fail "generated project must keep Share on its existing entitlements in Debug and Release"

bundle_id_count=$(grep -c 'PRODUCT_BUNDLE_IDENTIFIER = com.zensystech.dropmesh.iphone.dev;' "$project_file" || true)
[[ "$bundle_id_count" -eq 2 ]] || fail "development main bundle ID changed or is missing"

printf 'PASS: development main Apple login entitlement is isolated from Share\n'
