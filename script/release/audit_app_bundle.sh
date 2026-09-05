#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --channel direct-beta|app-store-beta --app /path/to/Blocks.app [--require-signature --expected-team-id TEAM_ID --expected-authority AUTHORITY --expected-cert-sha1 SHA1]" >&2
}

channel=""
app_bundle=""
require_signature=0
expected_team_id=""
expected_authority=""
expected_cert_sha1="${BLOCKS_EXPECTED_SIGNING_CERT_SHA1:-}"

while (($#)); do
  case "$1" in
    --channel)
      channel="${2:-}"
      shift 2
      ;;
    --app)
      app_bundle="${2:-}"
      shift 2
      ;;
    --require-signature)
      require_signature=1
      shift
      ;;
    --expected-team-id)
      expected_team_id="${2:-}"
      shift 2
      ;;
    --expected-authority)
      expected_authority="${2:-}"
      shift 2
      ;;
    --expected-cert-sha1)
      expected_cert_sha1="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$channel" != "direct-beta" && "$channel" != "app-store-beta" ]]; then
  usage
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
if [[ ! -d "$app_bundle" ]]; then
  echo "error: app bundle not found: $app_bundle" >&2
  exit 66
fi

contents="$app_bundle/Contents"
main_executable="$contents/MacOS/Blocks"
info_plist="$contents/Info.plist"

fail() {
  echo "error: $*" >&2
  exit 1
}

# Release artifacts are self-contained and currently have no approved
# symlinked bundle members. Reject links before checking required paths so a
# known executable name cannot be redirected to an unreviewed payload.
while IFS= read -r -d '' symbolic_link; do
  fail "symbolic link is forbidden in release bundle: ${symbolic_link#"$app_bundle/"}"
done < <(find "$contents" -type l -print0)

require_path() {
  [[ -e "$1" ]] || fail "required bundle item missing: ${1#"$app_bundle/"}"
}

forbid_path() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "forbidden bundle item present: ${1#"$app_bundle/"}"
}

require_path "$main_executable"
require_path "$info_plist"

architectures="$(lipo -archs "$main_executable")"
[[ "$architectures" == "arm64" ]] \
  || fail "expected arm64-only main executable, got: $architectures"

minimum_system="$(plutil -extract LSMinimumSystemVersion raw "$info_plist")"
[[ "$minimum_system" == "14.0" ]] \
  || fail "expected LSMinimumSystemVersion 14.0, got: $minimum_system"

artifact_channel="$(plutil -extract BLOCKS_DISTRIBUTION_CHANNEL raw "$info_plist")"
[[ "$artifact_channel" == "$channel" ]] \
  || fail "expected channel $channel, got: $artifact_channel"

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
[[ "$bundle_identifier" == "app.blocks.app" ]] \
  || fail "expected bundle identifier app.blocks.app, got: $bundle_identifier"

display_name="$(plutil -extract CFBundleDisplayName raw "$info_plist")"
[[ "$display_name" == "Blocks for Mac" ]] \
  || fail "expected base display name Blocks for Mac, got: $display_name"

for localization in en ja zh-Hans; do
  strings_file="$contents/Resources/$localization.lproj/InfoPlist.strings"
  require_path "$strings_file"
done
[[ "$(plutil -extract CFBundleDisplayName raw "$contents/Resources/en.lproj/InfoPlist.strings")" == "Blocks for Mac" ]] \
  || fail "English display name drifted"
[[ "$(plutil -extract CFBundleDisplayName raw "$contents/Resources/ja.lproj/InfoPlist.strings")" == "Blocks for Mac" ]] \
  || fail "Japanese display name drifted"
[[ "$(plutil -extract CFBundleDisplayName raw "$contents/Resources/zh-Hans.lproj/InfoPlist.strings")" == "积木工具" ]] \
  || fail "Simplified Chinese display name drifted"

[[ "$(plutil -extract BLOCKS_RELEASE_PAGE_URL raw "$info_plist")" == "https://blocks.orangeforge.top/releases/" ]] \
  || fail "release page URL drifted"
[[ "$(plutil -extract BLOCKS_SUPPORT_URL raw "$info_plist")" == "https://blocks.orangeforge.top/support/" ]] \
  || fail "support URL drifted"
