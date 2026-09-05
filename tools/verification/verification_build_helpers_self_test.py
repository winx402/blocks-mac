#!/usr/bin/env python3
"""Deterministic nested timeout coverage for verification process supervision."""

from __future__ import annotations

import os
import json
import plistlib
import re
import signal
import stat
import sys
import tempfile
import time
from pathlib import Path

import verification_build_helpers
from verification_build_helpers import run_controlled_subprocess


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
    assert not process_exists(pid), f"{label} process {pid} survived timeout cleanup"


def run_variant(*, leader_ignores_term: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="verification-process-group-self-test-") as directory:
        pids_file = Path(directory) / "pids.txt"
        fixture = (
            "import os, signal, sys, time\n"
            "from pathlib import Path\n"
            "sys.path.insert(0, sys.argv[3])\n"
            "from verification_build_helpers import run_controlled_subprocess\n"
            "path = Path(sys.argv[1])\n"
            "if sys.argv[2] == 'ignore': signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "child_code = (\n"
            "    'import os, signal, sys, time; '\n"
            "    'Path = __import__(\\\"pathlib\\\").Path; '\n"
            "    'Path(sys.argv[1]).write_text(str(os.getpid()), encoding=\\\"utf-8\\\"); '\n"
            "    'signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'\n"
            ")\n"
            "path.write_text(str(os.getpid()), encoding='utf-8')\n"
            "run_controlled_subprocess([sys.executable, '-c', child_code, str(path) + '.inner'], cwd=Path.cwd(), timeout=60)\n"
            "time.sleep(60)\n"
        )
        result = run_controlled_subprocess(
            [
                sys.executable,
                "-c",
                fixture,
                str(pids_file),
                "ignore" if leader_ignores_term else "default",
                str(Path(__file__).parent),
            ],
            cwd=Path(directory),
            timeout=0.25,
        )
        label = "leader_ignores_term" if leader_ignores_term else "leader_default_term"
        assert result["timed_out"], (label, result)
        assert all("signal" in step and "status" in step for step in result.get("cleanup", [])), result
        assert result["cleanup"] == [{"signal": "SIGUSR1", "status": "supervisor_requested"}], result
        outer_pid = int(pids_file.read_text(encoding="utf-8"))
        inner_pid = int(Path(str(pids_file) + ".inner").read_text(encoding="utf-8"))
        assert_eventually_absent(outer_pid, f"{label} outer child")
        assert_eventually_absent(inner_pid, f"{label} nested child")


def run_pipe_holding_descendant_variant() -> None:
    """A normally exiting child must not let a pipe-holding descendant escape."""
    with tempfile.TemporaryDirectory(prefix="verification-pipe-holder-self-test-") as directory:
        pids_file = Path(directory) / "pids.txt"
        fixture = (
            "import os, signal, subprocess, sys, time\n"
            "from pathlib import Path\n"
            "path = Path(sys.argv[1])\n"
            "child_code = (\n"
            "    'import os, signal, sys, time; '\n"
            "    'signal.signal(signal.SIGTERM, signal.SIG_IGN); '\n"
            "    'time.sleep(60)'\n"
            ")\n"
            "child = subprocess.Popen([sys.executable, '-c', child_code])\n"
            "path.write_text(f'{os.getpid()} {child.pid}', encoding='utf-8')\n"
            "# Exit immediately; child retains this process's stdout/stderr.\n"
        )
        result = run_controlled_subprocess(
            [sys.executable, "-c", fixture, str(pids_file)],
            cwd=Path(directory),
            timeout=0.25,
        )
        assert not result["ok"], result
        assert (
            result["timed_out"]
            or result.get("process_cleanup", {}).get("status") == "target_group_residual_cleaned"
        ), result
        target_pid, descendant_pid = (int(value) for value in pids_file.read_text(encoding="utf-8").split())
        assert_eventually_absent(target_pid, "pipe-holder target")
        assert_eventually_absent(descendant_pid, "pipe-holder descendant")


def run_large_output_variant() -> None:
    """Relay both streams concurrently so a full pipe cannot deadlock a gate."""
    payload_size = 1024 * 1024
    fixture = (
        "import sys\n"
        f"sys.stdout.write('o' * {payload_size})\n"
        f"sys.stderr.write('e' * {payload_size})\n"
    )
    result = run_controlled_subprocess(
        [sys.executable, "-c", fixture],
        cwd=Path.cwd(),
        timeout=3,
    )
    assert result["ok"] and not result["timed_out"], result
    assert len(result["stdout"]) == payload_size, len(result["stdout"])
    assert len(result["stderr"]) == payload_size, len(result["stderr"])
    assert "output_truncation" not in result, result


def run_bounded_output_variant() -> None:
    """Streams larger than the collector limit retain only a marked bounded tail."""
    payload_size = verification_build_helpers._OUTPUT_STREAM_MEMORY_LIMIT + 2 * 1024
    fixture = f"import sys; sys.stdout.buffer.write(b'o' * {payload_size})"
    result = run_controlled_subprocess([sys.executable, "-c", fixture], cwd=Path.cwd(), timeout=5)
    truncation = result.get("output_truncation", {}).get("stdout", {})
    assert result["ok"] and not result["timed_out"], result
    assert truncation == {
        "truncated": True,
        "byte_count": payload_size,
        "retained_byte_count": verification_build_helpers._OUTPUT_STREAM_MEMORY_LIMIT,
    }, truncation
    assert result["stdout"].startswith("[output truncated after "), result["stdout"][:80]
    assert result["stdout"].endswith("o" * 128), result["stdout"][-128:]
    assert len(result["stdout"]) <= verification_build_helpers._OUTPUT_STREAM_MEMORY_LIMIT + 128, len(result["stdout"])


def run_exit_contract_variants() -> None:
    success = run_controlled_subprocess([sys.executable, "-c", "print('ok')"], cwd=Path.cwd(), timeout=2)
    failure = run_controlled_subprocess([sys.executable, "-c", "import sys; sys.exit(7)"], cwd=Path.cwd(), timeout=2)
    assert success["ok"] and success["stdout"] == "ok\n" and not success["timed_out"], success
    assert not failure["ok"] and failure["returncode"] == 7 and not failure["timed_out"], failure


def run_target_exit_sentinel_variants() -> None:
    """Target-defined 70/71 remain raw exits, not supervisor cleanup sentinels."""
    for returncode in (70, 71):
        result = run_controlled_subprocess(
            [sys.executable, "-c", f"import sys; sys.exit({returncode})"], cwd=Path.cwd(), timeout=2
        )
        assert not result["ok"] and not result["timed_out"], result
        assert result["returncode"] == returncode, result
        assert "process_cleanup" not in result and "cleanup" not in result, result


def run_redirected_descendant_variant() -> None:
    """A descendant that closes inherited pipes is still a structured failure."""
    with tempfile.TemporaryDirectory(prefix="verification-redirected-descendant-") as directory:
        pid_file = Path(directory) / "pid"
        sensitive_command = "PRIVATE_COMMAND_FRAGMENT_MUST_NOT_REACH_JSON"
        fixture = (
            "import signal, subprocess, sys; from pathlib import Path; "
            f"marker='{sensitive_command}'; "
            "code='import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'; "
            "child=subprocess.Popen([sys.executable,\'-c\',code],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
            "Path(sys.argv[1]).write_text(str(child.pid))"
        )
        result = run_controlled_subprocess([sys.executable, "-c", fixture, str(pid_file)], cwd=Path(directory), timeout=2)
        descendant = int(pid_file.read_text())
        assert not result["ok"] and not result["timed_out"], result
        assert result.get("process_cleanup", {}).get("status") == "target_group_residual_cleaned", result
        cleanup = result["process_cleanup"]
        assert cleanup.get("residual_process_count", 0) >= 1, cleanup
        assert cleanup.get("residual_processes_truncated") is False, cleanup
        assert all({"pid", "ppid", "pgid"} <= set(process) for process in cleanup.get("residual_processes", [])), cleanup
        assert sensitive_command not in json.dumps(result, sort_keys=True), result
        assert_eventually_absent(descendant, "redirected descendant")


def run_residual_executable_identity_producer_variant(*, force_ucomm_fallback: bool) -> None:
    """A long, spaced executable path never crosses the residual JSON boundary."""
    original_program = verification_build_helpers._SUPERVISOR_PROGRAM
    if force_ucomm_fallback:
        unavailable_library = "/dev/null/blocks-verification-libproc-unavailable"
        assert original_program.count("/usr/lib/libproc.dylib") >= 2
        verification_build_helpers._SUPERVISOR_PROGRAM = original_program.replace(
            "/usr/lib/libproc.dylib", unavailable_library
        )
    secret_path_component = "SECRET_EXECUTABLE_PATH_COMPONENT_MUST_NOT_REACH_JSON"
    try:
        with tempfile.TemporaryDirectory(prefix="verification residual executable path ") as directory:
            pid_file = Path(directory) / "pid"
            executable = Path(directory) / (
                f"residual executable with spaces {secret_path_component} " + "L" * 64
            )
            os.symlink(sys.executable, executable)
            child_code = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"
            fixture = (
                "import os, subprocess, sys; from pathlib import Path; "
                f"child_code={child_code!r}; "
                "child=subprocess.Popen([sys.argv[2], '-c', child_code], preexec_fn=os.setsid, "
                "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                "Path(sys.argv[1]).write_text(str(child.pid))"
            )
            result = run_controlled_subprocess(
                [sys.executable, "-c", fixture, str(pid_file), str(executable)],
                cwd=Path(directory),
                timeout=2,
            )
            descendant = int(pid_file.read_text())
            cleanup = result.get("process_cleanup", {})
            processes = cleanup.get("residual_processes", [])
            serialized = json.dumps(result, sort_keys=True)
            assert not result["ok"] and not result["timed_out"], result
            if force_ucomm_fallback:
                # Start-time metadata is a cleanup precondition, unlike optional
                # executable diagnostics.  Missing libproc is unverified.
                assert result["returncode"] == 71, result
                assert cleanup.get("status") == "internal_cleanup_failure", result
            else:
                assert result["returncode"] == 70, result
                assert cleanup.get("status") == "target_group_residual_cleaned" and processes, result
            assert secret_path_component not in serialized and str(executable) not in serialized, serialized
            assert verification_build_helpers._TARGET_TOKEN_ENV not in serialized, serialized
            for process in processes:
                assert "command" not in process and "environment" not in process and "token" not in process, process
                if "executable" in process:
                    assert re.fullmatch(r"[A-Za-z0-9._+-]{1,128}", process["executable"]), process
                    assert process["executable"] != "Xc" or process.get("executable_name_may_be_truncated") is True, process
                if "executable_name_may_be_truncated" in process:
                    assert process["executable_name_may_be_truncated"] is True, process
            if not force_ucomm_fallback and sys.platform == "darwin":
                assert any("executable" in process for process in processes), processes
                assert all("executable_name_may_be_truncated" not in process for process in processes), processes
            assert_eventually_absent(descendant, "residual executable identity descendant")
    finally:
        verification_build_helpers._SUPERVISOR_PROGRAM = original_program


def run_nonzero_residual_preserves_returncode_variant() -> None:
    """Residual cleanup must not replace a real failing target exit with 70."""
    with tempfile.TemporaryDirectory(prefix="verification-nonzero-residual-") as directory:
        pid_file = Path(directory) / "pid"
        fixture = (
            "import signal, subprocess, sys; from pathlib import Path; "
            "child_code=\"import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)\"; "
            "child=subprocess.Popen([sys.executable, '-c', child_code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
            "Path(sys.argv[1]).write_text(str(child.pid)); sys.exit(65)"
        )
        result = run_controlled_subprocess(
            [sys.executable, "-c", fixture, str(pid_file)], cwd=Path(directory), timeout=2
        )
        descendant = int(pid_file.read_text())
        cleanup = result.get("process_cleanup", {})
        assert not result["ok"] and not result["timed_out"], result
        assert result["returncode"] == 65, result
        assert cleanup.get("status") == "target_group_residual_cleaned", result
        assert cleanup.get("child_returncode") == 65, result
        assert_eventually_absent(descendant, "nonzero residual descendant")


def run_residual_handoff_propagation_variant() -> None:
    """A child-0 residual snapshot is diagnostic-only and still fails closed as 70."""
    original_program = verification_build_helpers._SUPERVISOR_PROGRAM
    secret_token = "a" * 64
    secret_command = "/private/build/secret-command --credential=do-not-leak"
    snapshot = {
        "count": 1,
        "processes": [{"pid": 101, "ppid": 1, "pgid": 101, "executable": "xcodebuild", "elapsed_seconds": 12}],
        "truncated": False,
        "detected_after_child_exit_seconds": 2.0,
        "cleanup_started_after_child_exit_seconds": 2.0,
        "cleanup_finished_after_child_exit_seconds": 2.1,
    }
    try:
        verification_build_helpers._SUPERVISOR_PROGRAM = (
            "import json, os; fd=int(os.environ['BLOCKS_VERIFICATION_TARGET_FD']); "
            f"os.write(fd, b'token ' + {secret_token.encode('ascii')!r} + b'\\npgid 101\\nchild_returncode 0\\nphase post_exit\\n'); "
            f"os.write(fd, b'residual ' + {json.dumps(snapshot).encode('ascii')!r} + b'\\nstatus residual_cleaned\\n'); "
            "raise SystemExit(75)"
        )
        result = run_controlled_subprocess([sys.executable, "-c", "pass"], cwd=Path.cwd(), timeout=2)
    finally:
        verification_build_helpers._SUPERVISOR_PROGRAM = original_program
    cleanup = result.get("process_cleanup", {})
    assert not result["ok"] and not result["timed_out"] and result["returncode"] == 70, result
    assert cleanup.get("child_returncode") == 0, cleanup
    assert cleanup.get("residual_processes") == snapshot["processes"], cleanup
    assert cleanup.get("residual_process_count") == 1 and cleanup.get("residual_processes_truncated") is False, cleanup
    assert cleanup.get("residual_detected_after_child_exit_seconds") == 2.0, cleanup
    assert cleanup.get("residual_cleanup_finished_after_child_exit_seconds") == 2.1, cleanup
    assert cleanup["residual_processes"][0].get("elapsed_seconds") == 12, cleanup
    serialized = json.dumps(result, sort_keys=True)
    assert secret_token not in serialized and secret_command not in serialized, serialized


def run_residual_identity_filter_variant() -> None:
    token = "a" * 64
    exact = f"BLOCKS_VERIFICATION_TARGET_TOKEN={token}"
    assert verification_build_helpers._has_exact_target_token(f"A=1 {exact} target", token)
    assert not verification_build_helpers._has_exact_target_token(f"A=1 {exact}x target", token)
    assert not verification_build_helpers._has_exact_target_token(f"X{exact} target", token)
    original_rows = verification_build_helpers._process_rows_with_environment
    original_uid = verification_build_helpers.os.getuid
    try:
        verification_build_helpers._process_rows_with_environment = lambda: [
            (101, 1, 501, 77, f"A=1 {exact} target"),
            (102, 1, 502, 77, f"A=1 {exact} target"),
            (103, 1, 501, 77, f"A=1 {exact}x target"),
        ]
        verification_build_helpers.os.getuid = lambda: 501
        assert verification_build_helpers._target_group_token_pids(77, token) == {101}
    finally:
        verification_build_helpers._process_rows_with_environment = original_rows
        verification_build_helpers.os.getuid = original_uid


def run_residual_handoff_rejection_variant() -> None:
    limit = verification_build_helpers._RESIDUAL_PROCESS_LIMIT
    valid_snapshot = {
        "count": 1,
        "processes": [{"pid": 10, "ppid": 1, "pgid": 10}],
        "truncated": False,
        "detected_after_child_exit_seconds": 2.0,
        "cleanup_started_after_child_exit_seconds": 2.0,
        "cleanup_finished_after_child_exit_seconds": 2.1,
    }
    valid = json.dumps(valid_snapshot).encode("ascii")
    assert verification_build_helpers._parse_residual_process_handoff(valid) == {
        **valid_snapshot,
    }
    over_limit = json.dumps({
        **valid_snapshot,
        "count": limit + 1,
        "processes": [{"pid": index + 10, "ppid": 1, "pgid": index + 10} for index in range(limit + 1)],
        "truncated": True,
    }).encode("ascii")
    assert verification_build_helpers._parse_residual_process_handoff(over_limit) is None
    assert verification_build_helpers._parse_residual_process_handoff(b'{"count":1,"processes":[[10,1]],"truncated":false}') is None
    unsafe = dict(valid_snapshot)
    unsafe["processes"] = [{"pid": 10, "ppid": 1, "pgid": 10, "executable": "secret command"}]
    assert verification_build_helpers._parse_residual_process_handoff(json.dumps(unsafe).encode("ascii")) is None
    fallback = dict(valid_snapshot)
    fallback["processes"] = [{
        "pid": 10,
        "ppid": 1,
        "pgid": 10,
        "executable": "Xc",
        "executable_name_may_be_truncated": True,
        "elapsed_seconds": 12,
    }]
    assert verification_build_helpers._parse_residual_process_handoff(json.dumps(fallback).encode("ascii")) == fallback
    api_failure = dict(valid_snapshot)
    api_failure["processes"] = [{"pid": 10, "ppid": 1, "pgid": 10, "elapsed_seconds": 12}]
    assert verification_build_helpers._parse_residual_process_handoff(json.dumps(api_failure).encode("ascii")) == api_failure
    invalid_marker = dict(fallback)
    invalid_marker["processes"] = [{
        "pid": 10, "ppid": 1, "pgid": 10, "executable_name_may_be_truncated": False,
    }]
    assert verification_build_helpers._parse_residual_process_handoff(json.dumps(invalid_marker).encode("ascii")) is None
    unsafe_path = dict(valid_snapshot)
    unsafe_path["processes"] = [{"pid": 10, "ppid": 1, "pgid": 10, "executable": "/private/secret"}]
    assert verification_build_helpers._parse_residual_process_handoff(json.dumps(unsafe_path).encode("ascii")) is None


def run_forged_handoff_fd_variant() -> None:
    """A forged nested descriptor cannot be passed or treated as a handoff."""
    with tempfile.TemporaryDirectory(prefix="verification-forged-handoff-") as directory:
        result_file = Path(directory) / "result.json"
        pid_file = Path(directory) / "inner.pid"
        helper_dir = repr(str(Path(__file__).parent))
        fixture = (
            f"import json, os, sys; sys.path.insert(0, {helper_dir}); from pathlib import Path; "
            "from verification_build_helpers import run_controlled_subprocess; "
            "os.environ['BLOCKS_VERIFICATION_TIMEOUT_FD']='999999'; "
            "code='import os,signal,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'; "
            "result=run_controlled_subprocess([sys.executable,'-c',code,sys.argv[2]],cwd=Path.cwd(),timeout=.1); "
            "Path(sys.argv[1]).write_text(json.dumps(result))"
        )
        result = run_controlled_subprocess([sys.executable, "-c", fixture, str(result_file), str(pid_file)], cwd=Path(directory), timeout=.5)
        nested = json.loads(result_file.read_text())
        assert nested["cleanup"] == [{"signal": "handoff", "status": "unavailable"}], nested
        assert result["timed_out"] or result.get("process_cleanup", {}).get("status") == "target_group_residual_cleaned", result
        assert_eventually_absent(int(pid_file.read_text()), "forged-fd descendant")


def run_forged_self_supervisor_variant() -> None:
    """A process cannot nominate itself as a nested supervisor."""
    with tempfile.TemporaryDirectory(prefix="verification-forged-self-supervisor-") as directory:
        result_file = Path(directory) / "result.json"
        target_pid_file = Path(directory) / "target.pid"
        helper_dir = repr(str(Path(__file__).parent))
        fixture = (
            f"import json, os, sys; sys.path.insert(0, {helper_dir}); from pathlib import Path; "
            "from verification_build_helpers import run_controlled_subprocess; "
            "os.environ['BLOCKS_VERIFICATION_CONTROLLED_GROUP']='1'; "
            "os.environ['BLOCKS_VERIFICATION_SUPERVISOR_PID']=str(os.getpid()); "
            "code='import os,signal,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'; "
            "result=run_controlled_subprocess([sys.executable,'-c',code,sys.argv[2]],cwd=Path.cwd(),timeout=.1); "
            "Path(sys.argv[1]).write_text(json.dumps(result))"
        )
        outer = run_controlled_subprocess(
            [sys.executable, "-c", fixture, str(result_file), str(target_pid_file)], cwd=Path(directory), timeout=2
        )
        nested = json.loads(result_file.read_text())
        assert nested["timed_out"] and nested["cleanup"] == [{"signal": "SIGUSR1", "status": "supervisor_requested"}], nested
        assert_eventually_absent(int(target_pid_file.read_text()), "forged-self target")
        assert outer["ok"], outer


def run_escaped_descendant_variants() -> None:
    """setsid escapees retain the target token and are reaped after group cleanup."""
    for timeout_case in (False, True):
        with tempfile.TemporaryDirectory(prefix="verification-setsid-escape-") as directory:
            pid_file = Path(directory) / "escaped.pid"
            fixture = (
                "import os, signal, subprocess, sys, time; from pathlib import Path; "
                "code='import os,signal,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'; "
                "child=subprocess.Popen([sys.executable,\'-c\',code,sys.argv[1]],preexec_fn=os.setsid,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                + ("time.sleep(60)" if timeout_case else "")
            )
            result = run_controlled_subprocess(
                [sys.executable, "-c", fixture, str(pid_file)], cwd=Path(directory), timeout=.2
            )
            escaped = int(pid_file.read_text())
            if timeout_case:
                assert result["timed_out"], result
            else:
                assert not result["ok"] and not result["timed_out"], result
                assert result["returncode"] == 70, result
                assert result.get("process_cleanup", {}).get("status") == "target_group_residual_cleaned", result
            assert_eventually_absent(escaped, "timeout" if timeout_case else "normal-exit")


def run_short_lived_descendant_drain_variant() -> None:
    """A ready setsid descendant gets an EOF release instead of timing assumptions."""
    with tempfile.TemporaryDirectory(prefix="verification-natural-drain-") as directory:
        ready_file = Path(directory) / "ready"
        finished_file = Path(directory) / "finished"
        descendant_code = (
            "import os, sys; from pathlib import Path; "
            "Path(sys.argv[1]).write_text('ready'); "
            "os.read(int(sys.argv[3]), 1); "
            "Path(sys.argv[2]).write_text('finished')"
        )
        fixture = (
            "import os, subprocess, sys, time\n"
            "from pathlib import Path\n"
            "read_fd, write_fd = os.pipe()\n"
            "subprocess.Popen([sys.executable, '-c', sys.argv[3], sys.argv[1], sys.argv[2], str(read_fd)], "
            "preexec_fn=os.setsid, pass_fds=(read_fd,))\n"
            "os.close(read_fd)\n"
            "deadline = time.monotonic() + 1\n"
            "while not Path(sys.argv[1]).exists() and time.monotonic() < deadline:\n"
            "    time.sleep(.01)\n"
            "assert Path(sys.argv[1]).exists()\n"
        )
        result = run_controlled_subprocess(
            [sys.executable, "-c", fixture, str(ready_file), str(finished_file), descendant_code],
            cwd=Path(directory), timeout=2, termination_grace_seconds=.2,
        )
        assert result["ok"] and result["returncode"] == 0 and not result["timed_out"], result
        assert ready_file.read_text() == "ready", result
        assert finished_file.read_text() == "finished", result


def run_unverified_group_identity_variant() -> None:
    """A recycled/foreign PGID never reaches killpg; exact-token cleanup remains available."""
    token = "a" * 64
    foreign_pid = 515151
    foreign_pgid = 717171
    original_rows = verification_build_helpers._process_rows_with_environment
    original_killpg = verification_build_helpers.os.killpg
    original_token_pids = verification_build_helpers._token_pids
    original_identity = verification_build_helpers._pid_start_identity
    original_kill = verification_build_helpers.os.kill
    killpg_calls: list[tuple[int, int]] = []
    token_kills: list[tuple[int, int]] = []
    token_states = [{foreign_pid}, set()]
    try:
        verification_build_helpers._process_rows_with_environment = lambda: [
            (foreign_pid, 1, os.getuid(), foreign_pgid, "foreign process without the target token")
        ]
        verification_build_helpers.os.killpg = lambda pgid, signum: killpg_calls.append((pgid, signum))
        assert not verification_build_helpers._cleanup_target_group(foreign_pgid, token, .01)
        assert killpg_calls == [], killpg_calls

        verification_build_helpers._token_pids = lambda _token: token_states.pop(0)
        verification_build_helpers._pid_start_identity = lambda _pid: (1, 1)

        def fake_kill(pid: int, signum: int) -> None:
            if signum == 0:
                raise ProcessLookupError
            token_kills.append((pid, signum))

        verification_build_helpers.os.kill = fake_kill
        assert verification_build_helpers._cleanup_target_token(token, .1) == "fallback_cleaned"
        assert token_kills == [(foreign_pid, signal.SIGTERM)], token_kills
    finally:
        verification_build_helpers._process_rows_with_environment = original_rows
        verification_build_helpers.os.killpg = original_killpg
        verification_build_helpers._token_pids = original_token_pids
        verification_build_helpers._pid_start_identity = original_identity
        verification_build_helpers.os.kill = original_kill


def run_supervisor_internal_status_fallback_variant() -> None:
    """A normal wait treats handoff internal status as a failed, cleaned invocation."""
    original_program = verification_build_helpers._SUPERVISOR_PROGRAM
    try:
        verification_build_helpers._SUPERVISOR_PROGRAM = (
            "import os; fd=int(os.environ['BLOCKS_VERIFICATION_TARGET_FD']); "
            "os.write(fd, b'token ' + b'a' * 64 + b'\\npgid 999999\\nstatus internal_cleanup_failure\\n'); "
            "raise SystemExit(75)"
        )
        result = run_controlled_subprocess([sys.executable, "-c", "pass"], cwd=Path.cwd(), timeout=2)
    finally:
        verification_build_helpers._SUPERVISOR_PROGRAM = original_program
    assert not result["ok"] and not result["timed_out"], result
    assert result["returncode"] == 71, result
    cleanup = result.get("process_cleanup", {})
    assert cleanup.get("status") == "internal_cleanup_failure", result
    assert any(step == {"signal": "fallback", "status": "internal_cleanup_failure"} for step in result.get("cleanup", [])), result
    assert any(step.get("signal") == "target_token" for step in result.get("cleanup", [])), result


def run_fallback_no_token_candidates_variant() -> None:
    """An empty first token query is unverified, never a claimed cleanup."""
    token = "a" * 64
    original_token_pids = verification_build_helpers._token_pids
    original_kill = verification_build_helpers.os.kill
    kill_calls: list[tuple[int, int]] = []
    try:
        verification_build_helpers._token_pids = lambda _token: set()
        verification_build_helpers.os.kill = lambda pid, signum: kill_calls.append((pid, signum))
        assert verification_build_helpers._cleanup_target_token(token, .01) == "fallback_no_token_candidates"
        cleanup: list[dict[str, str]] = []
        verification_build_helpers._append_parent_fallback_cleanup(
            cleanup,
            reason="self_test",
            target_pgid=None,
            target_token=token,
            termination_grace_seconds=.01,
        )
        assert cleanup == [
            {"signal": "fallback", "status": "self_test"},
            {"signal": "target_group", "status": "unknown"},
            {"signal": "target_token", "status": "fallback_no_token_candidates"},
        ], cleanup
        assert kill_calls == [], kill_calls
    finally:
        verification_build_helpers._token_pids = original_token_pids
        verification_build_helpers.os.kill = original_kill


def run_controlled_xctest_argv_and_plist_variants() -> None:
    """The dedicated app-hosted XCTest entry rejects ambiguity and leaves no plist residue."""
    with tempfile.TemporaryDirectory(prefix="verification-controlled-xctest-") as directory:
        xctestrun = Path(directory) / "Blocks.xctestrun"
        original_payload = {
            "TestConfigurations": [
                {
                    "IsEnabled": True,
                    "Name": "enabled",
                    "TestTargets": [
                        {"IsEnabled": True, "EnvironmentVariables": {"KEEP": "one"}},
                        {
                            "IsEnabled": True,
                            "EnvironmentVariables": {"KEEP": "two"},
                            "TestingEnvironmentVariables": {"MIRROR": "yes"},
                        },
                        {"IsEnabled": False, "EnvironmentVariables": {"DISABLED": "keep"}},
                    ],
                },
                {
                    "IsEnabled": False,
                    "TestTargets": [{"IsEnabled": True, "EnvironmentVariables": {"CONFIG": "keep"}}],
                },
            ]
        }
        original_bytes = plistlib.dumps(original_payload, sort_keys=False)
        xctestrun.write_bytes(original_bytes)
        command = [
            "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
            "-destination", "platform=macOS",
            "-parallel-testing-enabled", "NO",
            "-test-timeouts-enabled", "YES",
            "-default-test-execution-time-allowance", "60",
            "-maximum-test-execution-time-allowance", "120",
            "-only-testing:BlocksAppTests/FixtureTests/testFixture",
            "-resultBundlePath", str(Path(directory) / "Fixture.xcresult"),
            "-quiet",
        ]
        original_runner = verification_build_helpers.run_controlled_subprocess
        captured: dict[str, object] = {}
        try:
            def fake_runner(
                actual_command: list[str], **kwargs: object
            ) -> dict[str, object]:
                captured["command"] = actual_command
                captured["kwargs"] = kwargs
                temporary = Path(actual_command[3])
                captured["temporary"] = temporary
                captured["mode"] = stat.S_IMODE(temporary.stat().st_mode)
                captured["payload"] = plistlib.loads(temporary.read_bytes())
                return {"ok": True, "returncode": 0, "stdout": "", "stderr": "", "timed_out": False}

            verification_build_helpers.run_controlled_subprocess = fake_runner
            result = verification_build_helpers.run_controlled_xcode_test(
                command, cwd=Path(directory), timeout=1
            )
        finally:
            verification_build_helpers.run_controlled_subprocess = original_runner
        assert result["ok"], result
        assert xctestrun.read_bytes() == original_bytes, "source xctestrun was modified"
        temporary = captured["temporary"]
        assert isinstance(temporary, Path) and not temporary.exists(), captured
        assert captured["mode"] == 0o600, captured
        token = captured["kwargs"].get("_target_token")  # type: ignore[union-attr]
        assert isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64}", token), captured
        targets = captured["payload"]["TestConfigurations"]  # type: ignore[index]
        enabled_first = targets[0]["TestTargets"]  # type: ignore[index]
        for target in enabled_first[:2]:
            environment = target["EnvironmentVariables"]
            assert environment["BLOCKS_VERIFICATION_TARGET_TOKEN"] == token
            assert environment["BLOCKS_VERIFICATION_REQUIRE_TOKEN_PROBE"] == "1"
        assert enabled_first[1]["TestingEnvironmentVariables"]["BLOCKS_VERIFICATION_TARGET_TOKEN"] == token
        assert enabled_first[2]["EnvironmentVariables"] == {"DISABLED": "keep"}
        assert targets[1]["TestTargets"][0]["EnvironmentVariables"] == {"CONFIG": "keep"}

        for invalid in [
            ["/bin/sh", "-c", "xcodebuild test-without-building"],
            ["xcodebuild", "test", "-xctestrun", str(xctestrun)],
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-xctestrun", str(xctestrun)],
            ["xcodebuild", "test-without-building", "@response", "-xctestrun", str(xctestrun)],
            ["xcodebuild", "test-without-building", "-xctestrun"],
            ["xcodebuild", "test-without-building", "test-without-building", "-xctestrun", str(xctestrun)],
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "clean"],
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "build"],
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "archive"],
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "test"],
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "--", "clean"],
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-unknown"],
            [
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-parallel-testing-enabled", "MAYBE",
            ],
            [
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-destination", "platform=macOS", "-destination", "platform=macOS",
            ],
            [
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-only-testing:",
            ],
            [
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-only-testing:BlocksAppTests/Test Case/test()",
            ],
        ]:
            rejected = verification_build_helpers.run_controlled_xcode_test(
                invalid, cwd=Path(directory), timeout=1
            )
            assert rejected["process_cleanup"]["status"] == "controlled_xctest_rejected", rejected

        for payload in [
            {"TestConfigurations": []},
            {"TestConfigurations": [{"IsEnabled": True, "TestTargets": []}]},
            {"TestConfigurations": [{"IsEnabled": True, "TestTargets": [{"EnvironmentVariables": {
                "BLOCKS_VERIFICATION_TARGET_TOKEN": "collision"
            }}]}]},
        ]:
            xctestrun.write_bytes(plistlib.dumps(payload))
            rejected = verification_build_helpers.run_controlled_xcode_test(
                command, cwd=Path(directory), timeout=1
            )
            assert rejected["process_cleanup"]["status"] == "controlled_xctest_rejected", rejected


