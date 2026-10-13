import AppKit
import ApplicationServices
import BlocksCore
import XCTest
@testable import Blocks

@MainActor
final class ClipboardPasteWindowRoutingTests: XCTestCase {
    private let editorBounds = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func window(_ id: Int, pid: Int32 = 92, bounds: CGRect) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1,
         kCGWindowBounds as String: ["X": bounds.minX, "Y": bounds.minY,
                                    "Width": bounds.width, "Height": bounds.height]]
    }

    func testFocusedWindowRemainsStableWhenSameProcessAuxiliaryWindowIsReplaced() {
        let editor = window(106, bounds: editorBounds)
        for auxiliaryID in [770, 1219] {
            let windows = [window(auxiliaryID, bounds: CGRect(x: 140, y: 130, width: 180, height: 50)), editor]
            XCTAssertEqual(ClipboardPasteTargetEligibility.frontmostVisibleWindowID(
                processIdentifier: 92, windowInfo: windows, focusedWindowBounds: editorBounds), 106)
        }
    }

    func testFocusOnSmallerRealWindowIsNotReplacedByLargestWindow() {
        let small = CGRect(x: 150, y: 150, width: 350, height: 250)
        let windows = [window(1, bounds: editorBounds), window(2, bounds: small)]
        XCTAssertEqual(ClipboardPasteTargetEligibility.frontmostVisibleWindowID(
            processIdentifier: 92, windowInfo: windows, focusedWindowBounds: small), 2)
    }

    func testAmbiguousOrMissingFocusedWindowFailsClosed() {
        for windows in [[window(1, bounds: editorBounds), window(2, bounds: editorBounds)],
                        [window(1, pid: 93, bounds: editorBounds)], []] {
            XCTAssertNil(ClipboardPasteTargetEligibility.frontmostVisibleWindowID(
                processIdentifier: 92, windowInfo: windows, focusedWindowBounds: editorBounds))
        }
    }

    func testMissingAXPreservesIndependentWindowListRoute() {
        let small = CGRect(x: 140, y: 130, width: 180, height: 50)
        XCTAssertEqual(ClipboardPasteTargetEligibility.frontmostVisibleWindowID(
            processIdentifier: 92, windowInfo: [window(770, bounds: small), window(106, bounds: editorBounds)]), 770)
    }

    func testDiagnosticsNeverIncludeWindowTitleOrOtherProcessMetadata() {
        var target = window(106, bounds: editorBounds)
        target[kCGWindowName as String] = "private-title-must-not-appear"
        let summary = ClipboardPasteTargetEligibility.windowDiagnostics(
            processIdentifier: 92, windows: [target, window(999, pid: 93, bounds: editorBounds)])
        XCTAssertTrue(summary.contains("id=106"))
        XCTAssertFalse(summary.contains("private-title"))
        XCTAssertFalse(summary.contains("999"))
    }

    func testConfirmedSameWindowPostsExactlyOnceWithoutRewritingClipboard() async throws {
        let app = NSRunningApplication.current
        let snapshot = ClipboardPasteFocusSnapshot(target: ClipboardPasteTarget(app), windowID: 106,
                                                   usesFocusedWindowEvidence: true)
        let (result, posts, writes) = try await dispatch(captured: snapshot, current: snapshot)
        XCTAssertTrue(result.commandPosted)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(writes, 0)
    }

    func testWindowChangeAndLostEvidenceNeverPostAndHaveSpecificReasons() async throws {
        let app = NSRunningApplication.current
        let captured = ClipboardPasteFocusSnapshot(target: ClipboardPasteTarget(app), windowID: 106,
                                                   usesFocusedWindowEvidence: true)
        for (id, focused, expected) in [(107 as UInt32?, true, ClipboardPasteRoutingFailure.windowChanged),
                                       (106, false, .windowUnverifiable), (nil, true, .windowUnverifiable)] {
            let current = ClipboardPasteFocusSnapshot(target: ClipboardPasteTarget(app), windowID: id,
                                                       usesFocusedWindowEvidence: focused)
            do {
                _ = try await dispatch(captured: captured, current: current)
                XCTFail("A changed or unverified window must not receive a paste")
            } catch let failure as ClipboardAutoPastePartialFailure {
                XCTAssertEqual(failure.reason, .targetApplicationUnavailable)
                XCTAssertEqual(failure.routingFailure, expected)
                XCTAssertEqual(failure.pasteboardChangeCountAfterWrite, 10)
            }
        }
    }

    func testSwitchingAppDuringFinalWindowInspectionNeverPosts() async throws {
        try await assertMutationDuringFinalInspectionRejects(changesPasteboard: false)
    }

    func testOverwritingClipboardDuringFinalWindowInspectionNeverPosts() async throws {
        try await assertMutationDuringFinalInspectionRejects(changesPasteboard: true)
    }

    func testSameAppWindowChangeDuringFinalBrokerValidationNeverPosts() async throws {
        let state = RoutingWindowState()
        let app = NSRunningApplication.current
        let broker = RoutingValidationBroker { await MainActor.run { state.windowID = 107 } }
        var posts = 0
        let coordinator = ClipboardAutoPasteCoordinator(
            broker: broker, frontmostApplication: { app },
            focusSnapshot: { _ in .init(target: ClipboardPasteTarget(app), windowID: state.windowID) },
            eventPostingAccess: { _ in true }, optionalTargetInspection: { _ in .unknown },
            pasteShortcutPoster: { _ in posts += 1 })
        do {
            _ = try await coordinator.dispatchPaste(
                targetContext: .init(target: ClipboardPasteTarget(app), windowID: 106),
                pasteboardLease: .init(changeCount: 10), promptForAccessibility: false)
            XCTFail("An async lease check must not authorize a different window in the same app")
        } catch let failure as ClipboardAutoPastePartialFailure {
            XCTAssertEqual(failure.routingFailure, .windowChanged)
        }
        XCTAssertEqual(posts, 0)
    }

    private func assertMutationDuringFinalInspectionRejects(changesPasteboard: Bool) async throws {
        let app = NSRunningApplication.current
        let snapshot = ClipboardPasteFocusSnapshot(target: ClipboardPasteTarget(app), windowID: 106)
        var frontmost: NSRunningApplication? = app
        var inspections = 0
        var posts = 0
        let pasteboard = RoutingPasteboard()
        let coordinator = ClipboardAutoPasteCoordinator(
            pasteboard: pasteboard, frontmostApplication: { frontmost },
            focusSnapshot: { _ in
                inspections += 1
                if inspections == 2 {
                    if changesPasteboard { pasteboard.changeCount += 1 } else { frontmost = nil }
                }
                return snapshot
            }, eventPostingAccess: { _ in true }, optionalTargetInspection: { _ in .unknown },
            pasteShortcutPoster: { _ in posts += 1 })
        do {
            _ = try await coordinator.dispatchPaste(targetContext: snapshot,
                pasteboardLease: .init(changeCount: 10), promptForAccessibility: false)
            XCTFail("Inspection must not preserve a decision invalidated while it waited")
        } catch let failure as ClipboardAutoPastePartialFailure {
            XCTAssertEqual(failure.reason, changesPasteboard ? .pasteboardChanged : .targetApplicationNotFrontmost)
        }
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.writes, 0)
    }

    private func dispatch(captured: ClipboardPasteFocusSnapshot, current: ClipboardPasteFocusSnapshot)
        async throws -> (ClipboardAutoPasteCoordinator.PasteResult, Int, Int) {
        let pasteboard = RoutingPasteboard()
        var posts = 0
        let coordinator = ClipboardAutoPasteCoordinator(
            pasteboard: pasteboard, frontmostApplication: { NSRunningApplication.current },
            focusSnapshot: { _ in current }, eventPostingAccess: { _ in true },
            optionalTargetInspection: { _ in .unknown }, pasteShortcutPoster: { _ in posts += 1 })
        do {
            let result = try await coordinator.dispatchPaste(targetContext: captured,
                pasteboardLease: .init(changeCount: 10), promptForAccessibility: false)
            return (result, posts, pasteboard.writes)
        } catch {
            XCTAssertEqual(posts, 0)
            XCTAssertEqual(pasteboard.writes, 0)
            throw error
        }
    }
}

