#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project="$repo_root/apps/Blocks/Blocks.xcodeproj"
profile="$repo_root/apps/Blocks/Config/Distribution.DirectBeta.xcconfig"
identity_config="$repo_root/apps/Blocks/Config/ReleaseIdentity.local.xcconfig"
derived_data="${BLOCKS_HELPER_DERIVED_DATA:-$repo_root/DerivedData/SelectionHelperBeta}"
unsigned=0
version=""
build_number=""
release_name=""
channel="direct-beta"
update_feed_url=""
provisioning_profile=""

while (($#)); do
  case "$1" in
    --unsigned) unsigned=1; shift ;;
    --version) version="${2:-}"; shift 2 ;;
    --build-number) build_number="${2:-}"; shift 2 ;;
    --release-name) release_name="${2:-}"; shift 2 ;;
    --update-feed-url) update_feed_url="${2:-}"; shift 2 ;;
    --provisioning-profile) provisioning_profile="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--unsigned] [--version X.Y.Z --build-number N --release-name NAME]" >&2; exit 2 ;;
  esac
done
if [[ -n "$version$build_number$release_name$update_feed_url" ]]; then
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ && "$release_name" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ && "$update_feed_url" == "https://winx402.github.io/blocks-mac/appcast/stable.xml" ]] \
    || { echo "error: Helper version, build number, release name, and pinned update feed URL must be supplied together and valid." >&2; exit 2; }
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

if ((!unsigned)); then
  [[ "$provisioning_profile" =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo "error: --provisioning-profile must be the verified Helper profile UUID." >&2; exit 67; }
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
app_bundle="$derived_data/Build/Products/Release/Blocks Selection Helper.app"

# Check structural and release identity before applying the final signature.
helper_audit_args=("$app_bundle")
if [[ -n "$version" ]]; then
  helper_audit_args+=(--expected-version "$version" --expected-build "$build_number" --expected-release-name "$release_name")
fi
"$repo_root/script/release/audit_selection_helper_bundle.sh" "${helper_audit_args[@]}"
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
  helper_audit_args=("$app_bundle")
  if [[ -n "$version" ]]; then
    helper_audit_args+=(--expected-version "$version" --expected-build "$build_number" --expected-release-name "$release_name")
  fi
  helper_audit_args+=(--require-signature --expected-team-id "$development_team" --expected-authority "$identity" --expected-cert-sha1 "$expected_cert_sha1")
  "$repo_root/script/release/audit_selection_helper_bundle.sh" "${helper_audit_args[@]}"
fi

echo "$channel Selection Helper: $app_bundle"
