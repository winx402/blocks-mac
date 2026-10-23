import AppKit
import BlocksCore
import XCTest
@testable import Blocks

@MainActor
final class PermissionRestartTests: XCTestCase {
    func testPreparationFailureFeedbackUsesTypedAllowlistAndNeverRawErrorText() {
        let secret = "busy secret /Users/private/file credential"
        let unknown = NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        let cases: [(String, Error, PermissionRestartFailure)] = [
            ("helper", SelectionHelperUpdatePreparationFailure.helperNotPaired, .helperNotPaired),
            ("helper", SelectionHelperUpdatePreparationFailure.preparationUnavailable, .connectionUnavailable),
            ("helper", SelectionHelperUpdatePreparationFailure.preparationRejected, .componentNotReady),
            ("helper", SelectionAgentServiceFailure.keychainUnavailable, .authenticationUnavailable),
            ("helper", SelectionAgentServiceFailure.connectionFailed, .connectionUnavailable),
            ("helper", SelectionAgentServiceFailure.timedOut, .timedOut),
            ("helper", ApplicationOperationAdmissionGate.AdmissionError.busy(secret), .busy),
            ("helper", ApplicationOperationAdmissionGate.AdmissionError.paused(secret), .recoveryConflict),
            ("actionBroker", ActionBrokerUpdateError.busy, .busy),
            ("actionBroker", ActionBrokerUpdateError.timedOut, .timedOut),
            ("actionBroker", ActionBrokerUpdateError.connectionUnavailable, .connectionUnavailable),
            ("actionBroker", ActionBrokerUpdateError.untrustedPeer, .authenticationUnavailable),
            ("actionBroker", ActionBrokerUpdateError.unsupportedPeer, .componentNotReady),
            ("actionBroker", ActionBrokerUpdateError.preparationRejected, .componentNotReady),
            ("actionBroker", ActionBrokerUpdateError.requiresApproval, .componentNotReady),
            ("actionBroker", ActionBrokerUpdateError.serviceDidNotStop, .componentNotReady),
            ("actionBroker", ActionBrokerUpdateError.legacyRegistrationRequiresMigration, .componentNotReady),
            ("actionBroker", ActionBrokerUpdateError.preparationInProgress, .recoveryConflict),
            ("actionBroker", ActionBrokerUpdateError.invalidRecoveryState, .recoveryConflict),
            ("translation", ApplicationOperationAdmissionGate.AdmissionError.busy(secret), .busy),
            ("translation", ApplicationOperationAdmissionGate.AdmissionError.paused(secret), .recoveryConflict),
            ("app", ApplicationLifecycleCoordinator.SafetyError.preparationInProgress, .recoveryConflict),
            ("app", ApplicationLifecycleCoordinator.SafetyError.configurationLocked, .recoveryConflict),
            ("app", ApplicationLifecycleCoordinator.SafetyError.missingParticipants([secret]), .componentNotReady),
            ("database", unknown, .database),
            ("helper", unknown, .unknown),
            ("actionBroker", unknown, .unknown),
            (secret, unknown, .unknown),
        ]
        for (participant, error, expected) in cases {
            let wrapped = ApplicationLifecycleCoordinator.ParticipantDrainError(
                participantID: participant, underlying: error
            )
            let failure = PermissionRestartFailure(preparationError: wrapped)
            XCTAssertEqual(failure, expected, "participant=\(participant)")
            XCTAssertFalse(failure.message.contains(secret))
            XCTAssertNotEqual(failure.message, failure.localizationKey)
            if expected != .busy { XCTAssertNotEqual(failure.message, PermissionRestartFailure.busy.message) }
        }
        XCTAssertEqual(PermissionRestartFailure(preparationError: unknown), .unknown)
        for failure in PermissionRestartFailure.allCases {
            XCTAssertNotEqual(failure.message, failure.localizationKey)
            XCTAssertFalse(failure.message.contains(secret))
        }
        XCTAssertTrue(PermissionRestartFailure.helperNotPaired.message.contains("blocksHelper"))
        XCTAssertFalse(PermissionRestartFailure.helperNotPaired.message.contains("Blocks Selection Helper"))
        XCTAssertNotEqual(L10n.string("settings.permissionRecovery.keptOpen"), PermissionRestartFailure.busy.message)
    }

