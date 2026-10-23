import Foundation
import BlocksCore
import Combine
import XCTest
@testable import Blocks

@MainActor
final class AppUpdateCoordinatorTests: XCTestCase {
    private func configuration(
        official: Bool = true, local: Bool = false, testing: Bool = false,
        identifier: String = "app.blocks.app",
        feed: String? = AppUpdateTrack.stable.feedURL.absoluteString,
        key: String? = Data(repeating: 7, count: 32).base64EncodedString(),
        automaticInstallation: Bool = false
    ) -> AppUpdateConfiguration {
        AppUpdateConfiguration(
            isOfficialDistribution: official, isLocalDevelopment: local,
            isUnitTestHost: testing, bundleIdentifier: identifier,
            feedURLString: feed, publicKey: key,
            allowsAutomaticInstallation: automaticInstallation
        )
    }

    func testCompleteConfigurationPassesPureValidationWithoutStartingUpdater() {
        XCTAssertNil(configuration().unavailableReasonKey)
    }

    func testLocalDevelopmentAlwaysDisabledEvenWithOfficialMetadata() {
        XCTAssertEqual(configuration(local: true).unavailableReasonKey, "updates.unavailable.distribution")
        XCTAssertEqual(configuration(official: false).unavailableReasonKey, "updates.unavailable.distribution")
        XCTAssertEqual(configuration(identifier: "app.blocks.dev").unavailableReasonKey, "updates.unavailable.distribution")
    }

    func testTestHostAlwaysDisabledEvenWithOfficialMetadata() {
        XCTAssertEqual(configuration(testing: true).unavailableReasonKey, "updates.unavailable.testing")
    }

    func testFeedMustBeExactlyTheOwnedStableFeed() {
        for feed in [nil, "", "$(BLOCKS_UPDATE_FEED_URL)", "http://winx402.github.io/blocks-mac/appcast/stable.xml",
                     "https://example.com/appcast.xml", AppUpdateTrack.beta.feedURL.absoluteString,
                     "https://winx402.github.io/blocks-mac/appcast/stable.xml?redirect=1"] {
            XCTAssertEqual(configuration(feed: feed).unavailableReasonKey, "updates.unavailable.feed")
        }
    }

    func testPublicKeyMustBeRealLengthBase64AndNotZeroPlaceholder() {
        for key in [nil, "", "$(BLOCKS_UPDATE_PUBLIC_ED_KEY)", "invalid base64",
                    Data(repeating: 7, count: 31).base64EncodedString(),
                    Data(repeating: 7, count: 33).base64EncodedString(),
                    Data(repeating: 0, count: 32).base64EncodedString()] {
            XCTAssertEqual(configuration(key: key).unavailableReasonKey, "updates.unavailable.key")
        }
    }

    func testAutomaticInstallationIsRejected() {
        XCTAssertEqual(configuration(automaticInstallation: true).unavailableReasonKey,
                       "updates.unavailable.automaticInstallation")
    }

    func testChannelsRemainPinnedAndStableDoesNotOptInToBeta() {
        XCTAssertEqual(AppUpdateTrack.stable.feedURL.absoluteString,
                       "https://winx402.github.io/blocks-mac/appcast/stable.xml")
        XCTAssertEqual(AppUpdateTrack.beta.feedURL.absoluteString,
                       "https://winx402.github.io/blocks-mac/appcast/beta.xml")
        XCTAssertEqual(AppUpdateTrack.stable.allowedChannels, [])
        XCTAssertEqual(AppUpdateTrack.beta.allowedChannels, ["beta"])
    }

    func testRejectsNonHTTPSOrCredentialBearingDownloadURLs() {
        for value in ["http://example.com/update.zip", "file:///tmp/update.zip",
                      "https://user:password@example.com/update.zip", "https:relative"] {
            XCTAssertFalse(AppUpdateConfiguration.acceptsDownloadURL(URL(string: value)))
        }
        XCTAssertFalse(AppUpdateConfiguration.acceptsDownloadURL(nil))
        XCTAssertTrue(AppUpdateConfiguration.acceptsDownloadURL(URL(string: "https://github.com/winx402/blocks-mac/releases/download/v1/Blocks.zip")))
    }

