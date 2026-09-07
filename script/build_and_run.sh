#!/usr/bin/env bash
set -euo pipefail

MODE="${1-run}"
usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--verify-permissions|--open-existing|--verify-existing|--verify-permissions-existing]"
}
# Reject bad arguments before identity lookups, stopping processes or touching
# either the build products or the stable installation.
if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 2
fi
case "$MODE" in
  --help|-h|help)
    usage
    exit 0
    ;;
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--verify-permissions|verify-permissions|--open-existing|open-existing|--verify-existing|verify-existing|--verify-permissions-existing|verify-permissions-existing)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/stable_app_install.sh"
PROJECT="$ROOT_DIR/apps/Blocks/Blocks.xcodeproj"
SCHEME="Blocks"
CONFIGURATION="Debug"
DERIVED_DATA="${BLOCKS_DERIVED_DATA_DIR:-$HOME/Library/Caches/BlocksDev/DerivedData.noindex/Blocks}"
APP_NAME="Blocks"
BUILT_APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
CLI_BINARY="$DERIVED_DATA/Build/Products/$CONFIGURATION/blocks"
STABLE_APP_DIR="${BLOCKS_STABLE_APP_DIR:-$HOME/Applications/BlocksDev/$CONFIGURATION}"
APP_BUNDLE="$STABLE_APP_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
REQUIRE_STABLE_SIGNING="${BLOCKS_REQUIRE_STABLE_SIGNING:-0}"
USE_STABLE_SIGNING="${BLOCKS_USE_STABLE_SIGNING:-auto}"
CODE_SIGN_IDENTITY_OVERRIDE="${BLOCKS_CODE_SIGN_IDENTITY:-Apple Development}"
DEVELOPMENT_TEAM_OVERRIDE="${BLOCKS_DEVELOPMENT_TEAM:-}"
SKIP_BUILD=0
REQUIRE_TCC="${BLOCKS_REQUIRE_TCC:-0}"
APP_BUNDLE_IDENTIFIER="app.blocks.app"
PREVIOUS_STABLE_APP_PIDS=""

case "$MODE" in
  --verify-permissions|verify-permissions)
    REQUIRE_STABLE_SIGNING=1
    USE_STABLE_SIGNING=1
    ;;
  --open-existing|open-existing|--verify-existing|verify-existing|--verify-permissions-existing|verify-permissions-existing)
    SKIP_BUILD=1
    ;;
esac

has_code_signing_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -Eq '^[[:space:]]*[0-9]+\) [A-F0-9]{40} '
}

has_invalid_user_trust_settings() {
  security dump-trust-settings 2>/dev/null \
    | awk -v identity="$CODE_SIGN_IDENTITY_OVERRIDE" '
        $0 ~ ("Cert [0-9]+: " identity) { in_cert=1; next }
        in_cert && /^Cert [0-9]+:/ { in_cert=0 }
        in_cert && /kSecTrustSettingsResultTrustAsRoot/ { found=1 }
        END { exit(found ? 0 : 1) }
      '
}

resolve_development_team() {
  security find-certificate -a -p -c "$CODE_SIGN_IDENTITY_OVERRIDE" 2>/dev/null \
    | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/.*OU=\([^,]*\).*/\1/p' \
    | head -1
}

HAS_SIGNING_IDENTITY=0
if has_code_signing_identity; then
  HAS_SIGNING_IDENTITY=1
fi

if [[ "$HAS_SIGNING_IDENTITY" != "1" ]]; then
  echo "warning: no valid macOS code signing identity found." >&2
  if [[ "$REQUIRE_STABLE_SIGNING" == "1" ]]; then
    echo "error: BLOCKS_REQUIRE_STABLE_SIGNING=1 but no code signing identity is available." >&2
    exit 66
  fi
fi

