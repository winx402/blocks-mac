#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: package_dmg.sh \
  --artifact direct-stable|direct-beta|selection-helper-stable|selection-helper-beta \
  --app /path/to/App.app \
  --release-name VERSION \
  [--expected-dmg-name NAME.dmg] \
  [--expected-version X.Y.Z --expected-build N] \
  --output-dir /path/to/output \
  --expected-team-id TEAMID \
  --expected-cert-sha1 SHA1 \
  [--identity 'Developer ID Application: ... (TEAMID)']
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifact=""
app_bundle=""
release_name=""
output_directory=""
expected_team_id=""
expected_cert_sha1="${BLOCKS_EXPECTED_SIGNING_CERT_SHA1:-}"
identity="${BLOCKS_DEVELOPER_ID_APPLICATION:-}"
expected_dmg_name=""
expected_version=""
expected_build=""

while (($#)); do
  case "$1" in
    --artifact) artifact="${2:-}"; shift 2 ;;
    --app) app_bundle="${2:-}"; shift 2 ;;
    --release-name) release_name="${2:-}"; shift 2 ;;
    --output-dir) output_directory="${2:-}"; shift 2 ;;
    --expected-team-id) expected_team_id="${2:-}"; shift 2 ;;
    --expected-cert-sha1) expected_cert_sha1="${2:-}"; shift 2 ;;
    --identity) identity="${2:-}"; shift 2 ;;
    --expected-dmg-name) expected_dmg_name="${2:-}"; shift 2 ;;
    --expected-version) expected_version="${2:-}"; shift 2 ;;
    --expected-build) expected_build="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$artifact" == "direct-beta" || "$artifact" == "direct-stable" || "$artifact" == "selection-helper-beta" || "$artifact" == "selection-helper-stable" ]] \
  || { usage; exit 2; }
[[ -d "$app_bundle" ]] \
  || { echo "error: app bundle not found: $app_bundle" >&2; exit 66; }
[[ "$release_name" =~ ^[0-9A-Za-z._+-]+$ ]] \
  || { echo "error: release name contains unsupported filename characters" >&2; exit 2; }
[[ -n "$output_directory" && "$output_directory" != "/" ]] \
  || { echo "error: an explicit, non-root output directory is required" >&2; exit 2; }
if [[ -n "$expected_dmg_name" ]]; then
  [[ "$expected_dmg_name" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*\.dmg$ ]] \
    || { echo "error: --expected-dmg-name must be one safe .dmg filename" >&2; exit 2; }