    func testRequiresEd25519SignatureMetadataWithoutClaimingCryptographicVerification() {
        XCTAssertFalse(AppUpdateConfiguration.hasEd25519Signature(in: [:]))
        XCTAssertFalse(AppUpdateConfiguration.hasEd25519Signature(in: ["enclosure": ["sparkle:dsaSignature": "legacy"]]))
        for signature in ["", "invalid", Data(repeating: 7, count: 63).base64EncodedString(),
                          Data(repeating: 0, count: 64).base64EncodedString()] {
            XCTAssertFalse(AppUpdateConfiguration.hasEd25519Signature(in: ["enclosure": ["sparkle:edSignature": signature]]))
        }
        XCTAssertTrue(AppUpdateConfiguration.hasEd25519Signature(in: [
            "enclosure": ["sparkle:edSignature": Data(repeating: 7, count: 64).base64EncodedString()]
        ]), "Checks format only; Sparkle must validate the actual archive")
    }

    func testUnconfiguredLifecycleDoesNotCreateUpdater() {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(configuration: configuration(), defaults: defaults)
        coordinator.startIfPossible()
        XCTAssertEqual(coordinator.unavailableReasonKey, "updates.unavailable.lifecycle")
        XCTAssertFalse(coordinator.isAvailable)
        XCTAssertFalse(coordinator.canCheckForUpdates)
        XCTAssertFalse(coordinator.canChangePreferences)
        coordinator.checkForUpdates()
        XCTAssertEqual(coordinator.statusKey, "updates.status.ready")
    }

    func testTestHostCannotStartUpdaterEvenAfterSafetyRegistration() {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        var preparationCalled = false
        coordinator.configureInstallationSafety(
            prepareForUpdate: { preparationCalled = true },
            resumeAfterCancelledUpdate: {}
        )
        coordinator.startIfPossible()
        XCTAssertFalse(coordinator.isAvailable)
        XCTAssertFalse(preparationCalled)
        XCTAssertEqual(coordinator.unavailableReasonKey, "updates.unavailable.testing")
    }

    func testTrackDefaultsToStableAndCannotBeChangedWhileUnavailable() {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("untrusted-custom-channel", forKey: AppUpdateCoordinator.trackDefaultsKey)
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        XCTAssertEqual(coordinator.track, .stable)
        XCTAssertFalse(coordinator.receivesBetaUpdates)
        coordinator.setReceivesBetaUpdates(true)
        XCTAssertFalse(coordinator.receivesBetaUpdates)
        coordinator.setTrack(.beta)
        XCTAssertEqual(coordinator.track, .stable)
        coordinator.setAutomaticallyChecksForUpdates(true)
        XCTAssertFalse(coordinator.automaticallyChecksForUpdates)
        XCTAssertNil(defaults.object(forKey: "SUEnableAutomaticChecks"))
    }

    func testPreviouslyExplicitBetaPreferenceIsRestoredWithoutStartingUpdater() {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("beta", forKey: AppUpdateCoordinator.trackDefaultsKey)
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        XCTAssertEqual(coordinator.track, .beta)
        XCTAssertTrue(coordinator.receivesBetaUpdates)
        coordinator.setReceivesBetaUpdates(false)
        XCTAssertTrue(coordinator.receivesBetaUpdates, "Unavailable controls must not change an existing opt-in")
        XCTAssertEqual(defaults.string(forKey: AppUpdateCoordinator.trackDefaultsKey), "beta")
        XCTAssertFalse(coordinator.isAvailable)
    }

