#!/usr/bin/env bash
set -euo pipefail

if [[ "${CONFIGURATION:-}" != "AppStoreRelease" \
      && "${BLOCKS_DISTRIBUTION_CHANNEL:-}" != "app-store-beta" ]]; then
  exit 0
fi

bundle_root="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
cli_path="$bundle_root/Resources/CLI/blocks"
action_broker_path="$bundle_root/MacOS/BlocksActionBroker"
launch_agent_path="$bundle_root/Library/LaunchAgents/app.blocks.action-broker.plist"

for forbidden_path in "$cli_path" "$action_broker_path" "$launch_agent_path"; do
  if [[ -e "$forbidden_path" || -L "$forbidden_path" ]]; then
    /bin/rm -f -- "$forbidden_path"
  fi
done

/bin/rmdir "$bundle_root/Resources/CLI" 2>/dev/null || true
/bin/rmdir "$bundle_root/Library/LaunchAgents" 2>/dev/null || true
