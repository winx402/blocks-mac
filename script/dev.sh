#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v python3 >/dev/null; then
  echo 'error: Python 3 is required. Install/select the full Xcode developer tools first.' >&2
  exit 2
fi
exec python3 "$root/script/development.py" "$@"
