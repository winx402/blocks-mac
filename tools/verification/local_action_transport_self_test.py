"""Isolated UDS framing/FD/lifecycle tests. Trust shim is NOT signing proof."""
import array
import concurrent.futures
import os
import pathlib
import pwd
import socket
import struct
import subprocess
import sys
import tempfile
import time

EXE = sys.argv[1]
HEADER = struct.Struct("!4sBBBBII")

def frame(data=b"", op=0, fdcount=0, timeout=1000, length=None):
    return HEADER.pack(b"BLAC", 1, op, fdcount, 0, len(data) if length is None else length, timeout) + data

def connect(path):
    peer = socket.socket(socket.AF_UNIX)
    peer.settimeout(4)
    peer.connect(str(path / "action.sock"))
    return peer

def exact(peer, count):
    out = bytearray()
    while len(out) < count:
        part = peer.recv(count - len(out))
        assert part, "unexpected EOF"
        out.extend(part)
    return out

def exchange(path, data=b"", op=0, fd=None):
    with connect(path) as peer:
        packet = frame(data, op, int(fd is not None), timeout=12000)
        if fd is None:
            peer.sendall(packet)
        else:
            sent = peer.sendmsg([packet], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
            peer.sendall(packet[sent:])
        h = HEADER.unpack(exact(peer, 16))
        assert h[:5] == (b"BLAC", 1, op | 128, 0, 0), h
        return exact(peer, h[5])

def rejected(path, packet, fds=()):
    with connect(path) as peer:
        if fds:
            peer.sendmsg([packet], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
        else:
            peer.sendall(packet)
        try:
            assert peer.recv(1) == b""
        except ConnectionResetError:
            pass

def start(path, *flags):
    process = subprocess.Popen([EXE, "server", str(path), *flags], stdout=subprocess.PIPE, text=True)
    assert process.stdout.readline().strip() == "ready"
    return process

def client(path, payload, *flags):
    return subprocess.run([EXE, "client", str(path), payload, *flags], text=True, capture_output=True)

with tempfile.TemporaryDirectory(prefix=".bact-", dir=pwd.getpwuid(os.getuid()).pw_dir) as root:
    root = pathlib.Path(root)
    path = root / "Actions"
    process = start(path)
    try:
        assert exchange(path) == b"probe"
        assert exchange(path, b"one", 1) == b"one"
        assert exchange(path, b"cancel-id", 3) == b"cancel-id"
        assert client(path, "hello").stdout.strip() == "hello"
        assert client(path, "hello", "--reject-app").stdout.strip() == "untrustedPeer"
        assert client(path, "hello", "--wrong-user").stdout.strip() == "untrustedPeer"
        assert client(path, "stall").stdout.strip() == "timedOut"
        assert exchange(path, b"x" * (36 * 1024 * 1024), 2) == b"x" * (36 * 1024 * 1024)
        output = root / "output"
        with output.open("wb") as handle:
            assert exchange(path, b"binary\x00output", 2, handle.fileno()) == b"binary\x00output"
            assert output.read_bytes() == b"binary\x00output"
            baseline = int(exchange(path, b"fds"))
            for _ in range(32):
                rejected(path, frame(b"bad", 2, 1), (handle.fileno(), handle.fileno()))
            time.sleep(0.1)
            assert int(exchange(path, b"fds")) <= baseline
            rejected(path, frame(b"bad", 0, 1), (handle.fileno(),))
            rejected(path, frame(b"bad", 2, 0), (handle.fileno(),))
            rejected(path, frame(b"bad", 2, 1))
        with output.open("rb") as handle:
            rejected(path, frame(b"bad", 2, 1), (handle.fileno(),))
        # An async action owns its duplicate FD independently of the socket.
        with output.open("wb") as handle:
            with connect(path) as peer:
                peer.sendmsg([frame(b"late-write", 2, 1, timeout=100)],
                             [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [handle.fileno()]))])
                assert peer.recv(1) == b""
            time.sleep(0.5)
            assert output.read_bytes() == b"retained-after-timeout"
        with output.open("wb") as handle:
            with connect(path) as peer:
                peer.sendmsg([frame(b"late-write", 2, 1)],
                             [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [handle.fileno()]))])
                time.sleep(0.1)
            time.sleep(0.5)
            assert output.read_bytes() == b"retained-after-timeout"
        rejected(path, frame(length=36 * 1024 * 1024 + 1))
        rejected(path, frame(op=99))
        rejected(path, frame(timeout=600001))
        rejected(path, b"BAD!" + frame()[4:])
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            assert list(pool.map(lambda n: exchange(path, str(n).encode()), range(24))) == [str(n).encode() for n in range(24)]
        idle_peers = [connect(path) for _ in range(8)]
        try:
            time.sleep(0.15)
            with connect(path) as excess:
                assert excess.recv(1) == b"", "connection cap not enforced"
        finally:
            for peer in idle_peers:
                peer.close()
        time.sleep(0.1)
        with connect(path) as idle:
            t = time.monotonic()
            assert idle.recv(1) == b""
            assert time.monotonic() - t < 3.8
        # Existing connections are fenced if a same-user endpoint is substituted.
        with connect(path) as peer:
            time.sleep(0.05)
            os.rename(path / "action.sock", path / "old.sock")
            replacement = socket.socket(socket.AF_UNIX)
            replacement.bind(str(path / "action.sock"))
            os.chmod(path / "action.sock", 0o600)
            peer.sendall(frame())
            assert peer.recv(1) == b""
            replacement.close()
    finally:
        process.terminate(); process.wait(timeout=5)
    for flag in ("--reject-cli", "--wrong-user"):
        p = start(root / flag[2:], flag)
        try:
            rejected(root / flag[2:], frame())
        finally:
            p.terminate(); p.wait(timeout=5)
    symlink = root / "symlink"
    symlink.symlink_to(path, target_is_directory=True)
    assert subprocess.run([EXE, "server", str(symlink)], capture_output=True).returncode == 2
    for entry in ("listener.lock", "action.sock"):
        unsafe = root / ("bad-" + entry)
        unsafe.mkdir(mode=0o700)
        (unsafe / entry).symlink_to(root / "output")
        assert subprocess.run([EXE, "server", str(unsafe)], capture_output=True).returncode == 2
    insecure = root / "insecure"
    insecure.mkdir(mode=0o755)
    assert subprocess.run([EXE, "server", str(insecure)], capture_output=True).returncode == 2
    long_path = root / ("z" * 110)
    assert subprocess.run([EXE, "server", str(long_path)], capture_output=True).returncode == 2
    assert client(root / "missing", "hello").stdout.strip() == "unavailable"
    result = subprocess.run([EXE, "lifecycle", str(root / "lifecycle")], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    print("PASS: roundtrip, 36MiB, FD transfer/leaks/rejection, trust shim, timeout, concurrency, substitution, symlink, lifecycle, formal exclusion")