@MainActor
private final class RoutingPasteboard: ClipboardPasteboardWriting {
    var changeCount = 10
    var writes = 0
    func writeItems(_ items: [ClipboardPasteboardWriteItem]) -> Bool {
        writes += 1
        changeCount += 1
        return true
    }
}

@MainActor
private final class RoutingWindowState {
    var windowID: CGWindowID = 106
}

private actor RoutingValidationBroker: ClipboardBrokerServing {
    let onFinalValidation: @Sendable () async -> Void
    var validations = 0
    init(onFinalValidation: @escaping @Sendable () async -> Void) {
        self.onFinalValidation = onFinalValidation
    }
    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        validations += 1
        if validations == 3 { await onFinalValidation() }
        return true
    }
    func baseline() async throws -> Int { 10 }
    func observe(_ request: ClipboardBrokerObserveRequest) async throws -> ClipboardBrokerObservationResult {
        throw ClipboardBrokerClientError.malformedResponse
    }
    func write(_ request: ClipboardBrokerWriteRequest) async throws -> ClipboardPasteboardWriteLease {
        throw ClipboardBrokerClientError.malformedResponse
    }
    func currentPlainText(limit: Int) async throws -> ClipboardBrokerPlainTextResult {
        throw ClipboardBrokerClientError.malformedResponse
    }
    func shutdown() async {}
}
