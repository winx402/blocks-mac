#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 '/path/to/Blocks Selection Helper.app' [--require-signature --expected-team-id TEAM_ID --expected-authority AUTHORITY --expected-cert-sha1 SHA1]" >&2
}

if (($# < 1)); then
  usage
  exit 2
fi

app_bundle="$1"
shift
require_signature=0
expected_team_id=""
expected_authority=""
expected_cert_sha1="${BLOCKS_EXPECTED_SIGNING_CERT_SHA1:-}"
expected_version=""
expected_build=""
expected_release_name=""
while (($#)); do case "$1" in
  --require-signature) require_signature=1; shift ;;
  --expected-team-id) expected_team_id="${2:-}"; shift 2 ;;
  --expected-authority) expected_authority="${2:-}"; shift 2 ;;
  --expected-cert-sha1) expected_cert_sha1="${2:-}"; shift 2 ;;
  --expected-version) expected_version="${2:-}"; shift 2 ;;
  --expected-build) expected_build="${2:-}"; shift 2 ;;
  --expected-release-name) expected_release_name="${2:-}"; shift 2 ;;
  *) echo "error: unknown argument: $1" >&2; exit 2 ;;
esac; done

if [[ -n "$expected_version$expected_build$expected_release_name" ]] && ! [[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$expected_build" =~ ^[1-9][0-9]*$ && "$expected_release_name" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
  echo "error: --expected-version, --expected-build, and --expected-release-name must be supplied together and valid" >&2
  exit 2
fi
if ((require_signature)) && [[ -z "$expected_authority" ]]; then
  echo "error: --require-signature requires an explicit non-empty --expected-authority" >&2
  usage
  exit 2
fi
# Shell arguments cannot contain NUL bytes. Reject line breaks explicitly so an
# Authority remains one metadata line and cannot alter a line-oriented check.
if [[ "$expected_authority" == *$'\r'* || "$expected_authority" == *$'\n'* ]]; then
  echo "error: --expected-authority must be a single line" >&2
  exit 2
fi

[[ -d "$app_bundle" ]] || {
  echo "error: Selection Helper bundle not found: $app_bundle" >&2
  exit 66
}

executable="$app_bundle/Contents/MacOS/Blocks Selection Helper"
info_plist="$app_bundle/Contents/Info.plist"
contents="$app_bundle/Contents"
[[ -x "$executable" ]] || { echo "error: Helper executable is missing" >&2; exit 1; }
[[ -f "$info_plist" ]] || { echo "error: Helper Info.plist is missing" >&2; exit 1; }

if forbidden_link="$(find "$contents" -type l -print -quit)"; [[ -n "$forbidden_link" ]]; then
  echo "error: symbolic link is forbidden in Helper bundle: ${forbidden_link#"$app_bundle/"}" >&2
  exit 1
fi

while IFS= read -r -d '' bundle_member; do
  file -b "$bundle_member" | grep -q 'Mach-O' || continue
  [[ "$bundle_member" == "$executable" ]] && continue
  echo "error: unexpected nested Helper executable: ${bundle_member#"$app_bundle/"}" >&2
  exit 1
done < <(find "$contents" -type f -print0)

architectures="$(lipo -archs "$executable")"
minimum_system="$(plutil -extract LSMinimumSystemVersion raw "$info_plist")"
channel="$(plutil -extract BLOCKS_DISTRIBUTION_CHANNEL raw "$info_plist")"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
url_scheme="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw "$info_plist")"

[[ "$architectures" == "arm64" ]] || {
  echo "error: expected arm64-only Helper, got: $architectures" >&2
  exit 1
}
[[ "$minimum_system" == "14.0" ]] || {
  echo "error: expected Helper minimum macOS 14.0, got: $minimum_system" >&2
  exit 1
}
[[ "$channel" == "direct-beta" || "$channel" == "direct-stable" ]] || {
  echo "error: expected direct-beta or direct-stable Helper channel, got: $channel" >&2
  exit 1
}
[[ "$bundle_identifier" == "app.blocks.selection-helper" ]] || {
  echo "error: expected Helper bundle identifier app.blocks.selection-helper, got: $bundle_identifier" >&2
  exit 1
}
[[ "$url_scheme" == "blocks-selection-helper" ]] || {
  echo "error: expected Helper URL scheme blocks-selection-helper, got: $url_scheme" >&2
  exit 1
}

# Packaging validates the requested release identity. Runtime compatibility
# remains governed by the authenticated Helper protocol, not marketing labels.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release_profile="$repo_root/apps/Blocks/Config/Distribution.DirectBeta.xcconfig"
read_release_value() {
  awk -F= -v key="$1" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      count++; value=$2; sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      if (NF != 2) invalid=1
    }
    END { if (count != 1 || invalid || value == "") exit 1; print value }
  ' "$release_profile"
}
if [[ -z "$expected_version" ]]; then
  if [[ "$channel" == "direct-stable" ]]; then
    expected_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -expect string "$info_plist")"
    expected_build="$(/usr/bin/plutil -extract CFBundleVersion raw -expect string "$info_plist")"
    expected_release_name="$(/usr/bin/plutil -extract BLOCKS_RELEASE_NAME raw -expect string "$info_plist")"
  else
    expected_version="$(read_release_value MARKETING_VERSION)" \
      && expected_build="$(read_release_value CURRENT_PROJECT_VERSION)" \
      && expected_release_name="$(read_release_value BLOCKS_RELEASE_NAME)" \
      || { echo "error: Helper release profile identity is missing or ambiguous" >&2; exit 1; }
  fi
