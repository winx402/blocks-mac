import Foundation
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
}
