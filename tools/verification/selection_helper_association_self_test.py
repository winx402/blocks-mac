#!/usr/bin/env python3
"""Run the local-only pairing policy fixture; no app, credentials, or network."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    platform = Path(subprocess.check_output(
        ["xcrun", "--show-sdk-platform-path"], text=True
    ).strip())
    frameworks = platform / "Developer/Library/Frameworks"
    libraries = platform / "Developer/usr/lib"
    private_frameworks = platform / "Developer/Library/PrivateFrameworks"
    core = ROOT / "apps/Blocks/BlocksCore"
    sources = [core / name for name in (
        "BlocksRuntimeIdentity.swift", "BlocksLocalBuildTrust.swift",
        "SelectionAgentXPC.swift", "SelectionHelperLocalAssociation.swift",
    )]
    sources.append(ROOT / "apps/Blocks/BlocksAppTests/SelectionHelperLocalAssociationTests.swift")
    with tempfile.TemporaryDirectory(prefix="blocks-local-association-tests-") as raw:
        binary = Path(raw) / "association-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5",
            "-D", "BLOCKS_LOCAL_DEVELOPMENT", "-D", "SELECTION_HELPER_ASSOCIATION_FIXTURE",
            "-F", str(frameworks), "-I", str(libraries), "-L", str(libraries),
            "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
            "-Xlinker", "-rpath", "-Xlinker", str(libraries),
            "-Xlinker", "-rpath", "-Xlinker", str(private_frameworks),
            *map(str, sources), "-o", str(binary),
        ], cwd=ROOT, check=True)
        subprocess.run([str(binary)], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