fi
[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
   && "$expected_build" =~ ^[0-9]+$ \
   && "$expected_release_name" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] \
  || { echo "error: Helper release profile identity is invalid" >&2; exit 1; }
/usr/bin/python3 - "$repo_root" "$expected_release_name" "$expected_version" "$expected_build" "$channel" <<'PY' \
  || { echo "error: Helper release name, version/build, and channel are inconsistent" >&2; exit 1; }
import sys
sys.path.insert(0, sys.argv[1] + "/script/release")
from release_versioning import validate_bundle_version
parsed = validate_bundle_version("v" + sys.argv[2], sys.argv[2], sys.argv[3], sys.argv[4])
if sys.argv[5] != ("direct-beta" if parsed.is_prerelease else "direct-stable"):
    raise ValueError("Helper channel does not match SemVer prerelease state")
PY
verify_release_field() {
  local actual
  # Keep a sentinel while capturing output so shell substitution cannot strip
  # trailing newlines from a malformed value and make it match the release.
  actual="$(/usr/bin/plutil -extract "$1" raw -expect string -n "$info_plist" 2>/dev/null && printf '.')" \
    && actual="${actual%.}" \
    && [[ "$actual" == "$2" ]] \
    || { echo "error: Helper $1 differs from release profile or is not a string" >&2; return 1; }
}
verify_release_field CFBundleShortVersionString "$expected_version"
verify_release_field CFBundleVersion "$expected_build"
verify_release_field BLOCKS_RELEASE_NAME "$expected_release_name"

