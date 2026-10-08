import BlocksCore
import Combine
import ServiceManagement
import XCTest
@testable import Blocks

@MainActor
final class ActionBrokerUpdateSafetyTests: XCTestCase {
    func testLocalCancellationUsesTheActionRequestIdentifierContract() {
        let generated = ActionRequestID.make().rawValue
        XCTAssertTrue(generated.hasPrefix("req_"))
        XCTAssertEqual(ScreenshotActionHost.cancellationRequestID(from: Data(generated.utf8)), generated)
        XCTAssertEqual(ScreenshotActionHost.cancellationRequestID(from: Data("custom-action-id".utf8)), "custom-action-id")
        for invalid in [Data(), Data(" bad-id".utf8), Data("bad id".utf8), Data([0xff])] {
            XCTAssertNil(ScreenshotActionHost.cancellationRequestID(from: invalid))
        }
    }

    func testAppOwnedPreferenceImportsIntentOnlyOnce() throws {
        let suite = "AppOwnedCLI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let control = ActionBrokerServiceControl.appOwned(defaults: defaults, inheritedIntent: true)
        XCTAssertEqual(control.status(), .enabled)
        try control.unregister()
        let relaunched = ActionBrokerServiceControl.appOwned(defaults: defaults, inheritedIntent: true)
        XCTAssertEqual(relaunched.status(), .notRegistered)
        try relaunched.register()
        XCTAssertEqual(control.status(), .enabled)
    }