def run_pid_start_identity_variants() -> None:
    """PID reuse or inaccessible libproc start metadata is always fail-closed."""
    token = "a" * 64
    original_token_pids = verification_build_helpers._token_pids
    original_identity = verification_build_helpers._pid_start_identity
    original_kill = verification_build_helpers.os.kill
    calls: list[tuple[int, int]] = []
    try:
        verification_build_helpers._token_pids = lambda _token: {42}
        verification_build_helpers._pid_start_identity = lambda _pid: (10, 20)
        verification_build_helpers.os.kill = lambda pid, signum: calls.append((pid, signum))
        assert verification_build_helpers._signal_verified_identities({42: (10, 20)}, signal.SIGTERM)
        assert calls == [(42, signal.SIGTERM)], calls
        calls.clear()
        verification_build_helpers._pid_start_identity = lambda _pid: (10, 21)
        assert not verification_build_helpers._signal_verified_identities({42: (10, 20)}, signal.SIGTERM)
        assert calls == [], calls
        verification_build_helpers._pid_start_identity = lambda _pid: None
        assert verification_build_helpers._cleanup_target_token(token, .01) == "fallback_unverified"
    finally:
        verification_build_helpers._token_pids = original_token_pids
        verification_build_helpers._pid_start_identity = original_identity
        verification_build_helpers.os.kill = original_kill


