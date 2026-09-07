#!/usr/bin/env bash
# Official end-user installer. Development builds intentionally use dev.sh
# (or the existing build entry) and must never pass through this release path.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 "$root_dir/script/install_helpers.py" "$@"
