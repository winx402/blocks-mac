#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  local path="$1"
  if [[ ! -f "$ROOT_DIR/$path" ]]; then
    echo "missing file: $path" >&2
    exit 1
  fi
}

require_contains() {
  local path="$1"
  local pattern="$2"
  if ! grep -Fq -- "$pattern" "$ROOT_DIR/$path"; then
    echo "missing pattern in $path: $pattern" >&2
    exit 1
  fi
}

require_file "scripts/build.sh"
require_file "Sources/BlocksLoginItemProbe/main.swift"
require_file "Sources/BlocksLoginItemHelper/main.swift"
require_file "Resources/BlocksLoginItemProbe-Info.plist"
require_file "Resources/BlocksLoginItemHelper-Info.plist"
require_file "Resources/BlocksLoginItemProbe.entitlements"
require_file "Resources/BlocksLoginItemHelper.entitlements"
require_file "README.md"

require_contains "Resources/BlocksLoginItemProbe-Info.plist" "app.blocks.spikes.loginitem.app"
require_contains "Resources/BlocksLoginItemHelper-Info.plist" "app.blocks.spikes.loginitem.helper"
require_contains "Resources/BlocksLoginItemProbe.entitlements" "com.apple.security.app-sandbox"
require_contains "Resources/BlocksLoginItemHelper.entitlements" "com.apple.security.app-sandbox"
require_contains "Sources/BlocksLoginItemProbe/main.swift" "blocks-login-helper"
require_contains "Sources/BlocksLoginItemProbe/main.swift" "--roundtrip"
require_contains "Sources/BlocksLoginItemHelper/main.swift" "heartbeat"
require_contains "scripts/build.sh" "CODESIGN_IDENTITY"

echo "structure ok"