HAS_INVALID_TRUST_SETTINGS=0
if [[ "$HAS_SIGNING_IDENTITY" == "1" ]] && has_invalid_user_trust_settings; then
  HAS_INVALID_TRUST_SETTINGS=1
  echo "warning: user trust settings for $CODE_SIGN_IDENTITY_OVERRIDE are not system defaults; Xcode may reject this signing identity." >&2
  if [[ "$REQUIRE_STABLE_SIGNING" == "1" || "$USE_STABLE_SIGNING" == "1" || "$USE_STABLE_SIGNING" == "true" || "$USE_STABLE_SIGNING" == "yes" ]]; then
    echo "error: stable signing requested, but the Apple Development certificate has invalid trust settings." >&2
    echo "error: restore the certificate trust setting to system defaults, then rerun." >&2
    exit 68
  fi
fi

SHOULD_USE_STABLE_SIGNING=0
case "$USE_STABLE_SIGNING" in
  1|true|yes)
    SHOULD_USE_STABLE_SIGNING=1
    ;;
  0|false|no)
    SHOULD_USE_STABLE_SIGNING=0
    ;;
  auto)
    if [[ "$HAS_SIGNING_IDENTITY" == "1" && "$HAS_INVALID_TRUST_SETTINGS" != "1" ]]; then
      SHOULD_USE_STABLE_SIGNING=1
    elif [[ "$HAS_INVALID_TRUST_SETTINGS" == "1" ]]; then
      echo "warning: stable signing is unavailable until certificate trust is fixed." >&2
    fi
    ;;
  *)
    echo "error: BLOCKS_USE_STABLE_SIGNING must be 0, 1, or auto." >&2
    exit 2
    ;;
esac

if [[ "$SKIP_BUILD" != "1" && ( "$SHOULD_USE_STABLE_SIGNING" != "1" || "$HAS_SIGNING_IDENTITY" != "1" ) ]]; then
  echo "error: this Debug App requires Apple Development signing and a provisioning profile authorizing its keychain-access-groups; ad-hoc fallback is not supported." >&2
  echo "error: configure apps/Blocks/Config/Signing.local.xcconfig using Signing.local.example.xcconfig, then rerun with BLOCKS_USE_STABLE_SIGNING=1." >&2
  echo "error: existing installed apps can still be opened with --open-existing; no app or build product has been changed." >&2
  exit 66
fi

stable_app_runtime_records() {
  BLOCKS_VERIFY_APP_BUNDLE="$APP_BUNDLE" /usr/bin/osascript \
    -l JavaScript \
    -e '
      ObjC.import("AppKit");
      ObjC.import("Foundation");
      const environment = $.NSProcessInfo.processInfo.environment;
      const expectedValue = environment.objectForKey("BLOCKS_VERIFY_APP_BUNDLE");
      if (!expectedValue) {
        throw new Error("BLOCKS_VERIFY_APP_BUNDLE is missing");
      }
      const expectedPath = $.NSURL.fileURLWithPath(expectedValue).standardizedURL.path.js;
      const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(
        "app.blocks.app"
      );
      const records = [];
      for (let index = 0; index < applications.count; index += 1) {
        const application = applications.objectAtIndex(index);
        const bundleURL = application.bundleURL;
        const bundlePath = bundleURL ? bundleURL.standardizedURL.path.js : "";
        if (bundlePath !== expectedPath) {
          continue;
        }
        const executableURL = application.executableURL;
        const executablePath = executableURL ? executableURL.standardizedURL.path.js : "";
        records.push([
          String(application.processIdentifier),
          application.terminated ? "1" : "0",
          application.finishedLaunching ? "1" : "0",
          bundlePath,
          executablePath
        ].join("\t"));
      }
      records.join("\n");
    '
}

remember_previous_stable_app_pid() {
  local pid="$1"
  case $'\n'"$PREVIOUS_STABLE_APP_PIDS"$'\n' in
    *$'\n'"$pid"$'\n'*)
      ;;
    *)
      PREVIOUS_STABLE_APP_PIDS="${PREVIOUS_STABLE_APP_PIDS}${pid}"$'\n'
      ;;
  esac
}