    func testAppOwnedDisableRetiresAbsentLegacyRegistrationWithoutContactingBroker() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.host.prepareError = ActionBrokerUpdateError.untrustedPeer
        let manager = fixture.makeManager(appOwned: true, legacyStatus: .enabled)
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertEqual(manager.state, .disabled)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(fixture.host.drainCount, 1)
        XCTAssertTrue(fixture.host.prepareTokens.isEmpty)
        XCTAssertTrue(fixture.host.resumeTokens.isEmpty)
        XCTAssertEqual(fixture.unregisterCount, 1, "only the injected logical preference changes")
        XCTAssertEqual(fixture.legacyUnregisterCount, 1)
        XCTAssertEqual(fixture.legacyStatus, .notRegistered)
    }

    func testAppOwnedUpdatePreservesIntentWithoutRegistrationRPC() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let manager = fixture.makeManager(appOwned: true)
        try await manager.prepareForApplicationUpdate()
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(fixture.host.drainCount, 1)
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertTrue(fixture.host.prepareTokens.isEmpty)
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(manager.state, .enabled)
        XCTAssertEqual(fixture.registerCount, 0)
        XCTAssertTrue(fixture.host.resumeTokens.isEmpty)
    }

    func testAppOwnedUpdateRefusesLegacyRegistrationButOrdinaryQuitCanDrain() async throws {
        let fixture = BrokerServiceUpdateFixture()
        fixture.legacyJobAbsent = false
        let manager = fixture.makeManager(appOwned: true, legacyStatus: .enabled)
        do {
            try await manager.prepareForApplicationUpdate()
            XCTFail("legacy registration must be migrated before replacement")
        } catch { }
        XCTAssertEqual(fixture.host.drainCount, 1)
        XCTAssertEqual(fixture.unregisterCount, 0)
        try await manager.prepareForApplicationUpdate(stopService: false)
        XCTAssertEqual(fixture.host.drainCount, 2)
        XCTAssertTrue(fixture.host.prepareTokens.isEmpty)
    }

    func testAppOwnedUpdateRetiresOnlyAbsentLegacyJobAndNeverReregistersIt() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let manager = fixture.makeManager(appOwned: true, legacyStatus: .enabled)
        try await manager.prepareForApplicationUpdate()
        XCTAssertEqual(fixture.legacyUnregisterCount, 1)
        XCTAssertEqual(fixture.legacyStatus, .notRegistered)
        XCTAssertTrue(manager.isEnabled, "retirement must preserve app-owned intent")
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(manager.state, .enabled)
        XCTAssertEqual(fixture.registerCount, 0)
        XCTAssertTrue(fixture.host.prepareTokens.isEmpty)
        XCTAssertTrue(fixture.host.resumeTokens.isEmpty)
    }

    func testAppOwnedDisableRetainsIntentWhenLegacyJobIsLoadedOrProcessLingers() async {
        for jobAbsent in [false, true] {
            let fixture = BrokerServiceUpdateFixture()
            fixture.legacyJobAbsent = jobAbsent
            fixture.legacyProcesses = jobAbsent ? [77] : []
            let manager = fixture.makeManager(appOwned: true, legacyStatus: .enabled)
            manager.setEnabled(false)
            await manager.serviceChangeTask?.value
            XCTAssertTrue(manager.isEnabled)
            XCTAssertEqual(fixture.unregisterCount, 0)
            XCTAssertEqual(fixture.legacyUnregisterCount, 0)
            XCTAssertEqual(fixture.host.stopCount, 0, "failed removal cannot cancel the host")
            guard case .failed = manager.state else { return XCTFail("legacy failure must remain visible") }
        }
    }

    func testAppOwnedLegacyUnregisterFailureIsVisibleAndNeverRestartsLegacyService() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.legacyUnregisterError = ActionBrokerUpdateError.serviceDidNotStop
        let manager = fixture.makeManager(appOwned: true, legacyStatus: .enabled)
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertEqual(fixture.legacyUnregisterCount, 1)
        XCTAssertEqual(fixture.legacyStatus, .enabled)
        XCTAssertEqual(fixture.registerCount, 0)
        guard case .failed = manager.state else { return XCTFail("unregister failure must remain visible") }
    }

    func testAppOwnedUnverifiableLegacyJobCannotBeRetired() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.legacyVerificationError = ActionBrokerUpdateError.serviceDidNotStop
        let manager = fixture.makeManager(appOwned: true, legacyStatus: .enabled)
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(fixture.legacyUnregisterCount, 0)
        XCTAssertEqual(fixture.unregisterCount, 0)
        guard case .failed = manager.state else { return XCTFail("unverifiable launchd state must fail closed") }
    }

    func testAppOwnedLegacyAbsenceMustRemainVerifiedAfterUnregister() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.legacyReappearsAfterUnregister = true
        let manager = fixture.makeManager(appOwned: true, legacyStatus: .enabled)
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertEqual(fixture.legacyUnregisterCount, 1)
        guard case .failed = manager.state else { return XCTFail("reappearing job must block disable") }
    }

    func testLegacyJobAbsenceDoesNotConfuseMissingDomainOrPermissionFailureWithMissingJob() {
        let missing = "Could not find service \"\(BlocksActionBrokerXPC.launchAgentLabel)\" in domain for user gui: 501"
        XCTAssertTrue(ActionBrokerServiceManager.legacyJobIsAbsent(exitCode: 113, standardError: "Bad request.\n\(missing)\n", domain: "gui/501", uid: 501))
        XCTAssertFalse(ActionBrokerServiceManager.legacyJobIsAbsent(exitCode: 0, standardError: missing, domain: "gui/501", uid: 501))
        XCTAssertFalse(ActionBrokerServiceManager.legacyJobIsAbsent(exitCode: 112, standardError: "Could not find domain for user gui: 501", domain: "gui/501", uid: 501))
        XCTAssertFalse(ActionBrokerServiceManager.legacyJobIsAbsent(exitCode: 113, standardError: missing, domain: "user/501", uid: 501))
        XCTAssertFalse(ActionBrokerServiceManager.legacyJobIsAbsent(exitCode: 1, standardError: "Operation not permitted", domain: "gui/501", uid: 501))
    }

    func testBrokerProcessScanExcludesOnlyPositivelyUnrelatedUnlinkedProcessNames() throws {
        let detected = try ActionBrokerServiceManager.brokerProcessIDs(in: [11, 12, 13, 14], policy: .developmentMigration,
            executablePath: { pid in pid == 14 ? "/old/moved/Blocks.app/Contents/MacOS/BlocksActionBroker" : nil },
            kernelName: { pid in [11: "browser_crashpad_handler", 12: "bare-modifier-monitor"][pid] },
            hasExited: { $0 == 13 })
        XCTAssertEqual(detected, [14])
        let uncertainNames: [String?] = [nil, "", "BlocksActionBroker", "BlocksActionBro", "BlocksActionBroker-extra"]
        for name in uncertainNames {
            XCTAssertThrowsError(try ActionBrokerServiceManager.brokerProcessIDs(in: [77], policy: .developmentMigration,
                executablePath: { _ in nil }, kernelName: { _ in name }, hasExited: { _ in false }),
                "unknown or possible Broker identity must fail closed")
        }
    }

    func testBrokerProcessScanAllowsUnrelatedActiveUnlinkedExecutableWithKernelNameEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrokerProcessProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("UnlinkedSleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        // Wait for the copied fixture to exec, rather than inspecting the forked
        // test runner before the executable name has changed.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ActionBrokerServiceManager.kernelProcessName(process.processIdentifier) != "UnlinkedSleep",
              process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ActionBrokerServiceManager.kernelProcessName(process.processIdentifier), "UnlinkedSleep")
        try FileManager.default.removeItem(at: executable)
        XCTAssertTrue(process.isRunning, "the probe must not rely on process exit")
        XCTAssertNil(ActionBrokerServiceManager.processExecutablePath(process.processIdentifier),
                     "the live unlinked fixture must exercise proc_pidpath failure")
        let detected = try ActionBrokerServiceManager.brokerProcessIDs(in: [process.processIdentifier], policy: .developmentMigration,
            executablePath: ActionBrokerServiceManager.processExecutablePath,
            kernelName: ActionBrokerServiceManager.kernelProcessName,
            hasExited: { _ in !process.isRunning })
        XCTAssertTrue(detected.isEmpty)
        XCTAssertTrue(process.isRunning, "only this synthetic fixture is terminated by deferred test cleanup")
    }

    func testBrokerScanPolicyFollowsAppOwnedTransportAndOfficialBundlePath() {
        let bundle = URL(fileURLWithPath: "/Applications/Blocks.app")
        XCTAssertEqual(ActionBrokerServiceManager.brokerProcessScanPolicy(usesAppOwnedService: true, bundleURL: bundle),
                       .developmentMigration)
        XCTAssertEqual(ActionBrokerServiceManager.brokerProcessScanPolicy(usesAppOwnedService: false, bundleURL: bundle),
                       .currentBundle(executablePath: "/Applications/Blocks.app/Contents/MacOS/BlocksActionBroker"))
    }

    func testOfficialSandboxScanDoesNotUseStrictMigrationUnknownProcessPolicy() throws {
        let expected = "/Applications/Blocks.app/Contents/MacOS/BlocksActionBroker"
        let paths: [Int32: String] = [11: expected, 12: "/old/moved/Blocks.app/Contents/MacOS/BlocksActionBroker"]
        var kernelNameQueries = 0
        var presenceQueries = 0
        let official = try ActionBrokerServiceManager.brokerProcessIDs(in: [11, 12, 13],
            policy: .currentBundle(executablePath: expected),
            executablePath: { paths[$0] }, kernelName: { _ in kernelNameQueries += 1; return nil },
            hasExited: { _ in presenceQueries += 1; return false })
        XCTAssertEqual(official, [11], "official scan must match only its current bundle, not an old/moved source installation")
        XCTAssertEqual(kernelNameQueries, 0, "sandbox denial must never trigger the migration fallback")
        XCTAssertEqual(presenceQueries, 0)

        let migration = try ActionBrokerServiceManager.brokerProcessIDs(in: [11, 12], policy: .developmentMigration,
            executablePath: { paths[$0] }, kernelName: { _ in nil }, hasExited: { _ in false })
        XCTAssertEqual(migration, [11, 12], "source migration must still include old/moved installations")
        XCTAssertThrowsError(try ActionBrokerServiceManager.brokerProcessIDs(in: [13], policy: .developmentMigration,
            executablePath: { _ in nil }, kernelName: { _ in nil }, hasExited: { _ in false }),
            "unverifiable active processes remain fail-closed only for the strict migration policy")
    }

    func testAppOwnedBusyWorkPreventsDisableAndRecoversAdmission() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.host.drainError = ActionBrokerUpdateError.busy
        let manager = fixture.makeManager(appOwned: true)
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertGreaterThan(fixture.host.localResumeCount, 0)
        XCTAssertEqual(fixture.host.stopCount, 0, "failed drain must not revoke active work")
        guard case .failed = manager.state else { return XCTFail("busy must remain visible") }
    }

    func testAppOwnedBusyDisablePreservesActualInFlightHostServiceRequest() async throws {
        let suite = "AppOwnedBusyHostService.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let handlerStarted = expectation(description: "host service handler suspended")
        let suspension = SuspendedHostServiceHandler(started: handlerStarted)
        let service = ScreenshotActionHostService(
            executeHandler: { data, _ in
                let request = try! JSONDecoder().decode(
                    ActionBrokerRequest<JSONValue>.self,
                    from: data
                )
                await suspension.waitForRelease()
                return try! JSONEncoder().encode(
                    ActionBrokerTerminalResponse<JSONValue>.completed(
                        requestID: request.requestID,
                        actionID: request.actionID,
                        result: .object([:])
                    )
                )
            },
            cancelHandler: { _ in suspension.recordCancellation(); return true }
        )
        let host = AppOwnedHostServiceAdapter(service: service)
        let manager = ActionBrokerServiceManager(
            service: .appOwned(defaults: defaults, inheritedIntent: true),
            host: host,
            retryScheduler: { _, _ in AnyCancellable {} },
            updateRecoveryJournal: .init(),
            usesAppOwnedService: true
        )
        let request = ActionBrokerRequest(
            requestID: ActionRequestID.make(),
            actionID: BlocksAction.screenshotCapture.actionID,
            payload: JSONValue.null
        )
        let data = try JSONEncoder().encode(request)
        let response = Task {
            await withCheckedContinuation { continuation in
                service.execute(data, outputFile: nil) { continuation.resume(returning: $0) }
            }
        }

        await fulfillment(of: [handlerStarted], timeout: 1)
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value

        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(host.stopCount, 0, "a busy app-owned disable must not stop the actual host")
        XCTAssertEqual(host.integrationDisableCount, 0, "stop is the only adapter path that revokes requests")
        XCTAssertEqual(suspension.cancellationCount, 0)

        suspension.release()
        let terminal = try JSONDecoder().decode(
            ActionBrokerTerminalResponse<JSONValue>.self,
            from: await response.value
        )
        XCTAssertEqual(terminal.status, .completed)
        XCTAssertEqual(terminal.requestID, request.requestID)
        XCTAssertFalse(suspension.handlerWasCancelled)
        XCTAssertEqual(suspension.cancellationCount, 0)
    }

    func testAppOwnedPreparedUpdateCancelRestartsActualHostService() async throws {
        let suite = "AppOwnedPreparedHostService.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = ScreenshotActionHostService(
            executeHandler: { _, _ in Data() },
            cancelHandler: { _ in false }
        )
        let host = AppOwnedHostServiceAdapter(service: service)
        let manager = ActionBrokerServiceManager(
            service: .appOwned(defaults: defaults, inheritedIntent: true),
            host: host,
            retryScheduler: { _, _ in AnyCancellable {} },
            updateRecoveryJournal: .init(),
            usesAppOwnedService: true
        )
        XCTAssertEqual(host.startCount, 1)

        try await manager.prepareForApplicationUpdate()
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(host.integrationDisableCount, 1)

        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(host.startCount, 2)
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(manager.state, .enabled)
    }

    func testEnabledRegistrationWithFailedHandshakeNeverAutomaticallyUnregisters() {
        let fixture = BrokerServiceUpdateFixture()
        fixture.host.startError = ActionBrokerUpdateError.untrustedPeer
        let manager = fixture.makeManager()
        XCTAssertNotEqual(manager.state, .enabled, "registration alone is not connection readiness")
        XCTAssertEqual(fixture.registerCount, 0)
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertTrue(fixture.host.prepareTokens.isEmpty)
    }

    func testExplicitDisableDrainsAndPreservesModuleAuthorization() async throws {
        let suite = "BrokerDisable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = CLIModuleAccessPolicy(defaults: defaults)
        access.setEnabled(true, for: .clipboard)
        let fixture = BrokerServiceUpdateFixture()
        let manager = fixture.makeManager(moduleAccess: access)
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertEqual(fixture.unregisterCount, 1)
        XCTAssertEqual(fixture.host.prepareTokens.count, 1)
        XCTAssertEqual(fixture.registerCount, 0)
        XCTAssertEqual(manager.state, .disabled)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertTrue(access.isEnabled(.clipboard))
        manager.setEnabled(true)
        XCTAssertEqual(fixture.registerCount, 1)
        XCTAssertEqual(manager.state, .enabled)
    }

    func testExplicitDisableRefusesBusyOrUnverifiablePeerWithoutUnregistering() async throws {
        for error in [ActionBrokerUpdateError.busy, .untrustedPeer, .unsupportedPeer] {
            let fixture = BrokerServiceUpdateFixture()
            fixture.host.prepareError = error
            let manager = fixture.makeManager()
            manager.setEnabled(false)
            await manager.serviceChangeTask?.value
            XCTAssertEqual(fixture.unregisterCount, 0)
            XCTAssertEqual(fixture.registerCount, 0)
            XCTAssertTrue(manager.isEnabled)
            guard case .failed = manager.state else { return XCTFail("failure must remain visible") }
            XCTAssertEqual(fixture.host.resumeTokens, fixture.host.prepareTokens)
        }
    }

    func testExplicitDisableWhenAlreadyUnregisteredNeedsNoRemoteProof() async throws {
        let fixture = BrokerServiceUpdateFixture()
        fixture.status = .notRegistered
        fixture.processes = []
        let manager = fixture.makeManager()
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertEqual(manager.state, .disabled)
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertTrue(fixture.host.prepareTokens.isEmpty)
        XCTAssertNil(try fixture.journal.load())
    }

    func testPartialUnregisterFailureRestoresServiceAndReportsFailure() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.unregister = {
            fixture.status = .notRegistered
            fixture.processes = []
            throw ActionBrokerUpdateError.serviceDidNotStop
        }
        defer { fixture.unregister = nil }
        let manager = fixture.makeManager()
        manager.setEnabled(false)
        await manager.serviceChangeTask?.value
        XCTAssertEqual(fixture.unregisterCount, 1)
        XCTAssertEqual(fixture.registerCount, 1)
        XCTAssertTrue(manager.isEnabled)
        guard case .failed = manager.state else { return XCTFail("partial disable must not claim success") }
    }

    func testExplicitDisableCancelsPendingApprovalOnlyWithoutLingeringProcess() async throws {
        for processes: [Int32] in [[], [77]] {
            let fixture = BrokerServiceUpdateFixture()
            fixture.status = .requiresApproval
            fixture.processes = processes
            let manager = fixture.makeManager()
            manager.setEnabled(false)
            await manager.serviceChangeTask?.value
            XCTAssertEqual(fixture.unregisterCount, processes.isEmpty ? 1 : 0)
            XCTAssertEqual(fixture.registerCount, 0)
            XCTAssertTrue(fixture.host.prepareTokens.isEmpty)
            XCTAssertNil(try fixture.journal.load())
            if processes.isEmpty {
                XCTAssertEqual(manager.state, .disabled)
                XCTAssertEqual(fixture.status, .notRegistered)
            } else {
                XCTAssertEqual(fixture.status, .requiresApproval)
                XCTAssertEqual(fixture.processes, [77])
                guard case .failed = manager.state else { return XCTFail("lingering peer must block disable") }
            }
        }
    }

    func testExplicitDisableCancellationResumesAdmissionWithoutUnregister() async throws {
        let fixture = BrokerServiceUpdateFixture()
        fixture.host.onResume = { try Task.checkCancellation() }
        let entered = expectation(description: "prepare suspended")
        var release: CheckedContinuation<Void, Never>?
        fixture.host.onPrepare = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let manager = fixture.makeManager()
        manager.setEnabled(false)
        let operation = manager.serviceChangeTask
        await fulfillment(of: [entered], timeout: 1)
        do {
            try await manager.prepareForApplicationUpdate()
            XCTFail("update must not interleave with explicit disable")
        } catch { }
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertTrue(fixture.host.resumeTokens.isEmpty, "aborted update must not resume another transaction")
        operation?.cancel()
        release?.resume()
        await operation?.value
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertEqual(fixture.host.resumeTokens, fixture.host.prepareTokens)
        XCTAssertEqual(fixture.host.successfulResumeCount, 1)
        XCTAssertNil(try fixture.journal.load(), "independent recovery must finish despite disable cancellation")
        XCTAssertTrue(manager.isEnabled)
    }

    func testQuitFencesSuspendedExplicitDisableAndPreservesRecoveryIntent() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let entered = expectation(description: "prepare suspended")
        var release: CheckedContinuation<Void, Never>?
        fixture.host.onPrepare = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let manager = fixture.makeManager()
        manager.setEnabled(false)
        let operation = manager.serviceChangeTask
        await fulfillment(of: [entered], timeout: 1)
        manager.setEnabled(true)
        XCTAssertEqual(fixture.registerCount, 0, "no interleaved register during disable")
        manager.beginApplicationQuit()
        release?.resume()
        await operation?.value
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertTrue(fixture.host.resumeTokens.isEmpty)
        XCTAssertNotNil(try fixture.journal.load())
    }

    func testExplicitDisableDoesNotInterfereWithPreparedUpdate() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let manager = fixture.makeManager()
        try await manager.prepareForApplicationUpdate()
        manager.setEnabled(false)
        XCTAssertNil(manager.serviceChangeTask)
        XCTAssertNotNil(try fixture.journal.load())
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(manager.state, .enabled)
    }

    func testHostRequestAdmissionWaitsForTrustedReplacementRegistration() {
        let lifecycle = ActionBrokerHostConnectionLifecycle()
        let first = lifecycle.beginConnection().generation
        XCTAssertFalse(lifecycle.requestServiceResume())
        XCTAssertFalse(lifecycle.didRegisterTrustedHost(for: first), "unacknowledged endpoint must stay closed")
        XCTAssertTrue(lifecycle.claimCompletion(for: first))
        XCTAssertTrue(lifecycle.didRegisterTrustedHost(for: first))
        XCTAssertTrue(lifecycle.requestServiceResume(), "an unchanged verified endpoint can resume immediately")
        _ = lifecycle.stop()
        XCTAssertFalse(lifecycle.requestServiceResume())
        let replacement = lifecycle.beginConnection().generation
        XCTAssertFalse(lifecycle.didRegisterTrustedHost(for: first), "stale acknowledgement must not reopen admission")
        XCTAssertTrue(lifecycle.claimCompletion(for: replacement))
        XCTAssertTrue(lifecycle.didRegisterTrustedHost(for: replacement))
    }

    func testBrokerCannotFreezeOneConnectionWhileAnotherRequestIsActive() throws {
        let gate = ActionBrokerUpdateAdmission()
        let token = UUID().uuidString
        let request = try XCTUnwrap(gate.begin())
        XCTAssertThrowsError(try gate.prepare(token: token))
        let otherConnection = try XCTUnwrap(gate.begin())
        otherConnection.release()
        request.release()
        try gate.prepare(token: token)
        XCTAssertNil(gate.begin())
        try gate.resume(token: token)
        XCTAssertNotNil(gate.begin())
        XCTAssertThrowsError(try gate.prepare(token: token), "late prepare must not undo a cancellation")
    }

    func testBusyOrUnsupportedBrokerNeverReachesServiceUnregister() async throws {
        for error in [ActionBrokerUpdateError.busy, .unsupportedPeer] {
            let fixture = BrokerServiceUpdateFixture()
            fixture.host.prepareError = error
            if case .unsupportedPeer = error { fixture.host.resumeError = error }
            let manager = fixture.makeManager()
            do {
                try await manager.prepareForApplicationUpdate()
                XCTFail("unsafe Broker was accepted")
            } catch { }
            XCTAssertEqual(fixture.unregisterCount, 0)
            XCTAssertEqual(fixture.status, .enabled)
            XCTAssertTrue(manager.isEnabled)
            await manager.resumeAfterCancelledApplicationUpdate()
            XCTAssertEqual(fixture.unregisterCount, 0)
            XCTAssertEqual(fixture.host.resumeTokens.count, 1)
            if case .unsupportedPeer = error { XCTAssertNotNil(try fixture.journal.load()) }
        }
    }

    func testWaitsForAsyncServiceRemovalAndPreservesEnabledIntentUntilRecovery() async throws {
        let fixture = BrokerServiceUpdateFixture()
        var finishUnregister: CheckedContinuation<Void, Never>?
        let unregisterStarted = expectation(description: "async unregister entered after idle proof")
        fixture.unregister = {
            await withCheckedContinuation { continuation in
                finishUnregister = continuation
                unregisterStarted.fulfill()
            }
            fixture.status = .notRegistered
            fixture.processes = []
        }
        defer { fixture.unregister = nil }
        let manager = fixture.makeManager()
        var finished = false
        let preparation = Task {
            try await manager.prepareForApplicationUpdate()
            finished = true
        }
        await fulfillment(of: [unregisterStarted], timeout: 1)
        XCTAssertFalse(finished)
        XCTAssertEqual(fixture.host.prepareTokens.count, 1)
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertTrue(manager.isEnabled, "temporary service withdrawal must not change the user's preference")
        finishUnregister?.resume()
        try await preparation.value
        XCTAssertFalse(manager.isServiceRegistered)
        XCTAssertTrue(manager.isEnabled)
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(fixture.registerCount, 1)
        XCTAssertEqual(fixture.status, .enabled)
        XCTAssertEqual(fixture.host.resumeTokens, fixture.host.prepareTokens)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(manager.state, .enabled)
    }

    func testRecoveryRequiringUserApprovalKeepsTicketAndDoesNotClaimEnabled() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let manager = fixture.makeManager()
        try await manager.prepareForApplicationUpdate()
        fixture.registrationRequiresApproval = true
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(manager.state, .requiresApproval)
        XCTAssertFalse(manager.isServiceRegistered)
        XCTAssertTrue(manager.isEnabled, "saved intent is distinct from actual registration")
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertTrue(fixture.host.resumeTokens.isEmpty)
    }

    func testFailedUnregisterKeepsOldServiceAndResumesItsAdmission() async throws {
        let fixture = BrokerServiceUpdateFixture()
        fixture.unregister = { throw ActionBrokerUpdateError.serviceDidNotStop }
        let manager = fixture.makeManager()
        do { try await manager.prepareForApplicationUpdate(); XCTFail("unregister failure was hidden") }
        catch { }
        XCTAssertEqual(fixture.status, .enabled)
        XCTAssertEqual(fixture.processes, [77])
        XCTAssertNotNil(try fixture.journal.load())
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(fixture.registerCount, 0)
        XCTAssertEqual(fixture.host.resumeTokens, fixture.host.prepareTokens)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(manager.state, .enabled)
    }

    func testNewAppRestoresPreviouslyEnabledBrokerFromRecoveryJournal() async throws {
        let fixture = BrokerServiceUpdateFixture()
        fixture.status = .notRegistered
        fixture.processes = []
        let ticket = ActionBrokerUpdateRecoveryTicket(processID: 77)
        try fixture.journal.save(ticket)
        let started = expectation(description: "new host starts after journal recovery")
        fixture.host.didStart = { started.fulfill() }
        let manager = fixture.makeManager()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(fixture.registerCount, 1)
        XCTAssertEqual(fixture.host.resumeTokens, [ticket.token])
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(manager.state, .enabled)
    }

    func testQuitDuringStartupRecoveryPreservesJournalAndFencesLateCompletion() async throws {
        let fixture = BrokerServiceUpdateFixture()
        let ticket = ActionBrokerUpdateRecoveryTicket(processID: 77)
        try fixture.journal.save(ticket)
        let entered = expectation(description: "remote recovery suspended")
        var release: CheckedContinuation<Void, Never>?
        fixture.host.onResume = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let manager = fixture.makeManager()
        await fulfillment(of: [entered], timeout: 1)
        manager.beginApplicationQuit()
        try await manager.prepareForApplicationUpdate(stopService: false)
        release?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertEqual(fixture.host.localResumeCount, 0)
    }

    func testDisabledPreferenceAndOrdinaryOfficialQuitDoNotToggleRegistration() async throws {
        let disabled = BrokerServiceUpdateFixture()
        disabled.status = .notRegistered
        disabled.processes = []
        let manager = disabled.makeManager()
        try await manager.prepareForApplicationUpdate()
        await manager.resumeAfterCancelledApplicationUpdate()
        XCTAssertEqual(disabled.unregisterCount, 0)
        XCTAssertEqual(disabled.registerCount, 0)
        XCTAssertFalse(manager.isEnabled)

        let enabled = BrokerServiceUpdateFixture()
        let ordinaryQuit = enabled.makeManager()
        try await ordinaryQuit.prepareForApplicationUpdate(stopService: false)
        XCTAssertEqual(enabled.unregisterCount, 0)
        XCTAssertTrue(enabled.host.prepareTokens.isEmpty)
        await ordinaryQuit.resumeAfterCancelledApplicationUpdate()
        XCTAssertTrue(ordinaryQuit.isEnabled)
    }

    func testLingeringUnregisteredBrokerFailsClosedWithoutKillingIt() async {
        let fixture = BrokerServiceUpdateFixture()
        fixture.status = .notRegistered
        fixture.processes = [77]
        let manager = fixture.makeManager()
        do { try await manager.prepareForApplicationUpdate(); XCTFail("lingering binary was ignored") }
        catch { }
        XCTAssertEqual(fixture.unregisterCount, 0)
        XCTAssertEqual(fixture.processes, [77])
        await manager.resumeAfterCancelledApplicationUpdate()
    }
}