    func testUnpairedHelperReasonSurvivesPreparationRecoveryAndChangesOnExplicitRetry() async {
        let failures: [Error] = [
            ApplicationLifecycleCoordinator.ParticipantDrainError(
                participantID: "helper", underlying: SelectionHelperUpdatePreparationFailure.helperNotPaired
            ),
            ApplicationOperationAdmissionGate.AdmissionError.busy("fixture"),
            NSError(domain: "private error", code: 1),
        ]
        var preparations = 0
        var resumes = 0
        var launches = 0
        var terminations = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, pid, completion in launches += 1; completion(pid + 1, nil) },
            applicationTerminator: {
                terminations += 1
                termination.finalizeTerminationResourcesIfNeeded()
            },
            safety: PermissionRestartSafety(prepare: {
                let index = preparations
                preparations += 1
                if index < failures.count { throw failures[index] }
            }, resume: { resumes += 1 }),
            terminationCoordinator: termination,
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        for (index, reason) in [PermissionRestartFailure.helperNotPaired, .busy, .unknown].enumerated() {
            let failed = expectation(description: "typed failure after recovery \(index)")
            actions.restartForPermissionRefresh {
                XCTAssertEqual($0, .failed(reason))
                XCTAssertEqual(resumes, index + 1, "Report failure only after reversible recovery")
                failed.fulfill()
            }
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertEqual(launches, 0)
            XCTAssertEqual(terminations, 0)
        }
        let scheduled = expectation(description: "retry can safely proceed without a stale failure")
        actions.restartForPermissionRefresh { XCTAssertEqual($0, .scheduled); scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertEqual(preparations, 4)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(terminations, 1)
    }

    func testDuplicateRequestsWaitForOneHandoffAndTerminateOnce() async {
        var launchCount = 0
        var terminateCount = 0
        var pending: (@Sendable (pid_t?, Error?) -> Void)?
        var results: [PermissionRestartResult] = []
        let launched = expectation(description: "prepared lifecycle starts one launcher")
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let parentPID = getpid()
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, _, completion in
                launchCount += 1
                pending = completion
                launched.fulfill()
            },
            applicationTerminator: {
                terminateCount += 1
                termination.finalizeTerminationResourcesIfNeeded()
            },
            safety: PermissionRestartSafety(prepare: {}, resume: {}),
            terminationCoordinator: termination,
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh { results.append($0) }
        actions.restartForPermissionRefresh { results.append($0) }
        await fulfillment(of: [launched], timeout: 1)
        XCTAssertEqual(launchCount, 1)
        XCTAssertTrue(results.isEmpty, "A second tap must not report readiness early")
        XCTAssertEqual(terminateCount, 0)

        pending?(parentPID + 1, nil)
        pending?(parentPID + 1, nil)
        XCTAssertEqual(results, [.scheduled, .scheduled])
        XCTAssertEqual(terminateCount, 1)

