import AppKit
import BlocksScreenshotCore
import ImageIO
import CoreMedia
import XCTest
@testable import Blocks
@testable import BlocksCore

private struct BrowserScrollFixtureManifest: Decodable {
    struct PixelSize: Decodable {
        let width: Int
        let height: Int
    }

    struct PixelRect: Decodable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    struct Frame: Decodable {
        let file: String
        let requestedScrollY: Int
        let scrollY: Int
        let sha256: String
    }

    struct GroundTruth: Decodable {
        let file: String
        let sha256: String
    }

    let viewport: PixelSize
    let documentSize: PixelSize
    let contentComparisonRect: PixelRect
    let frames: [Frame]
    let groundTruth: GroundTruth
}

final class ScrollingScreenshotAppTests: XCTestCase {
    func testDiskBackedSessionAssemblesTopToBottomPixelsAndCleansSecureStrips() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        let sessionID = "scroll-fixture"
        let startedSessionID = try await coordinator.begin(sessionID: sessionID)
        XCTAssertEqual(startedSessionID, sessionID)

        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))
        let appended = try await coordinator.ingest(capturedFrame(rows: Array(5..<13)))
        guard case .accepted = appended else {
            return XCTFail("Expected second frame to append, got \(appended)")
        }

        let sessionDirectory = root.appendingPathComponent(sessionID, isDirectory: true)
        let stripURLs = try FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(stripURLs.count, 2)
        for stripURL in stripURLs {
            let attributes = try FileManager.default.attributesOfItem(atPath: stripURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }

        let finalImage = try await coordinator.finalize()
        XCTAssertEqual(finalImage.width, 64)
        XCTAssertEqual(finalImage.height, 13)
        XCTAssertEqual(decodedRowIdentifiers(finalImage, candidates: Array(0..<13)), Array(0..<13))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
        let finishedStatus = await coordinator.status()
        XCTAssertEqual(finishedStatus.sessionID, sessionID)
        XCTAssertEqual(finishedStatus.state, .editing)

        try await coordinator.finishEditing(sessionID: sessionID, terminal: .completed)
        let completedStatus = await coordinator.status()
        XCTAssertNil(completedStatus.sessionID)
        XCTAssertEqual(completedStatus.state, .idle)
    }

    func testFinalizationKeepsSessionIdentityUntilEditorTerminalWins() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        let sessionID = try await coordinator.begin(sessionID: "editor-lifecycle")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        _ = try await coordinator.finalize()
        let editingStatus = await coordinator.status()
        XCTAssertEqual(editingStatus.state, .editing)

        try await coordinator.finishEditing(sessionID: sessionID, terminal: .cancelled)
        let idleStatus = await coordinator.status()
        XCTAssertEqual(idleStatus.state, .idle)
        do {
            try await coordinator.finishEditing(sessionID: sessionID, terminal: .completed)
            XCTFail("Only the first editor terminal may own the session.")
        } catch ScrollingScreenshotSessionError.staleSession {
            // Expected.
        }
    }

    func testFixedHeaderPixelsAreStoredOnlyOnce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "fixed-header")

        _ = try await coordinator.ingest(capturedFrame(rows: [100, 101] + Array(0..<8)))
        let appended = try await coordinator.ingest(capturedFrame(rows: [100, 101] + Array(5..<13)))
        guard case .accepted = appended else {
            return XCTFail("Expected fixed-header frame to append, got \(appended)")
        }

        let finalImage = try await coordinator.finalize()
        XCTAssertEqual(finalImage.height, 15)
        let expectedRows = [100, 101] + Array(0..<13)
        XCTAssertEqual(decodedRowIdentifiers(finalImage, candidates: expectedRows), expectedRows)
    }

    func testFixedHeaderAndFooterPixelsAreEachStoredOnce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "fixed-header-footer")

        _ = try await coordinator.ingest(capturedFrame(
            rows: [100, 101] + Array(0..<8) + [200, 201]
        ))
        let appended = try await coordinator.ingest(capturedFrame(
            rows: [100, 101] + Array(5..<13) + [200, 201]
        ))
        guard case .accepted = appended else {
            return XCTFail("Expected fixed-band frame to append, got \(appended)")
        }

        let finalImage = try await coordinator.finalize()
        let expectedRows = [100, 101] + Array(0..<13) + [200, 201]
        XCTAssertEqual(finalImage.height, expectedRows.count)
        XCTAssertEqual(decodedRowIdentifiers(finalImage, candidates: expectedRows), expectedRows)
    }

    func testLateFixedFooterThenDynamicFooterLeavesNoTransparentGap() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "late-fixed-footer")

        _ = try await coordinator.ingest(capturedFrame(
            rows: Array(0..<64) + Array(repeating: 200, count: 8)
        ))
        let fixedFooter = try await coordinator.ingest(capturedFrame(
            rows: Array(18..<82) + Array(repeating: 200, count: 8)
        ))
        guard case .accepted = fixedFooter else {
            return XCTFail("Expected the repeated footer frame to append, got \(fixedFooter)")
        }
        let dynamicFooter = try await coordinator.ingest(capturedFrame(
            rows: Array(36..<100) + Array(repeating: 500, count: 8)
        ))
        guard case .accepted = dynamicFooter else {
            return XCTFail("Expected the dynamic footer frame to append, got \(dynamicFooter)")
        }

        let finalImage = try await coordinator.finalize()
        let expectedRows = Array(0..<100) + Array(repeating: 500, count: 8)
        XCTAssertEqual(
            decodedRowIdentifiers(finalImage, candidates: expectedRows + [200]),
            expectedRows,
            "A footer that stops being fixed must not leave a gap or stale footer rows in the stitched body."
        )
    }

    func testCancellationRequiresConfirmationAndDeletesAllTemporaryContent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        let sessionID = try await coordinator.begin(sessionID: "cancel-fixture")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        do {
            try await coordinator.cancel(confirm: false)
            XCTFail("Expected confirmation-required error")
        } catch ScrollingScreenshotSessionError.confirmationRequired {
            // Expected: destructive cancellation requires an explicit confirmation.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let retainedStatus = await coordinator.status()
        XCTAssertEqual(retainedStatus.sessionID, sessionID)

        try await coordinator.cancel(confirm: true)
        let cancelledStatus = await coordinator.status()
        XCTAssertNil(cancelledStatus.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionID).path))
    }

    @MainActor
    func testLongImageEditorDisablesDirectImageCopy() throws {
        let suite = "ScrollingScreenshotAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = makeImage(rows: Array(0..<8))
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: image.width, height: image.height)
        let capture = ScreenshotCapture(
            id: "long-editor",
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            pixelSize: CGSize(width: image.width, height: image.height),
            sourceRect: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            kind: .region,
            displayScope: .displayID(1),
            sourceSummary: "long fixture",
            editingContext: ScreenshotEditingContext(
                sourceContext: ScreenshotSourceContext(
                    sourceBounds: bounds,
                    tileDescriptors: [ScreenshotSourceTileDescriptor(id: "long", bounds: bounds)],
                    compositeSource: image
                ),
                sourceFrame: CGRect(x: 0, y: 0, width: 64, height: 8),
                screens: [ScreenshotEditingScreen(displayID: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 8))],
                initialCropRect: bounds,
                supportsRangeExpansion: false
            ),
            defersOutputUntilEditorCompletion: true
        )
        let store = try ScreenshotEditorStore(
            capture: capture,
            preferencesStore: ScreenshotPreferencesStore(userDefaults: defaults),
            onComplete: { _ in },
            onRetake: {},
            onClose: {}
        )

        XCTAssertFalse(store.allowsDirectImageCopy)
        XCTAssertEqual(
            store.renderSubmissionCount,
            0,
            "An untouched long image must reuse its source instead of allocating an identical full render."
        )
        store.copyCurrent()
        XCTAssertNil(store.pendingOutputCommand)
    }

    func testReverseFramesRecoverAutomaticallyWithoutAppendingInvalidContent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "automatic-recovery")

        _ = try await coordinator.ingest(capturedFrame(rows: Array(5..<13)))
        let reverse = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))
        guard case let .recovering(snapshot) = reverse else {
            return XCTFail("Expected automatic recovery, got \(reverse)")
        }
        XCTAssertEqual(snapshot.state, .recovering)
        XCTAssertEqual(snapshot.outputSize.height, 8)

        let recovered = try await coordinator.ingest(capturedFrame(rows: Array(10..<18)))
        guard case let .recovered(recoveredSnapshot) = recovered else {
            return XCTFail("Expected automatic recovery to complete, got \(recovered)")
        }
        XCTAssertEqual(recoveredSnapshot.state, .capturing)
        XCTAssertEqual(recoveredSnapshot.outputSize.height, 13)

        let finalImage = try await coordinator.finalize()
        XCTAssertEqual(decodedRowIdentifiers(finalImage, candidates: Array(5..<18)), Array(5..<18))
    }

    func testThirdUnresolvedReverseFramePausesAndResumeRestartsRecoveryBudget() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "recovery-budget")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(5..<13)))

        for attempt in 1...3 {
            let event = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))
            if attempt < 3 {
                guard case .recovering = event else {
                    return XCTFail("Attempt \(attempt) should keep recovering, got \(event)")
                }
            } else {
                guard case let .paused(snapshot) = event else {
                    return XCTFail("Third attempt should pause, got \(event)")
                }
                XCTAssertEqual(snapshot.state, .paused)
            }
        }

        let resumed = try await coordinator.validateResumeAnchor(
            capturedFrame(rows: Array(5..<13))
        )
        XCTAssertEqual(resumed.state, .capturing)
        let recovered = try await coordinator.ingest(capturedFrame(rows: Array(10..<18)))
        guard case .accepted = recovered else {
            return XCTFail("A validated resume should restart normal capture, got \(recovered)")
        }
        try await coordinator.cancel(confirm: true)
    }

    func testResumeAnchorValidationStaysPausedUntilLastConsistentAnchorIsReestablished() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "resume-anchor")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))
        _ = await coordinator.pause()

        let rejected = try await coordinator.validateResumeAnchor(
            capturedFrame(rows: Array(30..<38))
        )
        XCTAssertEqual(rejected.state, .paused)
        XCTAssertEqual(rejected.outputSize.height, 8)

        let resumed = try await coordinator.validateResumeAnchor(
            capturedFrame(rows: Array(0..<8))
        )
        XCTAssertEqual(resumed.state, .capturing)
        try await coordinator.cancel(confirm: true)
    }

    @MainActor
    func testResumeHealthCheckerIsInjectableAndReceivesFrozenCaptureGeometry() async {
        let checker = ScrollingScreenshotHealthChecker { context in
            XCTAssertEqual(context.displayID, 42)
            XCTAssertEqual(context.selectionRect, CGRect(x: 10, y: 20, width: 300, height: 400))
            XCTAssertEqual(context.expectedPixelSize, .init(width: 600, height: 800))
            return .unhealthy(.displayUnavailable)
        }
        let context = ScrollingScreenshotHealthContext(
            displayID: 42,
            displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 900),
            selectionRect: CGRect(x: 10, y: 20, width: 300, height: 400),
            expectedPixelSize: .init(width: 600, height: 800),
            hasInputMonitor: true
        )

        let health = await checker.check(context)
        XCTAssertEqual(health, .unhealthy(.displayUnavailable))
    }

    @MainActor
    func testCaptureAbortsBeforeFrameSourceStartWhenInputMonitorInstallationFails() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in nil }
        )

        do {
            _ = try await coordinator.capture(
                sessionID: "monitor-install-failure",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
            XCTFail("A missing global input monitor must abort capture.")
        } catch let failure as ScrollingScreenshotHealthFailure {
            XCTAssertEqual(failure, .inputMonitorUnavailable)
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }

        XCTAssertEqual(frameSource.startCallCount, 0)
        let sessionStatus = await session.status()
        XCTAssertEqual(sessionStatus.state, .idle)
        XCTAssertNil(coordinator.terminalGate.sessionID)
    }

    @MainActor
    func testActiveHealthFailurePausesCaptureAndRejectsFinish() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            healthChecker: ScrollingScreenshotHealthChecker { _ in .unhealthy(.inputMonitoringPermissionMissing) },
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: "active-health-failure",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        await waitUntil { frameSource.startCallCount == 1 }
        let generation = coordinator.terminalGate.generation

        await coordinator.checkActiveHealth(generation: generation)
        await waitUntilAsync {
            (await coordinator.status()).state == .paused
        }

        let pausedStatus = await coordinator.status()
        XCTAssertEqual(pausedStatus.state, .paused)
        XCTAssertEqual(
            coordinator.finishFromAction(sessionID: "active-health-failure"),
            .rejected(.sessionPaused, state: .paused)
        )
        _ = await coordinator.cancelFromAction(sessionID: "active-health-failure", confirm: true)
        _ = try? await captureTask.value
    }

    @MainActor
    func testStaleActiveHealthCallbackCannotPauseNewSessionAfterCancellation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            healthChecker: ScrollingScreenshotHealthChecker { _ in .unhealthy(.displayUnavailable) },
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in }
        )
        let firstCapture = Task {
            try await coordinator.capture(sessionID: "first-health-session", displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400), backingScale: 2, originatingApplication: nil)
        }
        await waitUntil { frameSource.startCallCount == 1 }
        let firstGeneration = coordinator.terminalGate.generation
        _ = await coordinator.cancelFromAction(sessionID: "first-health-session", confirm: true)
        _ = try? await firstCapture.value

        let secondCapture = Task {
            try await coordinator.capture(sessionID: "second-health-session", displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400), backingScale: 2, originatingApplication: nil)
        }
        await waitUntil { frameSource.startCallCount == 2 }
        await coordinator.checkActiveHealth(generation: firstGeneration)

        let currentStatus = await coordinator.status()
        XCTAssertEqual(currentStatus.state, .capturing)
        _ = await coordinator.cancelFromAction(sessionID: "second-health-session", confirm: true)
        _ = try? await secondCapture.value
    }

    @MainActor
    func testFirstCompleteFrameWatchdogFailsSilentSourceAndAllowsNextCapture() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = RecordingScrollingFrameSource()
        let watchdogGate = FirstFrameWatchdogGate()
        let monitorRemovals = LockedCounter()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in _ = monitorRemovals.increment() },
            firstCompleteFrameDeadline: .milliseconds(1),
            firstFrameWatchdogWait: { _ in await watchdogGate.wait() }
        )
        let firstCapture = Task {
            try await coordinator.capture(
                sessionID: "first-frame-timeout",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }

        guard await frameSource.waitForStart() else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(sessionID: "first-frame-timeout", confirm: true)
            _ = try? await firstCapture.value
            return XCTFail("The frame source did not start.")
        }
        guard await watchdogGate.waitForWaiterCount(1) else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(sessionID: "first-frame-timeout", confirm: true)
            _ = try? await firstCapture.value
            return XCTFail("The first-frame watchdog did not arm.")
        }
        await watchdogGate.releaseNext()
        guard await frameSource.waitForStopCount(1) else {
            _ = await coordinator.cancelFromAction(sessionID: "first-frame-timeout", confirm: true)
            _ = try? await firstCapture.value
            return XCTFail("The timed-out capture did not stop the frame source.")
        }
        XCTAssertEqual(frameSource.stopCallCount, 1)

        do {
            _ = try await firstCapture.value
            XCTFail("A source that starts but never supplies a complete frame must fail capture.")
        } catch {
            XCTAssertTrue(error is ScreenshotCaptureError)
        }
        let failedStatus = await session.status()
        XCTAssertEqual(failedStatus.state, .idle)
        XCTAssertNil(coordinator.hud.windowNumber)
        XCTAssertEqual(monitorRemovals.currentValue, 1)

        let secondCapture = Task {
            try await coordinator.capture(
                sessionID: "capture-after-first-frame-timeout",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        guard await frameSource.waitForStartCount(2) else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(
                sessionID: "capture-after-first-frame-timeout",
                confirm: true
            )
            _ = try? await secondCapture.value
            return XCTFail("The replacement frame source did not start.")
        }
        guard await watchdogGate.waitForWaiterCount(1) else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(
                sessionID: "capture-after-first-frame-timeout",
                confirm: true
            )
            _ = try? await secondCapture.value
            return XCTFail("The replacement first-frame watchdog did not arm.")
        }
        let replacementStatus = await session.status()
        XCTAssertEqual(replacementStatus.state, .capturing)
        _ = await coordinator.cancelFromAction(
            sessionID: "capture-after-first-frame-timeout",
            confirm: true
        )
        await watchdogGate.releaseNext()
        _ = try? await secondCapture.value
        XCTAssertEqual(frameSource.stopCallCount, 2)
    }

    @MainActor
    func testFirstFrameWatchdogAndExplicitCancelResolvePastHangingStopDeadline() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = HangingStopScrollingFrameSource()
        let watchdogGate = FirstFrameWatchdogGate()
        let stopDeadlineGate = FirstFrameWatchdogGate()
        let monitorRemovals = LockedCounter()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in _ = monitorRemovals.increment() },
            firstCompleteFrameDeadline: .milliseconds(1),
            firstFrameWatchdogWait: { _ in await watchdogGate.wait() },
            frameSourceStopDeadline: .milliseconds(1),
            frameSourceStopDeadlineWait: { _ in await stopDeadlineGate.wait() }
        )
        let firstCapture = Task {
            try await coordinator.capture(
                sessionID: "hanging-stop-watchdog",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let firstStart = expectation(description: "The first hanging-stop source started")
        Task {
            if await frameSource.waitForStartCount(1) {
                firstStart.fulfill()
            }
        }
        await fulfillment(of: [firstStart], timeout: 2)
        guard frameSource.startCallCount >= 1,
              await watchdogGate.waitForWaiterCount(1) else {
            await watchdogGate.releaseNext()
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = await coordinator.cancelFromAction(sessionID: "hanging-stop-watchdog", confirm: true)
            _ = try? await firstCapture.value
            return XCTFail("The first-frame watchdog did not arm for the hanging source.")
        }

        let originalGeneration = coordinator.terminalGate.generation
        await watchdogGate.releaseNext()
        let firstStop = expectation(description: "The watchdog failure requested source stop")
        Task {
            if await frameSource.waitForStopCount(1) {
                firstStop.fulfill()
            }
        }
        await fulfillment(of: [firstStop], timeout: 2)
        guard frameSource.stopCallCount >= 1,
              await stopDeadlineGate.waitForWaiterCount(1) else {
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = try? await firstCapture.value
            return XCTFail("The watchdog failure did not enter the bounded stop teardown.")
        }
        await stopDeadlineGate.releaseNext()
        do {
            _ = try await firstCapture.value
            XCTFail("The first-frame watchdog must fail capture after the stop deadline.")
        } catch {
            XCTAssertTrue(error is ScreenshotCaptureError)
        }
        let firstTerminalStatus = await session.status()
        XCTAssertEqual(firstTerminalStatus.state, .idle)
        XCTAssertNil(coordinator.continuation)
        XCTAssertNil(coordinator.hud.windowNumber)
        XCTAssertEqual(monitorRemovals.currentValue, 1)

        let replacementCapture = Task {
            try await coordinator.capture(
                sessionID: "hanging-stop-replacement",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let replacementStart = expectation(description: "The replacement capture started")
        Task {
            if await frameSource.waitForStartCount(2) {
                replacementStart.fulfill()
            }
        }
        await fulfillment(of: [replacementStart], timeout: 2)
        guard frameSource.startCallCount >= 2,
              await watchdogGate.waitForWaiterCount(1) else {
            await watchdogGate.releaseNext()
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = await coordinator.cancelFromAction(sessionID: "hanging-stop-replacement", confirm: true)
            _ = try? await replacementCapture.value
            return XCTFail("A replacement capture could not start after the stop deadline.")
        }
        let replacementGeneration = coordinator.terminalGate.generation
        frameSource.releaseStop(generation: originalGeneration)
        await Task.yield()
        let replacementStatusBeforeCancellation = await session.status()
        XCTAssertEqual(replacementStatusBeforeCancellation.state, .capturing)
        XCTAssertEqual(coordinator.terminalGate.generation, replacementGeneration)

        let cancellation = Task {
            await coordinator.cancelFromAction(sessionID: "hanging-stop-replacement", confirm: true)
        }
        let replacementStop = expectation(description: "The explicit cancellation requested source stop")
        Task {
            if await frameSource.waitForStopCount(2) {
                replacementStop.fulfill()
            }
        }
        await fulfillment(of: [replacementStop], timeout: 2)
        guard frameSource.stopCallCount >= 2,
              await stopDeadlineGate.waitForWaiterCount(1) else {
            await watchdogGate.releaseNext()
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = await cancellation.value
            _ = try? await replacementCapture.value
            return XCTFail("Explicit cancellation did not enter the bounded stop teardown.")
        }
        await watchdogGate.releaseNext()
        await stopDeadlineGate.releaseNext()
        _ = await cancellation.value
        _ = try? await replacementCapture.value
        let replacementTerminalStatus = await session.status()
        XCTAssertEqual(replacementTerminalStatus.state, .idle)
        XCTAssertNil(coordinator.continuation)
        frameSource.releaseAllStops()
    }

    @MainActor
    func testFinishStopDeadlineFailsClosedAndLateStopCannotPolluteReplacement() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        let frameSource = HangingStopScrollingFrameSource()
        let stopDeadlineGate = FirstFrameWatchdogGate()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in },
            frameSourceStopDeadline: .milliseconds(1),
            frameSourceStopDeadlineWait: { _ in await stopDeadlineGate.wait() }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: "finish-hanging-stop",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let firstStart = expectation(description: "The finishing source started")
        Task {
            if await frameSource.waitForStartCount(1) {
                firstStart.fulfill()
            }
        }
        await fulfillment(of: [firstStart], timeout: 2)
        guard frameSource.startCallCount >= 1 else {
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = await coordinator.cancelFromAction(sessionID: "finish-hanging-stop", confirm: true)
            _ = try? await captureTask.value
            return XCTFail("The finishing source did not start.")
        }
        let originalGeneration = coordinator.terminalGate.generation
        await frameSource.deliver(
            generation: originalGeneration,
            requestID: 0,
            frame: capturedFrame(rows: Array(0..<8))
        )
        await waitUntilAsync { (await session.status()).outputSize.height == 8 }
        XCTAssertEqual(
            coordinator.finishFromAction(sessionID: "finish-hanging-stop"),
            .accepted(state: .finalizing)
        )
        let finishStop = expectation(description: "Finish requested source stop")
        Task {
            if await frameSource.waitForStopCount(1) {
                finishStop.fulfill()
            }
        }
        await fulfillment(of: [finishStop], timeout: 2)
        guard frameSource.stopCallCount >= 1,
              await stopDeadlineGate.waitForWaiterCount(1) else {
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = try? await captureTask.value
            return XCTFail("Finish did not enter the bounded stop teardown.")
        }
        await stopDeadlineGate.releaseNext()
        do {
            _ = try await captureTask.value
            XCTFail("Finish must fail closed when the source cannot stop before its deadline.")
        } catch {
            XCTAssertTrue(error is ScreenshotCaptureError)
        }
        XCTAssertNil(coordinator.hud.windowNumber)
        XCTAssertNil(coordinator.continuation)
        let finishFailureStatus = await session.status()
        XCTAssertEqual(finishFailureStatus.state, .idle)

        let replacementCapture = Task {
            try await coordinator.capture(
                sessionID: "finish-hanging-stop-replacement",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let replacementStart = expectation(description: "The post-finish replacement started")
        Task {
            if await frameSource.waitForStartCount(2) {
                replacementStart.fulfill()
            }
        }
        await fulfillment(of: [replacementStart], timeout: 2)
        guard frameSource.startCallCount >= 2 else {
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = await coordinator.cancelFromAction(
                sessionID: "finish-hanging-stop-replacement",
                confirm: true
            )
            _ = try? await replacementCapture.value
            return XCTFail("The post-finish replacement could not start.")
        }
        let replacementGeneration = coordinator.terminalGate.generation
        frameSource.releaseStop(generation: originalGeneration)
        await Task.yield()
        let postFinishReplacementStatus = await session.status()
        XCTAssertEqual(postFinishReplacementStatus.state, .capturing)
        XCTAssertEqual(coordinator.terminalGate.generation, replacementGeneration)

        let cancellation = Task {
            await coordinator.cancelFromAction(
                sessionID: "finish-hanging-stop-replacement",
                confirm: true
            )
        }
        let replacementStop = expectation(description: "The replacement stop was requested")
        Task {
            if await frameSource.waitForStopCount(2) {
                replacementStop.fulfill()
            }
        }
        await fulfillment(of: [replacementStop], timeout: 2)
        guard frameSource.stopCallCount >= 2,
              await stopDeadlineGate.waitForWaiterCount(1) else {
            await stopDeadlineGate.releaseNext()
            frameSource.releaseAllStops()
            _ = await cancellation.value
            _ = try? await replacementCapture.value
            return XCTFail("The replacement did not request source stop.")
        }
        frameSource.releaseStop(generation: replacementGeneration)
        _ = await cancellation.value
        _ = try? await replacementCapture.value
        await stopDeadlineGate.releaseNext()
        let remainingStopDeadlineWaiters = await stopDeadlineGate.waiterCount
        XCTAssertEqual(remainingStopDeadlineWaiters, 0)
    }

    @MainActor
    func testFirstCompleteFrameCancelsWatchdogBeforeItsDeadline() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = RecordingScrollingFrameSource()
        let watchdogGate = FirstFrameWatchdogGate()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in },
            firstCompleteFrameDeadline: .milliseconds(1),
            firstFrameWatchdogWait: { _ in await watchdogGate.wait() }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: "first-frame-cancels-watchdog",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }

        guard await frameSource.waitForStart() else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(
                sessionID: "first-frame-cancels-watchdog",
                confirm: true
            )
            _ = try? await captureTask.value
            return XCTFail("The frame source did not start.")
        }
        guard await watchdogGate.waitForWaiterCount(1) else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(
                sessionID: "first-frame-cancels-watchdog",
                confirm: true
            )
            _ = try? await captureTask.value
            return XCTFail("The first-frame watchdog did not arm.")
        }
        let generation = coordinator.terminalGate.generation
        await frameSource.deliver(
            generation: generation,
            requestID: 0,
            frame: capturedFrame(rows: Array(0..<8))
        )
        await watchdogGate.releaseNext()
        await waitUntilAsync { (await session.status()).outputSize.height == 8 }
        XCTAssertEqual(frameSource.stopCallCount, 0)

        _ = await coordinator.cancelFromAction(
            sessionID: "first-frame-cancels-watchdog",
            confirm: true
        )
        _ = try? await captureTask.value
        XCTAssertEqual(frameSource.stopCallCount, 1)
    }

    @MainActor
    func testFirstCompleteFrameDeliveredBeforeStartReturnsDoesNotArmWatchdog() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = RecordingScrollingFrameSource(
            firstFrameBeforeStartReturns: capturedFrame(rows: Array(0..<8))
        )
        let watchdogGate = FirstFrameWatchdogGate()
        let schedulingProbe = FirstFrameWatchdogSchedulingProbe()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in },
            firstCompleteFrameDeadline: .milliseconds(1),
            firstFrameWatchdogWait: { _ in await watchdogGate.wait() },
            firstFrameWatchdogSchedulingDidComplete: { outcome in
                schedulingProbe.record(outcome)
            }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: "reentrant-first-frame",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }

        guard await frameSource.waitForStart() else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(sessionID: "reentrant-first-frame", confirm: true)
            _ = try? await captureTask.value
            return XCTFail("The frame source did not start.")
        }
        guard let schedulingOutcome = await schedulingProbe.nextOutcome() else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(sessionID: "reentrant-first-frame", confirm: true)
            _ = try? await captureTask.value
            return XCTFail("The first-frame watchdog did not report its scheduling outcome.")
        }
        XCTAssertEqual(schedulingOutcome, .skippedAlreadyReceived)
        await watchdogGate.releaseNext()
        if schedulingOutcome == .armed {
            _ = await coordinator.cancelFromAction(sessionID: "reentrant-first-frame", confirm: true)
            _ = try? await captureTask.value
            return
        }

        let status = await session.status()
        XCTAssertEqual(status.state, .capturing)
        XCTAssertEqual(frameSource.stopCallCount, 0)

        _ = await coordinator.cancelFromAction(sessionID: "reentrant-first-frame", confirm: true)
        _ = try? await captureTask.value
        XCTAssertEqual(frameSource.stopCallCount, 1)
    }

    @MainActor
    func testOldFirstCompleteFrameWatchdogCannotFailReplacementCapture() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = RecordingScrollingFrameSource()
        let watchdogGate = FirstFrameWatchdogGate()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in },
            firstCompleteFrameDeadline: .milliseconds(1),
            firstFrameWatchdogWait: { _ in await watchdogGate.wait() }
        )
        let firstCapture = Task {
            try await coordinator.capture(sessionID: "old-watchdog", displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400), backingScale: 2, originatingApplication: nil)
        }
        guard await frameSource.waitForStart() else {
            await watchdogGate.releaseNext()
            _ = await coordinator.cancelFromAction(sessionID: "old-watchdog", confirm: true)
            _ = try? await firstCapture.value
            return XCTFail("The old frame source did not start.")
        }
        guard await watchdogGate.waitForWaiterCount(1) else {
            _ = await coordinator.cancelFromAction(sessionID: "old-watchdog", confirm: true)
            await watchdogGate.releaseNext()
            _ = try? await firstCapture.value
            return XCTFail("The old first-frame watchdog did not arm.")
        }
        _ = await coordinator.cancelFromAction(sessionID: "old-watchdog", confirm: true)

        let replacementCapture = Task {
            try await coordinator.capture(sessionID: "replacement-watchdog", displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400), backingScale: 2, originatingApplication: nil)
        }
        guard await frameSource.waitForStartCount(2) else {
            _ = await coordinator.cancelFromAction(sessionID: "replacement-watchdog", confirm: true)
            await watchdogGate.releaseNext()
            await watchdogGate.releaseNext()
            _ = try? await firstCapture.value
            _ = try? await replacementCapture.value
            return XCTFail("The replacement frame source did not start.")
        }
        guard await watchdogGate.waitForWaiterCount(2) else {
            _ = await coordinator.cancelFromAction(
                sessionID: "replacement-watchdog",
                confirm: true
            )
            await watchdogGate.releaseNext()
            await watchdogGate.releaseNext()
            _ = try? await firstCapture.value
            _ = try? await replacementCapture.value
            return XCTFail("The replacement first-frame watchdog did not arm.")
        }
        await watchdogGate.releaseNext()
        let currentStatus = await session.status()
        XCTAssertEqual(currentStatus.state, .capturing)

        _ = await coordinator.cancelFromAction(sessionID: "replacement-watchdog", confirm: true)
        await watchdogGate.releaseNext()
        _ = try? await firstCapture.value
        _ = try? await replacementCapture.value
    }

    @MainActor
    func testFrameSourceLateStartFailureDoesNotPolluteReplacement() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        let frameSource = BlockingStartScrollingFrameSource()
        let startDeadlineGate = FirstFrameWatchdogGate()
        let lateStartFailureHandled = expectation(
            description: "The original late start failure completed coordinator handling"
        )
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in },
            frameSourceStartDeadline: .milliseconds(1),
            frameSourceStartDeadlineWait: { _ in await startDeadlineGate.wait() },
            frameSourceStartFailureDidComplete: { _ in lateStartFailureHandled.fulfill() }
        )
        let firstCapture = Task {
            try await coordinator.capture(
                sessionID: "blocked-start",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }

        guard await frameSource.waitForStartCount(1),
              await startDeadlineGate.waitForWaiterCount(1) else {
            _ = await coordinator.cancelFromAction(sessionID: "blocked-start", confirm: true)
            await startDeadlineGate.releaseNext()
            frameSource.completeFirstStart()
            _ = try? await firstCapture.value
            return XCTFail("The blocked source start deadline did not arm.")
        }
        let originalGeneration = coordinator.terminalGate.generation
        await startDeadlineGate.releaseNext()
        guard await frameSource.waitForStopCount(1) else {
            _ = await coordinator.cancelFromAction(sessionID: "blocked-start", confirm: true)
            frameSource.completeFirstStart()
            _ = try? await firstCapture.value
            return XCTFail("The start deadline did not stop the blocked source.")
        }
        do {
            _ = try await firstCapture.value
            XCTFail("A frame source start that exceeds its deadline must fail capture.")
        } catch {
            XCTAssertTrue(error is ScreenshotCaptureError)
        }
        XCTAssertEqual(frameSource.stopCallCount, 1)

        let replacementCapture = Task {
            try await coordinator.capture(
                sessionID: "blocked-start-replacement",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        guard await frameSource.waitForStartCount(2) else {
            _ = await coordinator.cancelFromAction(
                sessionID: "blocked-start-replacement",
                confirm: true
            )
            await startDeadlineGate.releaseNext()
            frameSource.completeFirstStart()
            _ = try? await replacementCapture.value
            return XCTFail("The replacement capture never started.")
        }
        let replacementGeneration = coordinator.terminalGate.generation
        let replacementStatus = await session.status()
        XCTAssertEqual(replacementStatus.state, .capturing)

        frameSource.completeFirstStart()
        guard await frameSource.waitForFirstStartCompletion() else {
            _ = await coordinator.cancelFromAction(
                sessionID: "blocked-start-replacement",
                confirm: true
            )
            await startDeadlineGate.releaseNext()
            frameSource.completeFirstStart()
            _ = try? await replacementCapture.value
            return XCTFail("The original blocked start did not fail late.")
        }
        guard await XCTWaiter.fulfillment(
            of: [lateStartFailureHandled],
            timeout: 2
        ) == .completed else {
            _ = await coordinator.cancelFromAction(
                sessionID: "blocked-start-replacement",
                confirm: true
            )
            await startDeadlineGate.releaseNext()
            frameSource.completeFirstStart()
            _ = try? await replacementCapture.value
            return XCTFail("The original late start failure did not finish coordinator handling.")
        }
        let statusAfterLateFailure = await session.status()
        XCTAssertEqual(statusAfterLateFailure.state, .capturing)
        XCTAssertEqual(frameSource.stopCallCount, 1)
        coordinator.issueFrameDemand(.seed, generation: replacementGeneration)
        guard await frameSource.waitForRequestCount(1) else {
            _ = await coordinator.cancelFromAction(
                sessionID: "blocked-start-replacement",
                confirm: true
            )
            await startDeadlineGate.releaseNext()
            frameSource.completeFirstStart()
            _ = try? await replacementCapture.value
            return XCTFail("The replacement capture did not receive a frame demand.")
        }
        XCTAssertEqual(frameSource.requests.last?.generation, replacementGeneration)

        _ = await coordinator.cancelFromAction(
            sessionID: "blocked-start-replacement",
            confirm: true
        )
        await startDeadlineGate.releaseNext()
        _ = try? await replacementCapture.value
        XCTAssertEqual(frameSource.stopCallCount, 2)
        XCTAssertEqual(frameSource.stoppedGenerations, [originalGeneration, replacementGeneration])
    }

    @MainActor
    func testSuspendedOldIngestCannotClearNewFrameOwnerOrOverwriteRestartedCapture() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = OperationReturnGate(blockedOccurrences: [.ingest: 2])
        let session = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root,
            operationReturnBoundary: { operation in
                await gate.suspendIfNeeded(operation)
            }
        )
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            healthChecker: ScrollingScreenshotHealthChecker { _ in .healthy },
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: "stale-ingest-after-restart",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let cleanup: @MainActor () async -> Void = {
            await gate.releaseAll()
            _ = await coordinator.cancelFromAction(
                sessionID: "stale-ingest-after-restart",
                confirm: true
            )
            _ = try? await captureTask.value
        }

        do {
            guard await frameSource.waitForStart() else {
                XCTFail("The frame source did not start.")
                await cleanup()
                return
            }
            let generation = coordinator.terminalGate.generation
            await frameSource.deliver(
                generation: generation,
                requestID: 0,
                frame: capturedFrame(rows: Array(0..<8))
            )
            guard await gate.waitForArrival(of: .ingest, count: 1) else {
                XCTFail("The first ingest never reached the suspended return boundary.")
                await cleanup()
                return
            }

            coordinator.handleHUDCommand(.restart)
            guard await frameSource.waitForRequestCount(1) else {
                XCTFail("The restarted capture did not receive a frame demand.")
                await cleanup()
                return
            }
            let restartedRequest = try XCTUnwrap(frameSource.requests.last)
            await frameSource.deliver(
                generation: generation,
                requestID: restartedRequest.requestID,
                frame: capturedFrame(rows: Array(100..<108))
            )
            guard await gate.waitForArrival(of: .ingest, count: 2) else {
                XCTFail("The restarted ingest never reached the suspended return boundary.")
                await cleanup()
                return
            }

            await gate.release(.ingest)
            await Task.yield()
            XCTAssertNotNil(
                coordinator.frameProcessingOwner,
                "The old frame worker must not clear the newer worker's ownership while it is suspended."
            )

            await gate.release(.ingest)
            await waitUntilAsync {
                let status = await coordinator.status()
                return status.state == .capturing && status.outputSize.height == 8
            }

            let status = await coordinator.status()
            XCTAssertEqual(status.state, .capturing)
            XCTAssertEqual(status.outputSize.height, 8)
            XCTAssertEqual(coordinator.hud.state.phase, .capturing)
            XCTAssertFalse(coordinator.isManuallyPaused)
        } catch {
            await cleanup()
            throw error
        }

        await cleanup()
    }

    @MainActor
    func testSuspendedResumeValidationCannotOverwriteNewPauseState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = OperationReturnGate(blockedOccurrences: [.validateResumeAnchor: 1])
        let session = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root,
            operationReturnBoundary: { operation in
                await gate.suspendIfNeeded(operation)
            }
        )
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            healthChecker: ScrollingScreenshotHealthChecker { _ in .healthy },
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: "stale-resume-validation",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let cleanup: @MainActor () async -> Void = {
            await gate.releaseAll()
            _ = await coordinator.cancelFromAction(
                sessionID: "stale-resume-validation",
                confirm: true
            )
            _ = try? await captureTask.value
        }

        do {
            guard await frameSource.waitForStart() else {
                XCTFail("The frame source did not start.")
                await cleanup()
                return
            }
            let generation = coordinator.terminalGate.generation
            await frameSource.deliver(
                generation: generation,
                requestID: 0,
                frame: capturedFrame(rows: Array(0..<8))
            )
            await waitUntilAsync {
                (await coordinator.status()).state == .capturing
                    && coordinator.hud.state.accumulatedHeight == 8
            }

            coordinator.handleHUDCommand(.pause)
            await waitUntilAsync { (await coordinator.status()).state == .paused }
            coordinator.handleHUDCommand(.resume)
            guard await frameSource.waitForRequestCount(1) else {
                XCTFail("The resumed capture did not receive a frame demand.")
                await cleanup()
                return
            }
            let validationRequest = try XCTUnwrap(frameSource.requests.last)
            await frameSource.deliver(
                generation: generation,
                requestID: validationRequest.requestID,
                frame: capturedFrame(rows: Array(0..<8))
            )
            guard await gate.waitForArrival(of: .validateResumeAnchor, count: 1) else {
                XCTFail("Resume validation never reached the suspended return boundary.")
                await cleanup()
                return
            }
            let suspendedValidationTask = try XCTUnwrap(coordinator.frameProcessingTask)

            coordinator.handleHUDCommand(.pause)
            await waitUntilAsync {
                (await coordinator.status()).state == .paused
                    && coordinator.hud.state.phase == .paused
                    && !coordinator.hud.state.isCheckingResume
            }
            let pausedPhase = coordinator.hud.state.phase
            let pausedWarning = coordinator.hud.state.warning
            let pausedWidth = coordinator.hud.state.accumulatedWidth
            let pausedHeight = coordinator.hud.state.accumulatedHeight
            XCTAssertTrue(coordinator.isManuallyPaused)
            XCTAssertFalse(coordinator.samplingGate.hasActiveCaptureAttempt)
            XCTAssertFalse(coordinator.samplingGate.hasPendingCaptureAttempt)

            await gate.release(.validateResumeAnchor)
            await suspendedValidationTask.value

            XCTAssertEqual(coordinator.hud.state.phase, pausedPhase)
            XCTAssertEqual(coordinator.hud.state.warning, pausedWarning)
            XCTAssertEqual(coordinator.hud.state.accumulatedWidth, pausedWidth)
            XCTAssertEqual(coordinator.hud.state.accumulatedHeight, pausedHeight)
            XCTAssertTrue(coordinator.isManuallyPaused)
            XCTAssertFalse(coordinator.samplingGate.hasActiveCaptureAttempt)
            XCTAssertFalse(coordinator.samplingGate.hasPendingCaptureAttempt)
            XCTAssertFalse(coordinator.hud.state.isCheckingResume)
            let statusAfterLateValidation = await coordinator.status()
            XCTAssertEqual(statusAfterLateValidation.state, .paused)
        } catch {
            await cleanup()
            throw error
        }

        await cleanup()
    }

    @MainActor
    func testFinishFailsClosedWhenAcceptedFramePipelineCannotDrain() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = OperationReturnGate(blockedOccurrences: [.ingest: 1])
        let session = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root,
            operationReturnBoundary: { operation in
                await gate.suspendIfNeeded(operation)
            }
        )
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            healthChecker: ScrollingScreenshotHealthChecker { _ in .healthy },
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: "finish-with-blocked-ingest",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let captureCompleted = expectation(
            description: "blocked-ingest capture completes with a bounded failure"
        )
        let captureCompletionTask = Task { @MainActor in
            let result = await captureTask.result
            captureCompleted.fulfill()
            return result
        }
        let cleanup: @MainActor () async -> Void = {
            await gate.releaseAll()
            _ = await coordinator.cancelFromAction(
                sessionID: "finish-with-blocked-ingest",
                confirm: true
            )
            _ = await captureCompletionTask.value
        }

        guard await frameSource.waitForStart() else {
            await cleanup()
            return XCTFail("The frame source did not start.")
        }
        let generation = coordinator.terminalGate.generation
        await frameSource.deliver(
            generation: generation,
            requestID: 0,
            frame: capturedFrame(rows: Array(0..<8))
        )
        guard await gate.waitForArrival(of: .ingest, count: 1) else {
            await cleanup()
            return XCTFail("The accepted frame never reached the suspended ingest boundary.")
        }

        XCTAssertEqual(
            coordinator.finishFromAction(sessionID: "finish-with-blocked-ingest"),
            .accepted(state: .finalizing)
        )
        guard await XCTWaiter.fulfillment(
            of: [captureCompleted],
            timeout: 2
        ) == .completed else {
            await cleanup()
            return XCTFail("Finalization did not fail closed within the test deadline.")
        }
        switch await captureCompletionTask.value {
        case .success:
            XCTFail("Finalization must fail closed instead of omitting an accepted in-flight frame.")
        case let .failure(error as ScrollingScreenshotSessionError):
            guard case .invalidState = error else {
                XCTFail("Unexpected scrolling capture failure: \(error)")
                await gate.releaseAll()
                return
            }
        case let .failure(error):
            XCTFail("Unexpected scrolling capture failure: \(error)")
        }
        XCTAssertNil(coordinator.continuation)
        XCTAssertNil(coordinator.frameProcessingOwner)
        XCTAssertEqual(coordinator.terminalGate.phase, .terminal(.failed))
        XCTAssertEqual(frameSource.stopCallCount, 1)

        await gate.releaseAll()
        let replacementCaptureTask = Task {
            try await coordinator.capture(
                sessionID: "finish-drain-replacement",
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        guard await frameSource.waitForStartCount(2) else {
            await gate.releaseAll()
            _ = await coordinator.cancelFromAction(
                sessionID: "finish-drain-replacement",
                confirm: true
            )
            _ = try? await replacementCaptureTask.value
            return XCTFail("The replacement capture did not start.")
        }
        let replacementGeneration = coordinator.terminalGate.generation
        await frameSource.deliver(
            generation: replacementGeneration,
            requestID: 0,
            frame: capturedFrame(rows: Array(10..<18))
        )
        await waitUntilAsync {
            let status = await coordinator.status()
            return status.state == .capturing && status.outputSize.height == 8
        }
        XCTAssertEqual(frameSource.startCallCount, 2)
        XCTAssertEqual(frameSource.stopCallCount, 1)
        _ = await coordinator.cancelFromAction(
            sessionID: "finish-drain-replacement",
            confirm: true
        )
        _ = try? await replacementCaptureTask.value

        await gate.releaseAll()
    }

    @MainActor
    func testFinishWaitsForFrameClaimedBySourceBeforeCallback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "finish-with-source-delivery-in-flight"
        let session = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: frameSource,
            healthChecker: ScrollingScreenshotHealthChecker { _ in .healthy },
            screenRecordingPreflight: { true },
            inputMonitoringPreflight: { true },
            scrollMonitorInstaller: { _ in NSObject() },
            scrollMonitorRemover: { _ in }
        )
        let captureTask = Task {
            try await coordinator.capture(
                sessionID: sessionID,
                displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectionRect: CGRect(x: 10, y: 10, width: 300, height: 400),
                backingScale: 2,
                originatingApplication: nil
            )
        }
        let callbackGate = ScrollingFrameCallbackGate()
        let callbackClaimed = expectation(
            description: "The frame source claimed the requested frame"
        )

        guard await frameSource.waitForStart() else {
            _ = await coordinator.cancelFromAction(sessionID: "finish-with-source-delivery-in-flight", confirm: true)
            _ = try? await captureTask.value
            return XCTFail("The frame source did not start.")
        }
        let generation = coordinator.terminalGate.generation
        await frameSource.deliver(
            generation: generation,
            requestID: 0,
            frame: capturedFrame(rows: Array(0..<8))
        )
        await waitUntilAsync {
            (await coordinator.status()).outputSize.height == 8
        }

        coordinator.issueFrameDemand(.seed, generation: generation)
        guard await frameSource.waitForRequestCount(1) else {
            _ = await coordinator.cancelFromAction(sessionID: "finish-with-source-delivery-in-flight", confirm: true)
            _ = try? await captureTask.value
            return XCTFail("The capture did not receive a frame demand.")
        }
        let request = try XCTUnwrap(frameSource.requests.last)
        let deliveryTask = Task {
            callbackClaimed.fulfill()
            await callbackGate.wait()
            await frameSource.deliver(
                generation: request.generation,
                requestID: request.requestID,
                frame: capturedFrame(rows: Array(5..<13))
            )
        }
        await fulfillment(of: [callbackClaimed], timeout: 1)

        XCTAssertEqual(
            coordinator.finishFromAction(sessionID: sessionID),
            .accepted(state: .finalizing)
        )
        await Task.yield()
        await callbackGate.release()
        let finalImage = try await captureTask.value
        await deliveryTask.value

        XCTAssertEqual(finalImage.height, 13)
        XCTAssertEqual(
            decodedRowIdentifiers(finalImage, candidates: Array(0..<13)),
            Array(0..<13),
            "Finish must include a frame already claimed by the source before its callback reaches the coordinator."
        )
        let editingResult = await coordinator.finishEditingSession(
            sessionID: sessionID,
            terminal: .completed
        )
        XCTAssertEqual(
            editingResult,
            .accepted(state: .idle, wasEditing: true)
        )
    }

    func testCleanupFailureIsDiagnosableAndCanBeRetriedWithoutLosingSessionState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = LockedCounter()
        let fileSystem = ScrollingScreenshotFileSystem(removeItem: { url in
            if attempts.increment() <= 3 {
                throw NSError(domain: "ScrollingCleanupFixture", code: 17)
            }
            try FileManager.default.removeItem(at: url)
        })
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root,
            fileSystem: fileSystem
        )
        let sessionID = try await coordinator.begin(sessionID: "cleanup-retry")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        do {
            try await coordinator.cancel(confirm: true)
            XCTFail("The first three cleanup attempts should fail.")
        } catch ScrollingScreenshotSessionError.cleanupFailed {
            // Expected.
        }
        let cleanupDiagnostic = await coordinator.cleanupDiagnostic()
        let diagnostic = try XCTUnwrap(cleanupDiagnostic)
        XCTAssertEqual(diagnostic.attempts, 3)
        XCTAssertEqual(diagnostic.errorCode, 17)
        let retainedStatus = await coordinator.status()
        XCTAssertEqual(retainedStatus.sessionID, sessionID)

        try await coordinator.retryCleanup()
        try await coordinator.cancel(confirm: true)
        let cancelledStatus = await coordinator.status()
        XCTAssertNil(cancelledStatus.sessionID)
    }

    func testCleanupFailureCanReleaseTheInMemoryGateForTheNextSession() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = LockedCounter()
        let fileSystem = ScrollingScreenshotFileSystem(removeItem: { url in
            if attempts.increment() <= 3 {
                throw NSError(domain: "ScrollingCleanupFixture", code: 18)
            }
            try FileManager.default.removeItem(at: url)
        })
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root,
            fileSystem: fileSystem
        )
        _ = try await coordinator.begin(sessionID: "cleanup-release-old")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        do {
            try await coordinator.cancel(confirm: true)
            XCTFail("The first cleanup should exhaust its bounded retries.")
        } catch ScrollingScreenshotSessionError.cleanupFailed {
            // Expected. The cache directory remains available for launch recovery.
        }

        await coordinator.releaseSessionAfterCleanupFailure()
        let nextSessionID = try await coordinator.begin(sessionID: "cleanup-release-next")
        XCTAssertEqual(nextSessionID, "cleanup-release-next")
        try await coordinator.cancel(confirm: true)
    }

    func testResourceMetricsExposeRSSDiskAndStageDurationsWithoutPaths() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampler = ScrollingScreenshotResourceSampler(residentBytes: { 42_000_000 })
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root,
            resourceSampler: sampler
        )
        let sessionID = try await coordinator.begin(sessionID: "resource-metrics")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))
        _ = try await coordinator.ingest(capturedFrame(rows: Array(5..<13)))

        let staged = await coordinator.resourceMetrics()
        XCTAssertEqual(staged.baselineResidentBytes, 42_000_000)
        XCTAssertEqual(staged.peakResidentBytes, 42_000_000)
        XCTAssertEqual(staged.peakResidentIncreaseBytes, 0)
        XCTAssertGreaterThan(staged.currentTemporaryDiskBytes, 0)
        XCTAssertGreaterThanOrEqual(staged.peakTemporaryDiskBytes, staged.currentTemporaryDiskBytes)
        XCTAssertEqual(staged.ingest.sampleCount, 2)

        _ = try await coordinator.finalize()
        let finalized = await coordinator.resourceMetrics()
        XCTAssertEqual(finalized.currentTemporaryDiskBytes, 0)
        XCTAssertEqual(finalized.finalize.sampleCount, 1)
        XCTAssertGreaterThanOrEqual(finalized.finalize.totalMilliseconds, 0)
        try await coordinator.finishEditing(sessionID: sessionID, terminal: .completed)
    }

    func testReturningToLastAcceptedFrameCompletesRecoveryWithoutStartingEndCountdown() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "return-to-anchor")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(5..<13)))
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        let recovered = try await coordinator.ingest(capturedFrame(rows: Array(5..<13)))
        guard case let .recovered(snapshot) = recovered else {
            return XCTFail("Returning to the anchor should recover, got \(recovered)")
        }
        XCTAssertEqual(snapshot.state, .capturing)
        XCTAssertEqual(snapshot.outputSize.height, 8)
        try await coordinator.cancel(confirm: true)
    }

    func testInsufficientOverlapUsesStableRecoveryBudgetBeforePausing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "insufficient-overlap")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        for attempt in 1...3 {
            let event = try await coordinator.ingest(capturedFrame(rows: Array(20..<28)))
            if attempt < 3 {
                guard case .recovering = event else {
                    return XCTFail("Transient overlap failure must remain recoverable, got \(event)")
                }
                continue
            }
            guard case let .paused(snapshot) = event else {
                return XCTFail("Stable overlap failure must pause after the recovery budget, got \(event)")
            }
            XCTAssertEqual(snapshot.state, .paused)
        }
        try await coordinator.cancel(confirm: true)
    }

    func testBufferedFramesFromOneGestureConsumeOneRecoveryAttempt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "buffered-recovery-budget")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        for offset in [20, 30, 40, 50] {
            let event = try await coordinator.ingest(
                capturedFrame(rows: Array(offset..<(offset + 8))),
                recoveryAttemptID: 1
            )
            guard case .recovering = event else {
                return XCTFail("Frames from one gesture must share one recovery attempt, got \(event)")
            }
        }

        let secondAttempt = try await coordinator.ingest(
            capturedFrame(rows: Array(60..<68)),
            recoveryAttemptID: 2
        )
        guard case .recovering = secondAttempt else {
            return XCTFail("The second stable gesture should remain recoverable, got \(secondAttempt)")
        }

        let thirdAttempt = try await coordinator.ingest(
            capturedFrame(rows: Array(70..<78)),
            recoveryAttemptID: 3
        )
        guard case let .paused(snapshot) = thirdAttempt else {
            return XCTFail("Only the third distinct stable gesture should pause, got \(thirdAttempt)")
        }
        XCTAssertEqual(snapshot.state, .paused)
        try await coordinator.cancel(confirm: true)
    }

    func testLaterStableFrameInOneGestureRecoversWithoutPausing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "buffered-transitional-frame")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))

        let transitional = try await coordinator.ingest(
            capturedFrame(rows: Array(20..<28)),
            recoveryAttemptID: 1
        )
        guard case .recovering = transitional else {
            return XCTFail("The transitional frame should enter recovery, got \(transitional)")
        }

        let stable = try await coordinator.ingest(
            capturedFrame(rows: Array(5..<13)),
            recoveryAttemptID: 1
        )
        guard case let .recovered(snapshot) = stable else {
            return XCTFail("A later stable frame from the same gesture should recover, got \(stable)")
        }
        XCTAssertEqual(snapshot.state, .capturing)
        XCTAssertEqual(snapshot.outputSize.height, 13)

        let finalImage = try await coordinator.finalize()
        XCTAssertEqual(decodedRowIdentifiers(finalImage, candidates: Array(0..<13)), Array(0..<13))
    }

    func testThirdGestureChecksLaterStableFrameBeforeCommittingPause() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "third-gesture-stable-tail")
        _ = try await coordinator.ingest(capturedFrame(rows: Array(0..<8)))
        _ = try await coordinator.ingest(
            capturedFrame(rows: Array(20..<28)),
            recoveryAttemptID: 1
        )
        _ = try await coordinator.ingest(
            capturedFrame(rows: Array(30..<38)),
            recoveryAttemptID: 2
        )

        let transitional = try await coordinator.ingest(
            capturedFrame(rows: Array(40..<48)),
            recoveryAttemptID: 3,
            commitsRecoveryAttempt: false
        )
        guard case .recovering = transitional else {
            return XCTFail("An intermediate frame must not commit the third failure, got \(transitional)")
        }

        let stable = try await coordinator.ingest(
            capturedFrame(rows: Array(5..<13)),
            recoveryAttemptID: 3,
            commitsRecoveryAttempt: true
        )
        guard case let .recovered(snapshot) = stable else {
            return XCTFail("The stable tail frame must recover before pause, got \(stable)")
        }
        XCTAssertEqual(snapshot.state, .capturing)
        XCTAssertEqual(snapshot.outputSize.height, 13)
        try await coordinator.cancel(confirm: true)
    }

    func testMediumLongImageFinalizationCompletesWithinResourceBudget() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "medium-long-resource")

        let frameHeight = 600
        let frameWidth = 512
        let scrollRows = 400
        let finalStart = 8_000
        let startedAt = CFAbsoluteTimeGetCurrent()
        for start in stride(from: 0, through: finalStart, by: scrollRows) {
            _ = try await coordinator.ingest(capturedFrame(
                rows: Array(start..<(start + frameHeight)),
                width: frameWidth
            ))
        }
        let image = try await coordinator.finalize()
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertEqual(image.width, frameWidth)
        XCTAssertEqual(image.height, finalStart + frameHeight)
        XCTAssertLessThan(
            elapsed,
            12,
            "A representative 4.4 MP long image must remain inside a practical finalization budget."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("medium-long-resource").path))
    }

    func testNearEffectiveLimitResourceProfile() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BLOCKS_RUN_SCROLLING_RESOURCE_PROFILE"] == "1",
            "Run explicitly to avoid adding a roughly 58.5 MP allocation to every App test pass."
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScrollingScreenshotSessionCoordinator(
            assembler: exactAssembler,
            rootDirectory: root
        )
        _ = try await coordinator.begin(sessionID: "near-effective-limit-resource")

        let frameHeight = 600
        let frameWidth = 3_900
        let scrollRows = 400
        let finalStart = 14_400
        for start in stride(from: 0, through: finalStart, by: scrollRows) {
            let event = try await coordinator.ingest(capturedFrame(
                rows: Array(start..<(start + frameHeight)),
                width: frameWidth
            ))
            guard case .accepted = event else {
                return XCTFail("Near-limit frame at y=\(start) must be accepted, got \(event)")
            }
        }
        let preFinalize = await coordinator.resourceMetrics()
        let preFinalizeStatus = await coordinator.status()
        let image = try await coordinator.finalize()
        let metrics = await coordinator.resourceMetrics()

        let outputSampler = ScrollingScreenshotResourceSampler()
        let outputBaselineResidentBytes = outputSampler.residentBytes()
        let encoder = ScreenshotImageEncoder()
        let pngStartedAt = CFAbsoluteTimeGetCurrent()
        let pngData = try encoder.pngData(image)
        let pngMilliseconds = (CFAbsoluteTimeGetCurrent() - pngStartedAt) * 1_000
        let jpegStartedAt = CFAbsoluteTimeGetCurrent()
        let jpegData = try encoder.jpegData(image, quality: 0.9)
        let jpegMilliseconds = (CFAbsoluteTimeGetCurrent() - jpegStartedAt) * 1_000
        let tiffStartedAt = CFAbsoluteTimeGetCurrent()
        let tiffData = try XCTUnwrap(
            NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ).tiffRepresentation
        )
        let tiffMilliseconds = (CFAbsoluteTimeGetCurrent() - tiffStartedAt) * 1_000
        let outputResidentBytes = outputSampler.residentBytes()
        let outputResidentIncreaseBytes = outputResidentBytes.flatMap { current in
            outputBaselineResidentBytes.map { max(0, current - $0) }
        }

        XCTAssertEqual(image.width, frameWidth)
        XCTAssertEqual(image.height, finalStart + frameHeight)
        XCTAssertEqual(image.width * image.height, 58_500_000)
        XCTAssertEqual(preFinalizeStatus.outputSize, .init(width: frameWidth, height: 15_000))
        XCTAssertNotNil(preFinalizeStatus.warning)
        XCTAssertGreaterThan(preFinalize.peakTemporaryDiskBytes, 0)
        XCTAssertEqual(metrics.currentTemporaryDiskBytes, 0)
        XCTAssertLessThan(metrics.finalize.maximumMilliseconds, 30_000)
        XCTAssertLessThan(metrics.peakResidentIncreaseBytes ?? .max, 900_000_000)
        XCTAssertFalse(pngData.isEmpty)
        XCTAssertFalse(jpegData.isEmpty)
        XCTAssertFalse(tiffData.isEmpty)
        XCTAssertLessThan(pngMilliseconds, 30_000)
        XCTAssertLessThan(jpegMilliseconds, 30_000)
        XCTAssertLessThan(tiffMilliseconds, 30_000)
        XCTAssertLessThan(outputResidentIncreaseBytes ?? .max, 1_200_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("near-effective-limit-resource").path
            )
        )
        print(
            "SCROLLING_RESOURCE_PROFILE "
                + "pixels=58500000 "
                + "finalize_ms=\(Int(metrics.finalize.maximumMilliseconds.rounded())) "
                + "rss_delta_bytes=\(metrics.peakResidentIncreaseBytes ?? -1) "
                + "temp_peak_bytes=\(preFinalize.peakTemporaryDiskBytes) "
                + "png_ms=\(Int(pngMilliseconds.rounded())) "
                + "png_bytes=\(pngData.count) "
                + "jpeg_ms=\(Int(jpegMilliseconds.rounded())) "
                + "jpeg_bytes=\(jpegData.count) "
                + "tiff_ms=\(Int(tiffMilliseconds.rounded())) "
                + "tiff_bytes=\(tiffData.count) "
                + "output_rss_delta_bytes=\(outputResidentIncreaseBytes ?? -1)"
        )
    }

    func testNearEffectiveLimitHistoryCommitResourceProfile() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BLOCKS_RUN_SCROLLING_RESOURCE_PROFILE"] == "1",
            "Run explicitly to avoid decoding a roughly 58.5 MP history payload in every App test pass."
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pngData = try autoreleasepool {
            let image = makeImage(rows: Array(0..<15_000), width: 3_900)
            return try ScreenshotImageEncoder().pngData(image)
        }
        let storageRoot = root.appendingPathComponent("history", isDirectory: true)
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: storageRoot)
        )
        defer { database.close() }
        let repository = ClipboardRepository(
            database: database,
            blobStore: BlobStore(directory: database.environment.blobDirectory, sidecarThresholdBytes: 1)
        )
        let now = Date()
        let record = ClipboardRecorderRecord(
            id: "near-effective-limit-history",
            createdAt: now,
            changeCount: 1,
            kind: .image,
            formatSummary: ClipboardRecorderFormatSummary(
                itemCount: 1,
                types: ["public.png"],
                byteCount: pngData.count
            ),
            sourceApp: nil,
            signatureSHA256: String(repeating: "0", count: 64),
            signatureSHA256_12: String(repeating: "0", count: 12),
            fixtureOwned: true,
            restorable: true,
            lastCopiedAt: now,
            summary: "Low-sensitivity resource fixture"
        )
        let sampler = ScrollingScreenshotResourceSampler()
        let baselineResidentBytes = sampler.residentBytes()
        let startedAt = CFAbsoluteTimeGetCurrent()

        let result = try repository.commitScreenshotHistory(
            request: ScreenshotHistoryCommitRequest(
                record: record,
                pngData: pngData,
                ocrState: .notRequired
            )
        )

        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        let residentIncreaseBytes = sampler.residentBytes().flatMap { current in
            baselineResidentBytes.map { max(0, current - $0) }
        }
        let storedByteCount = try database.connection.firstInt(
            "SELECT payload_byte_count FROM clipboard_payloads WHERE record_id = ?",
            bindings: [.string(record.id)]
        )
        let signatures = try database.connection.withStatement(
            """
            SELECT visual_signature_sha256, png_payload_sha256
            FROM clipboard_payloads
            WHERE record_id = ?
            """,
            bindings: [.string(record.id)]
        ) { statement -> (String?, String?)? in
            guard try statement.step() else { return nil }
            return (statement.columnString(0), statement.columnString(1))
        }
        let resolvedSignatures = try XCTUnwrap(signatures)

        XCTAssertEqual(result.record.id, record.id)
        XCTAssertEqual(storedByteCount, pngData.count)
        XCTAssertEqual(resolvedSignatures.0, result.record.signatureSHA256)
        XCTAssertEqual(try XCTUnwrap(resolvedSignatures.1).count, 64)
        XCTAssertLessThan(elapsedMilliseconds, 30_000)
        XCTAssertLessThan(residentIncreaseBytes ?? .max, 700_000_000)
        XCTAssertEqual(
            try ClipboardTagRepository(database: database)
                .loadRecordTags(recordIDs: [record.id])[record.id, default: []]
                .filter(\.isScreenshot)
                .count,
            1
        )
        print(
            "SCROLLING_HISTORY_RESOURCE_PROFILE "
                + "pixels=58500000 "
                + "commit_ms=\(Int(elapsedMilliseconds.rounded())) "
                + "png_bytes=\(pngData.count) "
                + "rss_delta_bytes=\(residentIncreaseBytes ?? -1)"
        )
    }

    func testBrowserRenderedFramesStitchWithoutMissingOrDuplicatedSeams() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = try ["0000", "0320", "0640", "0960"].map { try browserFixtureImage($0) }
        let coordinator = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        _ = try await coordinator.begin(sessionID: "browser-rendered-fixture")

        for (index, image) in frames.enumerated() {
            let event = try await coordinator.ingest(ScrollingCapturedFrame(
                image: image,
                timestamp: CMTime(value: CMTimeValue(index), timescale: 30),
                contentRect: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ))
            guard case .accepted = event else {
                return XCTFail("Browser frame \(index) must append without recovery, got \(event)")
            }
        }

        let stitched = try await coordinator.finalize()
        XCTAssertEqual(stitched.width, 900)
        XCTAssertEqual(stitched.height, 1_660)

        let stitchedBytes = rgbaBytes(stitched)
        let firstBytes = rgbaBytes(frames[0])
        assertSampledRegionEqual(
            source: firstBytes,
            sourceWidth: frames[0].width,
            sourceOriginY: 0,
            destination: stitchedBytes,
            destinationWidth: stitched.width,
            destinationOriginY: 0,
            height: 700
        )
        for index in 1..<frames.count {
            assertSampledRegionEqual(
                source: rgbaBytes(frames[index]),
                sourceWidth: frames[index].width,
                sourceOriginY: 380,
                destination: stitchedBytes,
                destinationWidth: stitched.width,
                destinationOriginY: 700 + (index - 1) * 320,
                height: 320
            )
        }
    }

    func testBrowserRenderedPageDownSequenceMatchesIndependentGroundTruthPixelForPixel() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try browserFixtureManifest()
        let coordinator = ScrollingScreenshotSessionCoordinator(rootDirectory: root)
        _ = try await coordinator.begin(sessionID: "browser-page-down-ground-truth")

        var lastOutputHeight = 0
        for (index, frame) in manifest.frames.enumerated() {
            let image = try browserFixtureImage(named: frame.file)
            let event = try await coordinator.ingest(ScrollingCapturedFrame(
                image: image,
                timestamp: CMTime(value: CMTimeValue(index), timescale: 30),
                contentRect: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ))
            let expectedHeight = frame.scrollY + manifest.viewport.height
            if index == manifest.frames.count - 1 {
                guard case let .unchanged(snapshot) = event else {
                    return XCTFail("A repeated bottom viewport must not append, got \(event)")
                }
                XCTAssertEqual(snapshot.outputSize.height, lastOutputHeight)
            } else {
                guard case let .accepted(snapshot) = event else {
                    return XCTFail("Page Down frame \(index) must append without a gap, got \(event)")
                }
                XCTAssertEqual(
                    snapshot.outputSize.height,
                    expectedHeight,
                    "Frame \(index) appended a different height than the browser actually scrolled."
                )
                lastOutputHeight = expectedHeight
            }
        }

        let stitched = try await coordinator.finalize()
        let groundTruth = try browserFixtureImage(named: manifest.groundTruth.file)
        XCTAssertEqual(stitched.width, manifest.documentSize.width)
        XCTAssertEqual(stitched.height, manifest.documentSize.height)
        XCTAssertEqual(groundTruth.width, manifest.documentSize.width)
        XCTAssertEqual(groundTruth.height, manifest.documentSize.height)
        assertPixelRegionEqual(
            source: groundTruth,
            destination: stitched,
            rect: manifest.contentComparisonRect
        )
    }

    func testVisionAlignmentFindsTheRenderedPageDownDistanceAcrossIndependentRegions() throws {
        let previous = try browserFixtureImage(named: "page-down-00.png")
        let incoming = try browserFixtureImage(named: "page-down-01.png")
        let hint = try XCTUnwrap(
            ScrollingScreenshotVisionAligner().alignmentHint(previous: previous, incoming: incoming)
        )
        XCTAssertEqual(hint.scrollRows, 310, accuracy: 4)
        XCTAssertGreaterThanOrEqual(hint.agreeingRegions, 2)
        XCTAssertTrue(hint.hasConsensus)
    }

    @MainActor
    func testCaptureInputIntentSamplesEitherWheelDirectionAndSupportedKeyboardWithoutReadingText() throws {
        let pageDown = try keyEvent(keyCode: 121)
        let downArrow = try keyEvent(keyCode: 125)
        let space = try keyEvent(keyCode: 49)
        let shiftSpace = try keyEvent(keyCode: 49, modifiers: .shift)
        let pageUp = try keyEvent(keyCode: 116)
        let upArrow = try keyEvent(keyCode: 126)
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: CGPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        for event in [pageDown, downArrow, space, shiftSpace, pageUp, upArrow, drag] {
            XCTAssertEqual(ScrollingScreenshotCaptureCoordinator.captureInputIntent(for: event), .sample)
        }

        XCTAssertEqual(
            ScrollingScreenshotCaptureCoordinator.captureInputIntent(
                eventType: .scrollWheel,
                scrollingDeltaX: 0,
                scrollingDeltaY: 4
            ),
            .sample
        )
        XCTAssertEqual(
            ScrollingScreenshotCaptureCoordinator.captureInputIntent(
                eventType: .scrollWheel,
                scrollingDeltaX: 0,
                scrollingDeltaY: -4
            ),
            .sample
        )
        XCTAssertEqual(
            ScrollingScreenshotCaptureCoordinator.captureInputIntent(
                eventType: .scrollWheel,
                scrollingDeltaX: 0,
                scrollingDeltaY: 0.2
            ),
            .none
        )
        XCTAssertEqual(
            ScrollingScreenshotCaptureCoordinator.captureInputIntent(
                eventType: .scrollWheel,
                scrollingDeltaX: 5,
                scrollingDeltaY: 1
            ),
            .none
        )
        XCTAssertTrue(ScrollingScreenshotCaptureCoordinator.isCancelKeyCode(53))
        XCTAssertFalse(ScrollingScreenshotCaptureCoordinator.isCancelKeyCode(36))
    }

    @MainActor
    func testScrollingCaptureEscapeUsesPhysicalKeyCode() {
        XCTAssertTrue(ScrollingScreenshotCaptureCoordinator.isCancelKeyCode(53))
        XCTAssertFalse(ScrollingScreenshotCaptureCoordinator.isCancelKeyCode(36))
    }

    @MainActor
    func testKeyboardScrollingDoesNotRequirePointerInsideSelection() {
        XCTAssertFalse(
            ScrollingScreenshotCaptureCoordinator.requiresPointerInsideSelection(for: .keyDown)
        )
        XCTAssertTrue(
            ScrollingScreenshotCaptureCoordinator.requiresPointerInsideSelection(for: .scrollWheel)
        )
        XCTAssertTrue(
            ScrollingScreenshotCaptureCoordinator.requiresPointerInsideSelection(for: .leftMouseDragged)
        )
    }

    @MainActor
    func testActionFinishIsAcceptedOnlyWhileCaptureCanBeFinalized() {
        XCTAssertTrue(ScrollingScreenshotRuntimeSnapshot.State.capturing.acceptsFinishAction)
        XCTAssertTrue(ScrollingScreenshotRuntimeSnapshot.State.possibleEnd.acceptsFinishAction)
        for state in [
            ScrollingScreenshotRuntimeSnapshot.State.idle,
            .selecting,
            .recovering,
            .paused,
            .finalizing,
        ] {
            XCTAssertFalse(state.acceptsFinishAction)
        }
    }

    func testFrameSamplingGateSeedsImmediatelyThenRequiresCaptureInput() {
        var gate = ScrollingFrameSamplingGate()

        XCTAssertTrue(gate.shouldIngestIncomingFrameImmediately)
        XCTAssertFalse(gate.registerCaptureAttempt())

        gate.markFrameAccepted()
        XCTAssertFalse(gate.shouldIngestIncomingFrameImmediately)
        XCTAssertFalse(gate.hasPendingCaptureAttempt)
        XCTAssertTrue(gate.registerCaptureAttempt())
        let firstRequest = gate.latestCaptureRequestSequence
        XCTAssertTrue(gate.registerCaptureAttempt())
        let secondRequest = gate.latestCaptureRequestSequence
        XCTAssertEqual(firstRequest, secondRequest, "One input burst must share one recovery budget.")
        XCTAssertTrue(gate.hasPendingCaptureAttempt)

        gate.markFrameEvaluated(through: firstRequest)
        XCTAssertFalse(gate.hasPendingCaptureAttempt)
        XCTAssertTrue(gate.hasActiveCaptureAttempt)
        XCTAssertTrue(gate.registerCaptureAttempt())
        XCTAssertEqual(gate.latestCaptureRequestSequence, firstRequest)

        gate.finishCaptureAttempt(through: firstRequest)
        XCTAssertFalse(gate.hasActiveCaptureAttempt)
        XCTAssertTrue(gate.registerCaptureAttempt())
        XCTAssertGreaterThan(gate.latestCaptureRequestSequence, secondRequest)
    }

    func testFrameBridgeBufferSeedsImmediatelyThenWaitsForAFreshRequestedSurface() throws {
        let buffer = ScrollingFrameBridgeBuffer<Int>()
        buffer.begin(generation: 7)

        let seed = try XCTUnwrap(buffer.offer(1, generation: 7))
        XCTAssertEqual(seed.value, 1)
        XCTAssertEqual(seed.requestID, 0)
        XCTAssertNil(buffer.offer(2, generation: 7))
        XCTAssertNil(buffer.offer(3, generation: 7))
        _ = buffer.complete(seed)

        XCTAssertNil(buffer.request(generation: 7, requestID: 41), "A request must wait for a post-input frame.")
        let fresh = try XCTUnwrap(buffer.offer(4, generation: 7))
        XCTAssertEqual(fresh.value, 4)
        XCTAssertEqual(fresh.requestID, 41)
        _ = buffer.complete(fresh)
        XCTAssertNil(buffer.request(generation: 7, requestID: 42), "A delivered surface cannot be converted twice.")
    }

    func testFrameBridgeBufferDeliversOrderedFutureFramesForQueuedDemands() throws {
        let buffer = ScrollingFrameBridgeBuffer<Int>()
        buffer.begin(generation: 7)
        let seed = try XCTUnwrap(buffer.offer(1, generation: 7))
        _ = buffer.complete(seed)

        XCTAssertNil(buffer.request(generation: 7, requestID: 11))
        XCTAssertNil(buffer.request(generation: 7, requestID: 12))
        let first = try XCTUnwrap(buffer.offer(2, generation: 7))
        XCTAssertEqual(first.value, 2)
        XCTAssertEqual(first.requestID, 11)
        XCTAssertNil(buffer.offer(3, generation: 7))
        let second = try XCTUnwrap(buffer.complete(first))
        XCTAssertEqual(second.value, 3)
        XCTAssertEqual(second.requestID, 12)
        _ = buffer.complete(second)
    }

    func testFrameBridgeBufferCancelsCoalescedDemandWithoutConsumingAFutureFrame() throws {
        let buffer = ScrollingFrameBridgeBuffer<Int>()
        buffer.begin(generation: 7)
        let seed = try XCTUnwrap(buffer.offer(1, generation: 7))
        _ = buffer.complete(seed)

        XCTAssertNil(buffer.request(generation: 7, requestID: 21))
        XCTAssertNil(buffer.request(generation: 7, requestID: 22))
        buffer.cancelRequests(generation: 7, requestIDs: [21])

        let delivery = try XCTUnwrap(buffer.offer(2, generation: 7))
        XCTAssertEqual(delivery.requestID, 22)
        XCTAssertEqual(delivery.value, 2)
    }

    func testFrameBridgeBufferRejectsOldGenerationAfterNewStreamStarts() throws {
        let buffer = ScrollingFrameBridgeBuffer<Int>()
        buffer.begin(generation: 1)
        _ = buffer.offer(10, generation: 1)
        buffer.begin(generation: 2)

        XCTAssertNil(buffer.offer(11, generation: 1))
        XCTAssertNil(buffer.request(generation: 1, requestID: 1))
        XCTAssertEqual(try XCTUnwrap(buffer.offer(20, generation: 2)).value, 20)
    }

    @MainActor
    func testPauseCancelsPendingFrameSourceRequestsBeforeResume() throws {
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(frameSource: frameSource)
        let generation = try coordinator.terminalGate.begin(sessionID: "pause-cancels-demands")
        coordinator.issueFrameDemand(.motion(1), generation: generation)
        coordinator.issueFrameDemand(.motion(2), generation: generation)
        let pendingRequestIDs = Set(coordinator.frameDemands.keys)

        coordinator.handleHUDCommand(.pause)

        XCTAssertFalse(pendingRequestIDs.isEmpty)
        XCTAssertEqual(frameSource.cancelledRequestIDs, pendingRequestIDs)
        XCTAssertTrue(coordinator.frameDemands.isEmpty)
    }

    @MainActor
    func testPossibleEndResetIsSkippedWhenCountdownIsInactive() throws {
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            frameSource: RecordingScrollingFrameSource()
        )
        _ = try coordinator.terminalGate.begin(sessionID: "inactive-countdown")

        XCTAssertFalse(coordinator.cancelPossibleEnd())
        XCTAssertNil(coordinator.possibleEndTask)
        XCTAssertNil(coordinator.possibleEndResetTask)
    }

    @MainActor
    func testPossibleEndDoesNotRestartAfterFinalizationBegins() throws {
        let frameSource = RecordingScrollingFrameSource()
        let coordinator = ScrollingScreenshotCaptureCoordinator(frameSource: frameSource)
        let generation = try coordinator.terminalGate.begin(
            sessionID: "finalizing-does-not-restart-countdown"
        )
        coordinator.samplingGate.markFrameAccepted()
        XCTAssertTrue(coordinator.samplingGate.registerCaptureAttempt())
        XCTAssertTrue(coordinator.terminalGate.markFinalizing(generation: generation))

        coordinator.schedulePossibleEndIfNeeded()

        XCTAssertNil(coordinator.possibleEndTask)
        XCTAssertTrue(frameSource.requests.isEmpty)
    }

    @MainActor
    func testPossibleEndResetCoalescesRapidCaptureInput() async throws {
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: temporaryRoot())
        let coordinator = ScrollingScreenshotCaptureCoordinator(
            session: session,
            frameSource: RecordingScrollingFrameSource()
        )
        let sessionID = try await session.begin(sessionID: "coalesced-countdown")
        _ = try coordinator.terminalGate.begin(sessionID: sessionID)
        coordinator.samplingGate.markFrameAccepted()
        XCTAssertTrue(coordinator.samplingGate.registerCaptureAttempt())
        coordinator.schedulePossibleEndIfNeeded()
        XCTAssertNotNil(coordinator.possibleEndTask)

        XCTAssertTrue(coordinator.cancelPossibleEnd())
        let resetTask = try XCTUnwrap(coordinator.possibleEndResetTask)
        XCTAssertFalse(coordinator.cancelPossibleEnd())
        XCTAssertNotNil(coordinator.possibleEndResetTask)

        await resetTask.value
        let snapshot = await session.status()
        XCTAssertEqual(snapshot.state, .capturing)
        try await session.cancel(confirm: true)
    }

    func testPossibleEndMutationRejectsStaleSessionID() async throws {
        let session = ScrollingScreenshotSessionCoordinator(rootDirectory: temporaryRoot())
        let firstSessionID = try await session.begin(sessionID: "first-possible-end")
        _ = await session.setPossibleEnd(true, expectedSessionID: firstSessionID)
        try await session.cancel(confirm: true)

        let secondSessionID = try await session.begin(sessionID: "second-possible-end")
        _ = await session.setPossibleEnd(true, expectedSessionID: secondSessionID)
        let staleReset = await session.setPossibleEnd(false, expectedSessionID: firstSessionID)

        XCTAssertEqual(staleReset.state, .possibleEnd)
        try await session.cancel(confirm: true)
    }

    @MainActor
    func testTerminalGateUsesFirstTerminalAndMakesOldSessionStructuredStale() throws {
        var gate = ScrollingScreenshotTerminalGate()
        let firstGeneration = try gate.begin(sessionID: "first")

        XCTAssertEqual(
            gate.claim(sessionID: "first", generation: firstGeneration, terminal: .cancelled),
            .accepted
        )
        XCTAssertEqual(
            gate.claim(sessionID: "first", generation: firstGeneration, terminal: .completed),
            .alreadyTerminal
        )

        let secondGeneration = try gate.begin(sessionID: "second")
        XCTAssertFalse(gate.acceptsCallback(generation: firstGeneration))
        XCTAssertTrue(gate.acceptsCallback(generation: secondGeneration))
        XCTAssertEqual(gate.controlFailure(for: "first"), .staleSession)
        XCTAssertEqual(gate.controlFailure(for: "first")?.code, "stale_session")
        XCTAssertNil(gate.controlFailure(for: "second"))
    }

    func testVisionAlignerProducesConsensusForTranslatedViewport() throws {
        let previous = makeImage(rows: Array(0..<180), width: 192)
        let incoming = makeImage(rows: Array(24..<204), width: 192)

        let hint = try XCTUnwrap(
            ScrollingScreenshotVisionAligner().alignmentHint(
                previous: previous,
                incoming: incoming
            )
        )

        XCTAssertTrue(hint.hasConsensus)
        XCTAssertGreaterThanOrEqual(hint.agreeingRegions, 2)
        XCTAssertLessThanOrEqual(abs(hint.scrollRows - 24), 2)
    }

    func testVisionAlignerRejectsReverseViewportMovement() {
        let previous = makeImage(rows: Array(24..<204), width: 192)
        let incoming = makeImage(rows: Array(0..<180), width: 192)

        XCTAssertNil(
            ScrollingScreenshotVisionAligner().alignmentHint(
                previous: previous,
                incoming: incoming
            )
        )
    }

    @MainActor
    func testScrollingHUDAnnouncementSchedulerCancelsSupersededABAText() async {
        let recorder = ScrollingHUDAnnouncementRecorder()
        let scheduler = ScrollingScreenshotHUDAnnouncementScheduler(announce: recorder.record)
        let current = ScrollingHUDAnnouncementCurrentState()
        let firstPanel = NSObject()
        let first = hudAnnouncementPresentation(warning: "A")
        let second = hudAnnouncementPresentation(warning: "B")

        current.panel = firstPanel
        current.text = first.announcementText
        scheduler.schedule(presentation: first) {
            current.matches(panel: firstPanel, text: first.announcementText)
        }
        await scheduler.waitUntilIdleForTesting()

        XCTAssertEqual(recorder.messages, [first.announcementText])

        current.text = second.announcementText
        scheduler.schedule(presentation: second) {
            current.matches(panel: firstPanel, text: second.announcementText)
        }
        current.text = first.announcementText
        scheduler.schedule(presentation: first) {
            current.matches(panel: firstPanel, text: first.announcementText)
        }

        await scheduler.waitUntilIdleForTesting()

        XCTAssertEqual(recorder.messages, [first.announcementText])
    }

    @MainActor
    func testScrollingHUDAnnouncementSchedulerUsesMediumForCapturingAndHighForWarnings() async {
        let recorder = ScrollingHUDAnnouncementRecorder()
        let scheduler = ScrollingScreenshotHUDAnnouncementScheduler(announce: recorder.record)
        let current = ScrollingHUDAnnouncementCurrentState()
        let panel = NSObject()
        let capturing = ScrollingScreenshotHUDPresentation(state: .init(phase: .capturing))
        let warning = hudAnnouncementPresentation(warning: "capture warning")

        current.panel = panel
        current.text = capturing.announcementText
        scheduler.schedule(presentation: capturing) {
            current.matches(panel: panel, text: capturing.announcementText)
        }
        await scheduler.waitUntilIdleForTesting()

        current.text = warning.announcementText
        scheduler.schedule(presentation: warning) {
            current.matches(panel: panel, text: warning.announcementText)
        }
        await scheduler.waitUntilIdleForTesting()

        XCTAssertEqual(recorder.messages, [capturing.announcementText, warning.announcementText])
        XCTAssertEqual(recorder.priorities, [.medium, .high])
    }

    @MainActor
    func testScrollingHUDAnnouncementSchedulerCancelsOnDismissAndResetsForNewPanel() async {
        let recorder = ScrollingHUDAnnouncementRecorder()
        let scheduler = ScrollingScreenshotHUDAnnouncementScheduler(announce: recorder.record)
        let current = ScrollingHUDAnnouncementCurrentState()
        let presentation = hudAnnouncementPresentation(warning: "same text")
        let dismissedPanel = NSObject()

        current.panel = dismissedPanel
        current.text = presentation.announcementText
        scheduler.schedule(presentation: presentation) {
            current.matches(panel: dismissedPanel, text: presentation.announcementText)
        }
        scheduler.reset()
        current.panel = nil

        XCTAssertTrue(recorder.messages.isEmpty)

        let newPanel = NSObject()
        current.panel = newPanel
        current.text = presentation.announcementText
        scheduler.schedule(presentation: presentation) {
            current.matches(panel: newPanel, text: presentation.announcementText)
        }

        await scheduler.waitUntilIdleForTesting()

        XCTAssertEqual(recorder.messages, [presentation.announcementText])
    }

    @MainActor
    func testScrollingHUDAnnouncementSchedulerCoalescesFrequentDimensionChanges() async {
        let recorder = ScrollingHUDAnnouncementRecorder()
        let scheduler = ScrollingScreenshotHUDAnnouncementScheduler(announce: recorder.record)
        let current = ScrollingHUDAnnouncementCurrentState()
        let panel = NSObject()
        current.panel = panel

        for dimension in 1...20 {
            let presentation = ScrollingScreenshotHUDPresentation(state: .init(
                phase: .capturing,
                accumulatedWidth: dimension,
                accumulatedHeight: dimension
            ))
            current.text = presentation.announcementText
            scheduler.schedule(presentation: presentation) {
                current.matches(panel: panel, text: presentation.announcementText)
            }
        }

        await scheduler.waitUntilIdleForTesting()

        let expected = ScrollingScreenshotHUDPresentation(state: .init(
            phase: .capturing,
            accumulatedWidth: 20,
            accumulatedHeight: 20
        )).announcementText
        XCTAssertEqual(recorder.messages, [expected])

        scheduler.schedule(presentation: .init(state: .init(
            phase: .capturing,
            accumulatedWidth: 21,
            accumulatedHeight: 21
        ))) {
            current.matches(panel: panel, text: expected)
        }
        await scheduler.waitUntilIdleForTesting()

        XCTAssertEqual(recorder.messages, [expected])
    }

    @MainActor
    func testScrollingHUDAnnouncementSchedulerOnlyDeliversFinalSuccessfulResumeStateAndKeepsFailureHighPriority() async {
        let recorder = ScrollingHUDAnnouncementRecorder()
        let scheduler = ScrollingScreenshotHUDAnnouncementScheduler(announce: recorder.record)
        let current = ScrollingHUDAnnouncementCurrentState()
        let panel = NSObject()
        let checking = ScrollingScreenshotHUDPresentation(state: .init(
            phase: .paused,
            isCheckingResume: true
        ))
        let resumed = ScrollingScreenshotHUDPresentation(state: .init(phase: .capturing))
        let failed = ScrollingScreenshotHUDPresentation(state: .init(
            phase: .paused,
            warning: "resume failed"
        ))

        current.panel = panel
        current.text = checking.announcementText
        scheduler.schedule(presentation: checking) {
            current.matches(panel: panel, text: checking.announcementText)
        }
        current.text = resumed.announcementText
        scheduler.schedule(presentation: resumed) {
            current.matches(panel: panel, text: resumed.announcementText)
        }

        await scheduler.waitUntilIdleForTesting()

        XCTAssertEqual(recorder.messages, [resumed.announcementText])
        XCTAssertEqual(recorder.priorities, [.medium])

        current.text = failed.announcementText
        scheduler.schedule(presentation: failed) {
            current.matches(panel: panel, text: failed.announcementText)
        }
        await scheduler.waitUntilIdleForTesting()

        XCTAssertEqual(recorder.messages, [resumed.announcementText, failed.announcementText])
        XCTAssertEqual(recorder.priorities, [.medium, .high])
    }

    func testScrollingHUDResumeCheckDisablesRestartWhilePausedDoesNot() {
        let checkingResume = ScrollingScreenshotHUDPresentation(state: .init(
            phase: .paused,
            isCheckingResume: true
        ))
        let paused = ScrollingScreenshotHUDPresentation(state: .init(phase: .paused))

        XCTAssertTrue(checkingResume.disabledCommands.contains(.resume))
        XCTAssertTrue(checkingResume.disabledCommands.contains(.restart))
        XCTAssertTrue(checkingResume.disabledCommands.contains(.finish))
        XCTAssertFalse(paused.disabledCommands.contains(.restart))
    }

    @MainActor
    func testScrollingHUDAndSelectionPanelsDoNotRequireApplicationActivation() {
        XCTAssertFalse(ScrollingScreenshotHUDController.requiresApplicationActivation)
        XCTAssertFalse(ScreenshotSelectionPanel(contentRect: .zero).canBecomeMain)
    }

    private var exactAssembler: ScrollingScreenshotAssembler {
        ScrollingScreenshotAssembler(matcher: ScrollingScreenshotMatcher(configuration: .init(
            minimumOverlapRows: 3,
            minimumFixedHeaderRows: 2,
            maximumFixedHeaderRows: 3,
            minimumFixedFooterRows: 2,
            maximumFixedFooterRows: 3,
            coarseCandidateCount: 16,
            horizontalSearchRadius: 0,
            minimumBlockSimilarity: 0.99,
            minimumMatchScore: 0.95,
            minimumMatchedBlockRatio: 0.75,
            ambiguityScoreTolerance: 0
        )))
    }

    private func hudAnnouncementPresentation(
        warning: String
    ) -> ScrollingScreenshotHUDPresentation {
        ScrollingScreenshotHUDPresentation(state: .init(
            phase: .capturing,
            warning: warning
        ))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrollingScreenshotAppTests.\(UUID().uuidString)", isDirectory: true)
    }

    private func capturedFrame(rows: [Int], width: Int = 64) -> ScrollingCapturedFrame {
        let image = makeImage(rows: rows, width: width)
        return ScrollingCapturedFrame(
            image: image,
            timestamp: .zero,
            contentRect: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func browserFixtureImage(_ suffix: String) throws -> CGImage {
        try browserFixtureImage(named: "frame-\(suffix).png")
    }

    private func browserFixtureImage(named fileName: String) throws -> CGImage {
        let file = URL(fileURLWithPath: fileName)
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(
                forResource: file.deletingPathExtension().lastPathComponent,
                withExtension: file.pathExtension,
                subdirectory: "Fixtures/Scrolling"
            )
        )
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil),
            "Missing browser fixture at \(url.path)"
        )
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func browserFixtureManifest() throws -> BrowserScrollFixtureManifest {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(
                forResource: "manifest",
                withExtension: "json",
                subdirectory: "Fixtures/Scrolling"
            )
        )
        return try JSONDecoder().decode(
            BrowserScrollFixtureManifest.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func assertSampledRegionEqual(
        source: [UInt8],
        sourceWidth: Int,
        sourceOriginY: Int,
        destination: [UInt8],
        destinationWidth: Int,
        destinationOriginY: Int,
        height: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for y in stride(from: 4, to: height - 4, by: 37) {
            for x in stride(from: 4, to: min(sourceWidth, destinationWidth) - 4, by: 53) {
                let sourceOffset = ((sourceOriginY + y) * sourceWidth + x) * 4
                let destinationOffset = ((destinationOriginY + y) * destinationWidth + x) * 4
                XCTAssertEqual(
                    Array(source[sourceOffset..<(sourceOffset + 4)]),
                    Array(destination[destinationOffset..<(destinationOffset + 4)]),
                    "Pixel mismatch at x=\(x), sourceY=\(sourceOriginY + y), destinationY=\(destinationOriginY + y)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertPixelRegionEqual(
        source: CGImage,
        destination: CGImage,
        rect: BrowserScrollFixtureManifest.PixelRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sourceBytes = rgbaBytes(source)
        let destinationBytes = rgbaBytes(destination)
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) {
                let sourceOffset = (y * source.width + x) * 4
                let destinationOffset = (y * destination.width + x) * 4
                for component in 0..<4 where sourceBytes[sourceOffset + component]
                    != destinationBytes[destinationOffset + component] {
                    XCTFail(
                        "Pixel mismatch at x=\(x), y=\(y), component=\(component): "
                            + "expected \(sourceBytes[sourceOffset + component]), "
                            + "got \(destinationBytes[destinationOffset + component])",
                        file: file,
                        line: line
                    )
                    return
                }
            }
        }
    }

    private func makeImage(rows: [Int], width: Int = 64) -> CGImage {
        let height = rows.count
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for (y, identifier) in rows.enumerated() {
            var pattern = UInt64(truncatingIfNeeded: identifier &* 1_103_515_245 &+ 12_345)
            pattern ^= pattern << 13
            pattern ^= pattern >> 7
            pattern ^= pattern << 17
            pattern |= 1
            for sample in 0..<64 where (pattern & (UInt64(1) << UInt64(sample))) != 0 {
                let lowerX = sample * width / 64
                let upperX = max(lowerX + 1, (sample + 1) * width / 64)
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: lowerX, y: y, width: upperX - lowerX, height: 1))
            }
        }
        return context.makeImage()!
    }

    private func topLeftGrayPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func decodedRowIdentifiers(_ image: CGImage, candidates: [Int]) -> [Int] {
        let actualPixels = topLeftGrayPixels(image)
        var candidateRows: [UInt64: Int] = [:]
        candidates.forEach { identifier in
            let pixels = topLeftGrayPixels(makeImage(rows: [identifier]))
            candidateRows[rowFingerprint(pixels)] = identifier
        }
        return (0..<image.height).map { row in
            let start = row * image.width
            let pixels = Array(actualPixels[start..<(start + image.width)])
            return candidateRows[rowFingerprint(pixels)] ?? -1
        }
    }

    private func rowFingerprint(_ pixels: [UInt8]) -> UInt64 {
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return pixels.enumerated().reduce(UInt64.zero) { value, item in
            item.element >= average ? value | (UInt64(1) << UInt64(item.offset)) : value
        }
    }
}