@MainActor
private final class BrokerServiceUpdateFixture {
    var status: SMAppService.Status = .enabled
    var processes: [Int32] = [77]
    var registerCount = 0
    var unregisterCount = 0
    var registrationRequiresApproval = false
    var unregister: (() async throws -> Void)?
    var legacyStatus: SMAppService.Status = .notRegistered
    var legacyProcesses: [Int32] = []
    var legacyJobAbsent = true
    var legacyUnregisterCount = 0
    var legacyUnregisterError: Error?
    var legacyVerificationError: Error?
    var legacyReappearsAfterUnregister = false
    let host = BrokerServiceUpdateHost()
    let journal = ActionBrokerUpdateRecoveryJournal()

    func makeManager(moduleAccess: CLIModuleAccessPolicy? = nil, appOwned: Bool = false,
                     legacyStatus: SMAppService.Status = .notRegistered) -> ActionBrokerServiceManager {
        self.legacyStatus = legacyStatus
        let control = ActionBrokerServiceControl(status: { self.status }, register: {
            self.registerCount += 1
            if self.registrationRequiresApproval {
                self.status = .requiresApproval
                throw ActionBrokerUpdateError.requiresApproval
            }
            self.status = .enabled
            self.processes = [88]
        }, unregister: {
            self.unregisterCount += 1
            self.status = .notRegistered
            self.processes = []
        }, unregisterAndWait: {
            self.unregisterCount += 1
            if let unregister = self.unregister { try await unregister() }
            else { self.status = .notRegistered; self.processes = [] }
        })
        return ActionBrokerServiceManager(service: control, host: host,
            retryScheduler: { _, _ in AnyCancellable {} }, updateRecoveryJournal: journal,
            runningBrokerProcessIDs: { appOwned ? self.legacyProcesses : self.processes }, processHasExited: { !self.processes.contains($0) },
            moduleAccess: moduleAccess, usesAppOwnedService: appOwned,
            legacyService: .init(status: { self.legacyStatus }, register: { XCTFail("legacy service must never be registered") }, unregister: {},
                unregisterAndWait: {
                    self.legacyUnregisterCount += 1
                    if let error = self.legacyUnregisterError { throw error }
                    self.legacyStatus = .notRegistered
                    if self.legacyReappearsAfterUnregister { self.legacyJobAbsent = false }
                }),
            legacyLaunchdJobsAreAbsent: {
                if let error = self.legacyVerificationError { throw error }
                return self.legacyJobAbsent
            })
    }
}

