#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/blocks-source-upgrade.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
core="$root/apps/Blocks/BlocksCore"
tests="$root/apps/Blocks/BlocksAppTests"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
test_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
private_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"
for mode in local official; do
    flags=(-swift-version 6)
    if [[ "$mode" == local ]]; then flags+=(-D BLOCKS_LOCAL_DEVELOPMENT); fi
    xcrun swiftc "${flags[@]}" -D SOURCE_UPGRADE_FIXTURE \
        -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
        -I "$test_libraries" -L "$test_libraries" -Xlinker -rpath -Xlinker "$test_libraries" \
        -Xlinker -rpath -Xlinker "$private_frameworks" \
        "$core/BlocksLocalBuildTrust.swift" "$core/SourceUpgradeProtocol.swift" \
        "$core/SourceUpgradeTransport.swift" "$tests/SourceUpgradeProtocolTests.swift" \
        -o "$fixture/protocol-$mode"
    "$fixture/protocol-$mode"
    xcrun swiftc "${flags[@]}" -emit-module -emit-library -module-name BlocksCore \
        "$core/BlocksLocalBuildTrust.swift" "$core/SourceUpgradeProtocol.swift" \
        "$core/SourceUpgradeTransport.swift" -emit-module-path "$fixture/BlocksCore.swiftmodule" \
        -o "$fixture/libBlocksCore.dylib"
    xcrun swiftc -O "${flags[@]}" -D SOURCE_UPGRADE_CLI_FIXTURE \
        -I "$fixture" -L "$fixture" -lBlocksCore -Xlinker -rpath -Xlinker "$fixture" \
        "$root/apps/Blocks/BlocksCLI/SourceUpgradeCLI.swift" "$tests/SourceUpgradeCLIFixture.swift" \
        -o "$fixture/cli-$mode"
    "$fixture/cli-$mode"
done