@MainActor
private final class ScrollingHUDAnnouncementRecorder {
    private struct Announcement {
        let message: String
        let priority: NSAccessibilityPriorityLevel
    }

    private var announcements: [Announcement] = []

    var messages: [String] {
        announcements.map(\.message)
    }

    var priorities: [NSAccessibilityPriorityLevel] {
        announcements.map(\.priority)
    }

    func record(_ message: String, priority: NSAccessibilityPriorityLevel) {
        announcements.append(.init(message: message, priority: priority))
    }
}

@MainActor
private final class ScrollingHUDAnnouncementCurrentState {
    var panel: NSObject?
    var text = ""

    func matches(panel: NSObject, text: String) -> Bool {
        self.panel === panel && self.text == text
    }
}

@MainActor
private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the scrolling screenshot test condition.", file: file, line: line)
}

@MainActor
private func waitUntilAsync(
    _ predicate: @escaping @MainActor () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the scrolling screenshot async condition.", file: file, line: line)
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var currentValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private actor OperationReturnGate {
    private struct ArrivalWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let blockedOccurrences: [ScrollingScreenshotSessionCoordinator.OperationReturnBoundary: Int]
    private var arrivals: [ScrollingScreenshotSessionCoordinator.OperationReturnBoundary: Int] = [:]
    private var arrivalWaiters: [
        ScrollingScreenshotSessionCoordinator.OperationReturnBoundary: [ArrivalWaiter]
    ] = [:]
    private var releaseWaiters: [
        ScrollingScreenshotSessionCoordinator.OperationReturnBoundary: [CheckedContinuation<Void, Never>]
    ] = [:]

    init(
        blockedOccurrences: [ScrollingScreenshotSessionCoordinator.OperationReturnBoundary: Int]
    ) {
        self.blockedOccurrences = blockedOccurrences
    }

    func suspendIfNeeded(_ operation: ScrollingScreenshotSessionCoordinator.OperationReturnBoundary) async {
        let arrival = arrivals[operation, default: 0] + 1
        arrivals[operation] = arrival
        let waiters = arrivalWaiters[operation, default: []]
        let ready = waiters.filter { $0.count <= arrival }
        arrivalWaiters[operation] = waiters.filter { $0.count > arrival }
        ready.forEach { $0.continuation.resume(returning: true) }
        guard arrival <= blockedOccurrences[operation, default: 0] else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[operation, default: []].append(continuation)
        }
    }

    func waitForArrival(
        of operation: ScrollingScreenshotSessionCoordinator.OperationReturnBoundary,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        guard arrivals[operation, default: 0] < count else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                arrivalWaiters[operation, default: []].append(ArrivalWaiter(
                    id: id,
                    count: count,
                    continuation: continuation
                ))
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.resolveArrivalWaiter(
                        id: id,
                        operation: operation,
                        result: false
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolveArrivalWaiter(
                    id: id,
                    operation: operation,
                    result: false
                )
            }
        }
    }

    private func resolveArrivalWaiter(
        id: UUID,
        operation: ScrollingScreenshotSessionCoordinator.OperationReturnBoundary,
        result: Bool
    ) {
        guard let index = arrivalWaiters[operation, default: []].firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = arrivalWaiters[operation]!.remove(at: index)
        waiter.continuation.resume(returning: result)
    }

    func release(_ operation: ScrollingScreenshotSessionCoordinator.OperationReturnBoundary) {
        guard !releaseWaiters[operation, default: []].isEmpty else { return }
        releaseWaiters[operation]?.removeFirst().resume()
    }

    func releaseAll() {
        let waiters = releaseWaiters.values.flatMap { $0 }
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ScrollingFrameCallbackGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}