    func testInstallationHandlerRunsOnlyAfterPreparationCompletes() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        var events: [String] = []
        let completed = expectation(description: "Safe preparation and handler complete")
        coordinator.configureInstallationSafety(prepareForUpdate: {
            events.append("drain-and-backup")
        }, resumeAfterCancelledUpdate: { events.append("resume") })
        coordinator.postponeInstallation {
            events.append("install")
            completed.fulfill()
        }
        XCTAssertEqual(events, [])
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(events, ["drain-and-backup", "install"])
        XCTAssertEqual(coordinator.statusKey, "updates.status.installing")
        XCTAssertFalse(coordinator.isAvailable, "No real updater is created")
    }

    func testFailedPreparationNeverInstallsAndAllowsOneExplicitRetry() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        let failed = expectation(description: "Preparation fails closed")
        let installed = expectation(description: "Explicit retry safely completes")
        let observation = coordinator.$canRetryInstallationPreparation
            .filter { $0 }.prefix(1).sink { _ in failed.fulfill() }
        var attempts = 0
        var installCount = 0
        var resumeCount = 0
        coordinator.configureInstallationSafety(prepareForUpdate: {
            attempts += 1
            if attempts == 1 { throw NSError(domain: "test", code: 1) }
        }, resumeAfterCancelledUpdate: { resumeCount += 1 })
        coordinator.postponeInstallation {
            installCount += 1
            installed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(installCount, 0)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(coordinator.statusKey, "updates.status.preparationFailed")
        coordinator.retryInstallationPreparation()
        coordinator.retryInstallationPreparation()
        await fulfillment(of: [installed], timeout: 1)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertFalse(coordinator.canRetryInstallationPreparation)
        observation.cancel()
    }

    func testMissingSafetyCallbackNeverInvokesInstallationHandler() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        let failed = expectation(description: "Missing callback fails closed")
        let observation = coordinator.$canRetryInstallationPreparation
            .filter { $0 }.prefix(1).sink { _ in failed.fulfill() }
        var handlerCalled = false
        coordinator.postponeInstallation { handlerCalled = true }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertFalse(handlerCalled)
        XCTAssertEqual(coordinator.statusKey, "updates.status.preparationFailed")
        observation.cancel()
    }

    func testCancellationAfterPreparationRecoversExactlyOnce() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        let prepared = expectation(description: "Preparation completed")
        let recovered = expectation(description: "Cancelled install resumes work")
        var recoveryCount = 0
        coordinator.configureInstallationSafety(prepareForUpdate: {}, resumeAfterCancelledUpdate: {
            XCTAssertFalse(Task.isCancelled)
            recoveryCount += 1
            recovered.fulfill()
        })
        coordinator.postponeInstallation { prepared.fulfill() }
        await fulfillment(of: [prepared], timeout: 1)
        coordinator.cancelInstallationPreparation()
        coordinator.cancelInstallationPreparation()
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertFalse(coordinator.canRetryInstallationPreparation)
    }

    func testCancellationWaitsForPreparationToUnwindBeforeResuming() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults)
        let started = expectation(description: "Preparation is suspended")
        let recovered = expectation(description: "Recovery follows preparation unwind")
        var continuation: CheckedContinuation<Void, Never>?
        var events: [String] = []
        var installCount = 0
        coordinator.configureInstallationSafety(prepareForUpdate: {
            events.append("pause")
            await withCheckedContinuation { savedContinuation in
                continuation = savedContinuation
                started.fulfill()
            }
            events.append("drain-finished")
        }, resumeAfterCancelledUpdate: {
            XCTAssertFalse(Task.isCancelled)
            events.append("resume")
            recovered.fulfill()
        })
        coordinator.postponeInstallation { installCount += 1 }
        await fulfillment(of: [started], timeout: 1)
        coordinator.cancelInstallationPreparation()
        coordinator.cancelInstallationPreparation()
        XCTAssertEqual(events, ["pause"])
        XCTAssertTrue(coordinator.isPreparingInstallation)
        continuation?.resume()
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertEqual(events, ["pause", "drain-finished", "resume"])
        XCTAssertEqual(installCount, 0)
        XCTAssertFalse(coordinator.canRetryInstallationPreparation)
    }

    func testRecoveryWindowCanImmediatelyRetryTheSameContinuationExactlyOnce() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = UpdatePreparationPresenterStub()
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults,
                                               preparationPresenter: presenter)
        let installed = expectation(description: "Immediate UI retry installs")
        var attempts = 0
        var events: [String] = []
        coordinator.configureInstallationSafety(prepareForUpdate: {
            attempts += 1
            events.append("prepare")
            if attempts == 1 {
                throw ApplicationLifecycleCoordinator.ParticipantDrainError(
                    participantID: "helper", underlying: SelectionHelperUpdatePreparationFailure.helperNotPaired)
            }
        }, resumeAfterCancelledUpdate: { events.append("resume") })
        presenter.onShow = { state in
            guard case let .failed(failure) = state else { return }
            XCTAssertEqual(failure.reason, .helperNotPaired)
            XCTAssertEqual(events, ["prepare", "resume"], "Recovery precedes enabled Retry")
            presenter.retry?()
            presenter.retry?()
        }
        var installCount = 0
        coordinator.postponeInstallation {
            installCount += 1
            installed.fulfill()
        }
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(events, ["prepare", "resume", "prepare"])
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(presenter.states.count, 3)
        XCTAssertNil(coordinator.preparationFailure)
        XCTAssertFalse(coordinator.canRetryInstallationPreparation)
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    func testLaterRetainsUpdateAndCancelledWindowActionsCannotReplayIntoNewSession() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = UpdatePreparationPresenterStub()
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults,
                                               preparationPresenter: presenter)
        let firstFailed = expectation(description: "First session paused")
        let secondFailed = expectation(description: "Second session paused")
        var failureCount = 0
        var attempts = 0
        var installCount = 0
        coordinator.configureInstallationSafety(prepareForUpdate: {
            attempts += 1
            throw ActionBrokerUpdateError.busy
        }, resumeAfterCancelledUpdate: {})
        presenter.onShow = { state in
            if case .failed = state {
                failureCount += 1
                if failureCount == 1 { firstFailed.fulfill() } else { secondFailed.fulfill() }
            }
        }
        coordinator.postponeInstallation { installCount += 1 }
        await fulfillment(of: [firstFailed], timeout: 2)
        let staleRetry = presenter.retry
        let staleLater = presenter.later
        presenter.later?()
        XCTAssertEqual(installCount, 0)
        XCTAssertTrue(coordinator.canRetryInstallationPreparation)
        XCTAssertEqual(presenter.dismissCount, 1)
        coordinator.cancelInstallationPreparation()
        XCTAssertNil(coordinator.preparationFailure)
        coordinator.postponeInstallation { installCount += 1 }
        await fulfillment(of: [secondFailed], timeout: 2)
        let shownCount = presenter.states.count
        staleRetry?()
        staleLater?()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(presenter.states.count, shownCount)
        XCTAssertEqual(installCount, 0)
        XCTAssertTrue(coordinator.canRetryInstallationPreparation)
        coordinator.cancelInstallationPreparation()
    }

    func testFailureActionsAreNotPublishedUntilSuspendedRecoveryCompletes() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = UpdatePreparationPresenterStub()
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults,
                                               preparationPresenter: presenter)
        let recovering = expectation(description: "Recovery suspended")
        let finished = expectation(description: "Failure ready")
        var continuation: CheckedContinuation<Void, Never>?
        coordinator.configureInstallationSafety(prepareForUpdate: { throw ActionBrokerUpdateError.busy },
            resumeAfterCancelledUpdate: {
                await withCheckedContinuation { continuation = $0; recovering.fulfill() }
            })
        presenter.onShow = { state in if case .failed = state { finished.fulfill() } }
        coordinator.postponeInstallation { XCTFail("Must not install") }
        await fulfillment(of: [recovering], timeout: 2)
        XCTAssertTrue(coordinator.isPreparingInstallation)
        XCTAssertFalse(coordinator.canRetryInstallationPreparation)
        XCTAssertEqual(presenter.states, [.preparing])
        coordinator.retryInstallationPreparation()
        continuation?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(coordinator.isPreparingInstallation)
        XCTAssertTrue(coordinator.canRetryInstallationPreparation)
        coordinator.cancelInstallationPreparation()
    }

    func testPreparationFailureClassificationNeverDisplaysRawErrorOrUnknownParticipant() {
        let secret = "secret endpoint /Users/private/file"
        let raw = NSError(domain: secret, code: 7, userInfo: [NSLocalizedDescriptionKey: secret])
        let unknown = AppUpdatePreparationFailure(error: ApplicationLifecycleCoordinator.ParticipantDrainError(
            participantID: secret, underlying: raw))
        XCTAssertEqual(unknown.participant, "other")
        XCTAssertEqual(unknown.reason, .other)
        XCTAssertFalse(unknown.message.contains(secret))
        let cases: [(String, Error, AppUpdatePreparationFailure.Reason)] = [
            ("helper", SelectionHelperUpdatePreparationFailure.helperNotPaired, .helperNotPaired),
            ("helper", SelectionHelperUpdatePreparationFailure.preparationUnavailable, .helperUnavailable),
            ("helper", SelectionHelperUpdatePreparationFailure.preparationRejected, .helperUnavailable),
            ("helper", SelectionAgentServiceFailure.keychainUnavailable, .helperKeyUnavailable),
            ("helper", ApplicationOperationAdmissionGate.AdmissionError.busy(secret), .helperBusy),
            ("helper", ApplicationOperationAdmissionGate.AdmissionError.paused(secret), .helperUnavailable),
            ("helper", SelectionAgentServiceFailure.connectionFailed, .helperUnavailable),
            ("actionBroker", ActionBrokerUpdateError.legacyRegistrationRequiresMigration, .brokerMigration),
            ("actionBroker", ActionBrokerUpdateError.busy, .brokerBusy),
            ("actionBroker", ActionBrokerUpdateError.untrustedPeer, .brokerUntrusted),
            ("actionBroker", ActionBrokerUpdateError.unsupportedPeer, .brokerUnsupported),
            ("actionBroker", ActionBrokerUpdateError.connectionUnavailable, .brokerUnavailable),
            ("actionBroker", ActionBrokerUpdateError.timedOut, .brokerTimeout),
            ("actionBroker", ActionBrokerUpdateError.preparationRejected, .brokerRejected),
            ("actionBroker", ActionBrokerUpdateError.invalidRecoveryState, .brokerRecovery),
            ("actionBroker", ActionBrokerUpdateError.preparationInProgress, .brokerRecovery),
            ("actionBroker", ActionBrokerUpdateError.requiresApproval, .brokerApproval),
            ("actionBroker", ActionBrokerUpdateError.serviceDidNotStop, .brokerShutdown),
            ("actionBroker", ApplicationOperationAdmissionGate.AdmissionError.busy(secret), .brokerBusy),
            ("actionBroker", ApplicationOperationAdmissionGate.AdmissionError.paused(secret), .brokerRecovery),
            ("actionBroker", raw, .brokerUnavailable),
            ("database", raw, .database),
            ("translation", ApplicationOperationAdmissionGate.AdmissionError.busy(secret), .busy),
            ("translation", ApplicationOperationAdmissionGate.AdmissionError.paused(secret), .other),
        ]
        for (participant, error, reason) in cases {
            let failure = AppUpdatePreparationFailure(error: ApplicationLifecycleCoordinator.ParticipantDrainError(
                participantID: participant, underlying: error))
            XCTAssertEqual(failure.reason, reason)
            XCTAssertFalse(failure.message.contains(secret))
            XCTAssertNotEqual(failure.message, "updates.preparation.\(reason.rawValue)")
        }
    }

    func testUnpairedHelperRecoveryNamesTheActualHelperApplicationMenu() {
        let failure = AppUpdatePreparationFailure(error: ApplicationLifecycleCoordinator.ParticipantDrainError(
            participantID: "helper", underlying: SelectionHelperUpdatePreparationFailure.helperNotPaired))
        XCTAssertEqual(failure.reason, .helperNotPaired)
        XCTAssertTrue(failure.message.contains("blocksHelper"),
                      "Recovery must name the menu shown by the actual Helper, not its retired product name")
        XCTAssertFalse(failure.message.contains("Blocks Selection Helper"))
    }

    func testBrokerLifecycleRejectionsOnlyAcceptExactVersionedAllowlistCodes() {
        for error in ActionBrokerUpdateError.allCases {
            XCTAssertEqual(ActionBrokerUpdateError.rejection(wireCode: error.wireCode), error)
            XCTAssertFalse(error.wireCode.contains(" "))
        }
        // Old Brokers return localized prose, including prose that sounds
        // busy. It is not stable protocol evidence and must remain unknown.
        for code in [nil, "", "busy", "Action Broker still has active requests.",
                     "CLI 服务忙碌", "blocks.action-broker.update.v2.busy",
                     "blocks.action-broker.update.v1.busy\n",
                     "secret endpoint /Users/private/file"] as [String?] {
            let rejection = ActionBrokerUpdateError.rejection(wireCode: code)
            XCTAssertEqual(rejection, .preparationRejected)
            let failure = AppUpdatePreparationFailure(error: rejection)
            XCTAssertEqual(failure.reason, .brokerRejected)
            XCTAssertFalse(failure.message.contains("/Users/private"))
        }
    }

    func testBrokerPreparationOwnershipConflictIsNotReportedAsActiveWork() throws {
        let gate = ActionBrokerUpdateAdmission()
        let first = UUID().uuidString
        let second = UUID().uuidString
        let work = try XCTUnwrap(gate.begin())
        XCTAssertThrowsError(try gate.prepare(token: first)) {
            XCTAssertEqual($0 as? ActionBrokerUpdateError, .busy)
        }
        work.release()
        try gate.prepare(token: first)
        try gate.prepare(token: first) // Same transaction remains idempotent.
        for operation in [{ try gate.prepare(token: second) }, { try gate.resume(token: second) }] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? ActionBrokerUpdateError, .preparationInProgress)
                XCTAssertEqual(AppUpdatePreparationFailure(error: $0).reason, .brokerRecovery)
            }
            XCTAssertNil(gate.begin(), "a competing transaction must not reopen admission")
        }
        try gate.resume(token: first)
        let resumed = try XCTUnwrap(gate.begin())
        resumed.release()
    }

    func testSynchronousInstallerAbortRecoversOnceWithoutReopeningStaleActions() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = UpdatePreparationPresenterStub()
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults,
                                               preparationPresenter: presenter)
        let recovering = expectation(description: "Installer abort recovery suspended")
        let recovered = expectation(description: "Installer abort recovered")
        var continuation: CheckedContinuation<Void, Never>?
        var installCount = 0
        var resumeCount = 0
        var oldRetry: (() -> Void)?
        presenter.onShow = { _ in oldRetry = presenter.retry }
        coordinator.configureInstallationSafety(prepareForUpdate: {}, resumeAfterCancelledUpdate: {
            XCTAssertFalse(Task.isCancelled)
            resumeCount += 1
            await withCheckedContinuation { continuation = $0; recovering.fulfill() }
            recovered.fulfill()
        })
        coordinator.postponeInstallation {
            installCount += 1
            coordinator.cancelInstallationPreparation()
            coordinator.cancelInstallationPreparation()
        }
        await fulfillment(of: [recovering], timeout: 2)
        XCTAssertTrue(coordinator.isPreparingInstallation)
        oldRetry?()
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertFalse(coordinator.canRetryInstallationPreparation)
        continuation?.resume()
        await fulfillment(of: [recovered], timeout: 2)
        // Give the awaiting preparation its actor turn to finish.
        let deadline = ContinuousClock.now + .seconds(1)
        while coordinator.isPreparingInstallation, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(coordinator.isPreparingInstallation)
        XCTAssertEqual(presenter.states, [.preparing])
        XCTAssertNil(coordinator.preparationFailure)
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(resumeCount, 1)
    }

    func testCancelDuringFailedRecoveryDoesNotPublishFailureOrRetry() async {
        let suite = "AppUpdateCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = UpdatePreparationPresenterStub()
        let coordinator = AppUpdateCoordinator(configuration: configuration(testing: true), defaults: defaults,
                                               preparationPresenter: presenter)
        let recovering = expectation(description: "Recovery suspended")
        var continuation: CheckedContinuation<Void, Never>?
        coordinator.configureInstallationSafety(prepareForUpdate: { throw ActionBrokerUpdateError.busy },
            resumeAfterCancelledUpdate: {
                await withCheckedContinuation { continuation = $0; recovering.fulfill() }
            })
        coordinator.postponeInstallation { XCTFail("Cancelled update must not install") }
        await fulfillment(of: [recovering], timeout: 2)
        coordinator.cancelInstallationPreparation()
        continuation?.resume()
        let deadline = ContinuousClock.now + .seconds(1)
        while coordinator.isPreparingInstallation, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(coordinator.isPreparingInstallation)
        XCTAssertEqual(presenter.states, [.preparing])
        XCTAssertFalse(coordinator.canRetryInstallationPreparation)
        XCTAssertNil(coordinator.preparationFailure)
    }
}

