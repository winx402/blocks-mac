#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/blocks-action-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
xcrun swiftc -swift-version 6 -D BLOCKS_LOCAL_DEVELOPMENT -D LOCAL_ACTION_TRANSPORT_FIXTURE \
    "$root/apps/Blocks/BlocksCore/LocalActionTransport.swift" \
    "$root/tools/verification/fixtures/LocalActionTransportFixture.swift" -o "$fixture/transport"
# Formal compilation contains no transport implementation or references.
xcrun swiftc -swift-version 6 -emit-library "$root/apps/Blocks/BlocksCore/LocalActionTransport.swift" \
    -o "$fixture/formal.dylib"
if nm "$fixture/formal.dylib" | grep -q LocalActionTransport; then exit 1; fi
python3 "$root/tools/verification/local_action_transport_self_test.py" "$fixture/transport"
python3 "$root/tools/verification/local_action_signed_transport_self_test.py"