[[ "$(plutil -extract BLOCKS_PRIVACY_URL raw "$info_plist")" == "https://blocks.orangeforge.top/privacy/" ]] \
  || fail "privacy URL drifted"

require_path "$contents/MacOS/BlocksClipboardBroker"
require_path "$contents/XPCServices/BlocksPluginRunner.xpc"
clipboard_broker="$contents/MacOS/BlocksClipboardBroker"
xpc_plugin_runner_service="$contents/XPCServices/BlocksPluginRunner.xpc"
plugin_runner="$contents/XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner"
require_path "$plugin_runner"
forbid_path "$contents/MacOS/Blocks Selection Helper"
forbid_path "$contents/Helpers/Blocks Selection Helper.app"

if [[ "$channel" == "direct-beta" ]]; then
  [[ "$(plutil -extract BLOCKS_SELECTION_HELPER_DOWNLOAD_URL raw "$info_plist")" == "https://downloads.orangeforge.top/beta/0.1.0-beta.1/Blocks-Selection-Helper-0.1.0-beta.1-arm64.dmg" ]] \
    || fail "Selection Helper download URL drifted"
  require_path "$contents/Resources/CLI/blocks"
  require_path "$contents/MacOS/BlocksActionBroker"
  require_path "$contents/Library/LaunchAgents/app.blocks.action-broker.plist"
  action_broker="$contents/MacOS/BlocksActionBroker"
  for debug_identity_marker in \
    'Applications/BlocksDev/Debug/' \
    'Documents/Mac 工具集/DerivedData/' \
    'Library/Developer/Xcode/DerivedData/'; do
    if /usr/bin/strings -a "$action_broker" \
        | grep -Fq "$debug_identity_marker"; then
      fail "Direct ActionBroker contains a DEBUG-only identity marker: $debug_identity_marker"
    fi
  done
else
  [[ -z "$(plutil -extract BLOCKS_SELECTION_HELPER_DOWNLOAD_URL raw "$info_plist")" ]] \
    || fail "Store build exposes a Selection Helper download URL"
  forbid_path "$contents/Resources/CLI/blocks"
  forbid_path "$contents/MacOS/BlocksActionBroker"
  forbid_path "$contents/Library/LaunchAgents/app.blocks.action-broker.plist"

  while IFS= read -r plugin_package; do
    case "$plugin_package" in
      "$contents/Resources/BuiltInPlugins/"*.blocksplugin)
        ;;
      *)
        fail "non-built-in plugin package present: ${plugin_package#"$app_bundle/"}"
        ;;
    esac
  done < <(find "$contents" -type d -name '*.blocksplugin' -print)
fi

allowed_mach_o_paths=(
  "$main_executable"
  "$clipboard_broker"
  "$plugin_runner"
)
if [[ "$channel" == "direct-beta" ]]; then
  allowed_mach_o_paths+=(
    "$contents/MacOS/BlocksActionBroker"
    "$contents/Resources/CLI/blocks"
  )
fi

# Every approved executable is part of the arm64-only product contract. The
# main executable check above is intentionally repeated here so future changes
# to this exact inventory cannot add a Rosetta-dependent nested component
# without failing the release audit.
for allowed_mach_o_path in "${allowed_mach_o_paths[@]}"; do
  file -b "$allowed_mach_o_path" | grep -q 'Mach-O' \
    || fail "allowlisted executable is not Mach-O: ${allowed_mach_o_path#"$app_bundle/"}"
  component_architectures="$(lipo -archs "$allowed_mach_o_path" | xargs)"
  [[ "$component_architectures" == "arm64" ]] \
    || fail "expected arm64-only executable ${allowed_mach_o_path#"$app_bundle/"}, got: $component_architectures"
done

# Release bundles do not embed frameworks. Keep this as an exact executable
# inventory rather than allowing a directory pattern: a new Mach-O must be
# deliberately added to this channel's release policy before it can be signed.
while IFS= read -r -d '' executable; do
  file -b "$executable" | grep -q 'Mach-O' || continue
  allowed=0
  for allowed_mach_o_path in "${allowed_mach_o_paths[@]}"; do
    [[ "$executable" == "$allowed_mach_o_path" ]] && allowed=1
  done
  ((allowed)) || fail "unexpected Mach-O executable in bundle: ${executable#"$app_bundle/"}"
