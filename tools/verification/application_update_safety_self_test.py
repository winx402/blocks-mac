#!/usr/bin/env python3
"""Compile isolated production storage/lifecycle classes; use synthetic DBs only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def main() -> None:
    sources = sorted((ROOT / "apps/Blocks/BlocksCore").glob("*.swift"))
    sources.extend(ROOT / relative for relative in (
        "apps/Blocks/BlocksApp/Services/ApplicationLifecycleCoordinator.swift",
        "apps/Blocks/BlocksApp/Services/AppTerminationCoordinator.swift",
        "tools/verification/fixtures/ApplicationUpdateSafetySelfTest.swift",
    ))
    with tempfile.TemporaryDirectory(prefix="blocks-update-safety-self-test-") as temporary:
        root = Path(temporary)
        executable = root / "SafetySelfTest"
        subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-lsqlite3",
                        *map(str, sources), "-o", str(executable)], cwd=ROOT, check=True)
        subprocess.run([str(executable), str(root / "synthetic-storage")], cwd=ROOT, check=True)

if __name__ == "__main__":
    main()