fi
if [[ -n "$expected_version$expected_build" ]] && ! [[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$expected_build" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --expected-version and --expected-build must be supplied together and valid" >&2
  exit 2
fi
[[ "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]] \
  || { echo "error: --expected-team-id must be the explicit 10-character Apple Team ID" >&2; exit 2; }
expected_cert_sha1_compact="${expected_cert_sha1//:/}"
[[ "$expected_cert_sha1_compact" =~ ^[A-Fa-f0-9]{40}$ ]] \
  || { echo "error: --expected-cert-sha1 must be the explicit 40-hex signing certificate SHA-1" >&2; exit 2; }
[[ -n "$identity" ]] \
  || { echo "error: BLOCKS_DEVELOPER_ID_APPLICATION or --identity is required" >&2; exit 67; }
# Shell arguments cannot contain NUL bytes. Reject line breaks explicitly so an
# Authority remains one metadata line and cannot alter a line-oriented check.
[[ "$identity" != *$'\r'* && "$identity" != *$'\n'* ]] \
  || { echo "error: --identity must be a single line" >&2; exit 67; }
direct_identity_pattern="^Developer ID Application: .+ \\(${expected_team_id}\\)$"
[[ "$identity" =~ $direct_identity_pattern ]] \
  || { echo "error: --identity must be an exact Developer ID Application authority for --expected-team-id" >&2; exit 67; }
# A correctly audited bundle must not be published under another release's
# filename/URL. Preserve trailing whitespace during the string comparison.
bundle_release_name="$(/usr/bin/plutil -extract BLOCKS_RELEASE_NAME raw -expect string -n "$app_bundle/Contents/Info.plist" 2>/dev/null && printf '.')" \
  && bundle_release_name="${bundle_release_name%.}" \
  && [[ "$bundle_release_name" == "$release_name" ]] \
  || { echo "error: --release-name must match the bundle BLOCKS_RELEASE_NAME string" >&2; exit 2; }
channel="$(/usr/bin/python3 - "$repo_root" "$app_bundle/Contents/Info.plist" "$release_name" "$artifact" <<'PY'
import plistlib, sys
sys.path.insert(0, sys.argv[1] + "/script/release")
from release_versioning import validate_bundle_version
with open(sys.argv[2], "rb") as stream:
    info = plistlib.load(stream)
parsed = validate_bundle_version("v" + sys.argv[3], info.get("BLOCKS_RELEASE_NAME"),
                                 info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
channel = "direct-beta" if parsed.is_prerelease else "direct-stable"
suffix = "beta" if parsed.is_prerelease else "stable"
if info.get("BLOCKS_DISTRIBUTION_CHANNEL") != channel or sys.argv[4] not in ("direct-" + suffix, "selection-helper-" + suffix):
    raise ValueError("artifact kind, bundle channel, and release name disagree")
print(channel)
PY
)" || { echo "error: artifact and bundle channel must match the SemVer release identity" >&2; exit 2; }
if [[ -z "$expected_version" ]]; then
  expected_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -expect string "$app_bundle/Contents/Info.plist")"
  expected_build="$(/usr/bin/plutil -extract CFBundleVersion raw -expect string "$app_bundle/Contents/Info.plist")"
fi
security find-identity -v -p codesigning | awk -v identity="$identity" 'index($0, identity) { found = 1 } END { exit !found }' \
  || { echo "error: DMG signing identity is unavailable: $identity" >&2; exit 67; }

case "$artifact" in
  direct-beta|direct-stable)
    audit_args=(--channel "$channel" --app "$app_bundle" --require-signature --expected-team-id "$expected_team_id" --expected-authority "$identity" --expected-cert-sha1 "$expected_cert_sha1")
    if [[ -n "$expected_version" ]]; then
      audit_args+=(--expected-version "$expected_version" --expected-build "$expected_build" --expected-release-name "$release_name")
    fi
    "$repo_root/script/release/audit_app_bundle.sh" "${audit_args[@]}"
    ;;
  selection-helper-beta|selection-helper-stable)
    "$repo_root/script/release/audit_selection_helper_bundle.sh" \
      "$app_bundle" \
      --expected-version "$expected_version" --expected-build "$expected_build" --expected-release-name "$release_name" \
      --require-signature \
      --expected-team-id "$expected_team_id" \
      --expected-authority "$identity" \
      --expected-cert-sha1 "$expected_cert_sha1"
    ;;
esac

mkdir -p "$output_directory"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/blocks-dmg.XXXXXX")"
app_name="$(basename "$app_bundle" .app)"
app_slug="${app_name// /-}"
dmg_path="$output_directory/$app_slug-$release_name-arm64.dmg"
if [[ -n "$expected_dmg_name" ]]; then
  dmg_path="$output_directory/$expected_dmg_name"
fi
temporary_dmg="$output_directory/.$app_slug-$release_name-arm64.$$.tmp.dmg"
certificate_file=""
cleanup() {
  /bin/rm -R -- "$staging_directory"
  /bin/rm -f -- "$temporary_dmg"
  if [[ -n "$certificate_file" ]]; then
    /bin/rm -f -- "$certificate_file"{,0,1,2,3,4,5,6,7,8,9}
  fi
}
trap cleanup EXIT

[[ ! -e "$dmg_path" && ! -L "$dmg_path" ]] \
  || { echo "error: refusing to overwrite existing DMG: $dmg_path" >&2; exit 73; }
[[ ! -e "$dmg_path.sha256" && ! -L "$dmg_path.sha256" ]] \
  || { echo "error: refusing to pair a new DMG with an existing checksum: $dmg_path.sha256" >&2; exit 73; }

/usr/bin/ditto "$app_bundle" "$staging_directory/$(basename "$app_bundle")"
ln -s /Applications "$staging_directory/Applications"
hdiutil create \
  -volname "$app_name $release_name" \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$temporary_dmg"

codesign --force --sign "$identity" --timestamp "$temporary_dmg"
codesign --verify --verbose=2 "$temporary_dmg"
dmg_signature="$(codesign -dvv "$temporary_dmg" 2>&1)"
dmg_team_id="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$dmg_signature")"
[[ "$dmg_team_id" == "$expected_team_id" ]] \
  || { echo "error: DMG TeamIdentifier differs from expected Team ID" >&2; exit 1; }
dmg_authority="$(awk '/^Authority=/{print substr($0, 11); exit}' <<<"$dmg_signature")"
[[ "$dmg_authority" == "$identity" ]] \
  || { echo "error: DMG signing Authority differs from expected Authority" >&2; exit 1; }
certificate_file="$(mktemp "${TMPDIR:-/tmp}/blocks-dmg-signing-cert.XXXXXX")"
codesign -d --extract-certificates "$certificate_file" "$temporary_dmg" >/dev/null 2>&1 \
  || { echo "error: cannot extract the DMG signing certificate" >&2; exit 1; }
dmg_cert_sha1="$(openssl x509 -inform der -in "${certificate_file}0" -noout -fingerprint -sha1 2>/dev/null | sed 's/^[^=]*=//; s/://g')"
[[ "$(printf '%s' "$dmg_cert_sha1" | tr '[:lower:]' '[:upper:]')" \
    == "$(printf '%s' "$expected_cert_sha1_compact" | tr '[:lower:]' '[:upper:]')" ]] \
  || { echo "error: DMG signing certificate SHA-1 differs from expected certificate" >&2; exit 1; }

# A preflight existence check alone is racy, and BSD `mv -n` reports success
# when it silently keeps a competing destination. Both names are in the same
# output directory, so an exclusive hard link is an atomic no-overwrite
# publication step; the trap removes the temporary name afterward.
ln "$temporary_dmg" "$dmg_path" \
  || { echo "error: refusing to replace a concurrently published DMG: $dmg_path" >&2; exit 73; }
/bin/rm -f -- "$temporary_dmg"
stat -f 'size_bytes=%z' "$dmg_path"
echo "dmg=$dmg_path"
echo "checksum=pending-notarization-and-staple"