if ((require_signature)); then
  [[ "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]] || { echo "error: --expected-team-id must be the explicit 10-character Apple Team ID" >&2; exit 2; }
  expected_authority_pattern="^Developer ID Application: .+ \\(${expected_team_id}\\)$"
  [[ "$expected_authority" =~ $expected_authority_pattern ]] || { echo "error: --expected-authority must be the exact Developer ID Application authority for --expected-team-id" >&2; exit 2; }
  expected_cert_sha1_compact="${expected_cert_sha1//:/}"
  [[ "$expected_cert_sha1_compact" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo "error: --expected-cert-sha1 must be the explicit 40-hex signing certificate SHA-1" >&2; exit 2; }
  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  details="$(codesign -dvv "$app_bundle" 2>&1)"
  team_identifier="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$details")"
  [[ "$team_identifier" == "$expected_team_id" ]] || { echo "error: Helper TeamIdentifier differs from expected Team ID" >&2; exit 1; }
  signing_identifier="$(awk -F= '/^Identifier=/{print $2; exit}' <<<"$details")"
  [[ "$signing_identifier" == "app.blocks.selection-helper" ]] || { echo "error: Helper signing Identifier differs from expected bundle identifier" >&2; exit 1; }
  actual_authority="$(awk '/^Authority=/{print substr($0, 11); exit}' <<<"$details")"
  [[ "$actual_authority" == "$expected_authority" ]] || { echo "error: Helper signing Authority differs from expected Authority" >&2; exit 1; }
  if [[ -n "$expected_cert_sha1" ]]; then
    certificate_file="$(mktemp "${TMPDIR:-/tmp}/blocks-helper-signing-cert.XXXXXX")"
    codesign -d --extract-certificates "$certificate_file" "$app_bundle" >/dev/null 2>&1 || { echo "error: cannot extract Helper signing certificate" >&2; exit 1; }
    fingerprint="$(openssl x509 -inform der -in "${certificate_file}0" -noout -fingerprint -sha1 2>/dev/null | sed 's/^[^=]*=//; s/://g')"
    /bin/rm -f -- "$certificate_file"{,0,1,2,3,4,5,6,7,8,9}
    [[ "$(printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]')" == "$(printf '%s' "${expected_cert_sha1//:/}" | tr '[:lower:]' '[:upper:]')" ]] || { echo "error: Helper signing certificate SHA-1 differs from expected certificate" >&2; exit 1; }
  fi
  grep -q 'flags=.*runtime' <<<"$details" || {
    echo "error: Helper signature does not enable Hardened Runtime" >&2
    exit 1
  }
  helper_entitlements="$(mktemp "${TMPDIR:-/tmp}/blocks-helper-entitlements.XXXXXX.plist")"
  trap '/bin/rm -f -- "${helper_entitlements:-}"' EXIT
  codesign -d --entitlements :- "$app_bundle" > "$helper_entitlements" 2>/dev/null \
    || { echo "error: cannot read Helper signed entitlements" >&2; exit 1; }
  [[ -s "$helper_entitlements" ]] \
    || { echo "error: Helper signed entitlements are missing" >&2; exit 1; }
  plutil -lint "$helper_entitlements" >/dev/null \
    || { echo "error: Helper signed entitlements are invalid" >&2; exit 1; }
  helper_entitlement_keys="$(/usr/libexec/PlistBuddy -c Print "$helper_entitlements" | sed -n 's/^[[:space:]]*\([^[:space:] =]*\) =.*/\1/p' | LC_ALL=C sort -u)"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    case "$key" in
      com.apple.application-identifier|com.apple.developer.team-identifier|keychain-access-groups) ;;
      *) echo "error: unexpected Helper signed entitlement: $key" >&2; exit 1 ;;
    esac
  done <<< "$helper_entitlement_keys"
  if plutil -extract com.apple.developer.team-identifier raw "$helper_entitlements" >/dev/null 2>&1; then
    [[ "$(plutil -extract com.apple.developer.team-identifier raw "$helper_entitlements")" == "$expected_team_id" ]] \
      || { echo "error: Helper signed entitlement Team ID differs" >&2; exit 1; }
  fi
  if plutil -extract com.apple.application-identifier raw "$helper_entitlements" >/dev/null 2>&1; then
    [[ "$(plutil -extract com.apple.application-identifier raw "$helper_entitlements")" == "$expected_team_id.app.blocks.selection-helper" ]] \
      || { echo "error: Helper signed application identifier differs" >&2; exit 1; }
  fi
  helper_keychain_group="$(plutil -extract 'keychain-access-groups.0' raw "$helper_entitlements" 2>/dev/null || true)"
  [[ "$helper_keychain_group" == "$expected_team_id.app.blocks.selection-helper.shared" ]] \
    || { echo "error: Helper signed keychain-access-groups is missing or contains a non-shared group" >&2; exit 1; }
  if plutil -extract 'keychain-access-groups.1' raw "$helper_entitlements" >/dev/null 2>&1; then
    echo "error: Helper signed keychain-access-groups must contain exactly one shared group" >&2
    exit 1
  fi
fi

echo "PASS: $channel Selection Helper bundle audit"
echo "app=$app_bundle"
echo "architecture=$architectures"
echo "minimum_system=$minimum_system"
echo "bundle_identifier=$bundle_identifier"
echo "version=$expected_version"
echo "build=$expected_build"
echo "release_name=$expected_release_name"