@MainActor
private final class BrokerServiceUpdateHost: ActionBrokerHosting {
    var stopCount = 0
    var drainCount = 0
    var drainError: Error?
    var onPrepare: (() async -> Void)?
    var startError: Error?
    var onResume: (() async throws -> Void)?
    var successfulResumeCount = 0
    var localResumeCount = 0
    var prepareError: Error?
    var resumeError: Error?
    var prepareTokens: [String] = []
    var resumeTokens: [String] = []
    var didStart: (() -> Void)?
    func start(completion: @escaping (Result<Void, Error>) -> Void, onInvalidated: @escaping () -> Void) {
        completion(startError.map { .failure($0) } ?? .success(())); didStart?()
    }
    func stop() { stopCount += 1 }
    func pauseAndDrainForApplicationUpdate() async throws {
        drainCount += 1
        if let drainError { throw drainError }
    }
    func resumeAfterCancelledApplicationUpdate() { localResumeCount += 1 }
    func prepareBrokerForApplicationUpdate(token: String) async throws -> Int32 {
        prepareTokens.append(token)
        await onPrepare?()
        if let prepareError { throw prepareError }
        return 77
    }
    func resumeBrokerAfterCancelledApplicationUpdate(token: String) async throws {
        resumeTokens.append(token)
        try await onResume?()
        if let resumeError { throw resumeError }
        successfulResumeCount += 1
    }
}

