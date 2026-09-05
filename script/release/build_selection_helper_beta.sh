#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project="$repo_root/apps/Blocks/Blocks.xcodeproj"
profile="$repo_root/apps/Blocks/Config/Distribution.DirectBeta.xcconfig"
identity_config="$repo_root/apps/Blocks/Config/ReleaseIdentity.local.xcconfig"
derived_data="${BLOCKS_HELPER_DERIVED_DATA:-$repo_root/DerivedData/SelectionHelperBeta}"
unsigned=0

if [[ "${1:-}" == "--unsigned" ]]; then
  unsigned=1
  shift
fi
if (($#)); then
  echo "usage: $0 [--unsigned]" >&2
  exit 2
fi

if ((!unsigned)); then
  [[ -f "$identity_config" ]] || {
    echo "error: phase 0 identity file is missing; refusing to sign the Helper." >&2
    exit 66
  }
  identity="${BLOCKS_DEVELOPER_ID_APPLICATION:-}"
  expected_cert_sha1="${BLOCKS_EXPECTED_SIGNING_CERT_SHA1:-}"
  expected_cert_sha1_compact="${expected_cert_sha1//:/}"
  development_team="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$identity_config")"
  [[ "$development_team" =~ ^[A-Z0-9]{10}$ && "$development_team" != *YOUR* ]] || { echo "error: ReleaseIdentity.local.xcconfig must contain a confirmed DEVELOPMENT_TEAM." >&2; exit 67; }
  [[ -n "$identity" ]] || {
    echo "error: set BLOCKS_DEVELOPER_ID_APPLICATION to the exact confirmed certificate name." >&2
    exit 67
  }
  # Shell arguments/environment values cannot contain NUL bytes; reject CR/LF
  # so this exact signing authority remains a single certificate name.
  [[ "$identity" != *$'\r'* && "$identity" != *$'\n'* ]] || { echo "error: BLOCKS_DEVELOPER_ID_APPLICATION must be a single line." >&2; exit 67; }
  direct_identity_pattern="^Developer ID Application: .+ \\(${development_team}\\)$"
  [[ "$identity" =~ $direct_identity_pattern ]] || {
    echo "error: BLOCKS_DEVELOPER_ID_APPLICATION must be an exact Developer ID Application authority for DEVELOPMENT_TEAM." >&2
    exit 67
  }
  [[ "$expected_cert_sha1_compact" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo "error: set BLOCKS_EXPECTED_SIGNING_CERT_SHA1 to the confirmed signing certificate SHA-1." >&2; exit 67; }
  security find-identity -v -p codesigning | awk -v identity="$identity" 'index($0, identity) { found = 1 } END { exit !found }' || {
    echo "error: signing identity is unavailable: $identity" >&2
    exit 67
  }
fi

build_args=(
  -project "$project"
  -scheme BlocksSelectionHelper
  -configuration Release
  -xcconfig "$profile"
  -derivedDataPath "$derived_data"
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=NO
)
if ((unsigned)); then
  build_args+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${build_args[@]}" build
app_bundle="$derived_data/Build/Products/Release/Blocks Selection Helper.app"

# Check structural and release identity before applying the final signature.
"$repo_root/script/release/audit_selection_helper_bundle.sh" "$app_bundle"
if ((!unsigned)); then
  resolved_helper_entitlements="$(mktemp "${TMPDIR:-/tmp}/blocks-helper-entitlements.XXXXXX.plist")"
  trap '/bin/rm -f -- "${resolved_helper_entitlements:-}"' EXIT
  /bin/cp "$repo_root/apps/Blocks/BlocksSelectionHelper/BlocksSelectionHelper.entitlements" "$resolved_helper_entitlements"
  plutil -replace keychain-access-groups -xml "<array><string>${development_team}.app.blocks.selection-helper.shared</string></array>" "$resolved_helper_entitlements"
  [[ "$(plutil -extract 'keychain-access-groups.0' raw "$resolved_helper_entitlements")" == "$development_team.app.blocks.selection-helper.shared" ]] \
    && ! plutil -extract 'keychain-access-groups.1' raw "$resolved_helper_entitlements" >/dev/null 2>&1 \
    && ! grep -Fq '$(AppIdentifierPrefix)' "$resolved_helper_entitlements" \
    || { echo "error: resolved Helper keychain access group is invalid." >&2; exit 1; }
  codesign --force \
    --sign "$identity" \
    --options runtime \
    --timestamp \
    --entitlements "$resolved_helper_entitlements" \
    "$app_bundle"
  "$repo_root/script/release/audit_selection_helper_bundle.sh" \
    "$app_bundle" \
    --require-signature \
    --expected-team-id "$development_team" \
    --expected-authority "$identity" \
    --expected-cert-sha1 "$expected_cert_sha1"
fi

echo "Direct Beta Selection Helper: $app_bundle"
