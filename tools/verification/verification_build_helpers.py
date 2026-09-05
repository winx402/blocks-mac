#!/usr/bin/env python3
"""Side-effect-bounded helpers for trusted build verification gates.

These helpers constrain trusted build tools that retain the inherited target
identity.  They are not an OS sandbox: a target that deliberately scrubs that
identity or otherwise evades supervision requires an OS-level sandbox, which
is outside the P5 verification threat model.
"""

from __future__ import annotations

import codecs
import ctypes
import json
import math
import os
import plistlib
import re
import secrets
import select
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


_CONTROLLED_GROUP_ENV = "BLOCKS_VERIFICATION_CONTROLLED_GROUP"
_CONTROLLED_SUPERVISOR_ENV = "BLOCKS_VERIFICATION_SUPERVISOR_PID"
_CONTROLLED_TIMEOUT_FD_ENV = "BLOCKS_VERIFICATION_TIMEOUT_FD"
_CONTROLLED_TIMEOUT_MARKER_ENV = "BLOCKS_VERIFICATION_TIMEOUT_MARKER"
_CONTROLLED_TARGET_FD_ENV = "BLOCKS_VERIFICATION_TARGET_FD"
_TARGET_TOKEN_ENV = "BLOCKS_VERIFICATION_TARGET_TOKEN"
_XCTEST_REQUIRE_PROBE_ENV = "BLOCKS_VERIFICATION_REQUIRE_TOKEN_PROBE"
_OUTPUT_DECODE_EXIT = 70
_SUPERVISOR_RESIDUAL_EXIT = 70
_SUPERVISOR_INTERNAL_EXIT = 71
_OUTPUT_DIAGNOSTIC_LIMIT = 1800
_OUTPUT_STREAM_MEMORY_LIMIT = 4 * 1024 * 1024
_OUTPUT_READ_CHUNK_BYTES = 64 * 1024
_SUPERVISOR_STATUS_RESIDUAL = "residual_cleaned"
_SUPERVISOR_PHASE_POST_EXIT = "post_exit"
_RESIDUAL_PROCESS_LIMIT = 16
_RESIDUAL_HANDOFF_MAX_BYTES = 4096
# xcodebuild may leave trusted child services to finish their normal shutdown.
# This extends observation only; any residual that still needs cleanup remains a failure.
_XCODEBUILD_TERMINATION_GRACE_SECONDS = 2.0
_SUPERVISOR_INTERNAL_STATUSES = frozenset({
    "internal_start_failure",
    "internal_cleanup_failure",
    "internal_pipe_failure",
})
# Five signal/reap stages plus bounded process-table observation at stage edges.
_SUPERVISOR_CLEANUP_GRACE_MULTIPLIER = 8
_SUPERVISOR_CLEANUP_OVERHEAD_SECONDS = 0.5

