#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
APP_NAME="BlocksLoginItemProbe"
HELPER_NAME="BlocksLoginItemHelper"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
HELPER_BUNDLE="$APP_BUNDLE/Contents/Library/LoginItems/$HELPER_NAME.app"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Library/LoginItems"
mkdir -p "$HELPER_BUNDLE/Contents/MacOS"

cp "$ROOT_DIR/Resources/$APP_NAME-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/$HELPER_NAME-Info.plist" "$HELPER_BUNDLE/Contents/Info.plist"

xcrun swiftc \
  "$ROOT_DIR/Sources/$HELPER_NAME/main.swift" \
  -framework Foundation \
  -framework AppKit \
  -o "$HELPER_BUNDLE/Contents/MacOS/$HELPER_NAME"

xcrun swiftc \
  "$ROOT_DIR/Sources/$APP_NAME/main.swift" \
  -framework Foundation \
  -framework AppKit \
  -framework ServiceManagement \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "warning: using ad-hoc signing; unregister and re-register after helper executable changes" >&2
fi

codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT_DIR/Resources/$HELPER_NAME.entitlements" \
  "$HELPER_BUNDLE" >/dev/null

codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT_DIR/Resources/$APP_NAME.entitlements" \
  "$APP_BUNDLE" >/dev/null

codesign --verify --deep --strict "$APP_BUNDLE"

echo "$APP_BUNDLE"
