#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
  echo "usage: $0 /path/to/Blocks.app 'Developer ID Application: …'" >&2
  exit 2
fi

app_bundle="$1"
identity="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
identity_config="$repo_root/apps/Blocks/Config/ReleaseIdentity.local.xcconfig"

[[ -d "$app_bundle" ]] || { echo "error: app bundle not found: $app_bundle" >&2; exit 66; }
security find-identity -v -p codesigning | grep -Fq "$identity" \
  || { echo "error: signing identity is unavailable: $identity" >&2; exit 67; }
[[ -f "$identity_config" ]] || { echo "error: phase 0 identity file is missing; refusing to resolve Direct entitlements." >&2; exit 66; }
development_team="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$identity_config")"
[[ "$development_team" =~ ^[A-Z0-9]{10}$ && "$development_team" != *YOUR* ]] \
  || { echo "error: ReleaseIdentity.local.xcconfig must contain a confirmed DEVELOPMENT_TEAM." >&2; exit 67; }

resolved_main_entitlements="$(mktemp "${TMPDIR:-/tmp}/blocks-direct-entitlements.XXXXXX.plist")"
trap '/bin/rm -f -- "${resolved_main_entitlements:-}"' EXIT
/bin/cp "$repo_root/apps/Blocks/BlocksApp/Blocks.entitlements" "$resolved_main_entitlements"
plutil -replace keychain-access-groups -xml "<array><string>${development_team}.app.blocks.app</string><string>${development_team}.app.blocks.selection-helper.shared</string></array>" "$resolved_main_entitlements"
[[ "$(plutil -extract 'keychain-access-groups.0' raw "$resolved_main_entitlements")" == "$development_team.app.blocks.app" ]] \
  && [[ "$(plutil -extract 'keychain-access-groups.1' raw "$resolved_main_entitlements")" == "$development_team.app.blocks.selection-helper.shared" ]] \
  && ! plutil -extract 'keychain-access-groups.2' raw "$resolved_main_entitlements" >/dev/null 2>&1 \
  && ! grep -Fq '$(AppIdentifierPrefix)' "$resolved_main_entitlements" \
  || { echo "error: resolved Direct keychain access groups are invalid." >&2; exit 1; }

sign() {
  local target="$1"
  shift
  codesign --force --sign "$identity" --options runtime --timestamp "$@" "$target"
}

sign "$app_bundle/Contents/XPCServices/BlocksPluginRunner.xpc" \
  --entitlements "$repo_root/apps/Blocks/BlocksPluginRunner/BlocksPluginRunner.entitlements"
sign "$app_bundle/Contents/MacOS/BlocksClipboardBroker" \
  --identifier app.blocks.clipboard-broker \
  --entitlements "$repo_root/apps/Blocks/BlocksClipboardBroker/BlocksClipboardBroker.entitlements"
sign "$app_bundle/Contents/MacOS/BlocksActionBroker" \
  --identifier app.blocks.action-broker \
  --entitlements "$repo_root/apps/Blocks/BlocksActionBroker/BlocksActionBroker.entitlements"
sign "$app_bundle/Contents/Resources/CLI/blocks" --identifier app.blocks.cli
sign "$app_bundle" \
  --entitlements "$resolved_main_entitlements"

codesign --verify --deep --strict --verbose=2 "$app_bundle"