done < <(find "$contents" -type f -print0)

if ((require_signature)); then
  [[ "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]] \
    || fail "--expected-team-id must be the explicit 10-character Apple Team ID"
  case "$channel" in
    direct-beta) expected_authority_pattern="^Developer ID Application: .+ \\(${expected_team_id}\\)$" ;;
    app-store-beta) expected_authority_pattern="^Apple Distribution: .+ \\(${expected_team_id}\\)$" ;;
  esac
  [[ "$expected_authority" =~ $expected_authority_pattern ]] \
    || fail "--expected-authority must be the exact ${channel} authority for --expected-team-id"
  expected_cert_sha1_compact="${expected_cert_sha1//:/}"
  [[ "$expected_cert_sha1_compact" =~ ^[A-Fa-f0-9]{40}$ ]] \
    || fail "--expected-cert-sha1 must be the explicit 40-hex signing certificate SHA-1"
  codesign --verify --deep --strict --verbose=2 "$app_bundle"

  # codesign metadata for the .app covers the main executable. Every nested
  # component was already checked against the exact structural inventory above.
  signing_components=("$app_bundle" "${allowed_mach_o_paths[@]:1}")

  main_signature_details="$(codesign -dvv "$app_bundle" 2>&1)"
  main_team_identifier="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$main_signature_details")"
  [[ "$main_team_identifier" == "$expected_team_id" ]] \
    || fail "main app TeamIdentifier differs from expected Team ID"

  verify_certificate_identity() {
    local component="$1"
    local details="$2"
    local certificate_file fingerprint
    local actual_authority
    actual_authority="$(awk '/^Authority=/{print substr($0, 11); exit}' <<<"$details")"
    [[ "$actual_authority" == "$expected_authority" ]] \
      || fail "signing Authority differs for ${component#"$app_bundle/"}"
    if [[ -n "$expected_cert_sha1" ]]; then
      certificate_file="$(mktemp "${TMPDIR:-/tmp}/blocks-signing-cert.XXXXXX")"
      codesign -d --extract-certificates "$certificate_file" "$component" >/dev/null 2>&1 \
        || fail "cannot extract signing certificate for ${component#"$app_bundle/"}"
      fingerprint="$(openssl x509 -inform der -in "${certificate_file}0" -noout -fingerprint -sha1 2>/dev/null | sed 's/^[^=]*=//; s/://g')"
      /bin/rm -f -- "$certificate_file"{,0,1,2,3,4,5,6,7,8,9}
      [[ "$(printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]')" == "$(printf '%s' "${expected_cert_sha1//:/}" | tr '[:lower:]' '[:upper:]')" ]] \
        || fail "signing certificate SHA-1 differs for ${component#"$app_bundle/"}"
    fi
  }

  verify_component_signing_identity() {
    local component="$1"
    local component_team_identifier
    codesign --verify --strict --verbose=2 "$component"
    component_signature_details="$(codesign -dvv "$component" 2>&1)"
    component_team_identifier="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$component_signature_details")"
    [[ "$component_team_identifier" == "$expected_team_id" ]] \
      || fail "signing TeamIdentifier differs from expected Team ID for ${component#"$app_bundle/"}"
    verify_certificate_identity "$component" "$component_signature_details"
  }

  validate_component_entitlements() {
    local component="$1"
    local component_identifier="$2"
    local entitlement_file actual_keys key allowed expected_application_id
    local allowed_keys=()
    entitlement_file="$(mktemp "${TMPDIR:-/tmp}/blocks-component-entitlements.XXXXXX.plist")"
    trap '/bin/rm -f -- "${entitlement_file:-}"' EXIT
    codesign -d --entitlements :- "$component" > "$entitlement_file" 2>/dev/null \
      || fail "cannot read signed entitlements: ${component#"$app_bundle/"}"
    if [[ -s "$entitlement_file" ]]; then
      plutil -lint "$entitlement_file" >/dev/null \
        || fail "signed entitlements are invalid: ${component#"$app_bundle/"}"
      actual_keys="$(/usr/libexec/PlistBuddy -c Print "$entitlement_file" | sed -n 's/^[[:space:]]*\([^[:space:] =]*\) =.*/\1/p' | LC_ALL=C sort -u)"
    else
      # Developer ID-signed standalone nested executables legitimately have no
      # entitlement blob. Their empty set is still checked against the
      # component whitelist below.
      actual_keys=""
    fi

    if [[ "$component" == "$app_bundle" ]]; then
      if [[ "$channel" == "direct-beta" ]]; then
        allowed_keys=(
          com.apple.security.app-sandbox
          com.apple.security.files.user-selected.read-write
          com.apple.security.network.client
          com.apple.security.temporary-exception.files.absolute-path.read-only
          com.apple.security.temporary-exception.mach-lookup.global-name
          com.apple.application-identifier
          com.apple.developer.team-identifier
          keychain-access-groups
        )
      else
        # The Store main-app whitelist and exact values are validated below.
        /bin/rm -f -- "$entitlement_file"
        trap - EXIT
        return
      fi
    elif [[ "$component" == "$clipboard_broker" ]]; then
      allowed_keys=(
        com.apple.security.app-sandbox
        com.apple.security.inherit
        com.apple.application-identifier
        com.apple.developer.team-identifier
      )
    elif [[ "$component" == "$plugin_runner" ]]; then
      allowed_keys=(
        com.apple.security.app-sandbox
        com.apple.application-identifier
        com.apple.developer.team-identifier
      )
    elif [[ "$channel" == "direct-beta" \
        && "$component" == "$contents/MacOS/BlocksActionBroker" ]]; then
      allowed_keys=(
        com.apple.security.app-sandbox
        com.apple.application-identifier
        com.apple.developer.team-identifier
      )
    elif [[ "$channel" == "direct-beta" \
        && "$component" == "$contents/Resources/CLI/blocks" ]]; then
      # The bundled Direct CLI receives no capability entitlements.
      allowed_keys=(
        com.apple.application-identifier
        com.apple.developer.team-identifier
      )
    else
      fail "unexpected signed executable in bundle: ${component#"$app_bundle/"}"
    fi

    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      allowed=0
      for allowed_key in "${allowed_keys[@]}"; do
        [[ "$key" == "$allowed_key" ]] && allowed=1
      done
      ((allowed)) \
        || fail "unexpected signed entitlement for ${component#"$app_bundle/"}: $key"
    done <<< "$actual_keys"

    if plutil -extract com.apple.developer.team-identifier raw "$entitlement_file" >/dev/null 2>&1; then
      [[ "$(plutil -extract com.apple.developer.team-identifier raw "$entitlement_file")" == "$expected_team_id" ]] \
        || fail "signed entitlement Team ID differs for ${component#"$app_bundle/"}"
    fi
    if plutil -extract com.apple.application-identifier raw "$entitlement_file" >/dev/null 2>&1; then
      expected_application_id="$expected_team_id.$component_identifier"
      [[ "$(plutil -extract com.apple.application-identifier raw "$entitlement_file")" == "$expected_application_id" ]] \
        || fail "signed application identifier differs for ${component#"$app_bundle/"}"
    fi

    case "$component" in
      "$app_bundle")
        for key in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.network.client; do
          [[ "$(plutil -extract "$key" raw "$entitlement_file")" == "true" ]] \
            || fail "Direct app entitlement is not true: $key"
        done
        [[ "$(plutil -extract 'com.apple.security.temporary-exception.mach-lookup.global-name.0' raw "$entitlement_file")" == "app.blocks.action-broker.xpc" ]] \
          || fail "Direct app ActionBroker Mach exception differs from the allowed service"
        if plutil -extract 'com.apple.security.temporary-exception.mach-lookup.global-name.1' raw "$entitlement_file" >/dev/null 2>&1; then
          fail "Direct app ActionBroker Mach exception must contain exactly one service"
        fi
        [[ "$(plutil -extract 'com.apple.security.temporary-exception.files.absolute-path.read-only.0' raw "$entitlement_file")" == "/Applications/Blocks Selection Helper.app/" ]] \
          || fail "Direct app Helper read exception differs from the stable bundle"
        if plutil -extract 'com.apple.security.temporary-exception.files.absolute-path.read-only.1' raw "$entitlement_file" >/dev/null 2>&1; then
          fail "Direct app Helper read exception must contain exactly one path"
        fi
        default_keychain_group="$(plutil -extract 'keychain-access-groups.0' raw "$entitlement_file" 2>/dev/null || true)"
        shared_keychain_group="$(plutil -extract 'keychain-access-groups.1' raw "$entitlement_file" 2>/dev/null || true)"
        [[ "$default_keychain_group" == "$expected_team_id.app.blocks.app" ]] \
          || fail "Direct app keychain-access-groups is missing or has a non-default first group"
        [[ "$shared_keychain_group" == "$expected_team_id.app.blocks.selection-helper.shared" ]] \
          || fail "Direct app keychain-access-groups is missing or has a non-shared second group"
        if plutil -extract 'keychain-access-groups.2' raw "$entitlement_file" >/dev/null 2>&1; then
          fail "Direct app keychain-access-groups must contain exactly default and shared groups"
        fi
        ;;
      "$clipboard_broker")
        for key in com.apple.security.app-sandbox com.apple.security.inherit; do
          [[ "$(plutil -extract "$key" raw "$entitlement_file")" == "true" ]] \
            || fail "Clipboard Broker entitlement is not true: $key"
        done
        ;;
      "$plugin_runner"|"$contents/MacOS/BlocksActionBroker")
        [[ "$(plutil -extract com.apple.security.app-sandbox raw "$entitlement_file")" == "true" ]] \
          || fail "sandbox entitlement is not true for ${component#"$app_bundle/"}"
        ;;
    esac
    /bin/rm -f -- "$entitlement_file"
    trap - EXIT
  }

  for component in "${signing_components[@]}"; do
    # The XPC service bundle is its own signed code object. Establish its
    # identity before examining the signed executable it contains, while
    # retaining that executable's independent entitlement audit below.
    if [[ "$component" == "$plugin_runner" ]]; then
      verify_component_signing_identity "$xpc_plugin_runner_service"
    fi
    verify_component_signing_identity "$component"
    component_details="$component_signature_details"
    component_identifier="$(awk -F= '/^Identifier=/{print $2; exit}' <<<"$component_details")"
    case "$component" in
      "$app_bundle") expected_component_identifier="app.blocks.app" ;;
      "$clipboard_broker") expected_component_identifier="app.blocks.clipboard-broker" ;;
      "$plugin_runner") expected_component_identifier="app.blocks.plugin-runner" ;;
      "$contents/MacOS/BlocksActionBroker") expected_component_identifier="app.blocks.action-broker" ;;
      "$contents/Resources/CLI/blocks") expected_component_identifier="app.blocks.cli" ;;
      *) expected_component_identifier="" ;;
    esac
    if [[ -n "$expected_component_identifier" ]]; then
      [[ "$component_identifier" == "$expected_component_identifier" ]] \
        || fail "signing Identifier differs for ${component#"$app_bundle/"}"
    fi
    grep -q 'flags=.*runtime' <<<"$component_details" \
      || fail "signature does not enable Hardened Runtime: ${component#"$app_bundle/"}"
    validate_component_entitlements "$component" "$component_identifier"
  done

  if [[ "$channel" == "app-store-beta" ]]; then
    signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/blocks-store-entitlements.XXXXXX.plist")"
    trap '/bin/rm -f -- "${signed_entitlements:-}"' EXIT
    codesign -d --entitlements :- "$app_bundle" > "$signed_entitlements" 2>/dev/null \
      || fail "cannot read Store app signed entitlements"
    [[ -s "$signed_entitlements" ]] \
      || fail "Store app signed entitlements are missing"
    plutil -lint "$signed_entitlements" >/dev/null \
      || fail "Store app signed entitlements are invalid"
    expected_store_entitlements=(
      com.apple.security.app-sandbox
      com.apple.security.files.user-selected.read-write
      com.apple.security.network.client
      com.apple.application-identifier
      com.apple.developer.team-identifier
    )
    actual_store_keys="$(/usr/libexec/PlistBuddy -c Print "$signed_entitlements" | sed -n 's/^[[:space:]]*\([^[:space:] =]*\) =.*/\1/p' | LC_ALL=C sort)"
    expected_store_keys="$(printf '%s\n' "${expected_store_entitlements[@]}" | LC_ALL=C sort)"
    expected_store_keys_with_keychain="$(printf '%s\n' "${expected_store_entitlements[@]}" keychain-access-groups | LC_ALL=C sort)"
    [[ "$actual_store_keys" == "$expected_store_keys" || "$actual_store_keys" == "$expected_store_keys_with_keychain" ]] \
      || fail "Store app signed entitlements differ from the allowed whitelist"
    for entitlement in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.network.client; do
      [[ "$(plutil -extract "$entitlement" raw "$signed_entitlements")" == "true" ]] \
        || fail "Store app entitlement is not true: $entitlement"
    done
    [[ "$(plutil -extract com.apple.application-identifier raw "$signed_entitlements")" == "$expected_team_id.app.blocks.app" ]] \
      || fail "Store app signed application identifier differs from expected App ID"
    [[ "$(plutil -extract com.apple.developer.team-identifier raw "$signed_entitlements")" == "$expected_team_id" ]] \
      || fail "Store app signed team identifier differs from expected Team ID"
    if [[ "$actual_store_keys" == "$expected_store_keys_with_keychain" ]]; then
      [[ "$(plutil -extract 'keychain-access-groups.0' raw "$signed_entitlements")" == "$expected_team_id.app.blocks.app" ]] \
        || fail "Store app keychain-access-groups contains a non-default group"
      if plutil -extract 'keychain-access-groups.1' raw "$signed_entitlements" >/dev/null 2>&1; then
        fail "Store app keychain-access-groups must contain exactly one default group"
      fi
    fi
    embedded_profile="$contents/embedded.provisionprofile"
    require_path "$embedded_profile"
    profile_plist="$(security cms -D -i "$embedded_profile")" \
      || fail "Store embedded provisioning profile is not CMS-decodable"
    printf '%s' "$profile_plist" | plutil -lint - >/dev/null \
      || fail "Store embedded provisioning profile is not a plist"
    profile_team_identifier="$(printf '%s' "$profile_plist" | plutil -extract TeamIdentifier.0 raw -)" \
      || fail "Store embedded provisioning profile is missing TeamIdentifier"
    [[ "$profile_team_identifier" == "$expected_team_id" ]] \
      || fail "Store embedded provisioning profile TeamIdentifier differs from expected Team ID"
    profile_uuid="$(printf '%s' "$profile_plist" | plutil -extract UUID raw -)" \
      || fail "Store embedded provisioning profile is missing UUID"
    [[ "$profile_uuid" =~ ^[A-Fa-f0-9-]{36}$ ]] || fail "Store embedded provisioning profile UUID is invalid"
    profile_app_identifier="$(printf '%s' "$profile_plist" | plutil -extract Entitlements.application-identifier raw -)" \
      || fail "Store embedded provisioning profile is missing application-identifier"
    [[ "$profile_app_identifier" == "$expected_team_id.app.blocks.app" ]] \
      || fail "Store embedded provisioning profile application-identifier differs from expected App ID"
    profile_entitlement_team="$(printf '%s' "$profile_plist" | plutil -extract Entitlements.com.apple.developer.team-identifier raw -)" \
      || fail "Store embedded provisioning profile is missing entitlement team identifier"
    [[ "$profile_entitlement_team" == "$expected_team_id" ]] \
      || fail "Store embedded provisioning profile entitlement team identifier differs from expected Team ID"
    profile_expiration="$(printf '%s' "$profile_plist" | plutil -extract ExpirationDate raw -)" \
      || fail "Store embedded provisioning profile is missing ExpirationDate"
    expiration_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$profile_expiration" +%s 2>/dev/null || true)"
    [[ -n "$expiration_epoch" && "$expiration_epoch" -gt "$(date +%s)" ]] \
      || fail "Store embedded provisioning profile is expired or has an invalid ExpirationDate"
    for entitlement in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.network.client; do
      profile_value="$(printf '%s' "$profile_plist" | plutil -extract "Entitlements.$entitlement" raw - 2>/dev/null || true)"
      [[ "$profile_value" == "true" ]] \
        || fail "Store embedded provisioning profile lacks required entitlement: $entitlement"
    done
  fi
fi

if ((require_signature)); then
  echo "PASS: $channel signed bundle audit"
else
  echo "PASS: $channel unsigned structural bundle audit (signing not verified)"
fi
echo "app=$app_bundle"
echo "architecture=$architectures"
echo "minimum_system=$minimum_system"
echo "bundle_identifier=$bundle_identifier"