was_previous_stable_app_pid() {
  local pid="$1"
  case $'\n'"$PREVIOUS_STABLE_APP_PIDS"$'\n' in
    *$'\n'"$pid"$'\n'*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

runtime_records_contain_pid() {
  local records="$1"
  local expected_pid="$2"
  local pid terminated finished bundle_path executable_path

  while IFS=$'\t' read -r pid terminated finished bundle_path executable_path; do
    if [[ "$terminated" == "0" && "$pid" == "$expected_pid" ]]; then
      return 0
    fi
  done <<< "$records"
  return 1
}

stop_stable_app() {
  local records pids="" pid terminated finished bundle_path executable_path
  local active_records remaining attempt

  if ! records="$(stable_app_runtime_records)"; then
    echo "error: could not enumerate the installed Blocks process for $APP_BUNDLE; refusing to replace or relaunch it." >&2
    return 1
  fi

  while IFS=$'\t' read -r pid terminated finished bundle_path executable_path; do
    if [[ -z "$pid" || "$terminated" != "0" ]]; then
      continue
    fi
    case "$pid" in
      *[!0-9]*)
        echo "error: invalid Blocks process identifier '$pid'; refusing to replace or relaunch $APP_BUNDLE." >&2
        return 1
        ;;
    esac
    remember_previous_stable_app_pid "$pid"
    pids="${pids}${pid}"$'\n'
    if ! /bin/kill -TERM "$pid" >/dev/null 2>&1; then
      if active_records="$(stable_app_runtime_records)" \
        && runtime_records_contain_pid "$active_records" "$pid"; then
        echo "error: failed to request termination of installed Blocks pid $pid; refusing to replace or relaunch $APP_BUNDLE." >&2
        return 1
      fi
    fi
  done <<< "$records"

  if [[ -z "$pids" ]]; then
    return 0
  fi

  remaining="$pids"
  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if ! active_records="$(stable_app_runtime_records)"; then
      echo "error: could not verify that the old installed Blocks process exited; refusing to replace or relaunch $APP_BUNDLE." >&2
      return 1
    fi
    remaining=""
    while IFS= read -r pid; do
      if [[ -n "$pid" ]] && runtime_records_contain_pid "$active_records" "$pid"; then
        remaining="${remaining}${pid}"$'\n'
      fi
    done <<< "$pids"
    if [[ -z "$remaining" ]]; then
      return 0
    fi
    sleep 0.1
  done

  echo "error: installed Blocks process did not exit within 5 seconds (pids=$(echo "$remaining" | xargs)); refusing to replace or relaunch $APP_BUNDLE." >&2
  return 1
}

if [[ "$SKIP_BUILD" == "1" ]]; then
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "error: existing stable app not found at $APP_BUNDLE." >&2
    echo "error: run ./script/build_and_run.sh --verify-permissions once before using existing-app modes." >&2
    exit 69
  fi
  stop_stable_app