def run_precise_timeout_escape_cleanup_variant() -> None:
    """The parent waits for token cleanup; it never preempts the supervisor at 3x grace."""
    with tempfile.TemporaryDirectory(prefix="verification-timeout-token-cleanup-") as directory:
        pids_file = Path(directory) / "pids"
        escaped_code = "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        fixture = (
            "import os, signal, subprocess, sys, time; from pathlib import Path; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "escaped=subprocess.Popen([sys.executable, '-c', sys.argv[2]], preexec_fn=os.setsid, "
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
            "Path(sys.argv[1]).write_text(f'{os.getpid()} {escaped.pid}'); time.sleep(60)"
        )
        result = run_controlled_subprocess(
            [sys.executable, "-c", fixture, str(pids_file), escaped_code],
            cwd=Path(directory), timeout=.1, termination_grace_seconds=.1,
        )
        leader_pid, escaped_pid = (int(value) for value in pids_file.read_text().split())
        assert result["timed_out"], result
        assert not any(step.get("status") == "supervisor_fallback" for step in result["cleanup"]), result
        assert not process_exists(leader_pid), (leader_pid, result)
        assert not process_exists(escaped_pid), (escaped_pid, result)


def run_non_utf8_variant() -> None:
    result = run_controlled_subprocess(
        [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'\\xffout'); sys.stderr.buffer.write(b'\\xferr')"],
        cwd=Path.cwd(), timeout=2,
    )
    assert not result["ok"] and result["returncode"] == 70 and not result["timed_out"], result
    cleanup = result.get("process_cleanup", {})
    assert cleanup.get("status") == "invalid_utf8_output" and "replacement-safe" in cleanup.get("diagnostic", ""), result


