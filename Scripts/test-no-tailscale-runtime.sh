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

echo "no-tailscale-runtime PASS"
