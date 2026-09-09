#!/usr/bin/env python3
"""Run the real quit watchdog in an isolated temporary app bundle."""

from __future__ import annotations

import ctypes
import json
import os
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORCED_EXIT_CODE = 77
WATCHDOG_SECONDS = 5
REQUEST_TO_FORCE_MINIMUM_SECONDS = 4.9
REQUEST_TO_FORCE_MAXIMUM_SECONDS = 5.6


def process_executable_path(pid: int) -> str | None:
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    proc_pidpath = library.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    length = proc_pidpath(pid, buffer, len(buffer))
    return os.fsdecode(buffer.value) if length > 0 else None


def same_executable_path(actual_path: str | None, expected_path: Path) -> bool:
    return actual_path is not None and Path(actual_path).resolve() == expected_path.resolve()


def process_parent_pid(pid: int) -> int | None:
    completed = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "ppid="],
        check=False,
        capture_output=True,
        text=True,
    )
    value = completed.stdout.strip()
    return int(value) if completed.returncode == 0 and value.isdigit() else None


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def assert_eventually_absent(pid: int, label: str) -> None:
    deadline = time.monotonic() + 3
    while process_exists(pid) and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not process_exists(pid), f"{label} survived the fixture force-exit"


def wait_for_report(report_path: Path, fixture: subprocess.Popen[bytes]) -> dict[str, object]:
    deadline = time.monotonic() + 2
    while not report_path.exists() and fixture.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    assert report_path.exists(), f"fixture did not publish child identities (exit={fixture.poll()})"
    return json.loads(report_path.read_text(encoding="utf-8"))


def read_force_result(result_path: Path) -> dict[str, object]:
    assert result_path.exists(), "watchdog force closure did not write its controlled result"
    return json.loads(result_path.read_text(encoding="utf-8"))


def terminate_fixture_child(pid: int | None, expected_path: Path) -> None:
    if pid is None or not process_exists(pid):
        return
    if not same_executable_path(process_executable_path(pid), expected_path):
        return
    os.kill(pid, signal.SIGKILL)
    assert_eventually_absent(pid, f"fixture child {pid}")


def compile_fixture(output: Path) -> None:
    sources = sorted((ROOT / "apps/Blocks/BlocksCore").glob("*.swift"))
    sources.extend(ROOT / relative for relative in (
        "apps/Blocks/BlocksApp/Services/AppTerminationCoordinator.swift",
        "tools/verification/fixtures/QuitWatchdogProcessFixture.swift",
    ))
    subprocess.run(
        [
            "/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-lsqlite3",
            *map(str, sources), "-o", str(output),
        ],
        cwd=ROOT,
        check=True,
    )


def stage_fixture_app(root: Path) -> Path:
    app = root / "QuitWatchdogFixture.app"
    executable = app / "Contents/MacOS/QuitWatchdogProcessFixture"
    executable.parent.mkdir(parents=True)
    plist = {
        "CFBundleExecutable": executable.name,
        "CFBundleIdentifier": "app.blocks.quit-watchdog-fixture",
        "CFBundleName": "QuitWatchdogFixture",
        "CFBundlePackageType": "APPL",
    }
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
    compile_fixture(root / "QuitWatchdogProcessFixture")
    shutil.copy2(root / "QuitWatchdogProcessFixture", executable)
    return executable


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="blocks-quit-watchdog-self-test-") as directory:
        root = Path(directory)
        executable = stage_fixture_app(root)
        report_path = root / "fixture-report.json"
        force_result_path = root / "watchdog-force-result.json"
        fixture: subprocess.Popen[bytes] | None = None
        registered_pid: int | None = None
        unregistered_pid: int | None = None
        registered_path: Path | None = None
        unregistered_path: Path | None = None
        try:
            started = time.monotonic()
            fixture = subprocess.Popen(
                [str(executable), str(report_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            report = wait_for_report(report_path, fixture)
            parent_pid = int(report["parentPID"])
            registered_pid = int(report["registeredPID"])
            unregistered_pid = int(report["unregisteredPID"])
            registered_path = Path(str(report["registeredExecutablePath"]))
            unregistered_path = Path(str(report["unregisteredExecutablePath"]))

            assert parent_pid == fixture.pid, (parent_pid, fixture.pid)
            assert registered_path == executable.parent / "BlocksClipboardBroker", registered_path
            assert unregistered_path == Path("/bin/sleep"), unregistered_path
            assert same_executable_path(process_executable_path(registered_pid), registered_path), registered_pid
            assert same_executable_path(process_executable_path(unregistered_pid), unregistered_path), unregistered_pid
            assert process_parent_pid(registered_pid) == fixture.pid, registered_pid
            assert process_parent_pid(unregistered_pid) == fixture.pid, unregistered_pid

            stdout, stderr = fixture.communicate(timeout=12)
            startup_to_exit_seconds = time.monotonic() - started
            return_code = fixture.returncode
            force_result = read_force_result(force_result_path)
            request_uptime_nanoseconds = int(force_result["requestUptimeNanoseconds"])
            forced_uptime_nanoseconds = int(force_result["forcedUptimeNanoseconds"])
            request_to_force_seconds = int(force_result["forceDelayNanoseconds"]) / 1_000_000_000
            assert return_code == FORCED_EXIT_CODE, return_code
            assert forced_uptime_nanoseconds >= request_uptime_nanoseconds, force_result
            assert (
                REQUEST_TO_FORCE_MINIMUM_SECONDS <= request_to_force_seconds <= REQUEST_TO_FORCE_MAXIMUM_SECONDS
            ), (
                f"request-to-force delay {request_to_force_seconds:.3f}s, "
                f"expected about {WATCHDOG_SECONDS}s",
                force_result,
            )
            assert b"WATCHDOG_FORCE delayNanoseconds=" in stdout, stdout
            assert not stderr, stderr.decode("utf-8", errors="replace")
            assert_eventually_absent(registered_pid, "registered broker")
            assert process_exists(unregistered_pid), "unregistered /bin/sleep was incorrectly terminated"
            assert same_executable_path(process_executable_path(unregistered_pid), unregistered_path), unregistered_pid
            print(
                "PASS: real watchdog forced exit "
                f"startup-to-exit={startup_to_exit_seconds:.3f}s, "
                f"request-to-force={request_to_force_seconds:.3f}s "
                f"(exit={return_code}); registered broker reaped; "
                "unregistered sleep survived"
            )
        finally:
            if fixture is not None and fixture.poll() is None:
                fixture.kill()
                fixture.wait(timeout=3)
            # Only exact PIDs spawned by this fixture are eligible for cleanup.
            if registered_pid is not None and registered_path is not None:
                terminate_fixture_child(registered_pid, registered_path)
            if unregistered_pid is not None and unregistered_path is not None:
                terminate_fixture_child(unregistered_pid, unregistered_path)


if __name__ == "__main__":
    main()
