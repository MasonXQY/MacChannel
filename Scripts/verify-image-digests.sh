#!/usr/bin/env bash
set -euo pipefail

# Tags remain in Dockerfiles for human readability, but builds resolve the
# immutable manifest-list digest. This check detects if an upstream tag is ever
# moved so a maintainer can make that update explicit and review release notes.
images=(
  "library/postgres|17.11-alpine3.24|sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73"
  "library/golang|1.25.14-alpine3.24|sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59"
  "library/alpine|3.23.5|sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40"
  "coturn/coturn|4.17.2-r0-alpine|sha256:771a95d04cb97bbc5bfc672e5fdf455591c7d2b2a15f02bb9ceda3e27561695f"
)

for command_name in curl sed awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

for entry in "${images[@]}"; do
  IFS='|' read -r repository tag expected <<< "$entry"
  token_response="$(curl --fail --silent --show-error --get \
    --data-urlencode 'service=registry.docker.io' \
    --data-urlencode "scope=repository:$repository:pull" \
    https://auth.docker.io/token)"
  token="$(printf '%s' "$token_response" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  if [[ -z "$token" ]]; then
    echo "could not obtain registry token for $repository" >&2
    exit 1
  fi
  actual="$(curl --fail --silent --show-error --head \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry-1.docker.io/v2/$repository/manifests/$tag" \
    | awk 'tolower($1) == "docker-content-digest:" {gsub("\r", "", $2); print $2}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "$repository:$tag points to $actual, expected $expected" >&2
    exit 1
  fi
  echo "verified $repository:$tag@$expected"
done
