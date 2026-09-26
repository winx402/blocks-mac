#!/usr/bin/env python3
"""Exercise the production relaunch handoff in disposable macOS app processes.

No TCC access, user content, or installed Blocks process is involved. The second
launch exits immediately. A unique sandbox container retains only probe evidence.
"""
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

HARNESS = r'''
import AppKit
enum PermissionRestartResult { case scheduled, failed }
@MainActor protocol PermissionSystemActioning {}
'''

DRIVER = r'''
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var actions: DefaultPermissionSystemActions?
    private var marker: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier! + ".json")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let previous = (try? Data(contentsOf: marker)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let count = (previous?["launches"] as? Int ?? 0) + 1
        let firstPID = previous?["firstPID"] as? Int ?? Int(getpid())
        let parentGone: Bool
        if count == 1 { parentGone = false }
        else {
            errno = 0
            parentGone = kill(pid_t(firstPID), 0) == -1 && errno == ESRCH
        }
        let evidence: [String: Any] = ["launches": count, "firstPID": firstPID,
            "currentPID": Int(getpid()), "parentGone": parentGone]
        try! FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: evidence).write(to: marker, options: .atomic)
        if count == 1 {
            actions = DefaultPermissionSystemActions()
            actions!.restartForPermissionRefresh { result in
                if case .failed = result { NSApp.terminate(nil) }
            }
        } else { NSApp.terminate(nil) }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = ProbeDelegate()
    app.delegate = delegate
    app.run()
}
'''


def run_probe(sandbox: bool) -> dict:
    identifier = "app.blocks.restartprobe." + uuid.uuid4().hex
    support = Path.home() / "Library/Application Support"
    if sandbox:
        support = Path.home() / "Library/Containers" / identifier / "Data/Library/Application Support"
    marker = support / (identifier + ".json")
    source = (ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift").read_text()
    production = source[source.index("@MainActor\nstruct DefaultPermissionSystemActions:"):]
    with tempfile.TemporaryDirectory(prefix="blocks-permission-restart-probe-") as directory:
        root = Path(directory)
        app = root / "Restart Probe.app"
        contents = app / "Contents"
        executable = contents / "MacOS/RestartProbe"
        executable.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "RestartProbe",
            "CFBundleName": "Blocks Restart Probe", "CFBundlePackageType": "APPL",
            "LSUIElement": True, "NSPrincipalClass": "NSApplication",
        }))
        swift = root / "main.swift"
        swift.write_text(HARNESS + production + DRIVER)
        relaunch_source = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionRelaunchProcess.swift"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(swift), str(relaunch_source), "-o", str(executable)], check=True)
        command = ["codesign", "--force", "--sign", "-"]
        if sandbox:
            entitlements = root / "probe.entitlements"
            entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
            command += ["--entitlements", str(entitlements)]
        subprocess.run(command + [str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
        try:
            subprocess.run(["open", str(app)], check=True)
            deadline = time.monotonic() + 25
            evidence = {}
            while time.monotonic() < deadline:
                try:
                    evidence = json.loads(marker.read_text())
                    if evidence.get("launches", 0) >= 2:
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(0.1)
            assert evidence.get("launches") == 2, ("relaunch did not complete", sandbox, evidence, str(marker))
            assert evidence.get("parentGone") is True, ("old process still existed", evidence)
            assert evidence["firstPID"] != evidence["currentPID"], evidence
            # Do not remove a bundle while its disposable process still exists.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(evidence["currentPID"], 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("probe's second process did not exit")
            return {"sandbox": sandbox, "passed": True, "evidence": str(marker), **evidence}
        finally:
            # Teardown only processes still executing this unique probe binary.
            try:
                recorded = json.loads(marker.read_text())
            except (OSError, ValueError):
                recorded = {}
            for pid in {recorded.get("firstPID"), recorded.get("currentPID")} - {None}:
                if not isinstance(pid, int) or pid <= 0:
                    continue
                current = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
                if current.stdout.strip() == str(executable):
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True)


if __name__ == "__main__":
    for sandbox in (False, True):
        print(json.dumps(run_probe(sandbox), sort_keys=True), flush=True)