else
  rm -rf \
    "$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app" \
    "$DERIVED_DATA/Build/Products/$CONFIGURATION/BlocksLoginItemHelper.app"

  BUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA"
  )

  if [[ "$SHOULD_USE_STABLE_SIGNING" == "1" ]]; then
    if [[ -z "$DEVELOPMENT_TEAM_OVERRIDE" ]]; then
      DEVELOPMENT_TEAM_OVERRIDE="$(resolve_development_team)"
    fi
    if [[ -z "$DEVELOPMENT_TEAM_OVERRIDE" ]]; then
      echo "error: stable signing requested but DEVELOPMENT_TEAM could not be resolved from $CODE_SIGN_IDENTITY_OVERRIDE." >&2
      echo "error: set BLOCKS_DEVELOPMENT_TEAM explicitly." >&2
      exit 67
    fi
    BUILD_ARGS+=(
      CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_OVERRIDE"
      CODE_SIGN_STYLE=Manual
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_OVERRIDE"
    )
  fi

  xcodebuild "${BUILD_ARGS[@]}" build

  CLI_BUILD_ARGS=(
    -project "$PROJECT"
    -scheme BlocksCLI
    -configuration "$CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA"
  )
  if [[ "$SHOULD_USE_STABLE_SIGNING" == "1" ]]; then
    CLI_BUILD_ARGS+=(
      CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_OVERRIDE"
      CODE_SIGN_STYLE=Manual
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_OVERRIDE"
    )
  fi
  xcodebuild "${CLI_BUILD_ARGS[@]}" build

  # Xcode does not code sign a bare command-line executable target. Sign it
  # explicitly so the Broker can enforce the same Team ID contract as the App.
  if [[ "$SHOULD_USE_STABLE_SIGNING" == "1" ]]; then
    codesign --force --timestamp=none --sign "$CODE_SIGN_IDENTITY_OVERRIDE" "$CLI_BINARY"
    CLI_TEAM_IDENTIFIER="$({ codesign -dvvv "$CLI_BINARY" 2>&1 || true; } | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [[ "$CLI_TEAM_IDENTIFIER" != "$DEVELOPMENT_TEAM_OVERRIDE" ]]; then
      echo "error: CLI TeamIdentifier mismatch (expected $DEVELOPMENT_TEAM_OVERRIDE, got ${CLI_TEAM_IDENTIFIER:-missing})." >&2
      exit 72
    fi
  fi

  # A user can relaunch the old copy while Xcode is building. Stop the old
  # host again immediately before replacing the stable bundle. The separate
  # Selection Helper is independently installed and versioned; this script
  # must not stop or replace it.
  install_stable_app
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

code_identity_field() {
  local identity="$1"
  local field="$2"
  printf '%s\n' "$identity" \
    | sed -n "s/^${field}=//p" \
    | head -1
}

installed_app_code_identity() {
  codesign -dvvv "$APP_BUNDLE" 2>&1
}

running_app_code_identity() {
  local pid="$1"
  codesign -dvvv "+$pid" 2>&1
}

wait_for_stable_app_launch() {
  local expected_identity expected_identifier expected_team expected_cdhash
  local records pid terminated finished bundle_path executable_path
  local running_identity running_identifier running_team running_cdhash
  local state="not-running" attempt

  if ! expected_identity="$(installed_app_code_identity)"; then
    echo "error: could not read the installed Blocks code identity at $APP_BUNDLE." >&2
    return 1
  fi
  expected_identifier="$(code_identity_field "$expected_identity" Identifier)"
  expected_team="$(code_identity_field "$expected_identity" TeamIdentifier)"
  expected_cdhash="$(code_identity_field "$expected_identity" CDHash)"
  if [[ "$expected_identifier" != "$APP_BUNDLE_IDENTIFIER" || -z "$expected_cdhash" ]]; then
    echo "error: installed Blocks code identity is incomplete or unexpected (identifier=${expected_identifier:-missing}, cdhash=${expected_cdhash:-missing})." >&2
    return 1
  fi

  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if ! records="$(stable_app_runtime_records)"; then
      state="enumeration-failed"
      sleep 0.1
      continue
    fi
    state="not-running"
    while IFS=$'\t' read -r pid terminated finished bundle_path executable_path; do
      if [[ -z "$pid" || "$terminated" != "0" ]]; then
        continue
      fi
      if was_previous_stable_app_pid "$pid"; then
        state="stale-pid-$pid"
        continue
      fi
      if [[ "$executable_path" != "$APP_BINARY" ]]; then
        state="wrong-executable-$pid"
        continue
      fi
      if [[ "$finished" != "1" ]]; then
        state="starting-pid-$pid"
        continue
      fi
      if ! running_identity="$(running_app_code_identity "$pid")"; then
        state="identity-unavailable-pid-$pid"
        continue
      fi
      running_identifier="$(code_identity_field "$running_identity" Identifier)"
      running_team="$(code_identity_field "$running_identity" TeamIdentifier)"
      running_cdhash="$(code_identity_field "$running_identity" CDHash)"
      if [[ "$running_identifier" != "$expected_identifier" \
        || "$running_team" != "$expected_team" \
        || "$running_cdhash" != "$expected_cdhash" ]]; then
        state="identity-mismatch-pid-$pid"
        continue
      fi
      echo "Blocks stable app ready: pid=$pid executable=$executable_path cdhash=$running_cdhash"
      return 0
    done <<< "$records"
    sleep 0.1
  done
  echo "error: newly launched Blocks app did not pass verification within 5 seconds (state=${state:-unknown}, bundle=$APP_BUNDLE, executable=$APP_BINARY)." >&2
  echo "error: verification requires a new pid, the exact installed executable, matching code identity/CDHash, and finishedLaunching=true." >&2
  return 1
}

