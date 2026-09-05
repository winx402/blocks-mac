#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project="$repo_root/apps/Blocks/Blocks.xcodeproj"
profile="$repo_root/apps/Blocks/Config/Distribution.DirectBeta.xcconfig"
identity_config="$repo_root/apps/Blocks/Config/ReleaseIdentity.local.xcconfig"
derived_data="${BLOCKS_RELEASE_DERIVED_DATA:-$repo_root/DerivedData/DirectBeta}"
unsigned=0

if [[ "${1:-}" == "--unsigned" ]]; then
  unsigned=1
  shift
fi
if (($#)); then
  echo "usage: $0 [--unsigned]" >&2
  exit 2
fi

if ((unsigned)); then
  echo "warning: building an unsigned audit artifact; it is not publishable." >&2
else
  [[ -f "$identity_config" ]] || {
    echo "error: phase 0 identity file is missing. Copy ReleaseIdentity.local.example.xcconfig only after brand, URLs, Bundle ID, and Team ID are confirmed." >&2
    exit 66
  }
fi

build_args=(
  -project "$project"
  -scheme Blocks
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
app_bundle="$derived_data/Build/Products/Release/Blocks.app"

if ((unsigned)); then
  "$repo_root/script/release/audit_app_bundle.sh" \
    --channel direct-beta \
    --app "$app_bundle"
else
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
  "$repo_root/script/release/sign_direct_bundle.sh" "$app_bundle" "$identity"
  "$repo_root/script/release/audit_app_bundle.sh" \
    --channel direct-beta \
    --app "$app_bundle" \
    --require-signature \
    --expected-team-id "$development_team" \
    --expected-authority "$identity" \
    --expected-cert-sha1 "$expected_cert_sha1"
fi

echo "Direct Beta app: $app_bundle"