_SUPERVISOR_PROGRAM = r'''
import ctypes, json, os, re, secrets, signal, subprocess, sys, threading, time

command = json.loads(sys.argv[1])
grace = float(sys.argv[2])
provided_target_token = json.loads(sys.argv[3])
cancelled = False
target_handoff_fd = None
child = None

def request_cancel(_signal, _frame):
    global cancelled
    cancelled = True

def report_status(status):
    if target_handoff_fd is None:
        return False
    try:
        os.write(target_handoff_fd, f'status {status}\n'.encode('ascii'))
        return True
    except OSError:
        return False

def report_phase(phase):
    if target_handoff_fd is None:
        return False
    try:
        os.write(target_handoff_fd, f'phase {phase}\n'.encode('ascii'))
        return True
    except OSError:
        return False

def report_child_returncode(returncode):
    if target_handoff_fd is None:
        return False
    try:
        os.write(target_handoff_fd, f'child_returncode {returncode}\n'.encode('ascii'))
        return True
    except OSError:
        return False

def report_residual_processes(snapshot):
    if target_handoff_fd is None:
        return False
    try:
        payload = json.dumps(snapshot, separators=(',', ':'), sort_keys=True).encode('ascii')
        os.write(target_handoff_fd, b'residual ' + payload + b'\n')
        return True
    except (OSError, TypeError, ValueError):
        return False

def parse_etime_seconds(value):
    """Parse ps etime without forwarding its raw presentation into JSON."""
    parts = value.split('-')
    if len(parts) == 2:
        if not parts[0].isdigit():
            return None
        days, clock = int(parts[0]), parts[1]
    elif len(parts) == 1:
        days, clock = 0, parts[0]
    else:
        return None
    values = clock.split(':')
    if len(values) == 2:
        hours, minutes, seconds = 0, values[0], values[1]
    elif len(values) == 3:
        hours, minutes, seconds = values
    else:
        return None
    if not all(part.isdigit() for part in (str(hours), minutes, seconds)):
        return None
    hours, minutes, seconds = int(hours), int(minutes), int(seconds)
    if minutes >= 60 or seconds >= 60:
        return None
    return (((days * 24) + hours) * 60 + minutes) * 60 + seconds

def safe_executable_name(value):
    """Accept only a short, path-free executable identity for JSON handoff."""
    if not isinstance(value, str) or re.fullmatch(r'[A-Za-z0-9._+-]{1,128}', value) is None:
        return None
    return value

def load_proc_name():
    """Load only proc_name; diagnostic discovery must not affect cleanup."""
    try:
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
        proc_name = libproc.proc_name
        proc_name.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
        proc_name.restype = ctypes.c_int
        return proc_name
    except (AttributeError, OSError, TypeError, ValueError):
        return None

def proc_name_for_pid(proc_name, pid):
    """Return the kernel's path-free process name, or omit on API failure."""
    try:
        buffer = ctypes.create_string_buffer(129)
        length = proc_name(pid, buffer, len(buffer))
        if not isinstance(length, int) or not 0 < length < len(buffer):
            return None
        return safe_executable_name(buffer.raw[:length].split(b'\0', 1)[0].decode('ascii'))
    except (OSError, TypeError, ValueError, UnicodeDecodeError, ctypes.ArgumentError):
        return None

def ucomm_names_for_pids(pids):
    """Use ucomm only if libproc cannot load; never parse or forward paths."""
    try:
        completed = subprocess.run(
            ['/bin/ps', '-axo', 'pid=,ucomm='],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            check=True, timeout=max(grace, .1),
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    names = {}
    for line in completed.stdout.decode('utf-8', 'replace').splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        if pid in pids and (name := safe_executable_name(fields[1])) is not None:
            names[pid] = name
    return names

def elapsed_seconds_for_pids(pids):
    """Parse etime separately so executable names cannot corrupt field parsing."""
    try:
        completed = subprocess.run(
            ['/bin/ps', '-axo', 'pid=,etime='],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            check=True, timeout=max(grace, .1),
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    elapsed = {}
    for line in completed.stdout.decode('utf-8', 'replace').splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        if pid in pids and (seconds := parse_etime_seconds(fields[1])) is not None:
            elapsed[pid] = seconds
    return elapsed

def safe_process_metadata(pids):
    """Return safe process names and elapsed runtimes; diagnostic failures omit fields."""
    metadata = {pid: {} for pid in pids}
    proc_name = load_proc_name()
    if proc_name is None:
        # ucomm can be truncated.  The marker is retained even when its value is
        # rejected by the whitelist, so consumers never mistake it for proc_name.
        for pid, name in ucomm_names_for_pids(pids).items():
            metadata[pid]['executable'] = name
        for entry in metadata.values():
            entry['executable_name_may_be_truncated'] = True
    else:
        for pid in pids:
            if (name := proc_name_for_pid(proc_name, pid)) is not None:
                metadata[pid]['executable'] = name
    for pid, seconds in elapsed_seconds_for_pids(pids).items():
        metadata[pid]['elapsed_seconds'] = seconds
    metadata = {pid: entry for pid, entry in metadata.items() if entry}
    return metadata

def fail_internal(status):
    report_status(status)
    raise SystemExit(75)

signal.signal(signal.SIGTERM, request_cancel)
signal.signal(signal.SIGUSR1, request_cancel)
os.environ['BLOCKS_VERIFICATION_CONTROLLED_GROUP'] = '1'
os.environ['BLOCKS_VERIFICATION_SUPERVISOR_PID'] = str(os.getpid())

try:
    if provided_target_token is not None and re.fullmatch(r'[0-9a-f]{64}', provided_target_token) is None:
        fail_internal('internal_start_failure')
    target_token = provided_target_token or secrets.token_hex(32)
    target_handoff_fd = int(os.environ['BLOCKS_VERIFICATION_TARGET_FD'])
    # This precedes target creation, so a parent without a token can conclude
    # that this fixed supervisor has not launched a target yet.
    os.write(target_handoff_fd, f'token {target_token}\n'.encode('ascii'))
    target_environment = os.environ.copy()
    target_environment['BLOCKS_VERIFICATION_TARGET_TOKEN'] = target_token
    child = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        preexec_fn=os.setpgrp,
        pass_fds=(int(os.environ['BLOCKS_VERIFICATION_TIMEOUT_FD']),),
        env=target_environment,
    )
    target_pgid = child.pid
    os.write(target_handoff_fd, f'pgid {target_pgid}\n'.encode('ascii'))
except Exception:
    fail_internal('internal_start_failure')

relay_failure = threading.Event()

def forward(source, destination):
    try:
        while True:
            chunk = source.read1(65536)
            if not chunk:
                return
            destination.write(chunk)
            destination.flush()
    except Exception:
        relay_failure.set()

stdout_thread = threading.Thread(target=forward, args=(child.stdout, sys.stdout.buffer), daemon=True)
stderr_thread = threading.Thread(target=forward, args=(child.stderr, sys.stderr.buffer), daemon=True)
stdout_thread.start(); stderr_thread.start()

def _ps_rows():
    """Return same-user process rows including environment when ps permits it."""
    try:
        completed = subprocess.run(
            ['/bin/ps', 'eww', '-axo', 'pid=,ppid=,uid=,pgid=,command='],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            check=True, timeout=max(grace, .1),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    rows = []
    for line in completed.stdout.decode('utf-8', 'replace').splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) == 5:
            try:
                rows.append((int(fields[0]), int(fields[1]), int(fields[2]), int(fields[3]), fields[4]))
            except ValueError:
                pass
    return rows

def has_exact_target_token(command):
    needle = 'BLOCKS_VERIFICATION_TARGET_TOKEN=' + target_token
    start = 0
    while True:
        index = command.find(needle, start)
        if index < 0:
            return False
        end = index + len(needle)
        if (index == 0 or command[index - 1].isspace()) and (end == len(command) or command[end].isspace()):
            return True
        start = end

def token_pids(rows):
    return {pid for pid, _ppid, uid, _pgid, command in rows
            if uid == os.getuid() and has_exact_target_token(command)}

def target_group_token_pids(rows):
    return {pid for pid, _ppid, uid, pgid, command in rows
            if uid == os.getuid() and pgid == target_pgid and has_exact_target_token(command)}

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ('prefix', ctypes.c_uint32 * 12), ('comm', ctypes.c_char * 16),
        ('name', ctypes.c_char * 32), ('middle', ctypes.c_uint32 * 5),
        ('nice', ctypes.c_int32), ('start_tvsec', ctypes.c_uint64),
        ('start_tvusec', ctypes.c_uint64),
    ]

def pid_start_identity(pid):
    """Use public libproc PROC_PIDTBSDINFO; unavailable identity is unsafe."""
    try:
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
        proc_pidinfo.restype = ctypes.c_int
        info = ProcBSDInfo()
        if proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            return None
        return (int(info.start_tvsec), int(info.start_tvusec))
    except (AttributeError, OSError, TypeError, ValueError, ctypes.ArgumentError):
        return None

def verified_token_identities(rows):
    identities = {}
    for pid in token_pids(rows):
        identity = pid_start_identity(pid)
        if identity is None:
            return None
        identities[pid] = identity
    return identities

def signal_verified_identities(identities, signum):
    for pid, identity in identities.items():
        if pid_start_identity(pid) != identity:
            return False
        try: os.kill(pid, signum)
        except ProcessLookupError: pass
        except PermissionError: return False
    return True

def residual_process_snapshot(rows, child_exit_at):
    """Bounded pre-cleanup identity only; never include command or token data."""
    processes = sorted(
        (pid, ppid, pgid) for pid, ppid, uid, pgid, command in rows
        if uid == os.getuid() and has_exact_target_token(command)
    )
    metadata = safe_process_metadata({pid for pid, _ppid, _pgid in processes[:16]})
    detected_after_child_exit_seconds = max(0.0, time.monotonic() - child_exit_at)
    serialized = []
    for pid, ppid, pgid in processes[:16]:
        process = {'pid': pid, 'ppid': ppid, 'pgid': pgid}
        process.update(metadata.get(pid, {}))
        serialized.append(process)
    return {
        'count': len(processes),
        'processes': serialized,
        'truncated': len(processes) > 16,
        'detected_after_child_exit_seconds': detected_after_child_exit_seconds,
        'cleanup_started_after_child_exit_seconds': detected_after_child_exit_seconds,
    }

def wait_for_target_tree_drain():
    """Give the original group and token-bearing escapees one settle window."""
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        rows = _ps_rows()
        if rows is None:
            return False
        if not token_pids(rows):
            return True
        time.sleep(.01)
    rows = _ps_rows()
    return rows is not None and not token_pids(rows)

def cleanup_target_group():
    """Signal verified members individually; never signal a bare PGID."""
    for signum in (signal.SIGTERM, signal.SIGKILL):
        rows = _ps_rows()
        members = target_group_token_pids(rows) if rows is not None else None
        identities = verified_token_identities(rows) if rows is not None else None
        if not members or identities is None or not members.issubset(identities):
            return False
        if not signal_verified_identities({pid: identities[pid] for pid in members}, signum):
            return False
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            rows = _ps_rows()
            if rows is None:
                return False
            if not target_group_token_pids(rows):
                return True
            time.sleep(.01)
    rows = _ps_rows()
    return rows is not None and not target_group_token_pids(rows)

def pids_gone(pids):
    for pid in pids:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            return False
        return False
    return True

def cleanup_escaped_descendants(reap_exempt=()):
    """Kill only this target's token-bearing escapees; tokens are not a sandbox."""
    rows = _ps_rows()
    if rows is None:
        return False, False
    protected = {os.getpid()}
    ancestor = os.getppid()
    for _ in range(128):
        if ancestor <= 1 or ancestor in protected:
            break
        protected.add(ancestor)
        parent = next((ppid for pid, ppid, _uid, _pgid, _command in rows if pid == ancestor), 0)
        ancestor = parent
    identities = verified_token_identities(rows)
    if identities is None:
        return False, False
    candidates = set(identities).difference(protected)
    if not candidates:
        return True, False
    tracked = set(candidates)
    if not signal_verified_identities({pid: identities[pid] for pid in candidates}, signal.SIGTERM):
        return False, True
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        rows = _ps_rows()
        if rows is None: return False, True
        live = token_pids(rows).difference(protected)
        tracked.update(live)
        if not live and pids_gone(tracked.difference(reap_exempt)):
            return True, True
        time.sleep(.01)
    rows = _ps_rows()
    identities = verified_token_identities(rows) if rows is not None else None
    if identities is None or not live.issubset(identities):
        return False, True
    if not signal_verified_identities({pid: identities[pid] for pid in live}, signal.SIGKILL):
        return False, True
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        rows = _ps_rows()
        if rows is None: return False, True
        live = token_pids(rows).difference(protected)
        tracked.update(live)
        if not live and pids_gone(tracked.difference(reap_exempt)):
            return True, True
        time.sleep(.01)
    return (not live and pids_gone(tracked.difference(reap_exempt))), True

def cleanup_live_target():
    group_clean = cleanup_target_group()
    escaped_clean, _escaped_found = cleanup_escaped_descendants({child.pid})
    try:
        child.wait(timeout=grace)
        child_reaped = True
    except subprocess.TimeoutExpired:
        child_reaped = False
    return group_clean and escaped_clean and child_reaped

try:
    while child.poll() is None and not cancelled and not relay_failure.is_set():
        time.sleep(.01)
    if relay_failure.is_set():
        if child.poll() is None:
            cleanup_live_target()
        fail_internal('internal_pipe_failure')
    if child.poll() is None:
        if cleanup_live_target():
            raise SystemExit(124)
        fail_internal('internal_cleanup_failure')
    returncode = child.wait()
    child_exit_at = time.monotonic()
    if not report_child_returncode(returncode):
        fail_internal('internal_pipe_failure')
    if not report_phase('post_exit'):
        fail_internal('internal_pipe_failure')
    # A direct-child success stays successful only if its entire exact-token tree
    # (the original PG and setsid/double-fork escapees alike) naturally drains.
    if not wait_for_target_tree_drain():
        rows = _ps_rows()
        if rows is None:
            fail_internal('internal_cleanup_failure')
        snapshot = residual_process_snapshot(rows, child_exit_at)
        group_clean = cleanup_target_group()
        escaped_clean, escaped_found = cleanup_escaped_descendants()
        if escaped_clean and (group_clean or escaped_found):
            snapshot['cleanup_finished_after_child_exit_seconds'] = max(0.0, time.monotonic() - child_exit_at)
            if not report_residual_processes(snapshot):
                fail_internal('internal_cleanup_failure')
            report_status('residual_cleaned')
            raise SystemExit(75)
        fail_internal('internal_cleanup_failure')
    stdout_thread.join(grace)
    stderr_thread.join(grace)
    if relay_failure.is_set() or stdout_thread.is_alive() or stderr_thread.is_alive():
        fail_internal('internal_pipe_failure')
    raise SystemExit(returncode)
except SystemExit:
    raise
except Exception:
    try:
        if child.poll() is None:
            cleanup_live_target()
    except Exception:
        pass
    fail_internal('internal_cleanup_failure')
'''


