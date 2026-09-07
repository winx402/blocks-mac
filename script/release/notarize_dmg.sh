#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: notarize_dmg.sh /path/to/signed.dmg \
  --evidence-dir /path/to/new-or-empty-evidence-directory \
  --expected-team-id TEAMID \
  --expected-authority 'Developer ID Application: ... (TEAMID)' \
  --expected-cert-sha1 SHA1 \
  [--expected-version X.Y.Z --expected-build N --expected-release-name NAME]
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dmg_path=""
evidence_dir=""
expected_team_id=""
expected_authority=""
expected_cert_sha1=""
expected_version=""
expected_build=""
expected_release_name=""
while (($#)); do
  case "$1" in
    --evidence-dir) evidence_dir="${2:-}"; shift 2 ;;
    --expected-team-id) expected_team_id="${2:-}"; shift 2 ;;
    --expected-authority) expected_authority="${2:-}"; shift 2 ;;
    --expected-cert-sha1) expected_cert_sha1="${2:-}"; shift 2 ;;
    --expected-version) expected_version="${2:-}"; shift 2 ;;
    --expected-build) expected_build="${2:-}"; shift 2 ;;
    --expected-release-name) expected_release_name="${2:-}"; shift 2 ;;
    -*) usage; exit 2 ;;
    *) [[ -z "$dmg_path" ]] || { usage; exit 2; }; dmg_path="$1"; shift ;;
  esac
done

