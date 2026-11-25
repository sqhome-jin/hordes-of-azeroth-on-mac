#!/bin/bash
set -euo pipefail

part="${1:-all}"
root="$(cd "$(dirname "$0")/.." && pwd)"
client_source="${2:-$root/client}"
server_source="${3:-$root/server/core}"
out="${4:-$root/release/build/macos}"

mkdir -p "$out"
exec bash "$root/tools/mac/build.sh" "$part" "$client_source" "$server_source" "$out"