private actor FirstFrameWatchdogGate {
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var queuedReleases = 0

    var waiterCount: Int {
        waiters.count
    }

    func wait() async -> Bool {
        guard queuedReleases == 0 else {
            queuedReleases -= 1
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForWaiterCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while waiters.count < count {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func releaseNext() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: true)
        } else {
            queuedReleases += 1
        }
    }
}

@MainActor
private final class BlockingStartScrollingFrameSource:
    ScrollingScreenshotFrameSourcing
{
    private enum StartError: Error {
        case lateFailure
    }

    private var firstStartCompletion: CheckedContinuation<Void, Never>?
    private var firstStartCompletionRequested = false
    private var firstStartCompleted = false
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var requests: [(generation: UInt64, requestID: UInt64)] = []
    private(set) var stoppedGenerations: [UInt64] = []

    func start(
        generation _: UInt64,
        displayID _: UInt32,
        displayFrame _: CGRect,
        selectionRect _: CGRect,
        scale _: CGFloat,
        onFrame _: @escaping @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void,
        onFailure _: @escaping @Sendable (UInt64, Error) async -> Void
    ) async throws {
        startCallCount += 1
        guard startCallCount == 1 else { return }
        await withCheckedContinuation { continuation in
            if firstStartCompletionRequested {
                continuation.resume()
            } else {
                firstStartCompletion = continuation
            }
        }
        firstStartCompleted = true
        throw StartError.lateFailure
    }

    func requestFrame(generation: UInt64, requestID: UInt64) {
        requests.append((generation, requestID))
    }

    func cancelFrameRequests(generation _: UInt64, requestIDs _: Set<UInt64>) {}

    func stop(generation: UInt64) async {
        stopCallCount += 1
        stoppedGenerations.append(generation)
    }

    func completeFirstStart() {
        firstStartCompletionRequested = true
        let completion = firstStartCompletion
        firstStartCompletion = nil
        completion?.resume()
    }

    func waitForStartCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForCount(
            { self.startCallCount },
            atLeast: count,
            timeout: timeout
        )
    }

    func waitForStopCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForCount(
            { self.stopCallCount },
            atLeast: count,
            timeout: timeout
        )
    }

    func waitForFirstStartCompletion(
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForCount(
            { self.firstStartCompleted ? 1 : 0 },
            atLeast: 1,
            timeout: timeout
        )
    }

    func waitForRequestCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForCount(
            { self.requests.count },
            atLeast: count,
            timeout: timeout
        )
    }

    private func waitForCount(
        _ value: @escaping @MainActor () -> Int,
        atLeast count: Int,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while value() < count {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
private final class FirstFrameWatchdogSchedulingProbe {
    typealias Outcome = ScrollingScreenshotCaptureCoordinator.FirstFrameWatchdogSchedulingOutcome

    private var outcomes: [Outcome] = []

    func record(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    func nextOutcome(timeout: Duration = .seconds(2)) async -> Outcome? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while outcomes.isEmpty {
            guard clock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return outcomes.removeFirst()
    }
}

@MainActor
private final class HangingStopScrollingFrameSource: ScrollingScreenshotFrameSourcing {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var onFrames: [UInt64: @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void] = [:]
    private var stopContinuations: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    func start(
        generation: UInt64,
        displayID _: UInt32,
        displayFrame _: CGRect,
        selectionRect _: CGRect,
        scale _: CGFloat,
        onFrame: @escaping @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void,
        onFailure _: @escaping @Sendable (UInt64, Error) async -> Void
    ) async throws {
        startCallCount += 1
        onFrames[generation] = onFrame
    }

    func requestFrame(generation _: UInt64, requestID _: UInt64) {}

    func cancelFrameRequests(generation _: UInt64, requestIDs _: Set<UInt64>) {}

    func stop(generation: UInt64) async {
        stopCallCount += 1
        await withCheckedContinuation { continuation in
            stopContinuations[generation, default: []].append(continuation)
        }
    }

    func deliver(generation: UInt64, requestID: UInt64, frame: ScrollingCapturedFrame) async {
        guard let onFrame = onFrames[generation] else {
            XCTFail("Frame delivery requires the matching source generation to start first.")
            return
        }
        await onFrame(generation, requestID, frame)
    }

    func waitForStartCount(
        _ count: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        await waitForCount(timeout: timeout) { self.startCallCount >= count }
    }

    func waitForStopCount(
        _ count: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        await waitForCount(timeout: timeout) { self.stopCallCount >= count }
    }

    func releaseStop(generation: UInt64) {
        guard var continuations = stopContinuations[generation],
              !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        stopContinuations[generation] = continuations
        continuation.resume()
    }

    func releaseAllStops() {
        let continuations = stopContinuations.values.flatMap { $0 }
        stopContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func waitForCount(
        timeout: Duration,
        predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !predicate() {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return true
    }
}

@MainActor
private final class RecordingScrollingFrameSource: ScrollingScreenshotFrameSourcing {
    private let firstFrameBeforeStartReturns: ScrollingCapturedFrame?
    private(set) var cancelledRequestIDs: Set<UInt64> = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var requests: [(generation: UInt64, requestID: UInt64)] = []
    private var onFrame: (@Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(firstFrameBeforeStartReturns: ScrollingCapturedFrame? = nil) {
        self.firstFrameBeforeStartReturns = firstFrameBeforeStartReturns
    }

    func start(
        generation: UInt64,
        displayID: UInt32,
        displayFrame: CGRect,
        selectionRect: CGRect,
        scale: CGFloat,
        onFrame: @escaping @Sendable (UInt64, UInt64, ScrollingCapturedFrame) async -> Void,
        onFailure: @escaping @Sendable (UInt64, Error) async -> Void
    ) async throws {
        startCallCount += 1
        self.onFrame = onFrame
        if let firstFrameBeforeStartReturns {
            await onFrame(generation, 0, firstFrameBeforeStartReturns)
        }
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let ready = startCountWaiters.filter { $0.count <= startCallCount }
        startCountWaiters.removeAll { $0.count <= startCallCount }
        ready.forEach { $0.continuation.resume() }
    }

    func requestFrame(generation: UInt64, requestID: UInt64) {
        requests.append((generation, requestID))
        let ready = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForStart(timeout: Duration = .seconds(2)) async -> Bool {
        await waitForCount(
            { self.startCallCount },
            atLeast: 1,
            timeout: timeout
        )
    }

    func waitForStartCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForCount(
            { self.startCallCount },
            atLeast: count,
            timeout: timeout
        )
    }

    func waitForRequestCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForCount(
            { self.requests.count },
            atLeast: count,
            timeout: timeout
        )
    }

    func deliver(generation: UInt64, requestID: UInt64, frame: ScrollingCapturedFrame) async {
        guard let onFrame else {
            XCTFail("Frame delivery requires the source to have started first.")
            return
        }
        await onFrame(generation, requestID, frame)
    }

    func cancelFrameRequests(generation: UInt64, requestIDs: Set<UInt64>) {
        cancelledRequestIDs.formUnion(requestIDs)
    }

    func waitForStopCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForCount(
            { self.stopCallCount },
            atLeast: count,
            timeout: timeout
        )
    }

    func stop(generation: UInt64) async {
        stopCallCount += 1
        let ready = stopWaiters.filter { $0.count <= stopCallCount }
        stopWaiters.removeAll { $0.count <= stopCallCount }
        ready.forEach { $0.continuation.resume() }
    }

    private func waitForCount(
        _ value: @escaping @MainActor () -> Int,
        atLeast count: Int,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while value() < count {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