stable_app_cdhash() {
  codesign -dvvv "$APP_BUNDLE" 2>&1 \
    | sed -n 's/^CDHash=//p' \
    | head -1
}

tcc_value_for_service() {
  local service="$1"
  sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "select auth_value from access where client='app.blocks.app' and client_type=0 and service='$service' order by last_modified desc limit 1;" \
    2>/dev/null || true
}

tcc_row_for_service() {
  local service="$1"
  sqlite3 -separator ' | ' "/Library/Application Support/com.apple.TCC/TCC.db" \
    "select service, client, auth_value, flags, length(csreq), hex(csreq) from access where client='app.blocks.app' and client_type=0 and service='$service' order by last_modified desc limit 1;" \
    2>/dev/null || true
}

print_runtime_permission_diagnostics() {
  local cdhash screen_value accessibility_value

  cdhash="$(stable_app_cdhash)"
  screen_value="$(tcc_value_for_service kTCCServiceScreenCapture)"
  accessibility_value="$(tcc_value_for_service kTCCServiceAccessibility)"

  echo "Blocks stable app: $APP_BUNDLE"
  echo "Blocks CDHash: ${cdhash:-unknown}"
  echo "TCC ScreenCapture row: $(tcc_row_for_service kTCCServiceScreenCapture)"
  echo "TCC Accessibility row: $(tcc_row_for_service kTCCServiceAccessibility)"

  if [[ "$REQUIRE_TCC" == "1" ]]; then
    if [[ "$screen_value" != "2" ]]; then
      echo "error: Screen Recording TCC is not granted for app.blocks.app (auth_value=${screen_value:-missing})." >&2
      echo "error: enable Blocks in System Settings > Privacy & Security > Screen & System Audio Recording, then rerun without rebuilding by using --verify-permissions-existing." >&2
      exit 70
    fi
    if [[ "$accessibility_value" != "2" ]]; then
      echo "error: Accessibility TCC is not granted for app.blocks.app (auth_value=${accessibility_value:-missing})." >&2
      echo "error: enable Blocks in System Settings > Privacy & Security > Accessibility, then rerun without rebuilding by using --verify-permissions-existing." >&2
      exit 71
    fi
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"app.blocks.app\""
    ;;
  --verify|verify)
    open_app
    wait_for_stable_app_launch
    ;;
  --verify-permissions|verify-permissions)
    open_app
    wait_for_stable_app_launch
    codesign -dvvv --entitlements :- "$APP_BUNDLE" >/dev/null
    print_runtime_permission_diagnostics
    ;;
  --open-existing|open-existing)
    open_app
    ;;
  --verify-existing|verify-existing)
    open_app
    wait_for_stable_app_launch
    ;;
  --verify-permissions-existing|verify-permissions-existing)
    open_app
    wait_for_stable_app_launch
    codesign -dvvv --entitlements :- "$APP_BUNDLE" >/dev/null
    print_runtime_permission_diagnostics
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--verify-permissions|--open-existing|--verify-existing|--verify-permissions-existing]" >&2
    exit 2
    ;;
esac
