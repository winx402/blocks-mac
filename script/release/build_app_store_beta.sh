#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project="$repo_root/apps/Blocks/Blocks.xcodeproj"
profile="$repo_root/apps/Blocks/Config/Distribution.AppStoreBeta.xcconfig"
identity_config="$repo_root/apps/Blocks/Config/ReleaseIdentity.local.xcconfig"
derived_data="${BLOCKS_RELEASE_DERIVED_DATA:-$repo_root/DerivedData/AppStoreBeta}"
archive_path="${BLOCKS_ARCHIVE_PATH:-$repo_root/dist/app-store/Blocks-AppStoreBeta.xcarchive}"
unsigned=0

xcconfig_value() {
  local key="$1"
  local xcconfig="$2"

  awk -v key="$key" '
    {
      line = $0
      sub(/\/\/.*$/, "", line)
      equals = index(line, "=")
      if (!equals) {
        next
      }
      lhs = substr(line, 1, equals - 1)
      rhs = substr(line, equals + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
      if (lhs == key) {
        value = rhs
      }
    }
    END {
      if (value != "") {
        print value
      }
    }
  ' "$xcconfig"
}

require_identity_value() {
  local key="$1"
  local value="$2"

  [[ -n "$value" && "$value" != "-" && "$value" != *"YOUR_"* ]] || {
    echo "error: set $key in ReleaseIdentity.local.xcconfig to a confirmed Store signing value." >&2
    exit 67
  }
}

if [[ "${1:-}" == "--unsigned" ]]; then
  unsigned=1
  shift
fi
if (($#)); then
  echo "usage: $0 [--unsigned]" >&2
  exit 2
fi

common_args=(
  -project "$project"
  -scheme Blocks
  -configuration AppStoreRelease
  -xcconfig "$profile"
  -derivedDataPath "$derived_data"
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=NO
)

if ((unsigned)); then
  echo "warning: building an unsigned Store Beta audit artifact; it cannot be uploaded." >&2
  xcodebuild "${common_args[@]}" CODE_SIGNING_ALLOWED=NO build
  app_bundle="$derived_data/Build/Products/AppStoreRelease/Blocks.app"
  "$repo_root/script/release/audit_app_bundle.sh" \
    --channel app-store-beta \
    --app "$app_bundle"
else
  [[ -f "$identity_config" ]] || {
    echo "error: phase 0 identity file is missing; refusing to create a distribution archive." >&2
    exit 66
  }
  development_team="$(xcconfig_value DEVELOPMENT_TEAM "$identity_config")"
  profile_specifier="$(xcconfig_value PROVISIONING_PROFILE_SPECIFIER "$identity_config")"
  identity="${BLOCKS_APPLE_DISTRIBUTION_IDENTITY:-}"
  expected_cert_sha1="${BLOCKS_EXPECTED_SIGNING_CERT_SHA1:-}"
  expected_cert_sha1_compact="${expected_cert_sha1//:/}"
  require_identity_value DEVELOPMENT_TEAM "$development_team"
  [[ "$development_team" =~ ^[A-Z0-9]{10}$ ]] || { echo "error: DEVELOPMENT_TEAM must be the explicit 10-character Apple Team ID before xcodebuild." >&2; exit 67; }
  require_identity_value PROVISIONING_PROFILE_SPECIFIER "$profile_specifier"
  # Shell arguments/environment values cannot contain NUL bytes; reject CR/LF
  # so this exact signing authority remains a single certificate name.
  [[ "$identity" != *$'\r'* && "$identity" != *$'\n'* ]] || { echo "error: BLOCKS_APPLE_DISTRIBUTION_IDENTITY must be a single line." >&2; exit 67; }
  store_identity_pattern="^Apple Distribution: .+ \\(${development_team}\\)$"
  [[ "$identity" =~ $store_identity_pattern ]] || { echo "error: set BLOCKS_APPLE_DISTRIBUTION_IDENTITY to the exact Apple Distribution authority for DEVELOPMENT_TEAM." >&2; exit 67; }
  [[ "$expected_cert_sha1_compact" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo "error: set BLOCKS_EXPECTED_SIGNING_CERT_SHA1 to the confirmed signing certificate SHA-1." >&2; exit 67; }

  mkdir -p "$(dirname "$archive_path")"
  xcodebuild "${common_args[@]}" \
    -archivePath "$archive_path" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" \
    DEVELOPMENT_TEAM="$development_team" \
    PROVISIONING_PROFILE_SPECIFIER="$profile_specifier" \
    archive
  app_bundle="$archive_path/Products/Applications/Blocks.app"
  "$repo_root/script/release/audit_app_bundle.sh" \
    --channel app-store-beta \
    --app "$app_bundle" \
    --require-signature \
    --expected-team-id "$development_team" \
    --expected-authority "$identity" \
    --expected-cert-sha1 "$expected_cert_sha1"
fi

echo "Store Beta app: $app_bundle"
