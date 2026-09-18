import Darwin
import BlocksCore
import Foundation
import XCTest
@testable import Blocks

@MainActor
final class BlocksCLIManagedInstallationTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "BlocksCLIManagedInstallationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        // Foundation re-abbreviates /private/var to /var even when resolving
        // symlinks. Use POSIX realpath only for this trusted temporary fixture;
        // production directory validation must continue rejecting symlinks.
        let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        root = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("bundled-cli")
        try Data("v1".utf8).write(to: source)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private var destination: URL { root.appendingPathComponent(".local/bin/blocks-dev") }

    func testCanonicalDirectoryPathIsPreservedAndSymbolicAliasStillRejected() throws {
        let canonicalDestination = root.appendingPathComponent("canonical/bin", isDirectory: true)
        XCTAssertTrue(BlocksCLIManagedInstallationEnvironment.prepareDirectory(canonicalDestination, createMissing: true))
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonicalDestination.deletingLastPathComponent())
        XCTAssertFalse(BlocksCLIManagedInstallationEnvironment.prepareDirectory(alias.appendingPathComponent("bin"), createMissing: false))
    }

    func testExplicitEnableDuringStartupReconcileIsNotDropped() async throws {
        let controller = makeController()
        controller.reconcileManagedInstallation()
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(controller.state, .installedCurrent)
        XCTAssertEqual(try Data(contentsOf: destination), Data("v1".utf8))
    }

    func testDeletedManagedDirectoryCanBeRecreatedByExplicitLocalEnable() async throws {
        let controller = makeController()
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        try FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        controller.reconcileManagedInstallation()
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(controller.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(controller.state, .installedCurrent)
        XCTAssertEqual(try Data(contentsOf: destination), Data("v1".utf8))
    }

    func testAdmissionLeaseCoversQueuedManagementAndPausedUpdateBlocksEveryEntryPoint() async throws {
        let gate = ApplicationOperationAdmissionGate(name: "CLI test")
        let controller = makeController(applicationGate: gate)
        controller.reconcileManagedInstallation()
        XCTAssertGreaterThan(gate.activeOperationCount, 0, "Admission must be acquired before the Task starts")
        do {
            try await controller.prepareForApplicationUpdate()
            XCTFail("An update must not pause an admitted CLI operation")
        } catch { }
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(gate.activeOperationCount, 0)
        try await controller.prepareForApplicationUpdate()

        controller.ensureManagedInstallation(userInitiated: true)
        controller.reconcileManagedInstallation()
        controller.refresh()
        controller.startInstallForTesting(sourceURL: source, destinationURL: destination)
        await controller.install(sourceURL: source, destinationURL: destination)
        controller.chooseDestinationAndInstall()
        controller.uninstall()
        XCTAssertFalse(controller.canInstall)
        XCTAssertEqual(gate.activeOperationCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(defaults.data(forKey: BlocksCLIInstallationController.recordKey))
        XCTAssertFalse(defaults.bool(forKey: BlocksCLIInstallationController.automaticInstallationSuppressedKey))

        await controller.resumeAfterCancelledApplicationUpdate()
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(controller.state, .installedCurrent)
        XCTAssertEqual(gate.activeOperationCount, 0)
    }

    func testExplicitEnableInstallsNamespacedCommandWithoutPanelAndCreatesPrivateDirectories() async throws {
        var requests = 0
        let controller = makeController(authorize: { _ in requests += 1; return nil })
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()

        XCTAssertEqual(controller.state, .installedCurrent)
        XCTAssertEqual(try Data(contentsOf: destination), Data("v1".utf8))
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".local/bin/blocks").path))
        for path in [".local", ".local/bin"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        }
    }

    func testStartupDoesNotInstallOrRequestAuthorizationWithoutRecord() async {
        var requests = 0
        let controller = makeController(requiresAuthorization: true, authorize: { _ in requests += 1; return nil })
        controller.reconcileManagedInstallation()
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(controller.state, .notInstalled)
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSandboxCancellationDoesNotCreateDirectoryOrInstallationRecord() async {
        var suggested: URL?
        let controller = makeController(requiresAuthorization: true, authorize: { directory in
            suggested = directory
            return nil
        })
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(suggested, destination.deletingLastPathComponent())
        XCTAssertEqual(controller.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".local").path))
        XCTAssertNil(defaults.data(forKey: BlocksCLIInstallationController.recordKey))
    }

    func testSandboxAuthorizationPersistsSelectedDirectoryAndUpdatesOnNextLaunchWithoutPanel() async throws {
        let authorizedDirectory = root.appendingPathComponent("authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorizedDirectory, withIntermediateDirectories: false)
        var requests = 0
        let initial = makeController(requiresAuthorization: true, command: "blocks", authorize: { _ in
            requests += 1
            return authorizedDirectory
        })
        initial.ensureManagedInstallation(userInitiated: true)
        await initial.waitForManagedInstallationForTesting()
        XCTAssertEqual(initial.state, .installedCurrent)
        try Data("v2".utf8).write(to: source)

        let relaunched = makeController(requiresAuthorization: true, command: "blocks", authorize: { _ in
            requests += 1
            return nil
        })
        relaunched.reconcileManagedInstallation()
        await relaunched.waitForManagedInstallationForTesting()
        XCTAssertEqual(relaunched.state, .installedCurrent)
        XCTAssertEqual(try Data(contentsOf: authorizedDirectory.appendingPathComponent("blocks")), Data("v2".utf8))
        XCTAssertEqual(requests, 1)
    }

    func testUninstallSuppressesReinstallationUntilRecoveryCompletesAndUserExplicitlyEnables() async throws {
        defaults.set(true, forKey: "cli.module.clipboard.enabled.v1")
        defaults.set(false, forKey: "cli.module.screenshot.enabled.v1")
        let controller = makeController()
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        controller.uninstall()
        await waitUntilIdle(controller)
        // The existing uninstall transaction intentionally retains quarantine
        // instead of using an identity-racy pathname unlink. Do not weaken that
        // safety contract just to exercise automatic reinstall suppression.
        XCTAssertEqual(controller.state, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let quarantine = try XCTUnwrap(controller.recoveryURL)
        let journalData = try XCTUnwrap(defaults.data(forKey: BlocksCLIInstallationController.operationJournalKey))
        let journal = try JSONDecoder().decode(BlocksCLIOperationJournal.self, from: journalData)
        XCTAssertEqual(journal.kind, .uninstall)
        XCTAssertEqual(BlocksCLIFileIdentity.resourceIdentifier(of: quarantine), journal.expectedOldIdentity)
        XCTAssertEqual(BlocksCLIFileDigest.sha256(of: quarantine), journal.expectedOldDigest)
        XCTAssertTrue(defaults.bool(forKey: BlocksCLIInstallationController.automaticInstallationSuppressedKey))
        XCTAssertTrue(defaults.bool(forKey: "cli.module.clipboard.enabled.v1"))
        XCTAssertFalse(defaults.bool(forKey: "cli.module.screenshot.enabled.v1"))

        let relaunched = makeController()
        relaunched.reconcileManagedInstallation()
        await relaunched.waitForManagedInstallationForTesting()
        relaunched.ensureManagedInstallation(userInitiated: false)
        await relaunched.waitForManagedInstallationForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(relaunched.state, .recoveryRequired)
        XCTAssertTrue(defaults.bool(forKey: BlocksCLIInstallationController.automaticInstallationSuppressedKey))

        relaunched.ensureManagedInstallation(userInitiated: true)
        await relaunched.waitForManagedInstallationForTesting()
        XCTAssertEqual(relaunched.state, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(defaults.data(forKey: BlocksCLIInstallationController.operationJournalKey), journalData)

        // Simulate the user's explicit cleanup of this test-owned quarantine,
        // then use the real recovery path; never clear journal/record by hand.
        XCTAssertTrue(quarantine.path.hasPrefix(root.path + "/"))
        try FileManager.default.removeItem(at: quarantine)
        relaunched.reconcileManagedInstallation()
        await relaunched.waitForManagedInstallationForTesting()
        XCTAssertEqual(relaunched.state, .notInstalled)
        XCTAssertNil(defaults.data(forKey: BlocksCLIInstallationController.operationJournalKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        relaunched.ensureManagedInstallation(userInitiated: true)
        await relaunched.waitForManagedInstallationForTesting()
        XCTAssertEqual(relaunched.state, .installedCurrent)
        XCTAssertFalse(defaults.bool(forKey: BlocksCLIInstallationController.automaticInstallationSuppressedKey))
    }

    func testAutomaticInstallationNeverOverwritesForeignCommand() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: destination)
        let controller = makeController()
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(controller.state, .destinationConflict)
        XCTAssertEqual(try Data(contentsOf: destination), Data("foreign".utf8))
        XCTAssertNil(defaults.data(forKey: BlocksCLIInstallationController.recordKey))
    }

    func testAutomaticUpdateNeverOverwritesModifiedManagedCommand() async throws {
        let initial = makeController()
        initial.ensureManagedInstallation(userInitiated: true)
        await initial.waitForManagedInstallationForTesting()
        try Data("foreign".utf8).write(to: destination)
        try Data("v2".utf8).write(to: source)
        let relaunched = makeController()
        relaunched.reconcileManagedInstallation()
        await relaunched.waitForManagedInstallationForTesting()
        XCTAssertEqual(relaunched.state, .changed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("foreign".utf8))
    }

    func testAutomaticInstallationRefusesSymbolicLinkParent() async throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".local"), withDestinationURL: other)
        let controller = makeController()
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        XCTAssertEqual(controller.state, .destinationConflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("bin").path))
    }

    func testPathGuidanceIsDismissedPersistentlyAndDoesNotChangeShellConfiguration() async throws {
        let shellConfig = root.appendingPathComponent(".zshrc")
        try Data("# unchanged".utf8).write(to: shellConfig)
        let controller = makeController()
        controller.ensureManagedInstallation(userInitiated: true)
        await controller.waitForManagedInstallationForTesting()
        XCTAssertNotNil(controller.pathGuidanceDetail)
        controller.dismissPathGuidance()
        let relaunched = makeController()
        relaunched.reconcileManagedInstallation()
        await relaunched.waitForManagedInstallationForTesting()
        XCTAssertNil(relaunched.pathGuidanceDetail)
        XCTAssertEqual(try Data(contentsOf: shellConfig), Data("# unchanged".utf8))
    }

    private func makeController(
        requiresAuthorization: Bool = false,
        command: String = "blocks-dev",
        applicationGate: ApplicationOperationAdmissionGate = ApplicationOperationAdmissionGate(name: "CLI test"),
        authorize: @escaping @MainActor (URL) async -> URL? = { _ in nil }
    ) -> BlocksCLIInstallationController {
        let source = source!
        let root = root!
        return BlocksCLIInstallationController(
            defaults: defaults,
            bookmarkAccess: BlocksCLIInstallationBookmarkAccess(
                make: { Data($0.path.utf8) },
                resolve: { String(data: $0, encoding: .utf8).map(URL.init(fileURLWithPath:)) },
                start: { _ in true }, stop: { _ in }
            ),
            sourceURLProvider: { source },
            installationRecordStore: .defaults(defaults, key: BlocksCLIInstallationController.recordKey),
            operationJournalStore: .defaults(defaults, key: BlocksCLIInstallationController.operationJournalKey),
            operationLeaseProvider: .file(root.appendingPathComponent("operation.lock")),
            managedHomeDirectoryProvider: { root },
            requiresDirectoryAuthorization: requiresAuthorization,
            authorizeDirectory: authorize,
            processPathProvider: { "/usr/bin:/bin" },
            commandName: command,
            applicationUpdateGate: applicationGate
        )
    }

    private func waitUntilIdle(_ controller: BlocksCLIInstallationController) async {
        for _ in 0..<400 {
            if !controller.isBusy { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("CLI operation did not complete")
    }
}