@MainActor
private final class SuspendedHostServiceHandler {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var handlerWasCancelled = false
    private(set) var cancellationCount = 0

    init(started: XCTestExpectation) {
        self.started = started
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        handlerWasCancelled = Task.isCancelled
    }

    func release() {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }

    func recordCancellation() {
        cancellationCount += 1
    }
}

/// Deliberately models the dangerous old stop path: stopping the host disables
/// the actual service and revokes its requests. A busy app-owned disable must
/// never reach this adapter method.
@MainActor
private final class AppOwnedHostServiceAdapter: ActionBrokerHosting {
    private let service: ScreenshotActionHostService
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var integrationDisableCount = 0

    init(service: ScreenshotActionHostService) {
        self.service = service
    }

    func start(
        completion: @escaping (Result<Void, Error>) -> Void,
        onInvalidated _: @escaping () -> Void
    ) {
        startCount += 1
        service.setIntegrationEnabled(true)
        completion(.success(()))
    }

    func stop() {
        stopCount += 1
        integrationDisableCount += 1
        service.setIntegrationEnabled(false)
    }

    func pauseAndDrainForApplicationUpdate() async throws {
        try service.pauseForApplicationUpdate()
    }

    func resumeAfterCancelledApplicationUpdate() {
        service.resumeAfterCancelledApplicationUpdate()
    }
}
