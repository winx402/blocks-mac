#!/usr/bin/env python3
"""Exercise the real Helper ACL and no-UI coordinator in synthetic signed apps.

Only an explicitly named temporary keychain is read/written. Its password and
item bytes are synthetic. No user search list, real pairing item, or manifest is
changed. The temporary files (including the keychain) are removed on exit.
"""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SWIFT = r'''
import Foundation
import Security
import Darwin

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func success(_ status: OSStatus, _ message: String) {
    require(status == errSecSuccess, "\(message) status=\(status)")
}
func interactionAllowed() -> Bool {
    var allowed: DarwinBoolean = false
    success(SecKeychainGetUserInteractionAllowed(&allowed), "read interaction state")
    return allowed.boolValue
}
func report(_ mode: String, _ values: [String: Any] = [:]) {
    var output = values
    output["mode"] = mode
    output["ok"] = true
    let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@main struct Fixture {
    static func main() {
        // Set before opening any keychain; a denied ACL can never open a dialog.
        success(SecKeychainSetUserInteractionAllowed(false), "disable UI")
        let args = CommandLine.arguments
        require(args.count == 6, "fixture argument count")
        let mode = args[1], path = args[2], service = args[3]
        let peers = [URL(fileURLWithPath: args[4]), URL(fileURLWithPath: args[5])]
        if mode == "coordinator" {
            coordinatorChecks(peers)
            return
        }
        let password = Array("synthetic-fixture-only".utf8)
        var optionalKeychain: SecKeychain?
        if mode == "create" {
            let status = password.withUnsafeBytes {
                SecKeychainCreate(path, UInt32($0.count), $0.baseAddress!, false, nil, &optionalKeychain)
            }
            success(status, "create private fixture keychain")
        } else {
            success(SecKeychainOpen(path, &optionalKeychain), "open private fixture keychain")
        }
        guard let keychain = optionalKeychain else { require(false, "missing fixture keychain"); return }
        if mode != "locked-read" {
            success(password.withUnsafeBytes {
                SecKeychainUnlock(keychain, UInt32($0.count), $0.baseAddress!, true)
            }, "unlock only synthetic fixture")
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "synthetic-account",
            kSecUseDataProtectionKeychain as String: false,
        ]
        let synthetic = Data(repeating: 0x5A, count: 32)
        if mode == "create" || mode == "add" {
            guard let access = BlocksKeychainAccess.makeHelperAccess(trustedExecutables: peers) else {
                require(false, "real makeHelperAccess rejected valid fixture pair"); return
            }
            query[kSecUseKeychain as String] = keychain
            query[kSecAttrAccess as String] = access
            query[kSecValueData as String] = synthetic
            success(BlocksKeychainAccess.perform(helper: true) {
                SecItemAdd(query as CFDictionary, nil)
            }, "create narrow-ACL synthetic item")
        } else if mode == "helper-add-denied" {
            // This fixture is not one of the installed manifest participants.
            // helperAdd must therefore reject before it can attach an ACL. The
            // subsequent explicit-fixture search proves no item was written.
            query[kSecUseKeychain as String] = keychain
            query[kSecValueData as String] = synthetic
            let rejected = BlocksKeychainAccess.helperAdd(query as CFDictionary, nil)
            require(rejected == errSecAuthFailed, "unregistered helperAdd status=\(rejected)")
            var absence = query
            absence.removeValue(forKey: kSecUseKeychain as String)
            absence.removeValue(forKey: kSecValueData as String)
            absence[kSecMatchSearchList as String] = [keychain]
            absence[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let lookup = BlocksKeychainAccess.helperCopyMatching(absence as CFDictionary, &result)
            require(lookup == errSecItemNotFound && result == nil,
                    "rejected helperAdd left an item status=\(lookup)")
            report(mode, ["rejectedStatus": Int(rejected), "postRejectStatus": Int(lookup)])
        } else {
            query[kSecMatchSearchList as String] = [keychain]
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            if mode == "locked-read" { success(SecKeychainLock(keychain), "lock only synthetic fixture") }
            var result: CFTypeRef?
            let status = BlocksKeychainAccess.helperCopyMatching(query as CFDictionary, &result)
            if mode == "denied-read" || mode == "locked-read" {
                require(status == errSecAuthFailed || status == errSecInteractionNotAllowed,
                        "expected authorization denial, got status=\(status)")
                require(result == nil, "denied operation returned data")
            } else {
                success(status, "peer first read")
                require((result as? Data) == synthetic, "synthetic content mismatch")
            }
        }
        require(!interactionAllowed(), "operation did not preserve initially disabled UI")
        if mode != "helper-add-denied" { report(mode) }
    }

    static func coordinatorChecks(_ peers: [URL]) {
        require(BlocksKeychainAccess.makeHelperAccess(trustedExecutables: []) == nil, "empty ACL accepted")
        require(BlocksKeychainAccess.makeHelperAccess(trustedExecutables: [peers[0]]) == nil, "one-app ACL accepted")
        require(BlocksKeychainAccess.makeHelperAccess(trustedExecutables: [peers[0], peers[0]]) == nil,
                "duplicate-app ACL accepted")
        // No keychain operation is performed while UI is enabled: only inspect
        // process state inside coordinator closures, then immediately disable it.
        success(SecKeychainSetUserInteractionAllowed(true), "set initial coordinator policy")
        success(BlocksKeychainAccess.perform(helper: true) {
            require(!interactionAllowed(), "helper scope permits UI")
            success(BlocksKeychainAccess.perform(helper: true) {
                require(!interactionAllowed(), "nested helper scope permits UI")
                return errSecSuccess
            }, "nested coordinator")
            require(!interactionAllowed(), "nested restoration escaped outer scope")
            return errSecSuccess
        }, "coordinator success")
        require(interactionAllowed(), "successful helper scope failed to restore UI")
        let failed = BlocksKeychainAccess.perform(helper: true) { errSecAuthFailed }
        require(failed == errSecAuthFailed && interactionAllowed(), "failure failed to restore UI")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0), otherEntered = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            success(BlocksKeychainAccess.perform(helper: true) {
                require(!interactionAllowed(), "concurrent helper scope permits UI")
                entered.signal()
                require(release.wait(timeout: .now() + 5) == .success, "release helper timeout")
                return errSecSuccess
            }, "concurrent helper")
            group.leave()
        }
        require(entered.wait(timeout: .now() + 5) == .success, "helper enter timeout")
        group.enter()
        DispatchQueue.global().async {
            attempted.signal()
            success(BlocksKeychainAccess.perform {
                require(interactionAllowed(), "other store inherited temporary no-UI state")
                otherEntered.signal()
                return errSecSuccess
            }, "other store coordinator")
            group.leave()
        }
        require(attempted.wait(timeout: .now() + 5) == .success, "other store attempt timeout")
        require(otherEntered.wait(timeout: .now() + 0.15) == .timedOut, "other store raced helper scope")
        release.signal()
        require(group.wait(timeout: .now() + 5) == .success, "coordinator completion timeout")
        require(interactionAllowed(), "concurrent helper scope failed to restore UI")
        success(SecKeychainSetUserInteractionAllowed(false), "restore fixture no-UI policy")
        report("coordinator", [
            "emptyAclDenied": true,
            "oneAclDenied": true,
            "duplicateAclDenied": true,
            "nestedRestored": true,
            "failedScopeRestored": true,
            "initialNoUiPreserved": true,
            "otherStoreBlockedDuringHelper": true,
            "otherStoreRestoredAfterHelper": true,
        ])
    }
}
'''


