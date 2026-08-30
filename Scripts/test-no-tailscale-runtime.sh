#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
runtime_file="$project_root/App/ProductionAppRuntime.swift"

if rg -n \
  'Tailscale|PersonalMesh|personalMesh|buildPersonalMesh|MeshConnectionListener|MeshTransferConnector' \
  "$runtime_file"
then
  echo "Production runtime still contains a personal-mesh or Tailscale path" >&2
  exit 1
fi

if rg -n 'runtimeConnectivityMode|ConnectivityMode' \
  "$project_root/App/AppContainer.swift" \
  "$project_root/App/MacChannelApp.swift"
then
  echo "Application diagnostics still expose a selectable connectivity mode" >&2
  exit 1
fi

if rg -n -i 'tailscale|个人网络模式|个人网络通道' \
  "$project_root/Distribution/README.txt" \
  "$project_root/README.md"
then
  echo "Public installation instructions still mention the removed network dependency" >&2
  exit 1
fi

(
  cd "$project_root"
  swift build -c release --product MacChannelApp >/dev/null
)
release_binary="$(cd "$project_root" && swift build -c release --show-bin-path)/MacChannelApp"
if strings "$release_binary" | rg -n -i \
  'tailscale|tailscaled|/Applications/Tailscale\.app|/usr/local/bin/tailscale|ts\.net'
then
  echo "Release binary still contains a Tailscale implementation or endpoint" >&2
  exit 1
fi

echo "no-tailscale-runtime PASS"