def run_stdout_build_diagnostic_variant() -> None:
    original = verification_build_helpers.run_controlled_subprocess
    try:
        verification_build_helpers.run_controlled_subprocess = lambda *_args, **_kwargs: {
            "ok": False, "returncode": 65, "stdout": "fatal error: stdout-only failure\n" + "x" * 1_000_000,
            "stderr": "", "timed_out": False, "process_cleanup": {"status": "preserved"},
        }
        result = verification_build_helpers.run_blocks_no_launch_build(Path.cwd(), 1, "self-test")
    finally:
        verification_build_helpers.run_controlled_subprocess = original
    assert "fatal error: stdout-only failure" in result["stderr_tail"], result["stderr_tail"]
    assert len(result["stderr_tail"]) <= 1800, len(result["stderr_tail"])
    assert result.get("process_cleanup") == {"status": "preserved"}, result


def run_build_wrapper_termination_grace_variant() -> None:
    """Only the xcodebuild wrapper opts into its longer natural-drain observation window."""
    original = verification_build_helpers.run_controlled_subprocess
    captured: dict[str, object] = {}
    try:
        def controlled(*_args: object, **kwargs: object) -> dict[str, object]:
            captured.update(kwargs)
            return {"ok": True, "returncode": 0, "stdout": "", "stderr": "", "timed_out": False}
        verification_build_helpers.run_controlled_subprocess = controlled
        result = verification_build_helpers.run_blocks_no_launch_build(Path.cwd(), 1, "self-test")
    finally:
        verification_build_helpers.run_controlled_subprocess = original
    assert result["ok"], result
    assert captured.get("termination_grace_seconds") == 2.0, captured
    assert run_controlled_subprocess.__kwdefaults__["termination_grace_seconds"] == 0.5