def _inherited_controlled_supervisor() -> int | None:
    if os.environ.get(_CONTROLLED_GROUP_ENV) != "1":
        return None
    try:
        supervisor = int(os.environ[_CONTROLLED_SUPERVISOR_ENV])
        if supervisor <= 0 or supervisor == os.getpid() or os.getsid(0) != supervisor:
            return None
        if os.getpgid(supervisor) != supervisor:
            return None
        # A copied environment is not authority: the claimed supervisor must be
        # a strict ancestor of this process, as observed from read-only ps data.
        current = os.getpid()
        for _ in range(128):
            parent = subprocess.run(
                ["/bin/ps", "-o", "ppid=", "-p", str(current)], stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, check=False, timeout=_SUPERVISOR_CLEANUP_OVERHEAD_SECONDS,
            ).stdout.decode("ascii", "ignore").strip()
            try:
                current = int(parent)
            except ValueError:
                return None
            if current == supervisor:
                return supervisor
            if current <= 1:
                return None
        return None
    except (KeyError, ValueError, ProcessLookupError, PermissionError, subprocess.SubprocessError):
        return None


def _inherited_timeout_handoff_fd() -> int | None:
    value = os.environ.get(_CONTROLLED_TIMEOUT_FD_ENV)
    try:
        descriptor = int(value) if value is not None else -1
        return descriptor if descriptor >= 0 and stat.S_ISFIFO(os.fstat(descriptor).st_mode) else None
    except (ValueError, OSError):
        return None


def _read_available_fd(descriptor: int, buffer: bytearray) -> None:
    while True:
        try:
            chunk = os.read(descriptor, 128)
        except BlockingIOError:
            return
        if not chunk:
            return
        buffer.extend(chunk)
        if len(chunk) < 128:
            return


def _supervisor_cleanup_budget(termination_grace_seconds: float) -> float:
    """Bound the fixed supervisor's worst-case timeout cleanup work."""
    return max(
        _SUPERVISOR_CLEANUP_OVERHEAD_SECONDS,
        (termination_grace_seconds * _SUPERVISOR_CLEANUP_GRACE_MULTIPLIER)
        + _SUPERVISOR_CLEANUP_OVERHEAD_SECONDS,
    )


def _consume_target_handoff(
    buffer: bytearray,
    target_pgid: int | None,
    target_token: str | None,
    supervisor_status: str | None,
    supervisor_phase: str | None,
    child_returncode: int | None,
    residual_processes: dict[str, Any] | None,
    residual_handoff_invalid: bool,
    residual_handoff_seen: bool,
) -> tuple[int | None, str | None, str | None, str | None, int | None, dict[str, Any] | None, bool, bool]:
    """Consume the supervisor's private target identity and direct-child status handoff."""
    if len(buffer) > _RESIDUAL_HANDOFF_MAX_BYTES and b"\n" not in buffer:
        buffer.clear()
        residual_handoff_invalid = True
    while b"\n" in buffer:
        line, _, remainder = bytes(buffer).partition(b"\n")
        buffer[:] = remainder
        if line.startswith(b"token "):
            try:
                candidate = line[6:].decode("ascii")
            except UnicodeDecodeError:
                continue
            if re.fullmatch(r"[0-9a-f]{64}", candidate):
                target_token = candidate
        elif line.startswith(b"pgid "):
            try:
                candidate = int(line[5:])
            except ValueError:
                continue
            if candidate > 0:
                target_pgid = candidate
        elif line.startswith(b"status "):
            try:
                candidate = line[7:].decode("ascii")
            except UnicodeDecodeError:
                continue
            if candidate == _SUPERVISOR_STATUS_RESIDUAL or candidate in _SUPERVISOR_INTERNAL_STATUSES:
                supervisor_status = candidate
        elif line.startswith(b"child_returncode "):
            try:
                candidate = int(line[17:])
            except ValueError:
                continue
            if -255 <= candidate <= 255:
                child_returncode = candidate
        elif line == b"phase post_exit":
            supervisor_phase = _SUPERVISOR_PHASE_POST_EXIT
        elif line.startswith(b"residual "):
            if residual_handoff_seen:
                residual_handoff_invalid = True
                continue
            residual_handoff_seen = True
            candidate = _parse_residual_process_handoff(line[9:])
            if candidate is None:
                residual_handoff_invalid = True
            else:
                residual_processes = candidate
        else:
            try:
                candidate = int(line)
            except ValueError:
                continue
            if candidate > 0:
                target_pgid = candidate
    return (
        target_pgid, target_token, supervisor_status, supervisor_phase, child_returncode,
        residual_processes, residual_handoff_invalid, residual_handoff_seen,
    )


