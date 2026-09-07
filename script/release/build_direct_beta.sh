#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project="$repo_root/apps/Blocks/Blocks.xcodeproj"
profile="$repo_root/apps/Blocks/Config/Distribution.DirectBeta.xcconfig"
identity_config="$repo_root/apps/Blocks/Config/ReleaseIdentity.local.xcconfig"
derived_data="${BLOCKS_RELEASE_DERIVED_DATA:-$repo_root/DerivedData/DirectBeta}"
unsigned=0
embedded_helper=""
version=""
build_number=""
release_name=""
channel="direct-beta"
update_feed_url=""
provisioning_profile=""

while (($#)); do
  case "$1" in
    --unsigned) unsigned=1; shift ;;
    --embedded-helper) embedded_helper="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build-number) build_number="${2:-}"; shift 2 ;;
    --release-name) release_name="${2:-}"; shift 2 ;;
    --update-feed-url) update_feed_url="${2:-}"; shift 2 ;;
    --provisioning-profile) provisioning_profile="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--unsigned] --embedded-helper /path/to/Blocks\ Selection\ Helper.app [--version X.Y.Z --build-number N --release-name NAME]" >&2; exit 2 ;;
  esac
done
[[ -d "$embedded_helper" ]] || { echo "error: --embedded-helper must name the independently built Helper bundle." >&2; exit 66; }
if [[ -n "$version$build_number$release_name$update_feed_url" ]]; then
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ && "$release_name" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ && "$update_feed_url" == "https://winx402.github.io/blocks-mac/appcast/stable.xml" ]] \
    || { echo "error: main version, build number, release name, and pinned update feed URL must be supplied together and valid." >&2; exit 2; }
fi

if [[ -n "$release_name" ]]; then
  channel="$(/usr/bin/python3 - "$repo_root" "$release_name" "$version" "$build_number" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/script/release")
from release_versioning import validate_bundle_version
parsed = validate_bundle_version("v" + sys.argv[2], sys.argv[2], sys.argv[3], sys.argv[4])
print("direct-beta" if parsed.is_prerelease else "direct-stable")
PY
  )" || { echo "error: release name and version/build identity do not form a consistent SemVer release." >&2; exit 2; }
fi

if ((unsigned)); then
  echo "warning: building an unsigned audit artifact; it is not publishable." >&2
else
  [[ "$provisioning_profile" =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo "error: --provisioning-profile must be the verified main-App profile UUID." >&2; exit 67; }
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
  BLOCKS_DISTRIBUTION_CHANNEL="$channel"
)
if ((!unsigned)); then build_args+=(PROVISIONING_PROFILE_SPECIFIER="$provisioning_profile"); fi
if [[ -n "$version" ]]; then
  build_args+=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" BLOCKS_RELEASE_NAME="$release_name" BLOCKS_UPDATE_FEED_URL="$update_feed_url")
fi
if ((unsigned)); then
  build_args+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${build_args[@]}" build
app_bundle="$derived_data/Build/Products/Release/Blocks.app"
helper_destination="$app_bundle/Contents/Helpers/Blocks Selection Helper.app"
[[ ! -e "$helper_destination" && ! -L "$helper_destination" ]] || { echo "error: main build unexpectedly already contains a Helper payload." >&2; exit 1; }
mkdir -p "$app_bundle/Contents/Helpers"
/usr/bin/ditto "$embedded_helper" "$helper_destination"

if ((unsigned)); then
  helper_audit_args=("$helper_destination")
  if [[ -n "$version" ]]; then
    helper_audit_args+=(--expected-version "$version" --expected-build "$build_number" --expected-release-name "$release_name")
  fi
  "$repo_root/script/release/audit_selection_helper_bundle.sh" "${helper_audit_args[@]}"
  audit_args=(--channel "$channel" --app "$app_bundle")
  if [[ -n "$version" ]]; then
    audit_args+=(--expected-version "$version" --expected-build "$build_number" --expected-release-name "$release_name")
  fi
  "$repo_root/script/release/audit_app_bundle.sh" "${audit_args[@]}"
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
  helper_audit_args=("$helper_destination")
  if [[ -n "$version" ]]; then
    helper_audit_args+=(--expected-version "$version" --expected-build "$build_number" --expected-release-name "$release_name")
  fi
  helper_audit_args+=(--require-signature --expected-team-id "$development_team" --expected-authority "$identity" --expected-cert-sha1 "$expected_cert_sha1")
  "$repo_root/script/release/audit_selection_helper_bundle.sh" "${helper_audit_args[@]}"
  "$repo_root/script/release/sign_direct_bundle.sh" "$app_bundle" "$identity"
  audit_args=(--channel "$channel" --app "$app_bundle" --require-signature --expected-team-id "$development_team" --expected-authority "$identity" --expected-cert-sha1 "$expected_cert_sha1")
  if [[ -n "$version" ]]; then
    audit_args+=(--expected-version "$version" --expected-build "$build_number" --expected-release-name "$release_name")
  fi
  "$repo_root/script/release/audit_app_bundle.sh" "${audit_args[@]}"
fi

echo "$channel app: $app_bundle"