def search_list() -> str:
    return subprocess.check_output(
        ["/usr/bin/security", "list-keychains", "-d", "user"], text=True
    )


def runner_output(completed: subprocess.CompletedProcess[str]) -> dict[str, Any]:
    """Parse the fixture's single non-sensitive JSON result."""
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError(f"fixture emitted {len(lines)} result lines")
    parsed = json.loads(lines[0])
    if not isinstance(parsed, dict) or parsed.get("ok") is not True:
        raise RuntimeError("fixture did not report success")
    return parsed


def main() -> dict[str, Any]:
    before = search_list()
    report: dict[str, Any] = {
        "suite": "helper_keychain_acl_self_test",
        "ok": False,
        "fixture": {
            "temporaryKeychainOnly": True,
            "searchListWriteCommands": False,
            "realSecretOrItemAccess": False,
            # helperAdd's fixed trust API necessarily reads the current manifest
            # to reject this unsigned, unregistered synthetic process. Its path,
            # contents and identities are never printed or changed.
            "manifestReadForUnregisteredHelperRejection": True,
            "manifestModified": False,
            "syntheticValuesPrinted": False,
        },
        "checks": {},
        "failures": [],
    }
    try:
        with tempfile.TemporaryDirectory(prefix="blocks-helper-acl-tests-") as raw:
            root = Path(raw)
            source = root / "Fixture.swift"
            source.write_text(SWIFT)
            binary = root / "Fixture"
            core = ROOT / "apps/Blocks/BlocksCore"
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "5", "-suppress-warnings",
                "-D", "BLOCKS_LOCAL_DEVELOPMENT",
                *[str(core / name) for name in (
                    "BlocksRuntimeIdentity.swift", "BlocksLocalBuildTrust.swift", "BlocksKeychainNamespace.swift",
                )], str(source), "-o", str(binary),
            ], cwd=ROOT, check=True, timeout=90)
            executables = []
            for role in ("app", "helper", "outsider"):
                bundle = root / f"{role}.app"
                executable = bundle / "Contents/MacOS/Fixture"
                executable.parent.mkdir(parents=True)
                shutil.copy2(binary, executable)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": f"app.blocks.synthetic-keychain-test.{role}",
                    "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
                }))
                subprocess.run([
                    "/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle),
                ], check=True, capture_output=True, text=True, timeout=30)
                executables.append(executable)
            keychain = root / "synthetic.keychain"

            def run(index: int, mode: str, service: str = "synthetic.from-app") -> dict[str, Any]:
                completed = subprocess.run([
                    str(executables[index]), mode, str(keychain), service,
                    str(executables[0]), str(executables[1]),
                ], check=True, timeout=20, text=True, capture_output=True)
                return runner_output(completed)

            report["checks"]["aclShapeAndScopedNoUi"] = run(0, "coordinator")
            report["checks"]["appCreatesSharedAclItem"] = run(0, "create")
            report["checks"]["searchListAfterKeychainCreate"] = search_list() == before
            if not report["checks"]["searchListAfterKeychainCreate"]:
                raise RuntimeError("User keychain search list changed after fixture creation")
            report["checks"]["unregisteredHelperAddRejectsWithoutWrite"] = run(
                2, "helper-add-denied", "synthetic.unregistered-helper-add"
            )
            report["checks"]["helperReadsAppItem"] = run(1, "read")
            report["checks"]["helperWritesAppItem"] = run(1, "add", "synthetic.from-helper")
            report["checks"]["appReadsHelperItem"] = run(0, "read", "synthetic.from-helper")
            report["checks"]["outsiderDenied"] = run(2, "denied-read")
            report["checks"]["lockedFixtureFailsClosed"] = run(0, "locked-read")
            assert search_list() == before, "User keychain search list changed unexpectedly"
        report["checks"]["searchListAfterFixtureDeletion"] = search_list() == before
        if not report["checks"]["searchListAfterFixtureDeletion"]:
            raise RuntimeError("User keychain search list changed after fixture deletion")
        report["ok"] = True
        return report
    except Exception as error:
        report["failures"].append({"type": type(error).__name__, "detail": str(error)})
        return report
    finally:
        # Deliberately no search-list write or restoration command: never mutate
        # a user list, even if an unrelated process changes it during the test.
        if search_list() != before:
            report["failures"].append({
                "type": "search_list_changed",
                "detail": "User search list differs from initial snapshot; no restoration attempted",
            })
            report["ok"] = False


if __name__ == "__main__":
    result = main()
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    sys.exit(0 if result["ok"] else 1)