def run_long_single_line_build_diagnostic_variant() -> None:
    diagnostic = verification_build_helpers._build_diagnostic("fatal error: " + "x" * 10_000, "")
    assert len(diagnostic) <= 1800, len(diagnostic)
    assert "fatal error:" in diagnostic and "diagnostic truncated" in diagnostic, diagnostic


def run_nested_handoff_variant() -> None:
    """Nested timeout hands off cleanup without signalling its own caller."""
    with tempfile.TemporaryDirectory(prefix="verification-nested-handoff-self-test-") as directory:
        pids_file = Path(directory) / "pids.txt"
        fixture = (
            "import json, sys\n"
            "from pathlib import Path\n"
            "sys.path.insert(0, sys.argv[3])\n"
            "from verification_build_helpers import run_controlled_subprocess\n"
            "path = Path(sys.argv[1])\n"
            "child_code = (\n"
            "    'import os, signal, sys, time; '\n"
            "    'Path = __import__(\\\"pathlib\\\").Path; '\n"
            "    'Path(sys.argv[1]).write_text(str(os.getpid()), encoding=\\\"utf-8\\\"); '\n"
            "    'signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'\n"
            ")\n"
            "result = run_controlled_subprocess([sys.executable, '-c', child_code, str(path) + '.inner'], cwd=Path.cwd(), timeout=.2)\n"
            "path.write_text(str(__import__('os').getpid()), encoding='utf-8')\n"
            "Path(str(path) + '.result').write_text(json.dumps(result), encoding='utf-8')\n"
        )
        result = run_controlled_subprocess(
            [sys.executable, "-c", fixture, str(pids_file), "unused", str(Path(__file__).parent)],
            cwd=Path(directory),
            timeout=3,
        )
        nested_result = __import__("json").loads(Path(str(pids_file) + ".result").read_text(encoding="utf-8"))
        assert nested_result["timed_out"], nested_result
        assert nested_result["cleanup"] == [{"signal": "handoff", "status": "requested"}], nested_result
        assert result["timed_out"], result
        assert result["cleanup"] == [{"signal": "SIGUSR1", "status": "supervisor_requested"}], result
        outer_pid = int(pids_file.read_text(encoding="utf-8"))
        inner_pid = int(Path(str(pids_file) + ".inner").read_text(encoding="utf-8"))
        assert_eventually_absent(outer_pid, "nested handoff outer")
        assert_eventually_absent(inner_pid, "nested handoff child")