[[ -n "$dmg_path" && -n "$evidence_dir" ]] || { usage; exit 2; }
[[ "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]] \
  || { echo "error: --expected-team-id must be the explicit 10-character Apple Team ID" >&2; exit 2; }
[[ "$expected_authority" != *$'\r'* && "$expected_authority" != *$'\n'* ]] \
  || { echo "error: --expected-authority must be a single line" >&2; exit 2; }
expected_authority_pattern="^Developer ID Application: .+ \\(${expected_team_id}\\)$"
[[ "$expected_authority" =~ $expected_authority_pattern ]] \
  || { echo "error: --expected-authority must be an exact Developer ID Application authority for --expected-team-id" >&2; exit 2; }
expected_cert_sha1_compact="${expected_cert_sha1//:/}"
[[ "$expected_cert_sha1_compact" =~ ^[A-Fa-f0-9]{40}$ ]] \
  || { echo "error: --expected-cert-sha1 must be the explicit 40-hex signing certificate SHA-1" >&2; exit 2; }
if [[ -n "$expected_version$expected_build$expected_release_name" ]] && ! [[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$expected_build" =~ ^[1-9][0-9]*$ && "$expected_release_name" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
  echo "error: --expected-version, --expected-build, and --expected-release-name must be supplied together and valid" >&2
  exit 2
fi
profile="${BLOCKS_NOTARY_KEYCHAIN_PROFILE:-}"
[[ -f "$dmg_path" ]] || { echo "error: DMG not found: $dmg_path" >&2; exit 66; }
dmg_path="$(cd "$(dirname "$dmg_path")" && pwd)/$(basename "$dmg_path")"
[[ "$(basename "$dmg_path")" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*\.dmg$ ]] \
  || { echo "error: DMG filename is unsafe" >&2; exit 2; }
sha256_path="$dmg_path.sha256"
[[ ! -e "$sha256_path" && ! -L "$sha256_path" ]] \
  || { echo "error: refusing to overwrite an existing final checksum: $sha256_path" >&2; exit 73; }
[[ -n "$evidence_dir" && "$evidence_dir" != "/" ]] || { echo "error: an explicit, non-root evidence directory is required" >&2; exit 2; }
if [[ -e "$evidence_dir" ]]; then
  [[ -d "$evidence_dir" && -z "$(find "$evidence_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || { echo "error: refusing to mix evidence into a non-empty path: $evidence_dir" >&2; exit 73; }
else
  mkdir -p "$evidence_dir"
fi
[[ -n "$profile" ]] || {
  echo "error: set BLOCKS_NOTARY_KEYCHAIN_PROFILE to a Keychain profile created with notarytool store-credentials." >&2
  exit 67
}

result_json="$evidence_dir/notary-submit.json"
mount_point=""
attached_device=""
attach_plist="$evidence_dir/dmg-attach.plist"
checksum_temporary="$sha256_path.$$.tmp"
certificate_file=""
audited_mounted_app=""

cleanup() {
  /bin/rm -f -- "$checksum_temporary"
  if [[ -n "$certificate_file" ]]; then
    /bin/rm -f -- "$certificate_file"{,0,1,2,3,4,5,6,7,8,9}
  fi
  if [[ -n "$mount_point" || -n "$attached_device" ]]; then
    hdiutil detach "${mount_point:-$attached_device}" >> "$evidence_dir/dmg-detach.txt" 2>&1 || hdiutil detach -force "${mount_point:-$attached_device}" >> "$evidence_dir/dmg-detach.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

verify_pinned_signature() {
  local target="$1" label="$2" details actual_team actual_authority fingerprint
  codesign --verify --verbose=2 "$target" 2>&1 | tee "$evidence_dir/${label}-codesign-verify.txt"
  details="$(codesign -dvv "$target" 2>&1)"
  actual_team="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$details")"
  [[ "$actual_team" == "$expected_team_id" ]] \
    || { echo "error: ${label} TeamIdentifier differs from expected Team ID" >&2; return 1; }
  actual_authority="$(awk '/^Authority=/{print substr($0, 11); exit}' <<<"$details")"
  [[ "$actual_authority" == "$expected_authority" ]] \
    || { echo "error: ${label} signing Authority differs from expected Authority" >&2; return 1; }
  certificate_file="$(mktemp "${TMPDIR:-/tmp}/blocks-notary-signing-cert.XXXXXX")"
  codesign -d --extract-certificates "$certificate_file" "$target" >/dev/null 2>&1 \
    || { echo "error: cannot extract ${label} signing certificate" >&2; return 1; }
  fingerprint="$(openssl x509 -inform der -in "${certificate_file}0" -noout -fingerprint -sha1 2>/dev/null | sed 's/^[^=]*=//; s/://g')"
  /bin/rm -f -- "$certificate_file"{,0,1,2,3,4,5,6,7,8,9}
  certificate_file=""
  [[ "$(printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]')" == "$(printf '%s' "$expected_cert_sha1_compact" | tr '[:lower:]' '[:upper:]')" ]] \
    || { echo "error: ${label} signing certificate SHA-1 differs from expected certificate" >&2; return 1; }
}

attach_readonly_dmg() {
  hdiutil attach -readonly -nobrowse -plist "$dmg_path" > "$attach_plist"
  attached_device="$(plutil -extract 'system-entities.0.dev-entry' raw "$attach_plist" 2>/dev/null || true)"
  mount_point="$(plutil -extract 'system-entities.1.mount-point' raw "$attach_plist" 2>/dev/null || plutil -extract 'system-entities.0.mount-point' raw "$attach_plist" 2>/dev/null || true)"
  [[ -n "$mount_point" && -d "$mount_point" ]] || { echo "error: could not determine mounted DMG volume; cleanup will retry attached device ${attached_device:-unknown}" >&2; return 1; }
}

detach_readonly_dmg() {
  [[ -z "$mount_point" ]] && return 0
  if ! hdiutil detach "$mount_point" >> "$evidence_dir/dmg-detach.txt" 2>&1 \
      && ! hdiutil detach -force "$mount_point" >> "$evidence_dir/dmg-detach.txt" 2>&1; then
    echo "error: could not detach mounted DMG before continuing" >&2
    return 1
  fi
  mount_point=""
  attached_device=""
}

audit_mounted_artifact() {
  local mounted_apps=() root_entry root_name bundle_identifier artifact_channel applications_count=0
  audited_mounted_app=""
  while IFS= read -r -d '' root_entry; do
    root_name="${root_entry##*/}"
    if [[ -L "$root_entry" ]]; then
      if [[ "$root_name" == "Applications" && "$(readlink "$root_entry")" == "/Applications" ]]; then
        ((applications_count += 1))
      else
        printf 'error: unexpected DMG root symbolic link: %q\n' "$root_entry" >&2
        return 1
      fi
    elif [[ -d "$root_entry" && "$root_name" == *.app ]]; then
      mounted_apps+=("$root_entry")
    else
      printf 'error: unexpected DMG root entry: %q\n' "$root_entry" >&2
      return 1
    fi
  done < <(find "$mount_point" -mindepth 1 -maxdepth 1 -print0)
  (( ${#mounted_apps[@]} == 1 )) || { echo "error: expected exactly one non-symlink App at the DMG root, found ${#mounted_apps[@]}" >&2; return 1; }
  (( applications_count == 1 )) || { echo "error: expected exactly one Applications -> /Applications symbolic link at the DMG root, found ${applications_count}" >&2; return 1; }
  audited_mounted_app="${mounted_apps[0]}"
  bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${audited_mounted_app}/Contents/Info.plist")"
  case "$bundle_identifier" in
    app.blocks.app)
      artifact_channel="$(plutil -extract BLOCKS_DISTRIBUTION_CHANNEL raw "$audited_mounted_app/Contents/Info.plist")"
      [[ "$artifact_channel" == "direct-beta" || "$artifact_channel" == "direct-stable" ]] \
        || { echo "error: notarization requires a direct-beta or direct-stable App" >&2; return 1; }
      audit_args=(--channel "$artifact_channel" --app "$audited_mounted_app" --require-signature --expected-team-id "$expected_team_id" --expected-authority "$expected_authority" --expected-cert-sha1 "$expected_cert_sha1")
      if [[ -n "$expected_version" ]]; then
        audit_args+=(--expected-version "$expected_version" --expected-build "$expected_build" --expected-release-name "$expected_release_name")
      fi
      "$repo_root/script/release/audit_app_bundle.sh" "${audit_args[@]}"
      ;;
    app.blocks.selection-helper)
      helper_audit_args=("$audited_mounted_app" --require-signature --expected-team-id "$expected_team_id" --expected-authority "$expected_authority" --expected-cert-sha1 "$expected_cert_sha1")
      if [[ -n "$expected_version" ]]; then
        helper_audit_args+=(--expected-version "$expected_version" --expected-build "$expected_build" --expected-release-name "$expected_release_name")
      fi
      "$repo_root/script/release/audit_selection_helper_bundle.sh" "${helper_audit_args[@]}"
      ;;
    *) echo "error: mounted App has an unsupported bundle identifier: $bundle_identifier" >&2; return 1 ;;
  esac
}

# Identity and contents are both verified before the first network-capable
# notarytool operation. The mounted audit reuses the same exact three pins as
# the build/package gates, so a technically valid but differently signed DMG
# never becomes a notarized checksum artifact.
verify_pinned_signature "$dmg_path" "dmg"
attach_readonly_dmg
audit_mounted_artifact
detach_readonly_dmg

xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$profile" \
  --wait \
  --output-format json > "$result_json"

status="$(plutil -extract status raw "$result_json")"
submission_id="$(plutil -extract id raw "$result_json")"
[[ "$status" == "Accepted" ]] || {
  echo "error: notarization status is $status (submission $submission_id)" >&2
  xcrun notarytool log "$submission_id" --keychain-profile "$profile" --output-format json > "$evidence_dir/notary-log.json" || true
  exit 1
}

xcrun notarytool log "$submission_id" --keychain-profile "$profile" --output-format json > "$evidence_dir/notary-log.json"
xcrun stapler staple "$dmg_path" 2>&1 | tee "$evidence_dir/stapler-staple.txt"
xcrun stapler validate "$dmg_path" 2>&1 | tee "$evidence_dir/stapler-validate.txt"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path" 2>&1 | tee "$evidence_dir/dmg-spctl-open.txt"
attach_readonly_dmg
audit_mounted_artifact
spctl --assess --type exec --context context:primary-signature --verbose=4 "$audited_mounted_app" 2>&1 | tee "$evidence_dir/mounted-app-spctl-exec.txt"
detach_readonly_dmg

dmg_directory="$(cd "$(dirname "$dmg_path")" && pwd)"
dmg_basename="$(basename "$dmg_path")"
(
  cd "$dmg_directory"
  shasum -a 256 "$dmg_basename" > "$checksum_temporary"
  shasum -a 256 -c "$checksum_temporary"
)
# Publish the final checksum with an atomic no-overwrite operation. BSD
# `mv -n` can return success while retaining a competing destination.
ln "$checksum_temporary" "$sha256_path" \
  || { echo "error: refusing to replace a concurrently published checksum: $sha256_path" >&2; exit 73; }
/bin/rm -f -- "$checksum_temporary"
cp "$sha256_path" "$evidence_dir/final-dmg.sha256"
stat -f 'size_bytes=%z' "$dmg_path" | tee "$evidence_dir/final-dmg-stat.txt"

echo "PASS: notarized, stapled, Gatekeeper-assessed, and checksummed $dmg_path"
echo "evidence_dir=$evidence_dir"
echo "sha256_file=$sha256_path"
