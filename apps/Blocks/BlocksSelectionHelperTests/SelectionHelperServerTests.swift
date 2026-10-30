import ApplicationServices
import CryptoKit
import Foundation
import Security
import XCTest

#if DEBUG
@_spi(Testing) @testable import Blocks_Selection_Helper
#else
@_spi(Testing) import Blocks_Selection_Helper
#endif

@MainActor
final class SelectionHelperServerTests: XCTestCase {
    func testHostedTestDetectionRecognizesXCTestSignalsInDebugStylePolicy() {
        XCTAssertTrue(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: [
                    "XCTestConfigurationFilePath":
                        "/tmp/helper.xctestconfiguration",
                ],
                allowsXCTestMarkers: true,
                allowsDebugOverride: false
            )
        )
        XCTAssertTrue(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: ["XCTestBundlePath": "/tmp/HelperTests.xctest"],
                allowsXCTestMarkers: true,
                allowsDebugOverride: false
            )
        )
        XCTAssertTrue(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: ["XCInjectBundleInto": "/tmp/Helper"],
                allowsXCTestMarkers: true,
                allowsDebugOverride: false
            )
        )
        XCTAssertFalse(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: [:],
                allowsDebugOverride: false
            )
        )
        XCTAssertFalse(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: [:],
                allowsDebugOverride: true
            )
        )
        XCTAssertFalse(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: ["BLOCKS_UNIT_TESTING": "1"],
                allowsDebugOverride: false
            )
        )
    }

    func testHostedTestDetectionIgnoresAllSignalsInReleaseStylePolicy() {
        XCTAssertFalse(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: [
                    "XCTestConfigurationFilePath":
                        "/tmp/helper.xctestconfiguration",
                    "XCTestBundlePath": "/tmp/HelperTests.xctest",
                    "XCInjectBundleInto": "/tmp/Helper",
                    "BLOCKS_UNIT_TESTING": "1",
                ],
                allowsXCTestMarkers: false,
                allowsDebugOverride: false
            )
        )
    }

    #if DEBUG
    private let bootstrapKey = Data(repeating: 0x42, count: 32)
    private let pairingCode = "123456"
    private let testAccessGroup = "TEAMID.app.blocks.shared"

    func testCaptureTimeoutScopeConfiguresSystemWideBeforeAXAndRestoresAfterReturn() {
        let now = Date(timeIntervalSince1970: 100)
        var events: [String] = []
        var configuredTimeouts: [Float] = []
        let output = SelectionHelperAXMessagingTimeoutPolicy.withProcessWideTimeout(
            systemWideElement: "system-wide timeout handle",
            deadline: now.addingTimeInterval(10), now: now,
            setTimeout: { handle, timeout in
                XCTAssertEqual(handle, "system-wide timeout handle")
                events.append("timeout")
                configuredTimeouts.append(timeout)
            },
            operation: {
                events.append("capture descendants")
                return "completed"
            }
        )

        XCTAssertEqual(output, "completed")
        XCTAssertEqual(events, ["timeout", "capture descendants", "timeout"])
        XCTAssertEqual(configuredTimeouts, [0.1, 0])
    }

    func testCaptureTimeoutScopeRestoresProcessDefaultWhenCaptureThrows() {
        enum CaptureFailure: Error { case interrupted }
        var configuredTimeouts: [Float] = []
        XCTAssertThrowsError(try SelectionHelperAXMessagingTimeoutPolicy.withProcessWideTimeout(
            systemWideElement: "system-wide timeout handle",
            deadline: Date().addingTimeInterval(10),
            setTimeout: { _, timeout in configuredTimeouts.append(timeout) },
            operation: { () throws -> Void in throw CaptureFailure.interrupted }
        ))
        XCTAssertEqual(configuredTimeouts, [0.1, 0])
    }

    func testCaptureTimeoutPolicyRetainsShortProcessWideCeilingAndRemainingBudget() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(SelectionHelperAXMessagingTimeoutPolicy.timeout(
            deadline: now.addingTimeInterval(10), now: now
        ), 0.1)
        XCTAssertEqual(SelectionHelperAXMessagingTimeoutPolicy.timeout(
            deadline: now.addingTimeInterval(0.08), now: now
        ), 0.08, accuracy: 0.0001)
        XCTAssertEqual(SelectionHelperAXMessagingTimeoutPolicy.timeout(
            deadline: now.addingTimeInterval(0.01), now: now
        ), 0.05)
    }

    func testSelectionTextResolverUsesCurrentRangeForNilEmptyAndWhitespaceDirectText() {
        for direct in [nil, "", " \n\t"] as [String?] {
            let reads = SelectionTextReadFixture()
            reads.direct = direct
            reads.ranges = [NSRange(location: 7, length: 5)]
            reads.rangeText = "fresh"

            XCTAssertEqual(reads.resolve(), .selected(.init(
                text: "fresh", source: .range,
                range: NSRange(location: 7, length: 5), marker: nil
            )))
            XCTAssertEqual(reads.calls, ["direct", "range", "rangeText", "range"])
        }
    }

    func testSelectionTextResolverContinuesFromEmptyRangeTextToCurrentMarker() {
        let reads = SelectionTextReadFixture()
        reads.direct = ""
        reads.ranges = [NSRange(location: 2, length: 3)]
        reads.rangeText = " \n"
        reads.markers = [11]
        reads.markerLength = .known(6)
        reads.markerText = "marker"

        XCTAssertEqual(reads.resolve(), .selected(.init(
            text: "marker", source: .marker, range: nil, marker: 11
        )))
        XCTAssertEqual(reads.calls, [
            "direct", "range", "rangeText", "range", "marker",
            "markerLength", "markerText", "marker",
        ])
    }

    func testSelectionTextResolverSkipsCollapsedRangeAndMarkerWithoutReadingText() {
        let reads = SelectionTextReadFixture()
        reads.direct = ""
        reads.ranges = [NSRange(location: 12, length: 0)]
        reads.rangeText = "old range text"
        reads.markers = [11]
        reads.markerLength = .known(0)
        reads.markerText = "old marker text"

        XCTAssertEqual(reads.resolve(), .empty)
        XCTAssertEqual(reads.calls, ["direct", "range", "marker", "markerLength"])
    }

    func testSelectionTextResolverRefusesInvalidAndNegativeMarkerLength() {
        for length in [SelectionHelperMarkerLength.invalid, .known(-1)] {
            let reads = SelectionTextReadFixture()
            reads.markers = [11]
            reads.markerLength = length
            reads.markerText = "must not be read"

            XCTAssertEqual(reads.resolve(), .unavailable)
            XCTAssertFalse(reads.calls.contains("markerText"))
        }
    }

    func testMarkerLengthDecoderSeparatesUnsupportedOrMissingFromMalformedValues() {
        for status in [AXError.parameterizedAttributeUnsupported, .attributeUnsupported,
                       .notImplemented, .noValue] {
            XCTAssertEqual(SelectionHelperMarkerLength.decode(status: status, value: nil),
                           .unavailable)
        }
        XCTAssertEqual(SelectionHelperMarkerLength.decode(status: .success, value: nil),
                       .unavailable)
        XCTAssertEqual(SelectionHelperMarkerLength.decode(
            status: .success, value: NSNumber(value: 3)
        ), .known(3))
        XCTAssertEqual(SelectionHelperMarkerLength.decode(
            status: .success, value: NSNumber(value: 0)
        ), .known(0))
        let invalidValues: [CFTypeRef] = [
            NSNumber(value: -1), NSNumber(value: 1.5),
            "not a number" as CFString, NSNumber(value: true),
        ]
        for value in invalidValues {
            let length = SelectionHelperMarkerLength.decode(status: .success, value: value)
            XCTAssertEqual(length, .invalid)
            let reads = SelectionTextReadFixture()
            reads.markers = [11]
            reads.markerLength = length
            reads.markerText = "must not be read"
            XCTAssertEqual(reads.resolve(), .unavailable)
            XCTAssertFalse(reads.calls.contains("markerText"))
        }
        XCTAssertEqual(SelectionHelperMarkerLength.decode(status: .cannotComplete, value: nil),
                       .invalid)
    }

    func testSelectionTextResolverSupportsCurrentMarkerWhenLengthAttributeIsMissing() {
        let reads = SelectionTextReadFixture()
        reads.markers = [11]
        reads.markerLength = .unavailable
        reads.markerText = "string-only provider"

        XCTAssertEqual(reads.resolve(), .selected(.init(
            text: "string-only provider", source: .marker, range: nil, marker: 11
        )))
        XCTAssertEqual(reads.calls, ["direct", "range", "marker", "markerLength",
                                     "markerText", "marker"])
    }

    func testSelectionTextResolverTreatsWhitespaceFromMissingLengthMarkerAsEmpty() {
        let reads = SelectionTextReadFixture()
        reads.markers = [11]
        reads.markerLength = .unavailable
        reads.markerText = " \n\t"

        XCTAssertEqual(reads.resolve(), .empty)
        XCTAssertEqual(reads.calls.last, "marker")
    }

    func testSelectionTextResolverStillEnforcesBothLimitsWhenMarkerLengthIsMissing() {
        for (text, maximumCharacters, maximumBytes) in [
            ("large", 4, 20), ("😀", 4, 3),
        ] {
            let reads = SelectionTextReadFixture()
            reads.maximumCharacters = maximumCharacters
            reads.maximumUTF8Bytes = maximumBytes
            reads.markers = [11]
            reads.markerLength = .unavailable
            reads.markerText = text

            XCTAssertEqual(reads.resolve(), .failure(.selectionTooLarge))
            XCTAssertEqual(reads.calls.last, "markerText")
        }
    }

    func testSelectionTextResolverRejectsChangedMissingLengthMarker() {
        let reads = SelectionTextReadFixture()
        reads.markers = [11, 12]
        reads.markerLength = .unavailable
        reads.markerText = "stale"

        XCTAssertEqual(reads.resolve(), .unavailable)
        XCTAssertEqual(reads.trace.marker, .unstable)
    }

    func testSelectionTextResolverPreservesCancellationAndDeadlineForMissingMarkerLength() {
        for failure in [SelectionAgentFailureCode.cancelled, .timedOut] {
            for stage in ["markerLength", "markerText", "marker"] {
                let reads = SelectionTextReadFixture()
                reads.markers = [11]
                reads.markerLength = .unavailable
                reads.markerText = "current"
                reads.interruptAfterStage = stage
                reads.interruptAfterOccurrence = stage == "marker" ? 2 : 1
                reads.interruptWith = failure

                XCTAssertEqual(reads.resolve(), .failure(failure))
                XCTAssertEqual(reads.calls.last, stage)
            }
        }
    }

    func testSelectionTextResolverDoesNotFetchInvalidOrOverflowingRange() {
        for range in [NSRange(location: -1, length: 1),
                      NSRange(location: 0, length: -1),
                      NSRange(location: Int.max, length: 1)] {
            let reads = SelectionTextReadFixture()
            reads.ranges = [range]
            reads.rangeText = "must not be read"

            XCTAssertEqual(reads.resolve(), .unavailable)
            XCTAssertFalse(reads.calls.contains("rangeText"))
        }
    }

    func testSelectionTextResolverStopsWhenCurrentRangeChangesOrDisappears() {
        for current in [nil, NSRange(location: 7, length: 0),
                        NSRange(location: 8, length: 5)] as [NSRange?] {
            let reads = SelectionTextReadFixture()
            reads.direct = ""
            reads.ranges = [NSRange(location: 7, length: 5), current]
            reads.rangeText = "stale"
            reads.markers = [11]
            reads.markerLength = .known(5)
            reads.markerText = "other"

            XCTAssertEqual(reads.resolve(), .unavailable)
            XCTAssertFalse(reads.calls.contains("marker"))
            XCTAssertEqual(reads.trace.range, .unstable)
        }
    }

    func testSelectionTextResolverStopsWhenCurrentMarkerChangesOrDisappears() {
        for current in [nil, 12] as [Int?] {
            let reads = SelectionTextReadFixture()
            reads.markers = [11, current]
            reads.markerLength = .known(5)
            reads.markerText = "stale"

            XCTAssertEqual(reads.resolve(), .unavailable)
            XCTAssertEqual(reads.trace.marker, .unstable)
        }
    }

    func testSelectionTextResolverKeepsValidDirectTextAndDoesNotReadFallbacks() {
        let reads = SelectionTextReadFixture()
        reads.direct = " direct \n"
        reads.rangeText = "different"
        reads.markerText = "different"

        XCTAssertEqual(reads.resolve(), .selected(.init(
            text: " direct \n", source: .direct, range: nil, marker: nil
        )))
        XCTAssertEqual(reads.calls, ["direct"])
    }

    func testSelectionTextResolverRefusesPasswordBeforeAnyTextOrRangeRead() {
        let reads = SelectionTextReadFixture()
        reads.isPasswordField = true
        reads.direct = "not permitted"

        XCTAssertEqual(reads.resolve(), .failure(.passwordField))
        XCTAssertTrue(reads.calls.isEmpty)
    }

    func testSelectionTextResolverNeverMasksOversizedDirectOrFallbackWithShorterText() {
        for source in ["direct", "range", "marker"] {
            let reads = SelectionTextReadFixture()
            reads.maximumCharacters = 4
            reads.direct = source == "direct" ? "large" : ""
            reads.ranges = [NSRange(location: 0, length: 5)]
            reads.rangeText = source == "range" ? "large" : ""
            reads.markers = [11]
            reads.markerLength = .known(5)
            reads.markerText = source == "marker" ? "large" : "ok"

            XCTAssertEqual(reads.resolve(), .failure(.selectionTooLarge))
            if source == "direct" {
                XCTAssertEqual(reads.calls, ["direct"])
            } else if source == "range" {
                XCTAssertFalse(reads.calls.contains("marker"))
            }
        }
    }

    func testSelectionTextResolverEnforcesUTF8BytesAsWellAsCharacterLimit() {
        let reads = SelectionTextReadFixture()
        reads.maximumUTF8Bytes = 3
        reads.ranges = [NSRange(location: 0, length: 2)]
        reads.rangeText = "😀"
        reads.markers = [11]
        reads.markerLength = .known(1)
        reads.markerText = "x"

        XCTAssertEqual(reads.resolve(), .failure(.selectionTooLarge))
        XCTAssertFalse(reads.calls.contains("marker"))
    }

    func testSelectionTextResolverRefusesOversizedMarkerLengthBeforeFetchingText() {
        let reads = SelectionTextReadFixture()
        reads.maximumUTF8Bytes = 4
        reads.markers = [11]
        reads.markerLength = .known(5)
        reads.markerText = "x"

        XCTAssertEqual(reads.resolve(), .failure(.selectionTooLarge))
        XCTAssertFalse(reads.calls.contains("markerText"))
    }

    func testSelectionTextResolverRefusesOversizedRangeBeforeFetchingOrTryingMarker() {
        let reads = SelectionTextReadFixture()
        reads.maximumUTF8Bytes = 4
        reads.ranges = [NSRange(location: 0, length: 5)]
        reads.rangeText = "x"
        reads.markers = [11]
        reads.markerLength = .known(1)
        reads.markerText = "x"

        XCTAssertEqual(reads.resolve(), .failure(.selectionTooLarge))
        XCTAssertEqual(reads.calls, ["direct", "range"])
    }

    func testSelectionTextResolverObservesCancellationAndDeadlineAfterEveryReadStage() {
        for failure in [SelectionAgentFailureCode.cancelled, .timedOut] {
            for stage in ["direct", "range", "rangeText", "marker",
                          "markerLength", "markerText"] {
                let reads = SelectionTextReadFixture()
                reads.direct = ""
                reads.ranges = [NSRange(location: 0, length: 1)]
                reads.rangeText = ""
                reads.markers = [11]
                reads.markerLength = .known(1)
                reads.markerText = "x"
                reads.interruptAfterStage = stage
                reads.interruptWith = failure

                XCTAssertEqual(reads.resolve(), .failure(failure), stage)
                XCTAssertEqual(reads.calls.last, stage)
            }
        }
    }

    func testSelectionTextResolverDoesNotStartWhenAlreadyInterrupted() {
        for failure in [SelectionAgentFailureCode.cancelled, .timedOut] {
            let reads = SelectionTextReadFixture()
            reads.failure = failure

            XCTAssertEqual(reads.resolve(), .failure(failure))
            XCTAssertTrue(reads.calls.isEmpty)
        }
    }

    func testSelectionTextResolverRejectsCancellationDuringRangeAndMarkerConfirmation() {
        for stage in ["range", "marker"] {
            let reads = SelectionTextReadFixture()
            reads.ranges = [NSRange(location: 0, length: 1)]
            reads.rangeText = stage == "range" ? "x" : ""
            reads.markers = [11]
            reads.markerLength = .known(1)
            reads.markerText = "x"
            reads.interruptAfterStage = stage
            reads.interruptAfterOccurrence = 2

            XCTAssertEqual(reads.resolve(), .failure(.cancelled))
            XCTAssertEqual(reads.calls.last, stage)
        }
    }

    func testSelectionTextResolverDistinguishesEmptyFromUnavailableAndDoesNotCacheText() {
        let reads = SelectionTextReadFixture()
        reads.direct = "first"
        XCTAssertEqual(reads.resolve(), .selected(.init(
            text: "first", source: .direct, range: nil, marker: nil
        )))
        reads.direct = nil
        XCTAssertEqual(reads.resolve(), .unavailable)
        reads.direct = " \n"
        XCTAssertEqual(reads.resolve(), .empty)
    }

    func testSelectionCaptureDiagnosticsAreCappedAndNeverIncludeUnrecognizedRoleData() {
        var diagnostics = SelectionHelperCaptureDiagnostics()
        var trace = SelectionHelperCaptureDiagnostics.Trace()
        trace.role = .init("private document text")
        trace.record(.direct, .empty)
        trace.record(.range, .unavailable)
        trace.record(.marker, .selected)
        for _ in 0..<20 {
            diagnostics.record(strategy: .focusedWindowDocument, trace: trace)
        }

        XCTAssertEqual(diagnostics.inspectedCandidates, 20)
        XCTAssertEqual(diagnostics.records.count,
                       SelectionHelperCaptureDiagnostics.maximumCandidateRecords)
        XCTAssertEqual(diagnostics.omittedCandidates,
                       20 - SelectionHelperCaptureDiagnostics.maximumCandidateRecords)
        XCTAssertTrue(diagnostics.records.allSatisfy {
            $0 == "focusedWindowDocument:other:empty/unavailable/selected"
        })
    }

    func testNativeMarkerSnapshotChecksTypeAndComparesBothOpaqueEndpoints() throws {
        func marker(start: [UInt8], end: [UInt8]) -> AXTextMarkerRange {
            start.withUnsafeBufferPointer { startBytes in
                end.withUnsafeBufferPointer { endBytes in
                    AXTextMarkerRangeCreateWithBytes(
                        kCFAllocatorDefault,
                        startBytes.baseAddress!, startBytes.count,
                        endBytes.baseAddress!, endBytes.count
                    )
                }
            }
        }
        let first = try XCTUnwrap(SelectionHelperTextMarkerSnapshot(
            marker(start: [1, 2], end: [3, 4])
        ))
        let equal = try XCTUnwrap(SelectionHelperTextMarkerSnapshot(
            marker(start: [1, 2], end: [3, 4])
        ))
        let movedStart = try XCTUnwrap(SelectionHelperTextMarkerSnapshot(
            marker(start: [1, 5], end: [3, 4])
        ))
        let movedEnd = try XCTUnwrap(SelectionHelperTextMarkerSnapshot(
            marker(start: [1, 2], end: [3, 5])
        ))

        XCTAssertEqual(first, equal)
        XCTAssertNotEqual(first, movedStart)
        XCTAssertNotEqual(first, movedEnd)
        XCTAssertNil(SelectionHelperTextMarkerSnapshot("not a marker" as CFString))
        XCTAssertNil(SelectionHelperTextMarkerSnapshot(marker(
            start: Array(repeating: 1, count: 4_097), end: [2]
        )))
    }

    func testSelectionTargetHitTestUsesOnlyTargetApplicationAndChecksReturnedPID() {
        var applications: [String] = []
        let matched = SelectionHelperTargetHitTest.read(
            targetApplication: "frozen target application", targetPID: 42,
            isAllowed: { true },
            hitTest: { application in
                applications.append(application)
                return "target child"
            },
            processIdentifier: { _ in 42 }
        )
        XCTAssertEqual(applications, ["frozen target application"])
        XCTAssertEqual(matched.element, "target child")
        XCTAssertEqual(matched.status, .matched)

        let mismatched = SelectionHelperTargetHitTest.read(
            targetApplication: "frozen target application", targetPID: 42,
            isAllowed: { true }, hitTest: { _ in "foreign child" },
            processIdentifier: { _ in 99 }
        )
        XCTAssertNil(mismatched.element)
        XCTAssertEqual(mismatched.status, .pidMismatch)

        let unknownPID = SelectionHelperTargetHitTest.read(
            targetApplication: "frozen target application", targetPID: 42,
            isAllowed: { true }, hitTest: { _ in "unidentified child" },
            processIdentifier: { _ in nil }
        )
        XCTAssertNil(unknownPID.element)
        XCTAssertEqual(unknownPID.status, .unavailable)
    }

    func testSelectionTargetHitTestDoesNotReadPIDAfterInterruption() {
        var allowed = true
        var pidReads = 0
        let result = SelectionHelperTargetHitTest.read(
            targetApplication: "target", targetPID: 42,
            isAllowed: { allowed },
            hitTest: { _ in allowed = false; return "child" },
            processIdentifier: { _ in pidReads += 1; return 42 }
        )
        XCTAssertNil(result.element)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(pidReads, 0)
    }

    func testSelectionTargetHitTestSkipsAllWorkWhenAlreadyInterrupted() {
        var calls = 0
        let result = SelectionHelperTargetHitTest.read(
            targetApplication: "target", targetPID: 42,
            isAllowed: { false },
            hitTest: { _ in calls += 1; return "child" },
            processIdentifier: { _ in calls += 1; return 42 }
        )
        XCTAssertNil(result.element)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(calls, 0)
    }

    func testHostedTestDetectionAllowsExplicitOverrideOnlyInDebug() {
        XCTAssertTrue(
            SelectionHelperTestHost.isRunningUnitTests(
                environment: ["BLOCKS_UNIT_TESTING": "1"],
                allowsDebugOverride: true
            )
        )
    }

    func testLifecycleStartsServerOnFinishWithoutPresentingWindow() {
        var serverStartCount = 0
        var windowPresentationCount = 0
        let lifecycle = SelectionHelperAppLifecycle(
            isRunningUnitTests: { false },
            startServer: { serverStartCount += 1 },
            presentWindow: { windowPresentationCount += 1 }
        )

        lifecycle.applicationDidFinishLaunching()
        lifecycle.applicationDidFinishLaunching()

        XCTAssertEqual(serverStartCount, 1)
        XCTAssertEqual(windowPresentationCount, 0)
    }

    func testLifecyclePresentsOnActiveAndReopenWithoutRestartingServer() {
        var serverStartCount = 0
        var windowPresentationCount = 0
        let lifecycle = SelectionHelperAppLifecycle(
            isRunningUnitTests: { false },
            startServer: { serverStartCount += 1 },
            presentWindow: { windowPresentationCount += 1 }
        )

        lifecycle.applicationDidFinishLaunching()
        lifecycle.applicationDidBecomeActive()
        XCTAssertTrue(lifecycle.applicationShouldHandleReopen())

        XCTAssertEqual(serverStartCount, 1)
        XCTAssertEqual(windowPresentationCount, 2)
    }

    func testLifecycleDoesNotInstantiateModelOrPresentWindowDuringUnitTests() {
        var modelInitializationCount = 0
        var windowPresentationCount = 0
        let lifecycle = SelectionHelperAppLifecycle(
            isRunningUnitTests: { true },
            startServer: { modelInitializationCount += 1 },
            presentWindow: { windowPresentationCount += 1 }
        )

        lifecycle.applicationDidFinishLaunching()
        lifecycle.applicationDidBecomeActive()

        XCTAssertFalse(lifecycle.applicationShouldHandleReopen())
        XCTAssertEqual(modelInitializationCount, 0)
        XCTAssertEqual(windowPresentationCount, 0)
    }

    func testResponseSenderAdmissionLimitsAndIsolatesTokens() {
        let server = SelectionHelperServer(
            pairingCode: pairingCode,
            stateHandler: { _ in },
            pairingHandler: { _, _ in },
            keyStore: InMemoryKeyStore(),
            bootstrapKeyStore: FixedBootstrapKeyStore(key: bootstrapKey),
            maximumActiveResponseSenders: 1
        )

        guard let first = server.admitResponseSenderForTesting() else {
            XCTFail("first sender should be admitted")
            return
        }
        XCTAssertEqual(server.activeResponseSenderCountForTesting(), 1)
        XCTAssertNil(server.admitResponseSenderForTesting())
        XCTAssertEqual(server.activeResponseSenderCountForTesting(), 1)

        server.releaseResponseSenderForTesting(first)
        XCTAssertEqual(server.activeResponseSenderCountForTesting(), 0)

        guard let third = server.admitResponseSenderForTesting() else {
            XCTFail("third sender should be admitted after release")
            return
        }
        XCTAssertEqual(server.activeResponseSenderCountForTesting(), 1)
        server.releaseResponseSenderForTesting(first)
        XCTAssertEqual(server.activeResponseSenderCountForTesting(), 1)
        server.releaseResponseSenderForTesting(third)
        XCTAssertEqual(server.activeResponseSenderCountForTesting(), 0)
    }

    func testPasteTargetSemanticsMarksSupportedEditableControlEditable() {
        let semantics = SelectionHelperPasteTargetSemantics(
            role: "AXTextArea",
            enabled: true,
            explicitlyEditable: true,
            valueSettable: false,
            selectedTextSettable: false,
            focusedSettable: false,
            hasTextContentModel: false,
            hasTextSelectionModel: false,
            hasWebAreaAncestor: false,
            hasStableWebNodeIdentity: false
        )

        XCTAssertEqual(semantics.editability, .editable)
    }

    func testPasteTargetSemanticsMarksExplicitlyNonEditableControlNonEditable() {
        let semantics = SelectionHelperPasteTargetSemantics(
            role: "AXTextField",
            enabled: true,
            explicitlyEditable: false,
            valueSettable: false,
            selectedTextSettable: false,
            focusedSettable: false,
            hasTextContentModel: false,
            hasTextSelectionModel: false,
            hasWebAreaAncestor: false,
            hasStableWebNodeIdentity: false
        )

        XCTAssertEqual(semantics.editability, .nonEditable)
    }

    func testPasteTargetSemanticsMarksAmbiguousMetadataUnknown() {
        let semantics = SelectionHelperPasteTargetSemantics(
            role: "AXGroup",
            enabled: true,
            explicitlyEditable: false,
            valueSettable: false,
            selectedTextSettable: false,
            focusedSettable: false,
            hasTextContentModel: true,
            hasTextSelectionModel: true,
            hasWebAreaAncestor: true,
            hasStableWebNodeIdentity: false
        )

        XCTAssertEqual(semantics.editability, .unknown)
    }

    func testPasteTargetInspectionServiceReturnsUnknownWhileOneReadIsInFlight() {
        let firstStarted = expectation(description: "first inspection started")
        let firstFinished = expectation(description: "first inspection finished")
        let busyFinished = expectation(description: "busy inspection finished")
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstRequest = pasteTargetRequest(requestID: "first")
        let busyRequest = pasteTargetRequest(requestID: "busy")
        let afterRequest = pasteTargetRequest(requestID: "after")
        let service = SelectionHelperPasteTargetInspectionService(
            inspector: { request, _ in
                if request.requestID == firstRequest.requestID {
                    firstStarted.fulfill()
                    _ = releaseFirst.wait(timeout: .now() + 1)
                }
                return SelectionHelperPasteTargetInspection(
                    requestID: request.requestID,
                    targetPID: request.targetPID,
                    targetBundleIdentifier: request.targetBundleIdentifier,
                    editability: .editable
                )
            }
        )

        service.inspect(firstRequest) { inspection in
            XCTAssertEqual(inspection.editability, .editable)
            firstFinished.fulfill()
        }
        wait(for: [firstStarted], timeout: 1)

        service.inspect(busyRequest) { inspection in
            XCTAssertEqual(inspection.requestID, busyRequest.requestID)
            XCTAssertEqual(inspection.editability, .unknown)
            busyFinished.fulfill()
        }
        wait(for: [busyFinished], timeout: 1)

        releaseFirst.signal()
        wait(for: [firstFinished], timeout: 1)

        let afterFinished = expectation(description: "post-work inspection")
        service.inspect(afterRequest) { inspection in
            XCTAssertEqual(inspection.editability, .editable)
            afterFinished.fulfill()
        }
        wait(for: [afterFinished], timeout: 1)
    }

    func testPasteTargetInspectionServiceSkipsExpiredWorkBeforeMetadataRead() {
        let finished = expectation(description: "expired inspection finished")
        let metadataReadCount = InspectionCounter()
        let request = pasteTargetRequest(requestID: "expired")
        let service = SelectionHelperPasteTargetInspectionService(
            timeout: 0,
            inspector: { request, _ in
                metadataReadCount.increment()
                return SelectionHelperPasteTargetInspection(
                    requestID: request.requestID,
                    targetPID: request.targetPID,
                    targetBundleIdentifier: request.targetBundleIdentifier,
                    editability: .editable
                )
            }
        )

        service.inspect(request) { inspection in
            XCTAssertEqual(inspection.editability, .unknown)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(metadataReadCount.value, 0)
    }

    func testListenerReadinessFailsWhenIPv4FailsAfterIPv6IsReady() {
        var readiness = SelectionHelperServer.ListenerReadiness()

        XCTAssertNil(
            readiness.record(.ready, for: .ipv6Loopback)
        )
        XCTAssertEqual(
            readiness.record(
                .failed("address already in use"),
                for: .ipv4Loopback
            ),
            .failed(
                "IPv4 loopback listener failed: address already in use"
            )
        )
    }

    func testListenerReadinessIgnoresIPv6FailureAfterIPv4IsReady() {
        var readiness = SelectionHelperServer.ListenerReadiness()

        XCTAssertEqual(
            readiness.record(.ready, for: .ipv4Loopback),
            .ready
        )
        XCTAssertNil(
            readiness.record(
                .failed("address already in use"),
                for: .ipv6Loopback
            )
        )
    }

    func testListenerReadinessFailsWhenBothListenersFail() {
        var readiness = SelectionHelperServer.ListenerReadiness()

        XCTAssertNil(
            readiness.record(
                .failed("IPv6 unavailable"),
                for: .ipv6Loopback
            )
        )
        XCTAssertEqual(
            readiness.record(
                .failed("IPv4 unavailable"),
                for: .ipv4Loopback
            ),
            .failed("IPv4 loopback listener failed: IPv4 unavailable")
        )
    }

    func testListenerReadinessPublishesFirstIPv4TerminalFailureAfterReady() {
        var readiness = SelectionHelperServer.ListenerReadiness()

        XCTAssertEqual(
            readiness.record(.ready, for: .ipv4Loopback),
            .ready
        )
        XCTAssertEqual(
            readiness.record(
                .failed("listener terminated"),
                for: .ipv4Loopback
            ),
            .failed("IPv4 loopback listener failed: listener terminated")
        )
        XCTAssertNil(
            readiness.record(
                .failed("duplicate terminal failure"),
                for: .ipv4Loopback
            )
        )
        XCTAssertNil(
            readiness.record(.ready, for: .ipv6Loopback)
        )
        XCTAssertNil(
            readiness.record(
                .failed("unexpected later failure"),
                for: .ipv6Loopback
            )
        )
    }

    func testRetryCancelsOldListenersAndRecoversAfterInitialIPv4Failure() {
        let failed = expectation(description: "first IPv4 listener fails")
        let ready = expectation(description: "replacement IPv4 listener ready")
        var states: [SelectionHelperServer.State] = []
        var listeners: [TestListener] = []
        var ipv4Attempts = 0
        let server = SelectionHelperServer(
            pairingCode: pairingCode,
            stateHandler: { state in
                states.append(state)
                switch state {
                case .failed:
                    failed.fulfill()
                case .ready:
                    ready.fulfill()
                case .starting:
                    break
                }
            },
            pairingHandler: { _, _ in },
            keyStore: InMemoryKeyStore(),
            bootstrapKeyStore: FixedBootstrapKeyStore(key: bootstrapKey),
            listenerFactory: { _, host, stateHandler, _ in
                let result: SelectionHelperServer.ListenerResult?
                if host == .ipv4Loopback {
                    ipv4Attempts += 1
                    result = ipv4Attempts == 1
                        ? .failed("IPv4 unavailable")
                        : .ready
                } else {
                    result = nil
                }
                let listener = TestListener(result: result, stateHandler: stateHandler)
                listeners.append(listener)
                return listener
            }
        )

        server.start()
        wait(for: [failed], timeout: 1)
        server.retryIfFailed()
        server.retryIfFailed()
        wait(for: [ready], timeout: 1)

        XCTAssertEqual(states, [
            .starting,
            .failed("IPv4 loopback listener failed: IPv4 unavailable"),
            .starting,
            .ready,
        ])
        XCTAssertEqual(listeners.count, 4)
        XCTAssertTrue(listeners[0].wasCancelled)
        XCTAssertTrue(listeners[1].wasCancelled)
        XCTAssertFalse(listeners[2].wasCancelled)
        XCTAssertFalse(listeners[3].wasCancelled)
    }

    func testRetryIgnoresLateCallbacksFromCancelledGeneration() {
        let initialStart = expectation(description: "initial start")
        let initialReady = expectation(description: "initial ready")
        let initialFailure = expectation(description: "initial failure")
        let retryStart = expectation(description: "retry start")
        let replacementReady = expectation(description: "replacement ready")
        var states: [SelectionHelperServer.State] = []
        var listeners: [TestListener] = []
        let server = SelectionHelperServer(
            pairingCode: pairingCode,
            stateHandler: { state in
                states.append(state)
                switch state {
                case .starting where states.count == 1:
                    initialStart.fulfill()
                case .ready where states.count == 2:
                    initialReady.fulfill()
                case .failed where states.count == 3:
                    initialFailure.fulfill()
                case .starting where states.count == 4:
                    retryStart.fulfill()
                case .ready where states.count == 5:
                    replacementReady.fulfill()
                default:
                    break
                }
            },
            pairingHandler: { _, _ in },
            keyStore: InMemoryKeyStore(),
            bootstrapKeyStore: FixedBootstrapKeyStore(key: bootstrapKey),
            listenerFactory: { _, _, stateHandler, _ in
                let listener = TestListener(stateHandler: stateHandler)
                listeners.append(listener)
                return listener
            }
        )

        server.start()
        wait(for: [initialStart], timeout: 1)
        XCTAssertEqual(listeners.count, 2)

        listeners[0].emit(.ready)
        wait(for: [initialReady], timeout: 1)
        listeners[0].emit(.failed("listener terminated"))
        wait(for: [initialFailure], timeout: 1)

        server.retryIfFailed()
        wait(for: [retryStart], timeout: 1)
        XCTAssertEqual(listeners.count, 4)
        XCTAssertTrue(listeners[0].wasCancelled)
        XCTAssertTrue(listeners[1].wasCancelled)

        listeners[0].emit(.ready)
        listeners[0].emit(.failed("old generation failure"))
        listeners[2].emit(.ready)
        wait(for: [replacementReady], timeout: 1)

        XCTAssertEqual(states, [
            .starting,
            .ready,
            .failed("IPv4 loopback listener failed: listener terminated"),
            .starting,
            .ready,
        ])
    }

    func testRetryRecoversAfterIPv4ListenerFactoryThrows() {
        let initialFailure = expectation(description: "factory failure")
        let retryStart = expectation(description: "retry start")
        let replacementReady = expectation(description: "replacement ready")
        var states: [SelectionHelperServer.State] = []
        var listeners: [TestListener] = []
        var ipv4Attempts = 0
        let server = SelectionHelperServer(
            pairingCode: pairingCode,
            stateHandler: { state in
                states.append(state)
                switch state {
                case .failed where states.count == 2:
                    initialFailure.fulfill()
                case .starting where states.count == 3:
                    retryStart.fulfill()
                case .ready where states.count == 4:
                    replacementReady.fulfill()
                default:
                    break
                }
            },
            pairingHandler: { _, _ in },
            keyStore: InMemoryKeyStore(),
            bootstrapKeyStore: FixedBootstrapKeyStore(key: bootstrapKey),
            listenerFactory: { _, host, stateHandler, _ in
                if host == .ipv4Loopback {
                    ipv4Attempts += 1
                    if ipv4Attempts == 1 {
                        throw TestListenerFactoryFailure(
                            description: "IPv4 factory unavailable"
                        )
                    }
                }
                let listener = TestListener(stateHandler: stateHandler)
                listeners.append(listener)
                return listener
            }
        )

        server.start()
        wait(for: [initialFailure], timeout: 1)
        XCTAssertEqual(listeners.count, 1)

        server.retryIfFailed()
        wait(for: [retryStart], timeout: 1)
        XCTAssertEqual(listeners.count, 3)
        XCTAssertTrue(listeners[0].wasCancelled)
        XCTAssertFalse(listeners[1].wasCancelled)
        XCTAssertFalse(listeners[2].wasCancelled)

        listeners[1].emit(.ready)
        wait(for: [replacementReady], timeout: 1)
        XCTAssertEqual(states, [
            .starting,
            .failed("IPv4 loopback listener failed: IPv4 factory unavailable"),
            .starting,
            .ready,
        ])
    }

    #if DEBUG
    func testWrongCodeWithInvalidProofDoesNotConsumePairingRateLimitOrPersistKey() {
        let existingKey = Data(repeating: 0x11, count: 32)
        let store = InMemoryKeyStore(activeKey: existingKey)
        let paired = expectation(description: "successful pairing callback")
        var callbackCount = 0
        let server = makeServer(store: store) { isPaired, _ in
            guard isPaired else { return }
            callbackCount += 1
            paired.fulfill()
        }

        for requestID in (1...5).map({ "wrong-code-invalid-proof-\($0)" }) {
            let request = makeRequest(
                requestID: requestID,
                proof: Data(repeating: 0xFF, count: 32),
                pairingCode: "000000"
            )
            XCTAssertEqual(response(from: server.submitRawPairRequestForTesting(request))?.failureCode, "invalid_pairing_proof")
        }

        XCTAssertEqual(store.activeKey, existingKey)
        XCTAssertEqual(store.saveCount, 0)

        let fixture = makeValidRequest(requestID: "valid-after-invalid")
        let response = response(
            from: server.submitRawPairRequestForTesting(fixture.request)
        )
        XCTAssertNil(response?.failureCode)
        assertCommittedPairing(
            fixture,
            response: response,
            store: store
        )
        XCTAssertEqual(store.saveCount, 1)
        wait(for: [paired], timeout: 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testCommitPersistsBeforeDiscardedPairReply() {
        let store = InMemoryKeyStore()
        let paired = expectation(description: "pair callback")
        var callbackCount = 0
        let server = makeServer(store: store) { isPaired, _ in
            guard isPaired else { return }
            callbackCount += 1
            paired.fulfill()
        }

        let fixture = makeValidRequest(requestID: "discarded-reply")
        let response = response(
            from: server.submitRawPairRequestForTesting(fixture.request)
        )

        assertCommittedPairing(fixture, response: response, store: store)
        XCTAssertEqual(store.saveCount, 1)
        wait(for: [paired], timeout: 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testExactSuccessfulPairRequestReplaysSameReplyWithoutSecondCommit() throws {
        let store = InMemoryKeyStore()
        let paired = expectation(description: "one pair callback")
        var callbackCount = 0
        let server = makeServer(store: store) { isPaired, _ in
            guard isPaired else { return }
            callbackCount += 1
            paired.fulfill()
        }
        let fixture = makeValidRequest(requestID: "replay-exact-request")

        let first = try XCTUnwrap(
            server.submitRawPairRequestForTesting(fixture.request)
        )
        let second = try XCTUnwrap(
            server.submitRawPairRequestForTesting(fixture.request)
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(store.saveCount, 1)
        wait(for: [paired], timeout: 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testSameRequestIDWithDifferentFieldsDoesNotReplayPairReply() {
        let store = InMemoryKeyStore()
        let server = makeServer(store: store) { _, _ in }
        let fixture = makeValidRequest(requestID: "replay-tampered-request")

        XCTAssertNotNil(server.submitRawPairRequestForTesting(fixture.request))
        let tampered = SelectionHelperPairRequest(
            requestID: fixture.request.requestID,
            pairingCode: "654321",
            clientPublicKey: fixture.request.clientPublicKey,
            clientProof: fixture.request.clientProof
        )

        XCTAssertEqual(
            response(from: server.submitRawPairRequestForTesting(tampered))?
                .failureCode,
            "invalid_pairing_proof"
        )
        XCTAssertEqual(store.saveCount, 1)
    }

    func testExpiredOrEvictedPairReplyDoesNotReplay() {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryKeyStore()
        let server = makeServer(
            store: store,
            now: { currentDate }
        ) { _, _ in }
        let first = makeValidRequest(requestID: "replay-expired")

        XCTAssertNotNil(server.submitRawPairRequestForTesting(first.request))
        currentDate.addTimeInterval(6)
        XCTAssertEqual(
            response(from: server.submitRawPairRequestForTesting(first.request))?
                .failureCode,
            "invalid_pairing_code"
        )

        let replacementCode = "654321"
        _ = server.updatePairingCode(replacementCode)
        let replacement = makeValidRequest(
            requestID: "replay-replacement",
            pairingCode: replacementCode
        )
        XCTAssertNotNil(server.submitRawPairRequestForTesting(replacement.request))
        XCTAssertEqual(
            response(from: server.submitRawPairRequestForTesting(first.request))?
                .failureCode,
            "invalid_pairing_code"
        )
        XCTAssertEqual(store.saveCount, 2)
    }

    func testLegacyKeyBytesDoNotAuthenticateV4PairingWhenActiveKeyIsNil() {
        let store = InMemoryKeyStore(legacyKey: Data(repeating: 0xA5, count: 32))
        let server = makeServer(store: store) { _, _ in
            XCTFail("legacy data must not authenticate a v4 pairing")
        }
        let request = makeRequest(
            requestID: "legacy-is-not-bootstrap",
            proof: store.legacyKey!
        )

        XCTAssertEqual(response(from: server.submitRawPairRequestForTesting(request))?.failureCode, "invalid_pairing_proof")
        XCTAssertNil(store.activeKey)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testConcurrentValidPairAttemptsCommitExactlyOnce() async {
        let store = InMemoryKeyStore()
        let paired = expectation(description: "one pair callback")
        var callbackCount = 0
        let server = makeServer(store: store) { isPaired, _ in
            guard isPaired else { return }
            callbackCount += 1
            paired.fulfill()
        }
        let requests = [
            makeValidRequest(requestID: "concurrent-1"),
            makeValidRequest(requestID: "concurrent-2"),
        ].map(\.request)
        let responses = LockedResponses()
        let workersReady = expectation(description: "both pair workers are ready")
        workersReady.expectedFulfillmentCount = requests.count
        let workersFinished = expectation(description: "both pair workers finish")
        workersFinished.expectedFulfillmentCount = requests.count
        let startGate = ConcurrentStartGate()
        let workerQueue = DispatchQueue(
            label: "com.blocks.selection-helper-tests.concurrent-pairing",
            qos: .userInitiated,
            attributes: .concurrent
        )
        defer { startGate.open() }
        for request in requests {
            workerQueue.async {
                defer { workersFinished.fulfill() }
                workersReady.fulfill()
                guard startGate.waitToStart(timeout: 1) else { return }
                responses.append(server.submitRawPairRequestForTesting(request))
            }
        }
        await fulfillment(of: [workersReady], timeout: 1)
        startGate.open()
        await fulfillment(of: [workersFinished], timeout: 1)

        let decoded = responses.values.compactMap(response(from:))
        XCTAssertEqual(decoded.filter { $0.failureCode == nil }.count, 1)
        XCTAssertEqual(decoded.filter { $0.failureCode == "invalid_pairing_code" }.count, 1)
        XCTAssertEqual(store.saveCount, 1)
        await fulfillment(of: [paired], timeout: 1)
        XCTAssertEqual(callbackCount, 1)
    }
    #endif

    func testKeyStoreLoadQueriesOnlyV4Identity() {
        let expectedKey = Data(repeating: 0x24, count: 32)
        let spy = KeychainOperationSpy(copyResult: expectedKey)
        let store = makeKeyStore(spy: spy)

        XCTAssertEqual(store.load(), expectedKey)
        XCTAssertEqual(spy.operationKinds, [.copy])
        assertKeychainQueries(
            spy.copyQueries,
            identities: [activeKeyIdentity]
        )
        XCTAssertFalse(
            spy.copyQueries.contains(where: isLegacyActiveKeyQuery)
        )
    }

    func testKeyStoreSuccessfulSaveDeletesOnlyLegacyActiveKey() {
        let spy = KeychainOperationSpy()
        let store = makeKeyStore(spy: spy)
        let key = Data(repeating: 0x25, count: 32)

        XCTAssertTrue(store.save(key))
        XCTAssertEqual(spy.operationKinds, [.update, .add, .delete])
        assertKeychainQueries(
            spy.updateQueries,
            identities: [activeKeyIdentity]
        )
        assertKeychainQueries(
            spy.addQueries,
            identities: [activeKeyIdentity]
        )
        assertKeychainQueries(
            spy.deleteQueries,
            identities: [legacyActiveKeyIdentity]
        )
        XCTAssertFalse(
            spy.updateQueries.contains(where: isLegacyActiveKeyQuery)
        )
        XCTAssertFalse(spy.addQueries.contains(where: isLegacyActiveKeyQuery))
    }

    func testKeyStoreSaveUpdateSuccessSkipsAddAndDeletesLegacyActiveKey() {
        let spy = KeychainOperationSpy(updateStatus: errSecSuccess)
        let store = makeKeyStore(spy: spy)
        let key = Data(repeating: 0x29, count: 32)

        XCTAssertTrue(store.save(key))
        XCTAssertEqual(spy.operationKinds, [.update, .delete])
        assertKeychainQueries(
            spy.updateQueries,
            identities: [activeKeyIdentity]
        )
        assertKeychainQueries(spy.addQueries, identities: [])
        assertKeychainQueries(
            spy.deleteQueries,
            identities: [legacyActiveKeyIdentity]
        )
    }

    func testKeyStoreSaveAddFailureDoesNotDeleteLegacyActiveKey() {
        let spy = KeychainOperationSpy(addStatus: errSecAuthFailed)
        let store = makeKeyStore(spy: spy)
        let key = Data(repeating: 0x2A, count: 32)

        XCTAssertFalse(store.save(key))
        XCTAssertEqual(spy.operationKinds, [.update, .add])
        assertKeychainQueries(
            spy.updateQueries,
            identities: [activeKeyIdentity]
        )
        assertKeychainQueries(
            spy.addQueries,
            identities: [activeKeyIdentity]
        )
        assertKeychainQueries(spy.deleteQueries, identities: [])
    }

    func testKeyStoreSaveUpdateFailureSkipsAddAndLegacyCleanup() {
        let spy = KeychainOperationSpy(updateStatus: errSecAuthFailed)
        let store = makeKeyStore(spy: spy)
        let key = Data(repeating: 0x2B, count: 32)

        XCTAssertFalse(store.save(key))
        XCTAssertEqual(spy.operationKinds, [.update])
        assertKeychainQueries(
            spy.updateQueries,
            identities: [activeKeyIdentity]
        )
        assertKeychainQueries(spy.addQueries, identities: [])
        assertKeychainQueries(spy.deleteQueries, identities: [])
    }

    func testKeyStoreDeleteQueriesOnlyV4Identity() {
        let spy = KeychainOperationSpy()
        let store = makeKeyStore(spy: spy)

        XCTAssertTrue(store.delete())
        XCTAssertEqual(spy.operationKinds, [.delete])
        assertKeychainQueries(
            spy.deleteQueries,
            identities: [activeKeyIdentity]
        )
        XCTAssertFalse(
            spy.deleteQueries.contains(where: isLegacyActiveKeyQuery)
        )
    }

    func testKeyStoreDisconnectTombstoneSavesBeforeDeletingActiveKey() {
        let activeKey = Data(repeating: 0x26, count: 32)
        let spy = KeychainOperationSpy(copyResult: activeKey)
        let store = makeKeyStore(spy: spy)

        XCTAssertTrue(
            store.replaceActiveKeyWithDisconnectTombstone(
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
            )
        )
        XCTAssertEqual(
            spy.operationKinds,
            [.copy, .update, .add, .delete]
        )
        assertKeychainQueries(spy.copyQueries, identities: [activeKeyIdentity])
        assertKeychainQueries(spy.updateQueries, identities: [tombstoneIdentity])
        assertKeychainQueries(spy.addQueries, identities: [tombstoneIdentity])
        assertKeychainQueries(spy.deleteQueries, identities: [activeKeyIdentity])
    }

    func testKeyStoreDeleteFailureClearsNewTombstone() {
        let activeKey = Data(repeating: 0x27, count: 32)
        let spy = KeychainOperationSpy(
            copyResult: activeKey,
            deleteStatuses: [errSecAuthFailed, errSecSuccess]
        )
        let store = makeKeyStore(spy: spy)

        XCTAssertFalse(
            store.replaceActiveKeyWithDisconnectTombstone(
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
            )
        )
        XCTAssertEqual(
            spy.operationKinds,
            [.copy, .update, .add, .delete, .delete]
        )
        assertKeychainQueries(spy.copyQueries, identities: [activeKeyIdentity])
        assertKeychainQueries(spy.updateQueries, identities: [tombstoneIdentity])
        assertKeychainQueries(spy.addQueries, identities: [tombstoneIdentity])
        assertKeychainQueries(
            spy.deleteQueries,
            identities: [activeKeyIdentity, tombstoneIdentity]
        )
    }

    func testKeyStoreExpiredTombstoneClearsOnlyTombstone() {
        let tombstone = try! JSONEncoder().encode(
            SelectionHelperDisconnectTombstone(
                key: Data(repeating: 0x28, count: 32),
                expiresAt: Date(timeIntervalSince1970: 1)
            )
        )
        let spy = KeychainOperationSpy(copyResult: tombstone)
        let store = makeKeyStore(spy: spy)

        XCTAssertNil(
            store.loadDisconnectTombstone(
                now: Date(timeIntervalSince1970: 2)
            )
        )
        XCTAssertEqual(spy.operationKinds, [.copy, .delete])
        assertKeychainQueries(spy.copyQueries, identities: [tombstoneIdentity])
        XCTAssertTrue(spy.updateQueries.isEmpty)
        XCTAssertTrue(spy.addQueries.isEmpty)
        assertKeychainQueries(spy.deleteQueries, identities: [tombstoneIdentity])
    }

    #if !BLOCKS_LOCAL_DEVELOPMENT
    func testOfficialResetPersistsDurableOptOutBeforeRemovingActivePairing() throws {
        let key = Data(repeating: 0x67, count: 32)
        let store = InMemoryKeyStore(activeKey: key)
        let server = makeServer(store: store, pairingHandler: { _, _ in })
        _ = try server.resetPairing("654321").get()
        XCTAssertTrue(store.automaticAssociationDisabled)
        XCTAssertNil(store.activeKey)
        XCTAssertEqual(store.markerWriteCount, 1)
        XCTAssertEqual(store.deleteCount, 1)
    }

    func testOfficialResetMarkerFailurePreservesPairingAndReportsFailure() {
        let key = Data(repeating: 0x68, count: 32)
        let store = InMemoryKeyStore(activeKey: key)
        store.rejectMarkerWrites = true
        let server = makeServer(store: store, pairingHandler: { _, _ in })
        if case .success = server.resetPairing("654321") { XCTFail("Failed persistence must not report reset success") }
        XCTAssertEqual(store.activeKey, key)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testOfficialDisconnectMarkerFailurePreservesPairing() {
        let key = Data(repeating: 0x69, count: 32)
        let store = InMemoryKeyStore(activeKey: key)
        store.rejectMarkerWrites = true
        let server = makeServer(store: store, pairingHandler: { _, _ in })
        XCTAssertFalse(server.disconnectPairedClient())
        XCTAssertEqual(store.activeKey, key)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testOfficialPersistedOptOutBlocksHealthAndCaptureWhenActiveDeletionFails() async throws {
        let key = Data(repeating: 0x70, count: 32)
        let store = InMemoryKeyStore(activeKey: key)
        store.rejectDeletes = true
        let server = makeServer(store: store, pairingHandler: { _, _ in })
        if case .success = server.resetPairing("654321") { XCTFail("Active deletion failed") }
        XCTAssertTrue(store.automaticAssociationDisabled)
        XCTAssertEqual(store.activeKey, key)
        let responses = LockedResponses()
        let finished = expectation(description: "both disabled commands refused")
        finished.expectedFulfillmentCount = 2
        for kind in [SelectionHelperCommandKind.health, .capture] {
            let sealed = try SelectionHelperAuthenticatedCodec.seal(SelectionHelperCommand(kind: kind),
                requestID: UUID().uuidString, expiresAt: Date().addingTimeInterval(5), keyData: key)
            let packet = SelectionHelperWirePacket(kind: .authenticated, payload: try JSONEncoder().encode(sealed))
            server.submitRawAuthenticatedPacketForTesting(packet) { data in responses.append(data); finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(responses.values.count, 2)
        XCTAssertTrue(responses.values.allSatisfy { $0 == nil })
        XCTAssertEqual(store.activeKey, key)
    }

    func testOfficialHelperAssociationAbsenceAndAddOnlyPersistenceFailClosed() {
        let absentSpy = KeychainOperationSpy()
        XCTAssertTrue(makeKeyStore(spy: absentSpy).permitsLocalAssociation())
        XCTAssertEqual(absentSpy.operationKinds, [.copy, .copy, .copy])
        let presentSpy = KeychainOperationSpy(copyResult: Data())
        XCTAssertFalse(makeKeyStore(spy: presentSpy).permitsLocalAssociation())
        XCTAssertEqual(presentSpy.operationKinds, [.copy])
        let duplicateSpy = KeychainOperationSpy(addStatus: errSecDuplicateItem)
        XCTAssertFalse(makeKeyStore(spy: duplicateSpy).saveLocalAssociationIfAbsent(Data(repeating: 1, count: 32)))
        XCTAssertEqual(duplicateSpy.operationKinds, [.add])
    }
    #endif

    private func makeServer(
        store: InMemoryKeyStore,
        now: @escaping () -> Date = Date.init,
        pairingHandler: @escaping @MainActor (Bool, UInt64) -> Void
    ) -> SelectionHelperServer {
        SelectionHelperServer(
            pairingCode: pairingCode,
            stateHandler: { _ in },
            pairingHandler: pairingHandler,
            keyStore: store,
            bootstrapKeyStore: FixedBootstrapKeyStore(key: bootstrapKey),
            now: now
        )
    }

    private func pasteTargetRequest(
        requestID: String
    ) -> SelectionHelperPasteTargetRequest {
        SelectionHelperPasteTargetRequest(
            requestID: requestID,
            targetPID: 42,
            targetBundleIdentifier: "com.example.Target"
        )
    }

    private func makeValidRequest(
        requestID: String,
        pairingCode: String? = nil
    ) -> ValidPairFixture {
        let pairingCode = pairingCode ?? self.pairingCode
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let proof = try! XCTUnwrap(
            SelectionHelperPairingAuthentication.clientProof(
                bootstrapKey: bootstrapKey,
                requestID: requestID,
                pairingCode: pairingCode,
                clientPublicKey: publicKey
            )
        )
        return ValidPairFixture(
            privateKey: privateKey,
            request: makeRequest(
                requestID: requestID,
                proof: proof,
                publicKey: publicKey,
                pairingCode: pairingCode
            )
        )
    }

    private func assertCommittedPairing(
        _ fixture: ValidPairFixture,
        response: SelectionHelperPairResponse?,
        store: InMemoryKeyStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let response,
              let helperPublicKey = response.helperPublicKey,
              let helperProof = response.helperProof else {
            return XCTFail("Expected a complete pair response.", file: file, line: line)
        }
        XCTAssertTrue(
            SelectionHelperPairingAuthentication.verifiesHelperProof(
                helperProof,
                bootstrapKey: bootstrapKey,
                request: fixture.request,
                helperPublicKey: helperPublicKey
            ),
            file: file,
            line: line
        )
        let expectedKey = try? SelectionHelperAuthenticatedCodec.deriveSharedKey(
            privateKey: fixture.privateKey,
            peerPublicKeyData: helperPublicKey,
            requestID: fixture.request.requestID
        )
        XCTAssertEqual(store.activeKey, expectedKey, file: file, line: line)
    }

    private func makeRequest(
        requestID: String,
        proof: Data,
        publicKey: Data = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
        pairingCode: String? = nil
    ) -> SelectionHelperPairRequest {
        SelectionHelperPairRequest(
            requestID: requestID,
            pairingCode: pairingCode ?? self.pairingCode,
            clientPublicKey: publicKey,
            clientProof: proof
        )
    }

    private func response(from data: Data?) -> SelectionHelperPairResponse? {
        guard let data,
              let packet = try? JSONDecoder().decode(SelectionHelperWirePacket.self, from: data),
              packet.kind == .pair else {
            return nil
        }
        return try? JSONDecoder().decode(SelectionHelperPairResponse.self, from: packet.payload)
    }

    private func makeKeyStore(spy: KeychainOperationSpy) -> SelectionHelperKeyStore {
        SelectionHelperKeyStore(
            accessGroupProvider: { self.testAccessGroup },
            copyMatching: spy.copyMatching,
            updateItem: spy.updateItem,
            addItem: spy.addItem,
            deleteItem: spy.deleteItem
        )
    }

    private var activeKeyIdentity: KeychainIdentity {
        KeychainIdentity(
            service: BlocksSelectionHelperProtocol.keychainService,
            account: BlocksSelectionHelperProtocol.keychainAccount
        )
    }

    private var legacyActiveKeyIdentity: KeychainIdentity {
        KeychainIdentity(
            service: BlocksSelectionHelperProtocol.legacyKeychainService,
            account: BlocksSelectionHelperProtocol.legacyKeychainAccount
        )
    }

    private var tombstoneIdentity: KeychainIdentity {
        KeychainIdentity(
            service:
                "\(BlocksSelectionHelperProtocol.keychainService).disconnect-tombstone",
            account: "v1"
        )
    }

    private func assertKeychainQueries(
        _ queries: [CFDictionary],
        identities: [KeychainIdentity],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(queries.count, identities.count, file: file, line: line)
        for (query, identity) in zip(queries, identities) {
            let dictionary = query as NSDictionary
            XCTAssertEqual(
                keychainIdentity(query),
                identity,
                file: file,
                line: line
            )
            XCTAssertEqual(
                dictionary[kSecAttrAccessGroup] as? String,
                testAccessGroup,
                file: file,
                line: line
            )
            XCTAssertEqual(
                (dictionary[kSecUseDataProtectionKeychain] as? NSNumber)?
                    .boolValue,
                true,
                file: file,
                line: line
            )
        }
    }

    private func keychainIdentity(
        _ query: CFDictionary
    ) -> KeychainIdentity? {
        let dictionary = query as NSDictionary
        guard let service = dictionary[kSecAttrService] as? String,
              let account = dictionary[kSecAttrAccount] as? String else {
            return nil
        }
        return KeychainIdentity(service: service, account: account)
    }

    private func isLegacyActiveKeyQuery(_ query: CFDictionary) -> Bool {
        keychainIdentity(query) == legacyActiveKeyIdentity
    }
    #endif
}

#if DEBUG
/// Calls the same closure boundary used by SelectionAgentCaptureWorker. The
/// sequences deliberately model a selection changing during a single AX read.
private final class SelectionTextReadFixture {
    var isPasswordField = false
    var maximumCharacters = 100
    var maximumUTF8Bytes = 400
    var direct: String?
    var ranges: [NSRange?] = [nil]
    var rangeText: String?
    var markers: [Int?] = [nil]
    var markerLength = SelectionHelperMarkerLength.unavailable
    var markerText: String?
    var failure: SelectionAgentFailureCode?
    var interruptAfterStage: String?
    var interruptAfterOccurrence = 1
    var interruptWith = SelectionAgentFailureCode.cancelled
    private(set) var calls: [String] = []
    var trace = SelectionHelperCaptureDiagnostics.Trace()

    func resolve() -> SelectionHelperSelectionTextResolver.Outcome<Int> {
        SelectionHelperSelectionTextResolver.resolve(
            isPasswordField: isPasswordField,
            maximumCharacters: maximumCharacters,
            maximumUTF8Bytes: maximumUTF8Bytes,
            interruption: { self.failure },
            directText: { self.didRead("direct"); return self.direct },
            selectedRange: {
                self.didRead("range")
                return self.ranges.count > 1
                    ? self.ranges.removeFirst() : self.ranges.first ?? nil
            },
            rangeText: { _ in self.didRead("rangeText"); return self.rangeText },
            selectedMarker: {
                self.didRead("marker")
                return self.markers.count > 1
                    ? self.markers.removeFirst() : self.markers.first ?? nil
            },
            markerLength: { _ in
                self.didRead("markerLength")
                return self.markerLength
            },
            markerText: { _ in self.didRead("markerText"); return self.markerText },
            record: { self.trace.record($0, $1) }
        )
    }

    private func didRead(_ stage: String) {
        calls.append(stage)
        if interruptAfterStage == stage,
           calls.filter({ $0 == stage }).count == interruptAfterOccurrence {
            failure = interruptWith
        }
    }
}

private struct KeychainIdentity: Equatable {
    let service: String
    let account: String
}

private final class InspectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}

private final class TestListener: SelectionHelperServer.Listener {
    private let stateHandler: (SelectionHelperServer.ListenerResult) -> Void
    private let initialResult: SelectionHelperServer.ListenerResult?
    private(set) var wasCancelled = false

    init(
        result: SelectionHelperServer.ListenerResult? = nil,
        stateHandler: @escaping (SelectionHelperServer.ListenerResult) -> Void
    ) {
        initialResult = result
        self.stateHandler = stateHandler
    }

    func start(queue: DispatchQueue) {
        if let initialResult {
            emit(initialResult)
        }
    }

    func emit(_ result: SelectionHelperServer.ListenerResult) {
        stateHandler(result)
    }

    func cancel() {
        wasCancelled = true
    }
}

private struct TestListenerFactoryFailure: LocalizedError {
    let description: String

    var errorDescription: String? { description }
}

private enum KeychainOperationKind: Equatable {
    case copy
    case update
    case add
    case delete
}

private final class KeychainOperationSpy {
    private(set) var operationKinds: [KeychainOperationKind] = []
    private(set) var copyQueries: [CFDictionary] = []
    private(set) var updateQueries: [CFDictionary] = []
    private(set) var addQueries: [CFDictionary] = []
    private(set) var deleteQueries: [CFDictionary] = []
    private let copyResult: Data?
    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private let deleteStatuses: [OSStatus]
    private var deleteCallCount = 0

    init(
        copyResult: Data? = nil,
        updateStatus: OSStatus = errSecItemNotFound,
        addStatus: OSStatus = errSecSuccess,
        deleteStatuses: [OSStatus] = [errSecSuccess]
    ) {
        self.copyResult = copyResult
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.deleteStatuses = deleteStatuses
    }

    lazy var copyMatching: (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus = { [unowned self] query, result in
        self.operationKinds.append(.copy)
        self.copyQueries.append(query)
        guard let copyResult = self.copyResult else {
            return errSecItemNotFound
        }
        result?.pointee = copyResult as CFData
        return errSecSuccess
    }

    lazy var updateItem: (CFDictionary, CFDictionary) -> OSStatus = {
        [unowned self] query, _ in
        self.operationKinds.append(.update)
        self.updateQueries.append(query)
        return self.updateStatus
    }

    lazy var addItem: (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus = { [unowned self] query, _ in
        self.operationKinds.append(.add)
        self.addQueries.append(query)
        return self.addStatus
    }

    lazy var deleteItem: (CFDictionary) -> OSStatus = { [unowned self] query in
        self.operationKinds.append(.delete)
        self.deleteQueries.append(query)
        defer { self.deleteCallCount += 1 }
        guard self.deleteStatuses.indices.contains(self.deleteCallCount) else {
            return errSecSuccess
        }
        return self.deleteStatuses[self.deleteCallCount]
    }
}

private struct ValidPairFixture {
    let privateKey: P256.KeyAgreement.PrivateKey
    let request: SelectionHelperPairRequest
}

private final class FixedBootstrapKeyStore: SelectionHelperBootstrapKeyLoading {
    let key: Data

    init(key: Data) {
        self.key = key
    }

    func load() -> Data? { key }
}

private final class InMemoryKeyStore: SelectionHelperKeyStoring {
    var activeKey: Data?
    let legacyKey: Data?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private(set) var markerWriteCount = 0
    private(set) var automaticAssociationDisabled = false
    var rejectMarkerWrites = false
    var rejectDeletes = false

    init(activeKey: Data? = nil, legacyKey: Data? = nil) {
        self.activeKey = activeKey
        self.legacyKey = legacyKey
    }

    func load() -> Data? { activeKey }

    func save(_ data: Data) -> Bool {
        guard data.count == 32 else { return false }
        activeKey = data
        saveCount += 1
        return true
    }

    func delete() -> Bool {
        deleteCount += 1
        guard !rejectDeletes else { return false }
        activeKey = nil
        return true
    }

    func persistAutomaticAssociationDisabled() -> Bool {
        markerWriteCount += 1
        guard !rejectMarkerWrites else { return false }
        automaticAssociationDisabled = true
        return true
    }
    func permitsExplicitAssociationIntent() -> Bool { activeKey == nil && legacyKey == nil }
    func prepareExplicitLocalAssociation() -> Bool {
        guard permitsExplicitAssociationIntent() else { return false }
        automaticAssociationDisabled = false
        return true
    }
    func permitsAuthenticatedUse() -> Bool { !automaticAssociationDisabled }

    func replaceActiveKeyWithDisconnectTombstone(expiresAt: Date) -> Bool { false }
    func loadDisconnectTombstone(now: Date) -> Data? { nil }
    func clearDisconnectTombstone() -> Bool { true }
}

private final class LockedResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data?] = []

    func append(_ data: Data?) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var values: [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ConcurrentStartGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func waitToStart(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while !isOpen {
            guard condition.wait(until: deadline) else { return isOpen }
        }
        return true
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}
#endif
