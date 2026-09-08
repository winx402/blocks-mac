#!/usr/bin/env python3
"""Compile real Core security code twice; test only temporary files and dictionaries.

No SecItem APIs, real installation, real peer manifest, XPC connection, or app
launch is used. The internal reader seam takes a temporary manifest URL and root;
production entry points remain pinned to the login user's installation.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "apps/Blocks/BlocksCore"
SOURCES = [CORE / name for name in (
    "BlocksRuntimeIdentity.swift", "BlocksKeychainNamespace.swift", "BlocksLocalBuildTrust.swift"
)]

HARNESS = r'''
import Foundation
import Security
import Darwin

enum Failure: Error { case assertion(String) }
var cases = [String]()
func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
    guard value() else { throw Failure.assertion(name) }
    cases.append(name)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fakeHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!, isDirectory: true)
let input: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: BlocksRuntimeIdentity.providerKeychainService,
    kSecAttrAccount as String: "fixture-account",
    kSecAttrAccessGroup as String: "TESTTEAM00.fixture",
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecReturnData as String: true,
]

do {
    let query = BlocksKeychainNamespace.queryForCurrentBuild(input)
    try check(query[kSecAttrAccount as String] as? String == "fixture-account", "query-preserves-account")
    try check(query[kSecReturnData as String] as? Bool == true, "query-preserves-operation-flags")
    try check(input[kSecAttrAccessGroup as String] != nil, "query-does-not-mutate-input")
    let helper = BlocksKeychainNamespace.helperQuery(service: BlocksRuntimeIdentity.selectionHelperKeychainService,
                                                    account: "fixture", accessGroup: "TESTTEAM00.fixture")
    try check(helper?[kSecAttrAccount as String] as? String == "fixture", "helper-preserves-account")

    #if BLOCKS_LOCAL_DEVELOPMENT
    try check(BlocksRuntimeIdentity.isLocalDevelopment, "local-compile-identity")
    try check(BlocksRuntimeIdentity.applicationBundleIdentifier == "app.blocks.dev", "local-app-identity")
    try check(BlocksRuntimeIdentity.mainExecutableName == "Blocks", "local-main-executable")
    try check(BlocksRuntimeIdentity.actionBrokerMachServiceName == "app.blocks.dev.action-broker.xpc", "local-mach-namespace")
    try check(BlocksRuntimeIdentity.nativePluginRunnerServiceName == "app.blocks.dev.plugin-runner", "local-native-runner-namespace")
    try check(BlocksRuntimeIdentity.providerKeychainService == "app.blocks.dev.provider.dev", "local-provider-service")
    try check(BlocksRuntimeIdentity.translationServiceCredentialKeychainService == "app.blocks.dev.translation-service-credential", "local-translation-service")
    try check(BlocksRuntimeIdentity.nativePluginSecretKeychainService == "app.blocks.dev.translation-plugin-secret", "local-plugin-secret-service")
    try check(BlocksRuntimeIdentity.selectionHelperKeychainService == "app.blocks.dev.selection-helper.shared-active-key.v4", "local-helper-secret-service")
    try check(BlocksRuntimeIdentity.selectionHelperBootstrapKeychainService == "app.blocks.dev.selection-helper.shared-bootstrap-key", "local-bootstrap-service")
    try check(query[kSecAttrAccessGroup as String] == nil, "local-removes-provisioning-group")
    try check(query[kSecAttrAccessible as String] == nil, "local-removes-data-protection-accessibility")
    try check(query[kSecUseDataProtectionKeychain as String] as? Bool == false, "local-selects-login-keychain-query")
    try check(helper?[kSecAttrAccessGroup as String] == nil, "local-helper-does-not-require-certificate-group")
    try check(helper?[kSecUseDataProtectionKeychain as String] as? Bool == false, "local-helper-login-keychain-query")
    try check(BlocksKeychainNamespace.helperQuery(service: "fixture", account: "fixture", accessGroup: nil) != nil,
              "local-helper-query-works-without-team")
    // Merely resolving this property does not read the actual manifest. HOME is
    // intentionally forged to prove production discovery uses getpwuid instead.
    try check(BlocksLocalBuildTrust.manifestURL?.path.hasPrefix(fakeHome.path + "/") == false,
              "local-production-path-ignores-environment-home")
    try check(!BlocksLocalBuildTrust.accepts(processIdentifier: -1, userIdentifier: getuid(), role: "app"),
              "local-rejects-invalid-pid-before-manifest-access")
    try check(!BlocksLocalBuildTrust.accepts(processIdentifier: getpid(), userIdentifier: getuid() ^ 1, role: "app"),
              "local-rejects-wrong-uid-before-manifest-access")

    let directory = root.appendingPathComponent("secure/Installation", isDirectory: true)
    let url = directory.appendingPathComponent("peers.json")
    let expectedRoot = root.appendingPathComponent("Applications/Blocks.app").path
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let layout: [(String, String, String)] = [
        ("app", "app.blocks.dev", "Contents/MacOS/Blocks"),
        ("cli", "app.blocks.dev.cli", "Contents/Resources/CLI/blocks"),
        ("broker", "app.blocks.dev.action-broker", "Contents/MacOS/BlocksActionBroker"),
        ("helper", "app.blocks.dev.selection-helper", "Contents/Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper"),
    ]
    let peers = layout.map { ["role": $0.0, "identifier": $0.1,
                             "relativeExecutablePath": $0.2, "cdHash": String(repeating: "a", count: 40)] }
    let valid: [String: Any] = ["schemaVersion": 1, "appBundlePath": expectedRoot, "peers": peers]
    func write(_ value: [String: Any], mode: mode_t = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: url)
        guard chmod(url.path, mode) == 0 else { throw Failure.assertion("fixture-chmod") }
    }
    func loaded(_ file: URL? = nil) -> BlocksLocalBuildTrust.Manifest? {
        BlocksLocalBuildTrust.loadManifest(at: file ?? url, expectedRoot: expectedRoot)
    }
    func reject(_ value: [String: Any], _ name: String) throws {
        try write(value)
        try check(loaded() == nil, name)
    }
    try check(loaded() == nil, "reader-missing-manifest-fails-closed")
    try write(valid)
    try check(loaded()?.peers.count == 4, "reader-accepts-complete-private-manifest")
    try check(loaded()?.peers.map(\.role) == layout.map { $0.0 }, "reader-preserves-all-roles")
    try write(valid, mode: 0o644)
    try check(loaded() == nil, "reader-rejects-world-readable-manifest")
    try write(valid, mode: 0o660)
    try check(loaded() == nil, "reader-rejects-group-writable-manifest")
    try write(valid)
    _ = chmod(directory.path, 0o777)
    try check(loaded() == nil, "reader-rejects-writable-parent")
    _ = chmod(directory.path, 0o700)
    _ = chmod(directory.deletingLastPathComponent().path, 0o777)
    try check(loaded() == nil, "reader-rejects-writable-grandparent")
    _ = chmod(directory.deletingLastPathComponent().path, 0o700)
    let linked = directory.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: url)
    try check(loaded(linked) == nil, "reader-rejects-leaf-symlink")
    let linkedParent = directory.deletingLastPathComponent().appendingPathComponent("LinkedInstallation")
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: directory)
    try check(loaded(linkedParent.appendingPathComponent("peers.json")) == nil, "reader-rejects-parent-symlink")
    let linkedGrandparent = root.appendingPathComponent("secure-link")
    try FileManager.default.createSymbolicLink(at: linkedGrandparent, withDestinationURL: directory.deletingLastPathComponent())
    try check(loaded(linkedGrandparent.appendingPathComponent("Installation/peers.json")) == nil,
              "reader-rejects-grandparent-symlink")
    try check(loaded(directory) == nil, "reader-rejects-directory-as-manifest")
    var altered = valid; altered["schemaVersion"] = 2
    try reject(altered, "reader-rejects-new-schema")
    altered = valid; altered["appBundlePath"] = expectedRoot + ".other"
    try reject(altered, "reader-rejects-other-install-root")
    altered = valid; altered["peers"] = Array(peers.dropLast())
    try reject(altered, "reader-rejects-missing-peer")
    altered = valid; altered["peers"] = peers + [peers[0]]
    try reject(altered, "reader-rejects-extra-peer")
    var changedPeers = peers; changedPeers[1] = changedPeers[0]
    altered = valid; altered["peers"] = changedPeers
    try reject(altered, "reader-rejects-duplicate-role")
    for (field, value, name) in [
        ("role", "unknown", "reader-rejects-unknown-role"),
        ("identifier", "app.blocks.app", "reader-rejects-production-identifier"),
        ("relativeExecutablePath", "../Blocks", "reader-rejects-path-traversal"),
        ("relativeExecutablePath", "/tmp/Blocks", "reader-rejects-absolute-peer-path"),
        ("cdHash", "", "reader-rejects-empty-hash"),
        ("cdHash", String(repeating: "a", count: 39), "reader-rejects-short-hash"),
        ("cdHash", String(repeating: "a", count: 41), "reader-rejects-intermediate-hash"),
        ("cdHash", String(repeating: "z", count: 40), "reader-rejects-nonhex-hash"),
        ("cdHash", String(repeating: "A", count: 40), "reader-rejects-noncanonical-hash"),
    ] {
        changedPeers = peers; changedPeers[0][field] = value
        altered = valid; altered["peers"] = changedPeers
        try reject(altered, name)
    }
    try Data("not-json".utf8).write(to: url)
    try check(loaded() == nil, "reader-rejects-malformed-json")
    try Data().write(to: url)
    try check(loaded() == nil, "reader-rejects-empty-file")
    try Data(repeating: 0x20, count: 32_769).write(to: url)
    try check(loaded() == nil, "reader-rejects-oversize-file")
    try write(valid)
    try check(loaded() != nil, "reader-remains-usable-after-rejected-fixtures")
    #else
    try check(!BlocksRuntimeIdentity.isLocalDevelopment, "production-compile-identity")
    try check(BlocksRuntimeIdentity.applicationBundleIdentifier == "app.blocks.app", "production-app-identity")
    try check(BlocksRuntimeIdentity.mainExecutableName == "Blocks", "production-main-executable")
    try check(BlocksRuntimeIdentity.actionBrokerMachServiceName == "app.blocks.action-broker.xpc", "production-mach-namespace")
    try check(BlocksRuntimeIdentity.providerKeychainService == "app.blocks.provider.dev", "production-provider-service")
    try check(BlocksRuntimeIdentity.translationServiceCredentialKeychainService == "app.blocks.translation-service-credential", "production-translation-service")
    try check(BlocksRuntimeIdentity.nativePluginSecretKeychainService == "app.blocks.translation-plugin-secret", "production-plugin-secret-service")
    try check(query[kSecAttrAccessGroup as String] as? String == "TESTTEAM00.fixture", "production-retains-access-group")
    try check(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              "production-retains-accessibility")
    try check(query[kSecUseDataProtectionKeychain as String] == nil, "production-does-not-force-login-keychain")
    try check(helper?[kSecUseDataProtectionKeychain as String] as? Bool == true, "production-helper-data-protection-query")
    try check(BlocksKeychainNamespace.helperQuery(service: "fixture", account: "fixture", accessGroup: nil) == nil,
              "production-helper-rejects-missing-group")
    try check(BlocksKeychainNamespace.helperQuery(service: "fixture", account: "fixture", accessGroup: "") == nil,
              "production-helper-rejects-empty-group")
    try check(BlocksLocalBuildTrust.manifestURL == nil, "production-has-no-local-manifest")
    for role in ["app", "cli", "broker", "helper", "unknown"] {
        try check(BlocksLocalBuildTrust.connectionRequirement(role: role) == nil, "production-rejects-local-requirement-" + role)
        try check(!BlocksLocalBuildTrust.accepts(processIdentifier: getpid(), userIdentifier: getuid(), role: role),
                  "production-rejects-local-process-" + role)
        try check(!BlocksLocalBuildTrust.accepts(executableURL: root.appendingPathComponent("fixture"), role: role),
                  "production-rejects-local-executable-" + role)
    }
    #endif
    let result: [String: Any] = ["ok": true, "caseCount": cases.count, "cases": cases]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("security self-test failed: \(error)\n", stderr)
    exit(1)
}
'''


def main() -> None:
    if platform.system() != "Darwin":
        raise SystemExit("This self-test requires macOS Security.framework and the Swift toolchain.")
    results = {}
    with tempfile.TemporaryDirectory(prefix="blocks-local-security-") as temporary:
        directory = Path(temporary)
        harness = directory / "main.swift"
        harness.write_text(HARNESS, encoding="utf-8")
        environment = dict(os.environ)
        # getpwuid-based production discovery must not follow this HOME. No test
        # accesses the returned production path; manifest reads use only the seam.
        environment["HOME"] = str(directory / "fake-home")
        Path(environment["HOME"]).mkdir(mode=0o700)
        for name, flags in (("production", []), ("local", ["-D", "BLOCKS_LOCAL_DEVELOPMENT"])):
            executable = directory / f"security-{name}"
            build = subprocess.run(
                ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(directory / "module-cache"),
                 *flags, *(str(source) for source in SOURCES), str(harness), "-o", str(executable)],
                cwd=ROOT, capture_output=True, text=True, timeout=120,
            )
            if build.returncode:
                raise SystemExit(f"{name} compilation failed:\n{build.stderr}")
            fixture = directory / name
            fixture.mkdir(mode=0o700)
            run = subprocess.run([str(executable), str(fixture)], env=environment,
                                 capture_output=True, text=True, timeout=30)
            if run.returncode:
                raise SystemExit(f"{name} assertions failed:\n{run.stderr}")
            results[name] = json.loads(run.stdout)
    print(json.dumps({"ok": True, "configurations": results,
                      "not_exercised": ["live-keychain-ACL-and-prompts", "actual-XPC-server-authentication",
                                        "signed-peer-CDHash-and-path-runtime", "wrong-file-owner-requires-other-uid"]},
                     ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