def run_three_level_handoff_variant() -> None:
    """The original handoff FD must survive two nested Popen boundaries."""
    with tempfile.TemporaryDirectory(prefix="verification-three-level-handoff-") as directory:
        pids_file = Path(directory) / "pids.txt"
        helper_directory = repr(str(Path(__file__).parent))
        inner_code = (
            "import os, signal, sys, time; from pathlib import Path; "
            "Path(sys.argv[1]).write_text(str(os.getpid())); "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        )
        middle_code = (
            f"import json, sys; sys.path.insert(0, {helper_directory}); from pathlib import Path; "
            "from verification_build_helpers import run_controlled_subprocess; "
            "result=run_controlled_subprocess([sys.executable,'-c',sys.argv[2],sys.argv[1]+'.inner'],cwd=Path.cwd(),timeout=.2); "
            "Path(sys.argv[1]+'.deep').write_text(json.dumps(result))"
        )
        outer_code = (
            f"import json, sys; sys.path.insert(0, {helper_directory}); from pathlib import Path; "
            "from verification_build_helpers import run_controlled_subprocess; "
            "result=run_controlled_subprocess([sys.executable,'-c',sys.argv[2],sys.argv[1],sys.argv[3]],cwd=Path.cwd(),timeout=60); "
            "Path(sys.argv[1]+'.middle').write_text(json.dumps(result)); "
            "Path(sys.argv[1]).write_text(str(__import__('os').getpid()))"
        )
        result = run_controlled_subprocess(
            [sys.executable, "-c", outer_code, str(pids_file), middle_code, inner_code],
            cwd=Path(directory),
            timeout=3,
        )
        deep = __import__("json").loads(Path(str(pids_file) + ".deep").read_text())
        middle = __import__("json").loads(Path(str(pids_file) + ".middle").read_text())
        assert deep["timed_out"] and deep["cleanup"] == [{"signal": "handoff", "status": "requested"}], deep
        assert middle["timed_out"] and middle["cleanup"] == [{"signal": "handoff", "status": "requested"}], middle
        assert result["timed_out"], result
        assert result["cleanup"] == [{"signal": "SIGUSR1", "status": "supervisor_requested"}], result
        assert_eventually_absent(int(pids_file.read_text()), "three-level outer")
        assert_eventually_absent(int(Path(str(pids_file) + ".inner").read_text()), "three-level inner")


