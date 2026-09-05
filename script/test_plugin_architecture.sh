#!/bin/bash

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$root/apps/Blocks/BlocksApp/Resources/BuiltInPlugins/catalog.json"
source_roots=(
  "$root/apps/Blocks/BlocksApp"
  "$root/apps/Blocks/BlocksCore"
  "$root/apps/Blocks/BlocksCLI"
)

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to validate the built-in plugin architecture" >&2
  exit 2
fi

status=0
while IFS= read -r plugin_id; do
  if matches="$(
    rg --line-number --fixed-strings --glob '*.swift' "$plugin_id" \
      "${source_roots[@]}" 2>/dev/null
  )"; then
    echo "Built-in plugin ID leaked into host business source: $plugin_id" >&2
    echo "$matches" >&2
    status=1
  fi
done < <(jq -r '.entries[].id' "$catalog")

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "Plugin architecture gate passed: host business sources contain no built-in plugin IDs."