def _parse_residual_process_handoff(payload: bytes) -> dict[str, Any] | None:
    """Accept only a bounded identity-only residual snapshot from the supervisor."""
    if not payload or len(payload) > _RESIDUAL_HANDOFF_MAX_BYTES:
        return None
    try:
        decoded = payload.decode("ascii")
        candidate = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    required_fields = {
        "count", "processes", "truncated", "detected_after_child_exit_seconds",
        "cleanup_started_after_child_exit_seconds", "cleanup_finished_after_child_exit_seconds",
    }
    if not isinstance(candidate, dict) or set(candidate) != required_fields:
        return None
    count = candidate["count"]
    processes = candidate["processes"]
    truncated = candidate["truncated"]
    timing = {
        name: candidate[name]
        for name in (
            "detected_after_child_exit_seconds",
            "cleanup_started_after_child_exit_seconds",
            "cleanup_finished_after_child_exit_seconds",
        )
    }
    if type(count) is not int or not 0 <= count <= 1_000_000 or type(truncated) is not bool:
        return None
    if not isinstance(processes, list) or len(processes) > _RESIDUAL_PROCESS_LIMIT or count < len(processes):
        return None
    if truncated != (count > _RESIDUAL_PROCESS_LIMIT):
        return None
    if not truncated and count != len(processes):
        return None
    if any(type(value) not in (int, float) or not 0 <= value <= 86_400 for value in timing.values()):
        return None
    if not (
        timing["detected_after_child_exit_seconds"]
        <= timing["cleanup_started_after_child_exit_seconds"]
        <= timing["cleanup_finished_after_child_exit_seconds"]
    ):
        return None
    normalized: list[dict[str, int | str | bool]] = []
    for process in processes:
        if not isinstance(process, dict) or not {"pid", "ppid", "pgid"} <= set(process) <= {
            "pid", "ppid", "pgid", "executable", "executable_name_may_be_truncated", "elapsed_seconds"
        }:
            return None
        if any(type(process[name]) is not int or process[name] <= 0 for name in ("pid", "ppid", "pgid")):
            return None
        if "executable" in process and (
            not isinstance(process["executable"], str)
            or re.fullmatch(r"[A-Za-z0-9._+-]{1,128}", process["executable"]) is None
        ):
            return None
        if "executable_name_may_be_truncated" in process and process["executable_name_may_be_truncated"] is not True:
            return None
        if "elapsed_seconds" in process and (
            type(process["elapsed_seconds"]) is not int or process["elapsed_seconds"] < 0
        ):
            return None
        normalized.append(dict(process))
    if len({process["pid"] for process in normalized}) != len(normalized):
        return None
    return {"count": count, "truncated": truncated, "processes": normalized, **timing}


def _has_exact_target_token(command: str, target_token: str) -> bool:
    needle = f"{_TARGET_TOKEN_ENV}={target_token}"
    start = 0
    while True:
        index = command.find(needle, start)
        if index < 0:
            return False
        end = index + len(needle)
        if (index == 0 or command[index - 1].isspace()) and (end == len(command) or command[end].isspace()):
            return True
        start = end