def run_fast_exit_race_variant() -> None:
    """Run one deterministic fast exit; opt into a larger race loop by environment."""
    raw_iterations = os.environ.get("BLOCKS_VERIFICATION_FAST_EXIT_RACE_ITERATIONS", "1")
    try:
        iterations = int(raw_iterations)
    except ValueError as error:
        raise AssertionError("BLOCKS_VERIFICATION_FAST_EXIT_RACE_ITERATIONS must be an integer") from error
    if not 1 <= iterations <= 1000:
        raise AssertionError("BLOCKS_VERIFICATION_FAST_EXIT_RACE_ITERATIONS must be between 1 and 1000")
    for _ in range(iterations):
        result = run_controlled_subprocess([sys.executable, "-c", "pass"], cwd=Path.cwd(), timeout=1)
        assert result["ok"] and not result["timed_out"], result


def _self_test_watchdog_seconds() -> int:
    raw_seconds = os.environ.get("BLOCKS_VERIFICATION_SELF_TEST_WATCHDOG_SECONDS", "120")
    try:
        seconds = int(raw_seconds)
    except ValueError as error:
        raise AssertionError("BLOCKS_VERIFICATION_SELF_TEST_WATCHDOG_SECONDS must be an integer") from error
    if not 1 <= seconds <= 600:
        raise AssertionError("BLOCKS_VERIFICATION_SELF_TEST_WATCHDOG_SECONDS must be between 1 and 600")
    return seconds


