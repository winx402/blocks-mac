#!/usr/bin/env python3
"""Exercise the production relaunch handoff in disposable macOS app processes.

No TCC access, user content, or installed Blocks process is involved. The second
launch exits immediately. A unique sandbox container retains only probe evidence.
"""
import json
import argparse
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
import OSLog
enum PermissionRestartResult { case scheduled, failed }
@MainActor protocol PermissionSystemActioning {}
// The disposable process has no business participants or diagnostic store.
// Keep the real termination coordinator, with no-op sinks for unrelated quit
// telemetry and private processes. Permission preparation is injected below.
struct FeedbackShutdownEvent: Sendable {
    init(attemptID: UUID, phase: String, participant: String, code: String,
         elapsedMS: Int, forced: Bool, activeOperations: Int) {}
}
final class FeedbackStore: @unchecked Sendable {
    static let shared = FeedbackStore()
    func recordShutdownEvent(_ event: FeedbackShutdownEvent) throws {}
}
enum ShutdownPrivateProcesses { static func terminateRegisteredProcesses() {} }
enum ApplicationOperationAdmissionGate { static func closeAdmissionForQuit() {} }
'''

DRIVER = r'''
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var actions: DefaultPermissionSystemActions?
    private var isFirstLaunch = false
    private let termination = AppTerminationCoordinator(replyHandler: { NSApp.reply(toApplicationShouldTerminate: $0) })
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
        var evidence = previous ?? [:]
        evidence.merge(["launches": count, "firstPID": firstPID,
            "currentPID": Int(getpid()), "parentGone": parentGone]
        ) { _, new in new }
        try! FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: evidence).write(to: marker, options: .atomic)
        if count == 1 {
            isFirstLaunch = true
            termination.installFinalizer { self.record("oldFinalized", true) }
            let safety = PermissionRestartSafety(prepare: {
                self.record("prepared", true)
                if Bundle.main.object(forInfoDictionaryKey: "ProbeRejectPrepare") as? Bool == true {
                    throw CocoaError(.userCancelled)
                }
            }, resume: { self.record("resumed", true) })
            actions = DefaultPermissionSystemActions(relauncher: { bundle, parent, completion in
                PermissionRelaunchProcess.launch(bundleURL: bundle, parentProcessID: parent) { child, error in
                    Task { @MainActor in
                        if let child { self.record("launcherPID", Int(child)) }
                        completion(child, error)
                    }
                }
            }, safety: safety, terminationCoordinator: termination)
            actions!.restartForPermissionRefresh { result in
                if case .failed = result { self.record("failed", true) }
                else { self.record("handoffScheduled", true) }
            }
        } else { NSApp.terminate(nil) }
    }
    private func record(_ key: String, _ value: Any) {
        var evidence = (try? Data(contentsOf: marker)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        evidence[key] = value
        try! JSONSerialization.data(withJSONObject: evidence).write(to: marker, options: .atomic)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isFirstLaunch ? termination.requestTermination() : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if isFirstLaunch { termination.finalizeTerminationResourcesIfNeeded() }
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


def run_probe(sandbox: bool, identity: str = "-", reject_prepare: bool = False) -> dict:
    identifier = "app.blocks.restartprobe." + uuid.uuid4().hex
    support = Path.home() / "Library/Application Support"
    if sandbox:
        support = Path.home() / "Library/Containers" / identifier / "Data/Library/Application Support"
    marker = support / (identifier + ".json")
    source = (ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift").read_text()
    production = source[source.index("@MainActor\nfinal class PermissionRestartSafety") :]
    with tempfile.TemporaryDirectory(prefix="blocks-permission-restart-probe-") as directory:
        root = Path(directory)
        app = root / "Restart Probe.app"
        contents = app / "Contents"
        executable = contents / "MacOS/RestartProbe"
        executable.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "RestartProbe",
            "CFBundleName": "Blocks Restart Probe", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["MacOSX"], "LSMinimumSystemVersion": "14.0",
            "LSUIElement": True, "NSPrincipalClass": "NSApplication",
            "ProbeRejectPrepare": reject_prepare,
        }))
        swift = root / "main.swift"
        swift.write_text(HARNESS + production + DRIVER)
        relaunch_source = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionRelaunchProcess.swift"
        termination_source = ROOT / "apps/Blocks/BlocksApp/Services/AppTerminationCoordinator.swift"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx14.0", str(swift), str(relaunch_source), str(termination_source), "-o", str(executable)], check=True)
        command = ["codesign", "--force", "--sign", identity]
        if identity != "-":
            command += ["--options", "runtime", "--timestamp"]
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
                    if evidence.get("launches", 0) >= 2 or (reject_prepare and evidence.get("failed") and evidence.get("resumed")):
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(0.1)
            if reject_prepare:
                # Wait past the ordinary quit watchdog's deadline: rejection
                # must retain this real process, not merely report a failure.
                time.sleep(5.5)
                evidence = json.loads(marker.read_text())
                os.kill(evidence["firstPID"], 0)
                assert evidence.get("launches") == 1 and evidence.get("failed") and evidence.get("resumed"), evidence
                assert not evidence.get("handoffScheduled") and not evidence.get("oldFinalized"), evidence
                return {"sandbox": sandbox, "certificateSigned": identity != "-", "rejectedPreparation": True, "passed": True, **evidence}
            if evidence.get("launches") != 2:
                pids = [str(evidence.get(key, 0)) for key in ("firstPID", "launcherPID")]
                observed = subprocess.run(["ps", "-p", ",".join(pids), "-o", "pid=,ppid=,stat=,command="], capture_output=True, text=True)
                raise AssertionError(("relaunch did not complete", sandbox, evidence, observed.stdout, str(marker)))
            assert evidence.get("prepared") and evidence.get("handoffScheduled") and evidence.get("oldFinalized"), evidence
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
            return {"sandbox": sandbox, "certificateSigned": identity != "-", "passed": True, "evidence": str(marker), **evidence}
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
                if current.stdout.strip() in {str(executable), str(executable.resolve())}:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--identity", default="-", help="Optional local certificate identity; private keys are never exported")
    parser.add_argument("--repeat", type=int, choices=range(1, 6), default=1)
    args = parser.parse_args()
    for _ in range(args.repeat):
        for sandbox in (False, True):
            print(json.dumps(run_probe(sandbox, args.identity), sort_keys=True), flush=True)
    print(json.dumps(run_probe(True, args.identity, reject_prepare=True), sort_keys=True), flush=True)