def _process_rows_with_environment() -> list[tuple[int, int, int, int, str]] | None:
    """Return process metadata for exact-token cleanup; failures are fail-closed."""
    try:
        completed = subprocess.run(
            ["/bin/ps", "eww", "-axo", "pid=,ppid=,uid=,pgid=,command="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=_SUPERVISOR_CLEANUP_OVERHEAD_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    rows: list[tuple[int, int, int, int, str]] = []
    for line in completed.stdout.decode("utf-8", "replace").splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5:
            continue
        try:
            rows.append((int(fields[0]), int(fields[1]), int(fields[2]), int(fields[3]), fields[4]))
        except ValueError:
            continue
    return rows


def _token_pids(target_token: str) -> set[int] | None:
    rows = _process_rows_with_environment()
    if rows is None:
        return None
    parents = {pid: ppid for pid, ppid, _uid, _pgid, _command in rows}
    protected: set[int] = set()
    current = os.getpid()
    for _ in range(128):
        if current <= 1 or current in protected:
            break
        protected.add(current)
        current = parents.get(current, 0)
    return {
        pid
        for pid, _ppid, uid, _pgid, command in rows
        if uid == os.getuid() and pid not in protected and _has_exact_target_token(command, target_token)
    }


def _target_group_token_pids(target_pgid: int, target_token: str) -> set[int] | None:
    """Current same-user token members prove a PGID is still ours to signal."""
    rows = _process_rows_with_environment()
    if rows is None:
        return None
    return {
        pid
        for pid, _ppid, uid, pgid, command in rows
        if uid == os.getuid() and pgid == target_pgid and _has_exact_target_token(command, target_token)
    }


def _pids_gone(pids: set[int]) -> bool:
    for pid in pids:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            return False
        return False
    return True


def _pid_start_identity(pid: int) -> tuple[int, int] | None:
    """Return Darwin's public libproc start-time identity, or fail closed.

    PID values may be recycled between discovery and signalling.  The public
    ``proc_pidinfo(PROC_PIDTBSDINFO)`` fields are the smallest stable identity
    available to this helper; callers must not signal when they cannot read it.
    """
    if pid <= 0 or sys.platform != "darwin":
        return None

    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [
            ("_prefix", ctypes.c_uint32 * 12),
            ("_comm", ctypes.c_char * 16),
            ("_name", ctypes.c_char * 32),
            ("_middle", ctypes.c_uint32 * 5),
            ("_nice", ctypes.c_int32),
            ("pbi_start_tvsec", ctypes.c_uint64),
            ("pbi_start_tvusec", ctypes.c_uint64),
        ]

    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
        proc_pidinfo.restype = ctypes.c_int
        info = ProcBSDInfo()
        # PROC_PIDTBSDINFO is public in <libproc.h>.
        if proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            return None
        identity = (int(info.pbi_start_tvsec), int(info.pbi_start_tvusec))
        return identity if identity[0] >= 0 and identity[1] >= 0 else None
    except (AttributeError, OSError, TypeError, ValueError, ctypes.ArgumentError):
        return None


def _verified_token_identities(target_token: str) -> dict[int, tuple[int, int]] | None:
    """Snapshot exact-token candidates only when every PID has a start identity."""
    candidates = _token_pids(target_token)
    if candidates is None:
        return None
    identities: dict[int, tuple[int, int]] = {}
    for pid in candidates:
        identity = _pid_start_identity(pid)
        if identity is None:
            return None
        identities[pid] = identity
    return identities


def _signal_verified_identities(
    identities: dict[int, tuple[int, int]], signum: signal.Signals
) -> bool:
    """Signal only candidates whose start identity is unchanged immediately before use."""
    for pid, identity in identities.items():
        if _pid_start_identity(pid) != identity:
            return False
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            continue
        except PermissionError:
            return False
    return True


def _cleanup_target_token(target_token: str, termination_grace_seconds: float) -> str:
    """Return a fail-closed exact-token fallback cleanup outcome.

    A first empty process-table query is not evidence that the supervisor never
    launched a target.  In particular, it cannot prove cleanup after the
    supervisor has failed, so callers must preserve that uncertainty instead of
    reporting a successful cleanup.
    """
    identities = _verified_token_identities(target_token)
    if identities is None:
        return "fallback_unverified"
    if not identities:
        return "fallback_no_token_candidates"
    tracked = set(identities)
    if not _signal_verified_identities(identities, signal.SIGTERM):
        return "fallback_unverified"
    deadline = time.monotonic() + termination_grace_seconds
    while time.monotonic() < deadline:
        identities = _verified_token_identities(target_token)
        if identities is None:
            return "fallback_unverified"
        tracked.update(identities)
        if not identities and _pids_gone(tracked):
            return "fallback_cleaned"
        time.sleep(0.01)
    if identities is None:
        return "fallback_unverified"
    if not _signal_verified_identities(identities, signal.SIGKILL):
        return "fallback_unverified"
    deadline = time.monotonic() + termination_grace_seconds
    while time.monotonic() < deadline:
        identities = _verified_token_identities(target_token)
        if identities is None:
            return "fallback_unverified"
        tracked.update(identities)
        if not identities and _pids_gone(tracked):
            return "fallback_cleaned"
        time.sleep(0.01)
    identities = _verified_token_identities(target_token)
    if identities is None:
        return "fallback_unverified"
    return "fallback_cleaned" if not identities and _pids_gone(tracked) else "fallback_residual"


def _cleanup_target_group(
    target_pgid: int, target_token: str, termination_grace_seconds: float
) -> bool:
    """Drain current group members without ever signalling a bare process group."""
    for signum in (signal.SIGTERM, signal.SIGKILL):
        members = _target_group_token_pids(target_pgid, target_token)
        if members is None or not members:
            return False
        identities = _verified_token_identities(target_token)
        if identities is None or not members <= set(identities):
            return False
        if not _signal_verified_identities(
            {pid: identities[pid] for pid in members}, signum
        ):
            return False
        deadline = time.monotonic() + termination_grace_seconds
        while time.monotonic() < deadline:
            members = _target_group_token_pids(target_pgid, target_token)
            if members is None:
                return False
            if not members:
                return True
            time.sleep(0.01)
        members = _target_group_token_pids(target_pgid, target_token)
        if members is None:
            return False
        if not members:
            return True
        if signum == signal.SIGKILL:
            return False
    return False


def _append_parent_fallback_cleanup(
    cleanup: list[dict[str, str]],
    *,
    reason: str,
    target_pgid: int | None,
    target_token: str | None,
    termination_grace_seconds: float,
) -> None:
    """Record bounded exact-token fallback work after a supervisor failure."""
    cleanup.append({"signal": "fallback", "status": reason})
    if target_pgid is None:
        cleanup.append({"signal": "target_group", "status": "unknown"})
    elif target_token is None:
        cleanup.append({"signal": "target_group", "status": "unverified_token_unavailable"})
    else:
        group_clean = _cleanup_target_group(target_pgid, target_token, termination_grace_seconds)
        cleanup.append({
            "signal": "target_group",
            "status": "fallback_cleaned" if group_clean else "fallback_unverified_or_residual",
        })
    if target_token is None:
        cleanup.append({"signal": "target_token", "status": "unavailable_before_target_handoff"})
    else:
        cleanup.append({
            "signal": "target_token",
            "status": _cleanup_target_token(target_token, termination_grace_seconds),
        })


def _reported_returncode(
    process_returncode: int | None,
    supervisor_status: str | None,
    child_returncode: int | None,
    output_error: str | None,
) -> int | None:
    """Map supervisor-only outcomes only when their private handoff proves them."""
    if supervisor_status == _SUPERVISOR_STATUS_RESIDUAL:
        if child_returncode not in (None, 0):
            return child_returncode
        return _SUPERVISOR_RESIDUAL_EXIT
    if supervisor_status in _SUPERVISOR_INTERNAL_STATUSES:
        return _SUPERVISOR_INTERNAL_EXIT
    if output_error and process_returncode == 0:
        return _OUTPUT_DECODE_EXIT
    return process_returncode


class _BoundedTailCollector:
    """Keep a whole small stream or the bounded tail of a larger byte stream."""

    def __init__(self, limit: int = _OUTPUT_STREAM_MEMORY_LIMIT) -> None:
        self._limit = limit
        self._payload = bytearray()
        self._lock = threading.Lock()
        self.byte_count = 0
        self.truncated = False
        self.thread_error: str | None = None
        self._decoder = codecs.getincrementaldecoder("utf-8")("strict")
        self.invalid_utf8_offset: int | None = None
        self._decoder_finalized = False

    def append(self, chunk: bytes) -> None:
        if not chunk:
            return
        with self._lock:
            offset = self.byte_count
            self.byte_count += len(chunk)
            if self.invalid_utf8_offset is None and not self._decoder_finalized:
                try:
                    self._decoder.decode(chunk, final=False)
                except UnicodeDecodeError as error:
                    self.invalid_utf8_offset = offset + error.start
            if len(self._payload) + len(chunk) <= self._limit:
                self._payload.extend(chunk)
                return
            self.truncated = True
            if len(chunk) >= self._limit:
                self._payload[:] = chunk[-self._limit:]
                return
            remove = len(self._payload) + len(chunk) - self._limit
            if remove:
                del self._payload[:remove]
            self._payload.extend(chunk)

    def finish_utf8_validation(self) -> None:
        with self._lock:
            if self._decoder_finalized or self.invalid_utf8_offset is not None:
                return
            self._decoder_finalized = True
            try:
                self._decoder.decode(b"", final=True)
            except UnicodeDecodeError:
                self.invalid_utf8_offset = self.byte_count

    def payload(self) -> bytes:
        with self._lock:
            return bytes(self._payload)

    def decode_snapshot(self) -> tuple[bytes, int, bool, int | None]:
        with self._lock:
            return bytes(self._payload), self.byte_count, self.truncated, self.invalid_utf8_offset

    def metadata(self) -> dict[str, int | bool] | None:
        with self._lock:
            if not self.truncated:
                return None
            return {
                "truncated": True,
                "byte_count": self.byte_count,
                "retained_byte_count": len(self._payload),
            }


def _drain_stream(stream: Any, collector: _BoundedTailCollector) -> None:
    try:
        read_chunk = getattr(stream, "read1", stream.read)
        while True:
            chunk = read_chunk(_OUTPUT_READ_CHUNK_BYTES)
            if not chunk:
                return
            collector.append(chunk)
    except Exception as error:
        collector.thread_error = type(error).__name__


def _strict_decode_output(collector: _BoundedTailCollector, stream_name: str) -> tuple[str, str | None]:
    """Perform final strict decode in the caller and preserve a bounded safe tail."""
    collector.finish_utf8_validation()
    payload, byte_count, truncated, invalid_utf8_offset = collector.decode_snapshot()
    if invalid_utf8_offset is None:
        try:
            decoded = payload.decode("utf-8", "strict")
        except UnicodeDecodeError:
            # A bounded tail may begin halfway through a valid UTF-8 sequence.
            # Incremental validation above has already checked the full stream.
            if not truncated:
                raise
            decoded = payload.decode("utf-8", "replace")
        if truncated:
            marker = (
                f"[output truncated after {byte_count} bytes; "
                f"retaining final {len(payload)} bytes]\n"
            )
            return marker + decoded, None
        return decoded, None
    safe = payload.decode("utf-8", "replace")
    marker = ""
    if truncated:
        marker = (
            f"[output truncated after {byte_count} bytes; "
            f"retaining final {len(payload)} bytes]\n"
        )
    diagnostic = (
        f"{stream_name} contained invalid UTF-8 at byte {invalid_utf8_offset}; "
        f"replacement-safe tail: {safe[-_OUTPUT_DIAGNOSTIC_LIMIT:]}"
    )
    return marker + safe, diagnostic[-_OUTPUT_DIAGNOSTIC_LIMIT:]


def _output_truncation_metadata(
    stdout_collector: _BoundedTailCollector, stderr_collector: _BoundedTailCollector
) -> dict[str, dict[str, int | bool]] | None:
    metadata = {
        name: values
        for name, collector in (("stdout", stdout_collector), ("stderr", stderr_collector))
        if (values := collector.metadata()) is not None
    }
    return metadata or None


def _build_diagnostic(stdout: str, stderr: str) -> str:
    """Return a bounded, actionable build tail from both compiler streams."""
    def bounded(value: str) -> str:
        if len(value) <= _OUTPUT_DIAGNOSTIC_LIMIT:
            return value
        marker = "\n... diagnostic truncated ...\n"
        available = _OUTPUT_DIAGNOSTIC_LIMIT - len(marker)
        head = max(1, available // 2)
        return value[:head] + marker + value[-(available - head):]

    combined = stdout + ("\n" if stdout and stderr else "") + stderr
    lines = combined.splitlines()
    concrete_error_indices = [
        index for index, line in enumerate(lines)
        if re.search(r"(?:fatal error:|\berror:)", line, re.IGNORECASE)
    ]
    error_indices = concrete_error_indices or [
        index for index, line in enumerate(lines)
        if re.search(r"BUILD FAILED", line, re.IGNORECASE)
    ]
    if error_indices:
        index = error_indices[-1]
        priority = "\n".join(lines[max(0, index - 2):index + 1])
        separator = "\n--- tail ---\n"
        if len(priority) + len(separator) >= _OUTPUT_DIAGNOSTIC_LIMIT:
            return bounded(priority)
        tail_budget = _OUTPUT_DIAGNOSTIC_LIMIT - len(priority) - len(separator)
        tail = combined[-tail_budget:] if tail_budget else ""
        return bounded(priority + separator + tail)
    return bounded(combined[-_OUTPUT_DIAGNOSTIC_LIMIT:])


def _controlled_xctestrun_command(command: list[str]) -> tuple[int, Path]:
    """Validate the one supported app-hosted XCTest argv shape without a shell."""
    if not isinstance(command, list) or not command or any(
        not isinstance(value, str) or not value or "\0" in value or value.startswith("@")
        for value in command
    ):
        raise ValueError("controlled XCTest requires a non-empty literal argv without response files")
    if command[0] != "xcodebuild" or len(command) < 4 or command[1] != "test-without-building":
        raise ValueError("controlled XCTest only accepts xcodebuild test-without-building")
    value_options = {
        "-xctestrun",
        "-destination",
        "-resultBundlePath",
        "-parallel-testing-enabled",
        "-test-timeouts-enabled",
        "-default-test-execution-time-allowance",
        "-maximum-test-execution-time-allowance",
    }
    boolean_options = {"-parallel-testing-enabled", "-test-timeouts-enabled"}
    numeric_options = {
        "-default-test-execution-time-allowance",
        "-maximum-test-execution-time-allowance",
    }
    seen_options: set[str] = set()
    seen_selectors: set[str] = set()
    path_index: int | None = None
    index = 2
    while index < len(command):
        argument = command[index]
        if argument == "-quiet":
            if argument in seen_options:
                raise ValueError("controlled XCTest option is duplicated: -quiet")
            seen_options.add(argument)
            index += 1
            continue
        if argument.startswith("-only-testing:"):
            selector = argument.removeprefix("-only-testing:")
            if not selector or re.fullmatch(r"[A-Za-z0-9_./-]+", selector) is None:
                raise ValueError("controlled XCTest selector is malformed")
            if selector in seen_selectors:
                raise ValueError("controlled XCTest selector is duplicated")
            seen_selectors.add(selector)
            index += 1
            continue
        if argument not in value_options:
            raise ValueError(f"controlled XCTest argument is not allowed: {argument}")
        if argument in seen_options:
            raise ValueError(f"controlled XCTest option is duplicated: {argument}")
        if index + 1 >= len(command):
            raise ValueError(f"controlled XCTest option requires a value: {argument}")
        value = command[index + 1]
        if value.startswith("-"):
            raise ValueError(f"controlled XCTest option has an invalid value: {argument}")
        if argument in boolean_options and value not in {"YES", "NO"}:
            raise ValueError(f"controlled XCTest boolean option is malformed: {argument}")
        if argument in numeric_options:
            try:
                numeric_value = float(value)
            except ValueError as error:
                raise ValueError(f"controlled XCTest timeout option is malformed: {argument}") from error
            if not math.isfinite(numeric_value) or numeric_value <= 0:
                raise ValueError(f"controlled XCTest timeout option is malformed: {argument}")
        seen_options.add(argument)
        if argument == "-xctestrun":
            path_index = index + 1
        index += 2
    if path_index is None:
        raise ValueError("controlled XCTest requires exactly one -xctestrun")
    xctestrun = Path(command[path_index])
    if not xctestrun.is_absolute() or xctestrun.suffix != ".xctestrun" or not xctestrun.is_file():
        raise ValueError("controlled XCTest xctestrun path must name an existing .xctestrun file")
    return path_index, xctestrun.resolve()


def _inject_controlled_xctest_environment(xctestrun: Path, token: str) -> Path:
    """Write a private sibling plist copy while preserving __TESTROOT__ anchors."""
    original = xctestrun.read_bytes()
    payload = plistlib.loads(original)
    configurations = payload.get("TestConfigurations") if isinstance(payload, dict) else None
    if not isinstance(configurations, list):
        raise ValueError("xctestrun TestConfigurations is malformed")
    injected_targets = 0
    for configuration in configurations:
        if not isinstance(configuration, dict):
            raise ValueError("xctestrun TestConfigurations contains a malformed configuration")
        enabled = configuration.get("IsEnabled", True)
        if type(enabled) is not bool:
            raise ValueError("xctestrun configuration enablement is malformed")
        if not enabled:
            continue
        targets = configuration.get("TestTargets")
        if not isinstance(targets, list):
            raise ValueError("enabled xctestrun configuration has malformed TestTargets")
        for target in targets:
            if not isinstance(target, dict):
                raise ValueError("xctestrun TestTargets contains a malformed target")
            target_enabled = target.get("IsEnabled", True)
            if type(target_enabled) is not bool:
                raise ValueError("xctestrun target enablement is malformed")
            if not target_enabled:
                continue
            environments = ["EnvironmentVariables"]
            if "TestingEnvironmentVariables" in target:
                environments.append("TestingEnvironmentVariables")
            for name in environments:
                values = target.get(name, {})
                if not isinstance(values, dict) or any(
                    not isinstance(key, str) or not isinstance(value, str)
                    for key, value in values.items()
                ):
                    raise ValueError(f"xctestrun {name} is malformed")
                if _TARGET_TOKEN_ENV in values or _XCTEST_REQUIRE_PROBE_ENV in values:
                    raise ValueError(f"xctestrun {name} conflicts with controlled XCTest identity")
                target[name] = {
                    **values,
                    _TARGET_TOKEN_ENV: token,
                    _XCTEST_REQUIRE_PROBE_ENV: "1",
                }
            injected_targets += 1
    if injected_targets == 0:
        raise ValueError("xctestrun contains no enabled test target")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{xctestrun.stem}.controlled-", suffix=".xctestrun", dir=xctestrun.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(descriptor, "wb") as stream:
            plistlib.dump(payload, stream, sort_keys=False)
        return temporary
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise


def run_controlled_xcode_test(
    command: list[str], *, cwd: Path, timeout: int | float, termination_grace_seconds: float = 0.5
) -> dict[str, Any]:
    """Run one app-hosted XCTest xctestrun with a probeable exact-token identity."""
    try:
        path_index, xctestrun = _controlled_xctestrun_command(command)
        token = secrets.token_hex(32)
        temporary = _inject_controlled_xctest_environment(xctestrun, token)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        return {
            "ok": False,
            "returncode": None,
            "stdout": "",
            "stderr": "",
            "timed_out": False,
            "process_cleanup": {"status": "controlled_xctest_rejected", "diagnostic": str(error)},
        }
    try:
        controlled_command = list(command)
        controlled_command[path_index] = str(temporary)
        result = run_controlled_subprocess(
            controlled_command,
            cwd=cwd,
            timeout=timeout,
            termination_grace_seconds=termination_grace_seconds,
            _target_token=token,
        )
        if result.get("timed_out"):
            # A timeout is never evidence that a token-scrubbing app host was cleaned.
            result.setdefault("process_cleanup", {"status": "timeout_cleanup_unverified_or_residual"})
        return result
    finally:
        temporary.unlink(missing_ok=True)


def run_controlled_subprocess(
    command: list[str], *, cwd: Path, timeout: int | float, termination_grace_seconds: float = 0.5,
    _target_token: str | None = None,
) -> dict[str, Any]:
    """Run a trusted target with bounded cleanup of retained inherited identity.

    This is deliberately not an OS sandbox.  A target that actively scrubs the
    inherited token needs OS-level isolation and is outside this helper's P5
    verification threat model.
    """
    if _target_token is not None and re.fullmatch(r"[0-9a-f]{64}", _target_token) is None:
        raise ValueError("controlled target token must be 256-bit lowercase hexadecimal")
    inherited_supervisor = _inherited_controlled_supervisor()
    inherited_timeout_fd = _inherited_timeout_handoff_fd() if inherited_supervisor is not None else None
    environment = os.environ.copy()
    timeout_read_fd: int | None = None
    timeout_write_fd: int | None = None
    target_read_fd: int | None = None
    target_write_fd: int | None = None
    timeout_marker: str | None = None
    if inherited_supervisor is None:
        timeout_read_fd, timeout_write_fd = os.pipe()
        target_read_fd, target_write_fd = os.pipe()
        for descriptor in (timeout_write_fd, target_write_fd):
            os.set_inheritable(descriptor, True)
        marker_fd, timeout_marker = tempfile.mkstemp(prefix="blocks-verification-timeout-")
        os.close(marker_fd); os.unlink(timeout_marker)
        environment.update({
            _CONTROLLED_TIMEOUT_FD_ENV: str(timeout_write_fd),
            _CONTROLLED_TARGET_FD_ENV: str(target_write_fd),
            _CONTROLLED_TIMEOUT_MARKER_ENV: timeout_marker,
        })
        os.set_blocking(timeout_read_fd, False); os.set_blocking(target_read_fd, False)
        launched_command = [
            sys.executable, "-c", _SUPERVISOR_PROGRAM, json.dumps(command),
            str(termination_grace_seconds), json.dumps(_target_token),
        ]
        pass_fds = (timeout_write_fd, target_write_fd)
    else:
        launched_command = command
        pass_fds = () if inherited_timeout_fd is None else (inherited_timeout_fd,)
        timeout_marker = os.environ.get(_CONTROLLED_TIMEOUT_MARKER_ENV)

    process = subprocess.Popen(
        launched_command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=inherited_supervisor is None, env=environment, pass_fds=pass_fds,
    )
    for descriptor in (timeout_write_fd, target_write_fd):
        if descriptor is not None:
            os.close(descriptor)
    stdout_collector = _BoundedTailCollector()
    stderr_collector = _BoundedTailCollector()
    stdout_thread = threading.Thread(
        target=_drain_stream, args=(process.stdout, stdout_collector), daemon=True
    )
    stderr_thread = threading.Thread(
        target=_drain_stream, args=(process.stderr, stderr_collector), daemon=True
    )
    stdout_thread.start(); stderr_thread.start()
    cleanup: list[dict[str, str]] = []
    target_pgid: int | None = None
    target_token: str | None = None
    supervisor_status: str | None = None
    supervisor_phase: str | None = None
    child_returncode: int | None = None
    residual_processes: dict[str, Any] | None = None
    residual_handoff_invalid = False
    residual_handoff_seen = False
    target_buffer = bytearray()

    def consume_target_handoff() -> None:
        nonlocal target_pgid, target_token, supervisor_status, supervisor_phase, child_returncode
        nonlocal residual_processes, residual_handoff_invalid, residual_handoff_seen
        for descriptor in (timeout_read_fd, target_read_fd):
            if descriptor is not None:
                _read_available_fd(descriptor, target_buffer)
        (
            target_pgid, target_token, supervisor_status, supervisor_phase, child_returncode,
            residual_processes, residual_handoff_invalid, residual_handoff_seen,
        ) = _consume_target_handoff(
            target_buffer, target_pgid, target_token, supervisor_status, supervisor_phase, child_returncode,
            residual_processes, residual_handoff_invalid, residual_handoff_seen,
        )

    def collect_output() -> tuple[str, str, str | None, dict[str, dict[str, int | bool]] | None]:
        stdout, stdout_decode_error = _strict_decode_output(stdout_collector, "stdout")
        stderr, stderr_decode_error = _strict_decode_output(stderr_collector, "stderr")
        output_error = stdout_decode_error or stderr_decode_error
        thread_errors = [
            f"{name} drain failed: {collector.thread_error}"
            for name, collector in (("stdout", stdout_collector), ("stderr", stderr_collector))
            if collector.thread_error is not None
        ]
        if thread_errors:
            output_error = output_error or "; ".join(thread_errors)
        return stdout, stderr, output_error, _output_truncation_metadata(stdout_collector, stderr_collector)

    def attach_output_metadata(
        result: dict[str, Any],
        *,
        output_error: str | None,
        truncation: dict[str, dict[str, int | bool]] | None,
    ) -> None:
        if output_error:
            result["output_diagnostic"] = output_error
        if truncation:
            result["output_truncation"] = truncation

    try:
        if inherited_supervisor is None:
            try:
                supervisor_is_leader = os.getsid(process.pid) == process.pid and os.getpgid(process.pid) == process.pid
            except ProcessLookupError:
                supervisor_is_leader = process.poll() is not None
            if not supervisor_is_leader:
                raise RuntimeError("controlled supervisor did not become its own session/process-group leader")
        deadline = time.monotonic() + timeout
        handoff_deadline: float | None = None
        post_exit_deadline: float | None = None
        while process.poll() is None:
            if supervisor_phase == _SUPERVISOR_PHASE_POST_EXIT and post_exit_deadline is None:
                post_exit_deadline = time.monotonic() + _supervisor_cleanup_budget(termination_grace_seconds)
            active_deadline = post_exit_deadline or deadline
            remaining = active_deadline - time.monotonic()
            if remaining <= 0:
                if inherited_supervisor is None:
                    consume_target_handoff()
                    if supervisor_phase == _SUPERVISOR_PHASE_POST_EXIT:
                        post_exit_deadline = post_exit_deadline or (
                            time.monotonic() + _supervisor_cleanup_budget(termination_grace_seconds)
                        )
                        continue
                raise subprocess.TimeoutExpired(command, timeout)
            if timeout_marker is not None and os.path.exists(timeout_marker):
                handoff_deadline = handoff_deadline or time.monotonic() + termination_grace_seconds
            if handoff_deadline is not None:
                remaining = min(remaining, handoff_deadline - time.monotonic())
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
            readable = [fd for fd in (timeout_read_fd, target_read_fd) if fd is not None]
            ready, _, _ = select.select(readable, [], [], min(remaining, 0.05)) if readable else ([], [], [])
            for descriptor in ready:
                if descriptor == timeout_read_fd:
                    if os.read(descriptor, 128):
                        handoff_deadline = time.monotonic() + termination_grace_seconds
                else:
                    _read_available_fd(descriptor, target_buffer)
                    (
                        target_pgid, target_token, supervisor_status, supervisor_phase, child_returncode,
                        residual_processes, residual_handoff_invalid, residual_handoff_seen,
                    ) = _consume_target_handoff(
                        target_buffer, target_pgid, target_token, supervisor_status, supervisor_phase, child_returncode,
                        residual_processes, residual_handoff_invalid, residual_handoff_seen,
                    )
        if inherited_supervisor is not None and timeout_marker is not None and os.path.exists(timeout_marker):
            raise subprocess.TimeoutExpired(command, timeout)
        consume_target_handoff()
        if inherited_supervisor is None and supervisor_status in _SUPERVISOR_INTERNAL_STATUSES:
            _append_parent_fallback_cleanup(
                cleanup,
                reason=supervisor_status,
                target_pgid=target_pgid,
                target_token=target_token,
                termination_grace_seconds=termination_grace_seconds,
            )
        output_join_timeout = max(termination_grace_seconds, deadline - time.monotonic())
        stdout_thread.join(timeout=output_join_timeout)
        stderr_thread.join(timeout=output_join_timeout)
        if stdout_thread.is_alive() or stderr_thread.is_alive():
            raise subprocess.TimeoutExpired(command, timeout)
        stdout, stderr, output_error, truncation = collect_output()
        result: dict[str, Any] = {
            "ok": process.returncode == 0 and output_error is None and supervisor_status not in _SUPERVISOR_INTERNAL_STATUSES,
            "returncode": _reported_returncode(
                process.returncode, supervisor_status, child_returncode, output_error
            ),
            "stdout": stdout,
            "stderr": stderr,
            "timed_out": False,
        }
        if supervisor_status == _SUPERVISOR_STATUS_RESIDUAL:
            process_cleanup: dict[str, Any] = {
                "status": "target_group_residual_cleaned",
                "target_pgid": target_pgid,
            }
            if child_returncode is not None:
                process_cleanup["child_returncode"] = child_returncode
            if residual_handoff_seen and not residual_handoff_invalid and residual_processes is not None:
                # This is the pre-cleanup snapshot; later cleanup intentionally may change it.
                process_cleanup["residual_processes"] = residual_processes["processes"]
                process_cleanup["residual_process_count"] = residual_processes["count"]
                process_cleanup["residual_processes_truncated"] = residual_processes["truncated"]
                process_cleanup["residual_detected_after_child_exit_seconds"] = residual_processes[
                    "detected_after_child_exit_seconds"
                ]
                process_cleanup["residual_cleanup_started_after_child_exit_seconds"] = residual_processes[
                    "cleanup_started_after_child_exit_seconds"
                ]
                process_cleanup["residual_cleanup_finished_after_child_exit_seconds"] = residual_processes[
                    "cleanup_finished_after_child_exit_seconds"
                ]
            result["process_cleanup"] = process_cleanup
        elif supervisor_status in _SUPERVISOR_INTERNAL_STATUSES:
            result["process_cleanup"] = {
                "status": supervisor_status,
                "target_pgid": target_pgid,
                "fallback": cleanup,
            }
            result["cleanup"] = cleanup
        elif output_error:
            result["process_cleanup"] = {"status": "invalid_utf8_output", "diagnostic": output_error}
        attach_output_metadata(result, output_error=output_error, truncation=truncation)
        return result
    except subprocess.TimeoutExpired:
        if inherited_supervisor is None:
            consume_target_handoff()
        if inherited_supervisor is not None:
            try:
                if inherited_timeout_fd is None: raise OSError("unverified handoff fd")
                os.write(inherited_timeout_fd, b"timeout\n")
                Path(os.environ[_CONTROLLED_TIMEOUT_MARKER_ENV]).touch()
                cleanup.append({"signal": "handoff", "status": "requested"})
            except (KeyError, OSError):
                cleanup.append({"signal": "handoff", "status": "unavailable"})
            stdout, stderr, output_error, truncation = collect_output()
            result = {"ok": False, "returncode": process.returncode, "stdout": stdout, "stderr": stderr, "timed_out": True, "process_cleanup": cleanup, "cleanup": cleanup}
            attach_output_metadata(result, output_error=output_error, truncation=truncation)
            return result

        def control_supervisor() -> bool:
            try:
                if os.getsid(process.pid) != process.pid or os.getpgid(process.pid) != process.pid:
                    cleanup.append({"signal": "SIGUSR1", "status": "supervisor_not_leader"}); return False
                os.kill(process.pid, signal.SIGUSR1)
                cleanup.append({"signal": "SIGUSR1", "status": "supervisor_requested"}); return True
            except (ProcessLookupError, PermissionError):
                cleanup.append({"signal": "SIGUSR1", "status": "supervisor_unavailable"}); return False
        control_supervisor()
        # The fixed supervisor can need five signal/reap intervals plus bounded
        # process-table observation at their edges.  Do not preempt its token owner.
        supervisor_wait_budget = _supervisor_cleanup_budget(termination_grace_seconds)
        try:
            process.wait(timeout=supervisor_wait_budget + termination_grace_seconds)
        except subprocess.TimeoutExpired:
            cleanup.append({"signal": "wait", "status": "supervisor_cleanup_budget_elapsed"})
            cleanup.append({"signal": "SIGKILL", "status": "supervisor_fallback"})
            try: os.kill(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError): pass
            try:
                process.wait(timeout=max(termination_grace_seconds, 0.1))
                cleanup.append({"signal": "wait", "status": "supervisor_reaped"})
            except subprocess.TimeoutExpired:
                cleanup.append({"signal": "wait", "status": "supervisor_reap_failed"})
            consume_target_handoff()
            _append_parent_fallback_cleanup(
                cleanup,
                reason="supervisor_timeout_fallback",
                target_pgid=target_pgid,
                target_token=target_token,
                termination_grace_seconds=termination_grace_seconds,
            )
        else:
            consume_target_handoff()
            if supervisor_status in _SUPERVISOR_INTERNAL_STATUSES:
                _append_parent_fallback_cleanup(
                    cleanup,
                    reason=supervisor_status,
                    target_pgid=target_pgid,
                    target_token=target_token,
                    termination_grace_seconds=termination_grace_seconds,
                )
        stdout_thread.join(timeout=termination_grace_seconds); stderr_thread.join(timeout=termination_grace_seconds)
        stdout, stderr, output_error, truncation = collect_output()
        result = {"ok": False, "returncode": process.returncode, "stdout": stdout, "stderr": stderr, "timed_out": True, "process_cleanup": cleanup, "cleanup": cleanup}
        attach_output_metadata(result, output_error=output_error, truncation=truncation)
        return result
    finally:
        for descriptor in (timeout_read_fd, target_read_fd):
            if descriptor is not None:
                try: os.close(descriptor)
                except OSError: pass
        if timeout_marker is not None and inherited_supervisor is None:
            try: os.unlink(timeout_marker)
            except FileNotFoundError: pass


def run_blocks_no_launch_build(root: Path, timeout: int, gate_name: str) -> dict[str, Any]:
    safe_gate_name = re.sub(r"[^a-z0-9-]+", "-", gate_name.lower()).strip("-") or "gate"
    with tempfile.TemporaryDirectory(prefix=f"blocks-{safe_gate_name}-derived-data-") as derived_data:
        completed = run_controlled_subprocess([
            "xcodebuild", "-project", str(root / "apps" / "Blocks" / "Blocks.xcodeproj"), "-scheme", "Blocks",
            "-configuration", "Debug", "-derivedDataPath", derived_data, "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "-quiet", "build",
        ], cwd=root, timeout=timeout, termination_grace_seconds=_XCODEBUILD_TERMINATION_GRACE_SECONDS)
        if completed["timed_out"]:
            result = {"ok": False, "returncode": completed["returncode"], "stdout": completed["stdout"], "stderr_tail": f"xcodebuild timed out after {timeout}s", "mode": "isolated_xcodebuild_no_launch", "launched_app": False, "killed_app": False, "timed_out": True}
        else:
            result = {"ok": completed["ok"], "returncode": completed["returncode"], "stdout": completed["stdout"], "stderr_tail": _build_diagnostic(completed["stdout"], completed["stderr"]), "mode": "isolated_xcodebuild_no_launch", "launched_app": False, "killed_app": False, "timed_out": completed["timed_out"]}
        if "process_cleanup" in completed:
            result["process_cleanup"] = completed["process_cleanup"]
        if "output_diagnostic" in completed:
            result["output_diagnostic"] = completed["output_diagnostic"]
        if "output_truncation" in completed:
            result["output_truncation"] = completed["output_truncation"]
        return result