        actions.restartForPermissionRefresh { results.append($0) }
        XCTAssertEqual(results, [.scheduled, .scheduled, .scheduled])
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(terminateCount, 1)
    }

    func testFailedHandoffRetainsOldAppAndCanRetry() async {
        var launchCount = 0
        var terminateCount = 0
        var results: [PermissionRestartResult] = []
        var resumeCount = 0
        let failed = expectation(description: "failed launcher restores the old app twice")
        failed.expectedFulfillmentCount = 2
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, _, completion in
                launchCount += 1
                completion(nil, CocoaError(.fileReadUnknown))
            },
            applicationTerminator: { terminateCount += 1 },
            safety: PermissionRestartSafety(prepare: {}, resume: { resumeCount += 1 }),
            terminationCoordinator: AppTerminationCoordinator(replyHandler: { _ in }),
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh {
            results.append($0)
            failed.fulfill()
            actions.restartForPermissionRefresh {
                results.append($0)
                failed.fulfill()
            }
        }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(results, [.failed(.launchFailed), .failed(.launchFailed)])
        XCTAssertEqual(launchCount, 2)
        XCTAssertEqual(resumeCount, 2)
        XCTAssertEqual(terminateCount, 0)
    }

    func testUnconfiguredRestartSafetyFailsWithoutLaunchingOrTerminating() {
        var launches = 0
        var terminations = 0
        var result: PermissionRestartResult?
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, _, _ in launches += 1 },
            applicationTerminator: { terminations += 1 },
            safety: PermissionRestartSafety(),
            terminationCoordinator: AppTerminationCoordinator(replyHandler: { _ in }),
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh { result = $0 }

        XCTAssertEqual(result, .failed(.componentNotReady))
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(terminations, 0)
    }

    func testDuplicateRequestsWaitForPreparationBeforeLaunching() async {
        let preparing = expectation(description: "reversible preparation started")
        let launched = expectation(description: "launcher starts after preparation")
        var finishPreparation: CheckedContinuation<Void, Never>?
        var preparations = 0
        var launches = 0
        var results: [PermissionRestartResult] = []
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, pid, completion in
                launches += 1
                launched.fulfill()
                completion(pid + 1, nil)
            },
            applicationTerminator: { termination.finalizeTerminationResourcesIfNeeded() },
            safety: PermissionRestartSafety(prepare: {
                preparations += 1
                await withCheckedContinuation { finishPreparation = $0; preparing.fulfill() }
            }, resume: {}),
            terminationCoordinator: termination,
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh { results.append($0) }
        actions.restartForPermissionRefresh { results.append($0) }
        await fulfillment(of: [preparing], timeout: 1)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(launches, 0)
        XCTAssertTrue(results.isEmpty)

        finishPreparation?.resume()
        await fulfillment(of: [launched], timeout: 1)
        XCTAssertEqual(results, [.scheduled, .scheduled])
        XCTAssertEqual(launches, 1)
    }

    func testRejectedPreparationResumesWithoutLaunchingAndCanRetry() async {
        let failed = expectation(description: "preparation rejected and restored")
        let scheduled = expectation(description: "retry accepts a safe handoff")
        var preparations = 0
        var resumes = 0
        var launches = 0
        var terminations = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, pid, completion in launches += 1; completion(pid + 1, nil) },
            applicationTerminator: {
                terminations += 1
                termination.finalizeTerminationResourcesIfNeeded()
            },
            safety: PermissionRestartSafety(prepare: {
                preparations += 1
                if preparations == 1 { throw CocoaError(.fileReadUnknown) }
            }, resume: { resumes += 1 }),
            terminationCoordinator: termination,
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .failed(.unknown)); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(terminations, 0)

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .scheduled); scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(terminations, 1)
    }

    func testTimedOutPreparationKeepsOwnershipUntilLateCompletionAndNeverExits() async {
        let preparing = expectation(description: "non-cooperative preparation started")
        let failed = expectation(description: "bounded timeout reports failure")
        let resumed = expectation(description: "late preparation is finally restored")
        let retry = expectation(description: "retry prepares after real recovery")
        var finishPreparation: CheckedContinuation<Void, Never>?
        var preparations = 0
        var resumes = 0
        var launches = 0
        var terminations = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, pid, completion in launches += 1; completion(pid + 1, nil) },
            applicationTerminator: {
                terminations += 1
                termination.finalizeTerminationResourcesIfNeeded()
            },
            safety: PermissionRestartSafety(prepare: {
                preparations += 1
                if preparations == 1 {
                    await withCheckedContinuation { finishPreparation = $0; preparing.fulfill() }
                }
            }, resume: { resumes += 1; resumed.fulfill() }),
            terminationCoordinator: termination,
            preparationTimeoutNanoseconds: 20_000_000,
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .failed(.timedOut)); failed.fulfill() }
        await fulfillment(of: [preparing, failed], timeout: 1)
        XCTAssertEqual(resumes, 0, "Do not clear lifecycle ownership while prepare is still running")
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(terminations, 0)
        var concurrentRetry: PermissionRestartResult?
        actions.restartForPermissionRefresh { concurrentRetry = $0 }
        XCTAssertEqual(concurrentRetry, .failed(.recoveryConflict))
        XCTAssertEqual(preparations, 1)

        finishPreparation?.resume()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(launches, 0, "A cancelled late success must never launch")
        XCTAssertEqual(terminations, 0)

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .scheduled); retry.fulfill() }
        await fulfillment(of: [retry], timeout: 1)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(terminations, 1)
    }

    func testUncommittedHandoffTimeoutRestoresAppAndClearsScheduledGateForRetry() async {
        let scheduled = expectation(description: "launcher accepted handoff")
        let resumed = expectation(description: "AppKit did not terminate, so app resumed")
        let retried = expectation(description: "cleared handoff can be retried")
        var preparations = 0
        var resumes = 0
        var launches = 0
        var terminations = 0
        var callbacks = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, pid, completion in launches += 1; completion(pid + 1, nil) },
            applicationTerminator: {
                terminations += 1
                if terminations == 2 { termination.finalizeTerminationResourcesIfNeeded() }
            },
            safety: PermissionRestartSafety(prepare: { preparations += 1 }, resume: {
                resumes += 1
                resumed.fulfill()
            }),
            terminationCoordinator: termination,
            handoffTimeoutNanoseconds: 20_000_000,
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh {
            callbacks += 1
            XCTAssertEqual($0, .scheduled)
            scheduled.fulfill()
        }
        await fulfillment(of: [scheduled, resumed], timeout: 1)
        XCTAssertFalse(termination.isQuitting)
        XCTAssertEqual(callbacks, 1, "Completion reports handoff once, not eventual process exit")
        XCTAssertEqual(resumes, 1)

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .scheduled); retried.fulfill() }
        await fulfillment(of: [retried], timeout: 1)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(terminations, 2)
    }

    func testQuitDuringPreparationPreventsRelaunchAndDoesNotResumeCommittedQuit() async {
        let preparing = expectation(description: "permission preparation started")
        let failed = expectation(description: "ordinary quit won the interleave")
        var finishPreparation: CheckedContinuation<Void, Never>?
        var resumes = 0
        var launches = 0
        var terminations = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, _, _ in launches += 1 },
            applicationTerminator: { terminations += 1 },
            safety: PermissionRestartSafety(prepare: {
                await withCheckedContinuation { finishPreparation = $0; preparing.fulfill() }
            }, resume: { resumes += 1 }),
            terminationCoordinator: termination,
            cancelHandoff: { _ in true },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .failed(.recoveryConflict)); failed.fulfill() }
        await fulfillment(of: [preparing], timeout: 1)
        XCTAssertEqual(termination.requestTermination(), .terminateLater)
        finishPreparation?.resume()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(termination.isQuitting)
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(terminations, 0)
        XCTAssertEqual(resumes, 0)
    }

    func testHandoffRecoveryAwaitsOwnedLauncherExitBeforeResumingQuitOrRetry() async {
        let scheduled = expectation(description: "prepared handoff accepted")
        let cancelling = expectation(description: "owned launcher exit is not yet confirmed")
        let resumed = expectation(description: "confirmed exit permits business recovery")
        let retried = expectation(description: "retry begins only after confirmed recovery")
        var confirmExit: CheckedContinuation<Bool, Never>?
        var preparations = 0
        var launches = 0
        var resumes = 0
        var terminations = 0
        var cancellations = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, pid, completion in launches += 1; completion(pid + 1, nil) },
            applicationTerminator: {
                terminations += 1
                if terminations == 2 { termination.finalizeTerminationResourcesIfNeeded() }
            },
            safety: PermissionRestartSafety(prepare: { preparations += 1 }, resume: {
                resumes += 1
                resumed.fulfill()
            }),
            terminationCoordinator: termination,
            handoffTimeoutNanoseconds: 20_000_000,
            cancelHandoff: { _ in
                cancellations += 1
                if cancellations == 1 { return false }
                if cancellations == 2 {
                    return await withCheckedContinuation { confirmExit = $0; cancelling.fulfill() }
                }
                return true
            },
            commitHandoff: { _ in true }
        )

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .scheduled); scheduled.fulfill() }
        await fulfillment(of: [scheduled, cancelling], timeout: 1)
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(termination.requestTermination(), .terminateCancel,
                       "Keep the parent alive until its old launcher cannot reopen it")
        XCTAssertFalse(termination.isQuitting)
        var blockedRetry: PermissionRestartResult?
        actions.restartForPermissionRefresh { blockedRetry = $0 }
        XCTAssertEqual(blockedRetry, .failed(.recoveryConflict))
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(launches, 1)

        confirmExit?.resume(returning: true)
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(resumes, 1)
        XCTAssertFalse(termination.cancelPreparedRestart(), "The recovery already cancelled its arm")
        actions.restartForPermissionRefresh { XCTAssertEqual($0, .scheduled); retried.fulfill() }
        await fulfillment(of: [retried], timeout: 1)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(terminations, 2)
    }

    func testOwnedLauncherCancellationPreventsLateOpenAfterParentExits() async throws {
        let parent = try makeSleepingParent()
        defer { stop(parent) }
        let launcher = try makeScriptProcess(parentPID: parent.processIdentifier, maxPollCount: 150)
        defer { stop(launcher.process) }
        let ready = launcher.output.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(data: ready, encoding: .utf8), "READY\n")
        XCTAssertTrue(parent.isRunning)
        let ownership = PermissionRelaunchProcessOwnership()
        ownership.retainOwnedHandoff(launcher.process, parentProcessID: parent.processIdentifier)
        XCTAssertFalse(ownership.canLaunch(parentProcessID: parent.processIdentifier))

        let cancelled = await ownership.cancelOwnedHandoff(parentProcessID: parent.processIdentifier)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(launcher.process.isRunning)
        XCTAssertTrue(ownership.canLaunch(parentProcessID: parent.processIdentifier))
        stop(parent)
        let output = launcher.output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(data: output, encoding: .utf8), "",
                       "A cancelled owned launcher must not open after its parent later exits")
    }

    func testQuitBeforeDelayedReadyDoesNotCommitPermissionHandoff() async {
        let launched = expectation(description: "launcher spawned, readiness still pending")
        let failed = expectation(description: "manual quit prevents permission commit")
        var pending: (@Sendable (pid_t?, Error?) -> Void)?
        var commits = 0
        var cancellations = 0
        var terminations = 0
        var resumes = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, _, completion in pending = completion; launched.fulfill() },
            applicationTerminator: { terminations += 1 },
            safety: PermissionRestartSafety(prepare: {}, resume: { resumes += 1 }),
            terminationCoordinator: termination,
            cancelHandoff: { _ in cancellations += 1; return true },
            commitHandoff: { _ in commits += 1; return true }
        )

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .failed(.recoveryConflict)); failed.fulfill() }
        await fulfillment(of: [launched], timeout: 1)
        XCTAssertEqual(termination.requestTermination(), .terminateLater,
                       "No permission restart fence may change ordinary quit before READY")
        pending?(getpid() + 1, nil)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(terminations, 0)
        XCTAssertEqual(resumes, 0)
        XCTAssertTrue(termination.isQuitting)
    }

    func testRejectedHandoffCommitCancelsArmAndRestoresBeforeRetry() async {
        let failed = expectation(description: "COMMIT rejected before termination")
        let retry = expectation(description: "safe retry commits once")
        var commits = 0
        var cancellations = 0
        var resumes = 0
        var terminations = 0
        let termination = AppTerminationCoordinator(replyHandler: { _ in })
        let actions = DefaultPermissionSystemActions(
            relauncher: { _, pid, completion in completion(pid + 1, nil) },
            applicationTerminator: {
                terminations += 1
                termination.finalizeTerminationResourcesIfNeeded()
            },
            safety: PermissionRestartSafety(prepare: {}, resume: { resumes += 1 }),
            terminationCoordinator: termination,
            cancelHandoff: { _ in cancellations += 1; return true },
            commitHandoff: { _ in commits += 1; return commits > 1 }
        )

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .failed(.launchFailed)); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(terminations, 0)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(resumes, 1)
        XCTAssertFalse(termination.isQuitting)
        XCTAssertFalse(termination.cancelPreparedRestart())

        actions.restartForPermissionRefresh { XCTAssertEqual($0, .scheduled); retry.fulfill() }
        await fulfillment(of: [retry], timeout: 1)
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(terminations, 1)
    }

    func testUncommittedLauncherEOFNeverOpensAfterParentExits() throws {
        let parent = try makeSleepingParent()
        defer { stop(parent) }
        let launcher = try makeScriptProcess(
            parentPID: parent.processIdentifier,
            maxPollCount: 150,
            commit: false
        )
        defer { stop(launcher.process) }
        let ready = launcher.output.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(data: ready, encoding: .utf8), "READY\n")

        stop(parent)
        try launcher.input.fileHandleForWriting.close()
        launcher.process.waitUntilExit()
        let output = launcher.output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(data: output, encoding: .utf8), "")
        XCTAssertEqual(launcher.process.terminationStatus, 4)
    }

    func testOwnedLauncherCommitOpensOnlyOnceAfterParentExit() async throws {
        let parent = try makeSleepingParent()
        defer { stop(parent) }
        let launcher = try makeScriptProcess(
            parentPID: parent.processIdentifier, maxPollCount: 150, commit: false
        )
        defer { stop(launcher.process) }
        let ready = launcher.output.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(data: ready, encoding: .utf8), "READY\n")
        let ownership = PermissionRelaunchProcessOwnership()
        ownership.retainOwnedHandoff(
            launcher.process, parentProcessID: parent.processIdentifier,
            commitInput: launcher.input.fileHandleForWriting
        )

        XCTAssertTrue(ownership.commitOwnedHandoff(parentProcessID: parent.processIdentifier))
        XCTAssertTrue(ownership.commitOwnedHandoff(parentProcessID: parent.processIdentifier))
        XCTAssertTrue(parent.isRunning)
        stop(parent)
        launcher.process.waitUntilExit()
        let output = launcher.output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(data: output, encoding: .utf8), "LAUNCHED")
        XCTAssertEqual(launcher.process.terminationStatus, 0)
        XCTAssertTrue(ownership.canLaunch(parentProcessID: parent.processIdentifier))
    }

    func testCommitToClosedLauncherPipeDoesNotDeliverSIGPIPE() async throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 0<&-; printf 'READY\\n'; /bin/sleep 1"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { stop(process) }
        try input.fileHandleForReading.close()
        let ready = output.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(data: ready, encoding: .utf8), "READY\n")
        let ownership = PermissionRelaunchProcessOwnership()
        ownership.retainOwnedHandoff(
            process, parentProcessID: getpid(), commitInput: input.fileHandleForWriting
        )

        XCTAssertFalse(ownership.commitOwnedHandoff(parentProcessID: getpid()))
        let cancelled = await ownership.cancelOwnedHandoff(parentProcessID: getpid())
        XCTAssertTrue(cancelled)
    }

    func testPreparedRestartRemainsReversibleUntilWillTerminateWithoutWatchdog() async {
        let notForced = expectation(description: "safe restart never arms ordinary quit watchdog")
        notForced.isInverted = true
        var hides = 0
        var quits = 0
        var dispatches = 0
        var finalizations = 0
        let termination = AppTerminationCoordinator(
            dispatcher: { dispatches += 1 },
            finalizer: { finalizations += 1 },
            timeoutNanoseconds: 10_000_000,
            hideUI: { hides += 1 },
            forceExit: { notForced.fulfill() },
            replyHandler: { _ in XCTFail("Prepared restart must not use terminateLater reply") }
        )
        termination.installQuitObserver { quits += 1 }

        XCTAssertTrue(termination.armPreparedRestart())
        XCTAssertFalse(termination.armPreparedRestart())
        XCTAssertEqual(termination.requestTermination(), .terminateNow)
        XCTAssertEqual(termination.requestTermination(), .terminateNow)
        XCTAssertFalse(termination.isQuitting)
        XCTAssertEqual(hides, 0)
        XCTAssertEqual(quits, 0)
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(finalizations, 0)
        await fulfillment(of: [notForced], timeout: 0.05)

        XCTAssertTrue(termination.cancelPreparedRestart())
        XCTAssertFalse(termination.cancelPreparedRestart())
        XCTAssertTrue(termination.armPreparedRestart(), "An uncommitted safe handoff is retryable")
        termination.finalizeTerminationResourcesIfNeeded()
        termination.finalizeTerminationResourcesIfNeeded()
        XCTAssertTrue(termination.isQuitting)
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(hides, 0)
        XCTAssertEqual(dispatches, 0)
        XCTAssertFalse(termination.cancelPreparedRestart())
        XCTAssertFalse(termination.armPreparedRestart())
    }

    func testCancelledPreparedRestartAllowsOrdinaryQuitWatchdog() async {
        let forced = expectation(description: "manual ordinary quit still owns force-exit deadline")
        var hides = 0
        var quits = 0
        var finalizations = 0
        let termination = AppTerminationCoordinator(
            finalizer: { finalizations += 1 },
            timeoutNanoseconds: 10_000_000,
            hideUI: { hides += 1 },
            forceExit: { forced.fulfill() },
            replyHandler: { _ in XCTFail("Missing dispatcher must remain terminateLater") }
        )
        termination.installQuitObserver { quits += 1 }
        XCTAssertTrue(termination.armPreparedRestart())
        XCTAssertTrue(termination.cancelPreparedRestart())

        XCTAssertEqual(termination.requestTermination(), .terminateLater)
        XCTAssertTrue(termination.isQuitting)
        XCTAssertEqual(hides, 1)
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(finalizations, 0)
        XCTAssertFalse(termination.armPreparedRestart())
        XCTAssertFalse(termination.cancelPreparedRestart())
        await fulfillment(of: [forced], timeout: 1)
    }

    func testLauncherTimesOutWithoutOpeningWhileParentStillLives() throws {
        let parent = try makeSleepingParent()
        defer { stop(parent) }
        let launcher = try makeScriptProcess(
            parentPID: parent.processIdentifier,
            maxPollCount: 3
        )
        launcher.process.waitUntilExit()
        let output = launcher.output.fileHandleForReading.readDataToEndOfFile()

        XCTAssertEqual(String(data: output, encoding: .utf8), "READY\n")
        XCTAssertEqual(launcher.process.terminationStatus, 3)
        XCTAssertTrue(parent.isRunning)
    }

    func testLauncherOpensExactlyOnceOnlyAfterParentExits() throws {
        let parent = try makeSleepingParent()
        defer { stop(parent) }
        let launcher = try makeScriptProcess(
            parentPID: parent.processIdentifier,
            maxPollCount: 30
        )
        let ready = launcher.output.fileHandleForReading.readData(ofLength: 6)
        XCTAssertEqual(String(data: ready, encoding: .utf8), "READY\n")
        XCTAssertTrue(parent.isRunning)

        parent.terminate()
        parent.waitUntilExit()
        launcher.process.waitUntilExit()
        let output = launcher.output.fileHandleForReading.readDataToEndOfFile()

        XCTAssertEqual(String(data: output, encoding: .utf8), "LAUNCHED")
        XCTAssertEqual(launcher.process.terminationStatus, 0)
    }

    private func makeSleepingParent() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func makeScriptProcess(
        parentPID: pid_t,
        maxPollCount: Int,
        commit: Bool = true
    ) throws -> (process: Process, output: Pipe, input: Pipe) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            PermissionRelaunchScript.make(
                maxPollCount: maxPollCount,
                launchExecutable: "/usr/bin/printf"
            ),
            "blocks-permission-relaunch-test",
            String(parentPID),
            "LAUNCHED",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForReading.close()
        if commit {
            try input.fileHandleForWriting.write(contentsOf: Data("COMMIT\n".utf8))
            try input.fileHandleForWriting.close()
        }
        return (process, output, input)
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