@MainActor
private final class UpdatePreparationPresenterStub: AppUpdatePreparationPresenting {
    var states: [AppUpdatePreparationPresentation] = []
    var retry: (() -> Void)?
    var later: (() -> Void)?
    var onShow: ((AppUpdatePreparationPresentation) -> Void)?
    var dismissCount = 0
    func show(_ state: AppUpdatePreparationPresentation, retry: @escaping () -> Void, later: @escaping () -> Void) {
        states.append(state)
        self.retry = retry
        self.later = later
        onShow?(state)
    }
    func dismiss() { dismissCount += 1; retry = nil; later = nil }
}

@MainActor
final class UpdateSettingsStatusPresentationTests: XCTestCase {
    func testExpectedDevelopmentUnavailabilityIsNeutral() {
        for key in ["updates.unavailable.distribution", "updates.unavailable.testing"] {
            XCTAssertEqual(UpdateSettingsStatusPresentation.kind(
                unavailableReasonKey: key,
                statusKey: "updates.status.ready"
            ), .information)
        }
    }

    func testConfigurationAndRuntimeFailuresRemainWarnings() {
        for key in ["updates.unavailable.feed", "updates.unavailable.key",
                    "updates.unavailable.automaticInstallation", "updates.unavailable.lifecycle",
                    "updates.unavailable.start"] {
            XCTAssertEqual(UpdateSettingsStatusPresentation.kind(
                unavailableReasonKey: key,
                statusKey: "updates.status.ready"
            ), .warning)
        }
        for key in ["updates.status.failed", "updates.status.preparationFailed"] {
            XCTAssertEqual(UpdateSettingsStatusPresentation.kind(
                unavailableReasonKey: nil,
                statusKey: key
            ), .warning)
        }
        XCTAssertEqual(UpdateSettingsStatusPresentation.kind(
            unavailableReasonKey: nil,
            statusKey: "updates.status.ready"
        ), .information)
    }
}