def main() -> int:
    def watchdog(_signal: int, _frame: object) -> None:
        raise TimeoutError("verification build helper self-test watchdog expired")

    signal.signal(signal.SIGALRM, watchdog)
    signal.alarm(_self_test_watchdog_seconds())
    try:
        run_variant(leader_ignores_term=True)
        run_variant(leader_ignores_term=False)
        run_pipe_holding_descendant_variant()
        run_large_output_variant()
        run_bounded_output_variant()
        run_exit_contract_variants()
        run_target_exit_sentinel_variants()
        run_redirected_descendant_variant()
        run_residual_executable_identity_producer_variant(force_ucomm_fallback=False)
        run_residual_executable_identity_producer_variant(force_ucomm_fallback=True)
        run_nonzero_residual_preserves_returncode_variant()
        run_residual_handoff_propagation_variant()
        run_residual_identity_filter_variant()
        run_residual_handoff_rejection_variant()
        run_nested_handoff_variant()
        run_three_level_handoff_variant()
        run_fast_exit_race_variant()
        run_forged_handoff_fd_variant()
        run_forged_self_supervisor_variant()
        run_escaped_descendant_variants()
        run_short_lived_descendant_drain_variant()
        run_unverified_group_identity_variant()
        run_supervisor_internal_status_fallback_variant()
        run_fallback_no_token_candidates_variant()
        run_controlled_xctest_argv_and_plist_variants()
        run_pid_start_identity_variants()
        run_precise_timeout_escape_cleanup_variant()
        run_non_utf8_variant()
        run_stdout_build_diagnostic_variant()
        run_build_wrapper_termination_grace_variant()
        run_long_single_line_build_diagnostic_variant()
    finally:
        signal.alarm(0)
    print("verification build helper nested timeout self-test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
