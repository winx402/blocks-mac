import AppKit
import BlocksCore
import Darwin
import Foundation
import XCTest
@testable import Blocks

@MainActor
final class ClipboardBrokerBehaviorTests: XCTestCase {
    func testEarlyRejectionsDoNotReadTypesOrRepresentations() async throws {
        let scenarios: [
            (
                ClipboardBrokerObserveRequest,
                ClipboardBrokerObservationStatus,
                ClipboardBrokerSkipReason?
            )
        ] = [
            (
                ClipboardBrokerObserveRequest(
                    baselineChangeCount: -1,
                    suppressedChangeCounts: [0]
                ),
                .skipped,
                .selfWrite
            ),
            (
                ClipboardBrokerObserveRequest(
                    baselineChangeCount: -1,
                    prefilterDisposition: .redactPaused
                ),
                .redacted,
                nil
            ),
        ]

        for (requestTemplate, expectedStatus, expectedReason) in scenarios {
            let fixture = try makeFixture()
            defer { fixture.removeTrace() }
            let provider = PromisedRepresentationProvider(
                strings: [.string: "must-not-be-requested"]
            )
            let changeCount = try publish(
                provider: provider,
                types: [.string],
                to: fixture.pasteboard
            )
            var request = requestTemplate
            if request.suppressedChangeCounts == [0] {
                request = ClipboardBrokerObserveRequest(
                    baselineChangeCount: changeCount - 1,
                    suppressedChangeCounts: [changeCount]
                )
            } else {
                request = ClipboardBrokerObserveRequest(
                    baselineChangeCount: changeCount - 1,
                    prefilterDisposition: request.prefilterDisposition
                )
            }

            let client = try makeClient(fixture: fixture)
            let brokerBaseline = try await client.baseline()
            XCTAssertEqual(brokerBaseline, changeCount)
            let result = try await client.observe(request)
            await client.shutdown()

            XCTAssertEqual(result.status, expectedStatus)
            XCTAssertEqual(result.skipReason, expectedReason)
            let trace = try readTrace(fixture.traceURL)
            XCTAssertEqual(trace.typesReadCount, 0)
            XCTAssertEqual(trace.stringReadCount, 0)
            XCTAssertEqual(trace.dataReadCount, 0)
            XCTAssertEqual(provider.requestedTypes, [])
        }
    }

    func testPoisonedChangeDoesNotReadTypesOrRepresentations() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let provider = PromisedRepresentationProvider(
            strings: [.string: "must-not-be-requested"]
        )
        let changeCount = try publish(
            provider: provider,
            types: [.string],
            to: fixture.pasteboard
        )
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "block_observe_after_start",
            ]
        )
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, changeCount)

        do {
            _ = try await client.observe(
                ClipboardBrokerObserveRequest(
                    baselineChangeCount: changeCount - 1
                )
            )
            XCTFail("The injected observe stall must time out.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestTimedOut
            )
        }

        let restartBaseline = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: changeCount - 1
            )
        )
        XCTAssertEqual(restartBaseline.status, .noChange)
        let poisoned = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: changeCount - 1
            )
        )
        await client.shutdown()

        XCTAssertEqual(poisoned.status, .skipped)
        XCTAssertEqual(poisoned.skipReason, .poisonedChange)
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.typesReadCount, 0)
        XCTAssertEqual(trace.stringReadCount, 0)
        XCTAssertEqual(trace.dataReadCount, 0)
        XCTAssertEqual(provider.requestedTypes, [])
    }

    func testSensitiveAndRemoteMarkersReadTypesOnceWithoutRepresentations() async throws {
        for marker in [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("com.apple.is-remote-clipboard"),
        ] {
            let fixture = try makeFixture()
            defer { fixture.removeTrace() }
            let provider = PromisedRepresentationProvider(
                strings: [.string: "must-not-be-requested"]
            )
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            XCTAssertTrue(item.setData(Data(), forType: marker))
            fixture.pasteboard.clearContents()
            XCTAssertTrue(fixture.pasteboard.writeObjects([item]))
            let changeCount = fixture.pasteboard.changeCount

            let client = try makeClient(fixture: fixture)
            let brokerBaseline = try await client.baseline()
            XCTAssertEqual(brokerBaseline, changeCount)
            let result = try await client.observe(
                ClipboardBrokerObserveRequest(
                    baselineChangeCount: changeCount - 1
                )
            )
            await client.shutdown()

            XCTAssertEqual(result.status, .skipped)
            XCTAssertTrue(
                result.skipReason == .sensitiveMarker
                    || result.skipReason == .remoteClipboard
            )
            let trace = try readTrace(fixture.traceURL)
            XCTAssertEqual(trace.typesReadCount, 1)
            XCTAssertEqual(trace.stringReadCount, 0)
            XCTAssertEqual(trace.dataReadCount, 0)
            XCTAssertEqual(provider.requestedTypes, [])
        }
    }

    func testCompatibilitySnapshotRejectsSensitiveItemBeforeReadingSiblingText()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let provider = PromisedRepresentationProvider(
            strings: [.string: "must-not-be-requested"]
        )
        let sensitive = NSPasteboard.PasteboardType(
            "org.nspasteboard.ConcealedType"
        )
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(item.setData(Data(), forType: sensitive))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([item]))

        let client = try makeClient(fixture: fixture)
        let result = try await client.snapshot()
        await client.shutdown()

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.unsupportedTypes, [sensitive.rawValue])
        XCTAssertEqual(provider.requestedTypes, [])
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.stringReadCount, 0)
        XCTAssertEqual(trace.dataReadCount, 0)
    }

    func testCompatibilitySnapshotCapturesRestorablePlainText() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString(
            "restorable",
            forType: .string
        ))

        let client = try makeClient(fixture: fixture)
        let result = try await client.snapshot()
        await client.shutdown()

        XCTAssertEqual(result.status, .captured)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(
            result.items.first?.representations,
            [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType:
                        NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("restorable")
                ),
            ]
        )
    }

    func testScreenSharingUnknownItemDefersWithoutReadingRepresentation() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let provider = PromisedRepresentationProvider(
            strings: [.string: "deferred fixture"]
        )
        let changeCount = try publish(
            provider: provider,
            types: [.string],
            to: fixture.pasteboard
        )
        let client = try makeClient(fixture: fixture)
        _ = try await client.baseline()

        let deferred = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: changeCount - 1,
                screenSharingActive: true
            )
        )

        XCTAssertEqual(deferred.status, .deferred)
        XCTAssertNil(deferred.representation)
        XCTAssertEqual(deferred.resolutionTicket?.changeCount, changeCount)
        XCTAssertEqual(deferred.resolutionTicket?.family, .text)
        XCTAssertEqual(provider.requestedTypes, [])
        var trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.typesReadCount, 1)
        XCTAssertEqual(trace.stringReadCount + trace.dataReadCount, 0)

        let ticket = try XCTUnwrap(deferred.resolutionTicket)
        let resolved = try await client.resolve(
            ticket: ticket,
            timeout: .seconds(1)
        )
        await client.shutdown()

        XCTAssertEqual(resolved.status, .captured)
        XCTAssertEqual(resolved.representation?.plainText, "deferred fixture")
        XCTAssertEqual(provider.requestedTypes, [.string])
        trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.typesReadCount, 1)
        XCTAssertEqual(trace.stringReadCount + trace.dataReadCount, 1)
    }

    func testStaleResolutionTicketDoesNotReadRepresentation() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let provider = PromisedRepresentationProvider(
            strings: [.string: "must-not-be-requested"]
        )
        let changeCount = try publish(
            provider: provider,
            types: [.string],
            to: fixture.pasteboard
        )
        let client = try makeClient(fixture: fixture)
        _ = try await client.baseline()
        let ticket = ClipboardBrokerResolutionTicket(
            changeCount: changeCount - 1,
            family: .text,
            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
            advertisedTypes: [NSPasteboard.PasteboardType.string.rawValue]
        )

        let resolved = try await client.resolve(
            ticket: ticket,
            timeout: .seconds(1)
        )
        await client.shutdown()

        XCTAssertEqual(resolved.status, .skipped)
        XCTAssertEqual(resolved.skipReason, .stale)
        XCTAssertEqual(provider.requestedTypes, [])
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.stringReadCount + trace.dataReadCount, 0)
    }

    func testStaleResolutionDoesNotConsumeTheFollowingChange() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let firstProvider = PromisedRepresentationProvider(
            strings: [.string: "stale item"]
        )
        let firstChangeCount = try publish(
            provider: firstProvider,
            types: [.string],
            to: fixture.pasteboard
        )
        let client = try makeClient(fixture: fixture)
        _ = try await client.baseline()
        let deferred = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: firstChangeCount - 1,
                screenSharingActive: true
            )
        )
        let ticket = try XCTUnwrap(deferred.resolutionTicket)

        let nextProvider = PromisedRepresentationProvider(
            strings: [.string: "following item"]
        )
        let nextChangeCount = try publish(
            provider: nextProvider,
            types: [.string],
            to: fixture.pasteboard
        )
        let stale = try await client.resolve(
            ticket: ticket,
            timeout: .seconds(1)
        )
        let following = try await client.observe(
            ClipboardBrokerObserveRequest(baselineChangeCount: nil)
        )
        await client.shutdown()

        XCTAssertEqual(stale.status, .skipped)
        XCTAssertEqual(stale.skipReason, .stale)
        XCTAssertEqual(stale.observedAfterChangeCount, nextChangeCount)
        XCTAssertEqual(firstProvider.requestedTypes, [])
        XCTAssertEqual(following.status, .captured)
        XCTAssertEqual(following.changeCount, nextChangeCount)
        XCTAssertEqual(following.representation?.plainText, "following item")
        XCTAssertEqual(nextProvider.requestedTypes, [.string])
    }

    func testRepresentationPriorityRequestsExactlyOneProvider() async throws {
        let image = try imageRepresentations()
        let rtf = try rtfData("RTF priority")
        let cases: [
            (
                types: [NSPasteboard.PasteboardType],
                strings: [NSPasteboard.PasteboardType: String],
                data: [NSPasteboard.PasteboardType: Data],
                expectedFamily: ClipboardBrokerRepresentationFamily,
                expectedType: NSPasteboard.PasteboardType
            )
        ] = [
            (
                [.fileURL, .png, .tiff],
                [.fileURL: "file:///tmp/blocks-image.png"],
                [.png: image.png, .tiff: image.tiff],
                .imagePNG,
                .png
            ),
            (
                [.png, .tiff, .URL, .rtf, .string],
                [.URL: "https://example.invalid", .string: "text"],
                [.png: image.png, .tiff: image.tiff, .rtf: rtf],
                .imagePNG,
                .png
            ),
            (
                [.tiff, .URL, .rtf, .string],
                [.URL: "https://example.invalid", .string: "text"],
                [.tiff: image.tiff, .rtf: rtf],
                .imageTIFF,
                .tiff
            ),
            (
                [.URL, .rtf, .string],
                [.URL: "https://example.invalid", .string: "text"],
                [.rtf: rtf],
                .url,
                .URL
            ),
            (
                [.string],
                [.string: "text"],
                [:],
                .text,
                .string
            ),
            (
                [.fileURL],
                [.fileURL: "file:///tmp/blocks-file-url-only"],
                [:],
                .fileURL,
                .fileURL
            ),
        ]

        for testCase in cases {
            let fixture = try makeFixture()
            defer { fixture.removeTrace() }
            let provider = PromisedRepresentationProvider(
                strings: testCase.strings,
                data: testCase.data
            )
            let changeCount = try publish(
                provider: provider,
                types: testCase.types,
                to: fixture.pasteboard
            )
            let client = try makeClient(fixture: fixture)
            let brokerBaseline = try await client.baseline()
            XCTAssertEqual(brokerBaseline, changeCount)

            let result = try await client.observe(
                ClipboardBrokerObserveRequest(
                    baselineChangeCount: changeCount - 1
                )
            )
            await client.shutdown()

            XCTAssertEqual(result.status, .captured)
            XCTAssertEqual(result.representation?.family, testCase.expectedFamily)
            XCTAssertEqual(
                result.representation?.pasteboardType,
                testCase.expectedType.rawValue
            )
            XCTAssertEqual(provider.requestedTypes, [testCase.expectedType])
            let trace = try readTrace(fixture.traceURL)
            XCTAssertEqual(trace.typesReadCount, 1)
            XCTAssertEqual(
                trace.stringReadCount + trace.dataReadCount,
                1
            )
        }
    }

    func testScreenSharingResolutionPrefersPNGOverCompoundFileURL() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let image = try imageRepresentations()
        let provider = PromisedRepresentationProvider(
            strings: [.fileURL: "file:///tmp/blocks-screen-sharing-image.png"],
            data: [.png: image.png, .tiff: image.tiff]
        )
        let changeCount = try publish(
            provider: provider,
            types: [.fileURL, .png, .tiff],
            to: fixture.pasteboard
        )
        let client = try makeClient(fixture: fixture)
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, changeCount)
        let deferred = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: changeCount - 1,
                screenSharingActive: true
            )
        )

        XCTAssertEqual(deferred.status, .deferred)
        let ticket = try XCTUnwrap(deferred.resolutionTicket)
        XCTAssertEqual(ticket.family, .imagePNG)
        XCTAssertEqual(ticket.pasteboardType, NSPasteboard.PasteboardType.png.rawValue)
        XCTAssertEqual(provider.requestedTypes, [])

        let resolved = try await client.resolve(ticket: ticket, timeout: .seconds(1))
        await client.shutdown()

        XCTAssertEqual(resolved.status, .captured)
        XCTAssertEqual(resolved.representation?.family, .imagePNG)
        XCTAssertEqual(provider.requestedTypes, [.png])
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.requestedDataTypes, [NSPasteboard.PasteboardType.png.rawValue])
        XCTAssertEqual(trace.requestedStringTypes, [])
    }

    func testPNGFailureDoesNotFallBackToTIFF() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let image = try imageRepresentations()
        let provider = PromisedRepresentationProvider(
            data: [.tiff: image.tiff]
        )
        let changeCount = try publish(
            provider: provider,
            types: [.png, .tiff],
            to: fixture.pasteboard
        )
        let client = try makeClient(fixture: fixture)
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, changeCount)

        let result = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: changeCount - 1
            )
        )
        await client.shutdown()

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.skipReason, .unsupported)
        XCTAssertEqual(provider.requestedTypes, [.png])
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.typesReadCount, 1)
        XCTAssertEqual(
            trace.requestedDataTypes,
            [NSPasteboard.PasteboardType.png.rawValue]
        )
        XCTAssertEqual(trace.dataReadCount, 1)
        XCTAssertEqual(trace.stringReadCount, 0)
    }

    func testRTFDerivesPlainTextWithoutStringRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let provider = PromisedRepresentationProvider(
            strings: [.string: "wrong fallback"],
            data: [.rtf: try rtfData("Locally derived")]
        )
        let changeCount = try publish(
            provider: provider,
            types: [.rtf, .string],
            to: fixture.pasteboard
        )
        let client = try makeClient(fixture: fixture)
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, changeCount)

        let result = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: changeCount - 1
            )
        )
        await client.shutdown()

        XCTAssertEqual(result.status, .captured)
        XCTAssertEqual(result.representation?.family, .richText)
        XCTAssertEqual(result.representation?.plainText, "Locally derived")
        XCTAssertEqual(provider.requestedTypes, [.rtf])
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.typesReadCount, 1)
        XCTAssertEqual(
            trace.requestedDataTypes,
            [NSPasteboard.PasteboardType.rtf.rawValue]
        )
        XCTAssertEqual(trace.stringReadCount, 0)
    }

    func testFileURLCaptureDoesNotOpenReferencedFIFO() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let fifoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blocks-clipboard-broker-\(UUID().uuidString).fifo",
                isDirectory: false
            ).path
        XCTAssertEqual(Darwin.mkfifo(fifoPath, 0o600), 0)
        defer { _ = Darwin.unlink(fifoPath) }
        let provider = PromisedRepresentationProvider(
            strings: [
                .fileURL: URL(fileURLWithPath: fifoPath).absoluteString,
                .string: "wrong fallback",
            ]
        )
        let changeCount = try publish(
            provider: provider,
            types: [.fileURL, .string],
            to: fixture.pasteboard
        )
        let client = try makeClient(fixture: fixture)
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, changeCount)

        let result = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: changeCount - 1
            )
        )
        await client.shutdown()

        XCTAssertEqual(result.status, .captured)
        XCTAssertEqual(result.representation?.family, .fileURL)
        XCTAssertEqual(provider.requestedTypes, [.fileURL])
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.typesReadCount, 1)
        XCTAssertEqual(
            trace.requestedStringTypes,
            [NSPasteboard.PasteboardType.fileURL.rawValue]
        )
        XCTAssertEqual(trace.dataReadCount, 0)
    }

    func testExpectedChangeCountMismatchDoesNotClearOrWrite() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let currentChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(fixture: fixture)

        do {
            _ = try await client.write(
                ClipboardBrokerWriteRequest(
                    items: [
                        ClipboardBrokerWriteItem(representations: [
                            ClipboardBrokerWriteRepresentationEntry(
                                pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                                value: .string("replacement")
                            ),
                        ]),
                    ],
                    expectedChangeCount: currentChangeCount - 1
                )
            )
            XCTFail("The stale expected change count must reject the write.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }
        await client.shutdown()

        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "original"
        )
        XCTAssertEqual(fixture.pasteboard.changeCount, currentChangeCount)
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 0)
        XCTAssertEqual(trace.writeCount, 0)
    }

    func testExternalWriteBeforeClearIsPreservedAndObserved() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let pauseID = UUID()
        let pauseReadyURL = brokerPauseSignalURL(
            id: pauseID,
            suffix: "ready"
        )
        let pauseReleaseURL = brokerPauseSignalURL(
            id: pauseID,
            suffix: "release"
        )
        defer {
            try? FileManager.default.removeItem(at: pauseReadyURL)
            try? FileManager.default.removeItem(at: pauseReleaseURL)
        }
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT": "pause_before_clear",
                "BLOCKS_CLIPBOARD_BROKER_TEST_PAUSE_READY_PATH": pauseReadyURL.path,
                "BLOCKS_CLIPBOARD_BROKER_TEST_PAUSE_RELEASE_PATH": pauseReleaseURL.path,
            ]
        )
        let writeTask = Task { () -> ClipboardBrokerClientError? in
            do {
                _ = try await client.write(ClipboardBrokerWriteRequest(
                    items: [ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string("target")
                        ),
                    ])],
                    expectedChangeCount: originalChangeCount
                ))
                return nil
            } catch {
                return error as? ClipboardBrokerClientError
            }
        }

        try await waitForFile(at: pauseReadyURL)
        let sentinelItem = NSPasteboardItem()
        sentinelItem.setString("sentinel", forType: .string)
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([sentinelItem]))
        let sentinelChangeCount = fixture.pasteboard.changeCount
        XCTAssertNotEqual(sentinelChangeCount, originalChangeCount)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: pauseReleaseURL.path,
                contents: Data()
            )
        )

        let writeError = await writeTask.value
        XCTAssertEqual(writeError, .writeChanged)
        let observed = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: nil
        ))
        await client.shutdown()

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "sentinel")
        XCTAssertEqual(observed.status, .captured)
        XCTAssertEqual(observed.changeCount, sentinelChangeCount)
        XCTAssertEqual(observed.representation?.plainText, "sentinel")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 0)
        XCTAssertEqual(trace.writeCount, 0)
    }

    func testSemanticFileWriteReturningTrueWithoutReadablePublicationReportsChanged()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let targetURL = try temporaryFileURL(prefix: "blocks-unreadable-target")
        defer { try? FileManager.default.removeItem(at: targetURL) }
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "target_write_returns_true_but_semantic_file_unreadable",
            ]
        )

        do {
            _ = try await client.write(ClipboardBrokerWriteRequest(
                items: [ClipboardBrokerWriteItem(
                    representations: [],
                    semanticFileURLString: targetURL.absoluteString
                )],
                expectedChangeCount: originalChangeCount
            ))
            XCTFail("An unprovable target publication must not return a lease.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }
        await client.shutdown()

        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testOrdinaryRepresentationVerifierReportsChangedForUnprovableMismatch()
        async throws
    {
        let cases: [ClipboardBrokerWriteRepresentationEntry] = [
            ClipboardBrokerWriteRepresentationEntry(
                pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                value: .string("plain target")
            ),
            ClipboardBrokerWriteRepresentationEntry(
                pasteboardType: NSPasteboard.PasteboardType.html.rawValue,
                value: .string("<p>target</p>")
            ),
            ClipboardBrokerWriteRepresentationEntry(
                pasteboardType: NSPasteboard.PasteboardType.URL.rawValue,
                value: .string("https://example.invalid/target")
            ),
            ClipboardBrokerWriteRepresentationEntry(
                pasteboardType: NSPasteboard.PasteboardType.rtf.rawValue,
                value: .data(.inline(Data("{\\rtf1\\ansi target}".utf8)))
            ),
            ClipboardBrokerWriteRepresentationEntry(
                pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
                value: .data(.inline(Data([0x89, 0x50, 0x4e, 0x47])))
            ),
            ClipboardBrokerWriteRepresentationEntry(
                pasteboardType: NSPasteboard.PasteboardType.tiff.rawValue,
                value: .data(.inline(Data([0x49, 0x49, 0x2a, 0x00])))
            ),
        ]

        for representation in cases {
            let fixture = try makeFixture()
            defer { fixture.removeTrace() }
            fixture.pasteboard.clearContents()
            XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
            let originalChangeCount = fixture.pasteboard.changeCount
            let client = try makeClient(
                fixture: fixture,
                extraEnvironment: [
                    "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                    "target_write_returns_true_but_representation_mismatched",
                ]
            )

            do {
                _ = try await client.write(ClipboardBrokerWriteRequest(
                    items: [ClipboardBrokerWriteItem(
                        representations: [representation]
                    )],
                    expectedChangeCount: originalChangeCount
                ))
                XCTFail("An unprovable byte mismatch must not return a lease.")
            } catch {
                XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
            }
            await client.shutdown()

            let trace = try readTrace(fixture.traceURL)
            XCTAssertEqual(trace.clearCount, 1)
            XCTAssertEqual(trace.writeCount, 1)
            XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
            XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
        }
    }

    func testExternalWriteBeforeTargetNativeChangeCountIsPreservedAndObserved()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "target_write_succeeds_then_external_replaces_before_native_write_change_count",
            ]
        )

        do {
            _ = try await client.write(ClipboardBrokerWriteRequest(
                items: [ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("target")
                    ),
                ])],
                expectedChangeCount: originalChangeCount
            ))
            XCTFail("An externally replaced target must report changed.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }

        let sentinelChangeCount = fixture.pasteboard.changeCount
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "external sentinel")
        let observed = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: nil
        ))
        await client.shutdown()

        XCTAssertEqual(observed.status, .captured)
        XCTAssertEqual(observed.changeCount, sentinelChangeCount)
        XCTAssertEqual(observed.representation?.plainText, "external sentinel")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testTargetFalseBeforeFirstSamplePreservesCompoundExternalPublisher()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let originalURL = try temporaryFileURL(prefix: "blocks-compound-race-original")
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let image = try imageRepresentations()
        let originalItem = NSPasteboardItem()
        XCTAssertTrue(originalItem.setString(
            originalURL.absoluteString,
            forType: .fileURL
        ))
        XCTAssertTrue(originalItem.setData(image.png, forType: .png))
        XCTAssertTrue(originalItem.setData(image.tiff, forType: .tiff))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([originalItem]))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "target_fails_and_external_replaces_compound_before_native_write_change_count",
            ]
        )

        do {
            _ = try await client.write(ClipboardBrokerWriteRequest(
                items: [ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("target")
                    ),
                ])],
                expectedChangeCount: originalChangeCount
            ))
            XCTFail("An external replacement before the first sample must report changed.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }
        await client.shutdown()

        let sentinelItem = try XCTUnwrap(fixture.pasteboard.pasteboardItems?.first)
        XCTAssertEqual(sentinelItem.string(forType: .string), "external sentinel")
        XCTAssertNil(sentinelItem.data(forType: .png))
        XCTAssertNil(sentinelItem.data(forType: .tiff))
        XCTAssertTrue(
            (fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.isEmpty
                ?? true
        )
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testExternalWriteBeforeNativeWriteChangeCountIsNotContaminatedOrSuppressed()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let originalURL = try temporaryFileURL(prefix: "blocks-compound-race-original")
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let image = try imageRepresentations()
        let originalItem = NSPasteboardItem()
        XCTAssertTrue(originalItem.setString(
            originalURL.absoluteString,
            forType: .fileURL
        ))
        XCTAssertTrue(originalItem.setData(image.png, forType: .png))
        XCTAssertTrue(originalItem.setData(image.tiff, forType: .tiff))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([originalItem]))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "target_fails_and_external_replaces_compound_before_native_write_change_count",
            ]
        )

        do {
            _ = try await client.write(ClipboardBrokerWriteRequest(
                items: [ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("target")
                    ),
                ])],
                expectedChangeCount: originalChangeCount
            ))
            XCTFail("A pre-sampling external replacement must report changed.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }

        let sentinelChangeCount = fixture.pasteboard.changeCount
        let sentinelItem = try XCTUnwrap(fixture.pasteboard.pasteboardItems?.first)
        XCTAssertEqual(sentinelItem.string(forType: .string), "external sentinel")
        XCTAssertNil(sentinelItem.data(forType: .png))
        XCTAssertNil(sentinelItem.data(forType: .tiff))
        XCTAssertNil(sentinelItem.string(forType: .fileURL))
        XCTAssertTrue(
            (fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.isEmpty
                ?? true
        )

        let observed = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: nil
        ))
        await client.shutdown()

        XCTAssertEqual(observed.status, .captured)
        XCTAssertEqual(observed.changeCount, sentinelChangeCount)
        XCTAssertEqual(observed.representation?.plainText, "external sentinel")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testExternalWriteAfterTargetPublicationIsNotRolledBackOrSuppressed()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT": "pause_after_target_write",
            ]
        )
        let writeTask = Task { () -> ClipboardBrokerClientError? in
            do {
                _ = try await client.write(ClipboardBrokerWriteRequest(
                    items: [ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string("target")
                        ),
                    ])],
                    expectedChangeCount: originalChangeCount
                ))
                return nil
            } catch {
                return error as? ClipboardBrokerClientError
            }
        }

        try await waitForPasteboardString(
            "target",
            on: fixture.pasteboard
        )
        let sentinelItem = NSPasteboardItem()
        XCTAssertTrue(sentinelItem.setString("sentinel", forType: .string))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([sentinelItem]))
        let sentinelChangeCount = fixture.pasteboard.changeCount

        let writeError = await writeTask.value
        XCTAssertEqual(writeError, .writeChanged)
        // The changed result must leave this external count observable rather
        // than adding it to the client's self-write suppression set.
        let observed = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: nil
        ))
        await client.shutdown()

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "sentinel")
        XCTAssertEqual(observed.status, .captured)
        XCTAssertEqual(observed.changeCount, sentinelChangeCount)
        XCTAssertEqual(observed.representation?.plainText, "sentinel")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testExternalWriteAfterTargetVerificationDoesNotReturnLeaseOrSuppress()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "target_verified_then_external_replaces_before_terminal_sample",
            ]
        )

        do {
            _ = try await client.write(ClipboardBrokerWriteRequest(
                items: [ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("target")
                    ),
                ])],
                expectedChangeCount: originalChangeCount
            ))
            XCTFail("An external write after verification must not return a lease.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }

        let sentinelChangeCount = fixture.pasteboard.changeCount
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "external sentinel")
        let observed = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: nil
        ))
        await client.shutdown()

        XCTAssertEqual(observed.status, .captured)
        XCTAssertEqual(observed.changeCount, sentinelChangeCount)
        XCTAssertEqual(observed.representation?.plainText, "external sentinel")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testExternalWriteBeforeRollbackFinalFenceIsPreservedAndObserved()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "pause_before_rollback_final_fence",
            ]
        )
        let writeTask = Task { () -> ClipboardBrokerClientError? in
            do {
                _ = try await client.write(ClipboardBrokerWriteRequest(
                    items: [ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string("target")
                        ),
                    ])],
                    expectedChangeCount: originalChangeCount
                ))
                return nil
            } catch {
                return error as? ClipboardBrokerClientError
            }
        }

        try await waitForPasteboardString(
            "mismatched target",
            on: fixture.pasteboard
        )
        let sentinelItem = NSPasteboardItem()
        XCTAssertTrue(sentinelItem.setString("sentinel", forType: .string))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([sentinelItem]))
        let sentinelChangeCount = fixture.pasteboard.changeCount

        let writeError = await writeTask.value
        XCTAssertEqual(writeError, .writeChanged)
        _ = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: sentinelChangeCount
        ))
        let observed = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: sentinelChangeCount - 1
        ))
        await client.shutdown()

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "sentinel")
        XCTAssertEqual(observed.status, .captured)
        XCTAssertEqual(observed.changeCount, sentinelChangeCount)
        XCTAssertEqual(observed.representation?.plainText, "sentinel")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testTargetFalseWithoutExternalChangeFailsWithoutRestoring()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "fail_write_after_clear",
            ]
        )

        do {
            _ = try await client.write(ClipboardBrokerWriteRequest(
                items: [ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("replacement")
                    ),
                ])],
                expectedChangeCount: originalChangeCount
            ))
            XCTFail("A failed target publication must not return a lease.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)
        }
        await client.shutdown()

        XCTAssertNil(fixture.pasteboard.string(forType: .string))
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testPreparedFileURLCompoundFailureDoesNotRestoreOriginalRepresentations()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let originalURL = try temporaryFileURL(prefix: "blocks-rollback-original")
        let targetURL = try temporaryFileURL(prefix: "blocks-rollback-target")
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let image = try imageRepresentations()
        let originalItem = NSPasteboardItem()
        XCTAssertTrue(originalItem.setString(
            originalURL.absoluteString,
            forType: .fileURL
        ))
        XCTAssertTrue(originalItem.setData(image.png, forType: .png))
        XCTAssertTrue(originalItem.setData(image.tiff, forType: .tiff))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([originalItem]))
        let originalChangeCount = fixture.pasteboard.changeCount

        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT": "fail_write_after_clear",
            ]
        )
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(
                representations: [],
                semanticFileURLString: targetURL.absoluteString
            )],
            expectedChangeCount: originalChangeCount
        ))

        do {
            _ = try await client.commit(prepared)
            XCTFail("The injected target write failure must be surfaced.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)
        }
        await client.shutdown()

        XCTAssertTrue(fixture.pasteboard.pasteboardItems?.isEmpty ?? true)
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
    }

    func testPreparedFileURLCompoundCommitDoesNotRequirePriorSnapshot()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let originalURL = try temporaryFileURL(prefix: "blocks-compound-original")
        let targetURL = try temporaryFileURL(prefix: "blocks-compound-target")
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let image = try imageRepresentations()
        let originalItem = NSPasteboardItem()
        XCTAssertTrue(originalItem.setString(
            originalURL.absoluteString,
            forType: .fileURL
        ))
        XCTAssertTrue(originalItem.setData(image.png, forType: .png))
        XCTAssertTrue(originalItem.setData(image.tiff, forType: .tiff))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([originalItem]))
        let originalChangeCount = fixture.pasteboard.changeCount

        let client = try makeClient(fixture: fixture)
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(
                representations: [],
                semanticFileURLString: targetURL.absoluteString
            )],
            expectedChangeCount: originalChangeCount
        ))
        _ = try await client.commit(prepared)
        await client.shutdown()

        let resultingURLs = fixture.pasteboard.readObjects(
            forClasses: [NSURL.self]
        ) as? [URL]
        XCTAssertEqual(resultingURLs, [targetURL])
    }

    func testPreparedWriteRejectsPassiveObservationWithoutLosingCommitState()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(fixture: fixture)
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, originalChangeCount)

        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("prepared target")
                ),
            ])],
            expectedChangeCount: originalChangeCount
        ))
        let preparedDiagnostics = await client.diagnostics()

        do {
            _ = try await client.observe(ClipboardBrokerObserveRequest(
                baselineChangeCount: nil
            ))
            XCTFail("Passive observation must wait until the prepared write settles.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }
        do {
            _ = try await client.baseline()
            XCTFail("A passive baseline must not terminate the prepared-write Broker.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }

        _ = try await client.commit(prepared)
        let committedDiagnostics = await client.diagnostics()
        await client.shutdown()

        XCTAssertEqual(
            committedDiagnostics.processIdentifier,
            preparedDiagnostics.processIdentifier
        )
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "prepared target"
        )
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
    }

    func testPreparedWriteSurvivesClientIdleReapUntilCommit() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(fixture: fixture)
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("prepared after idle")
                ),
            ])],
            expectedChangeCount: originalChangeCount
        ))
        let preparedDiagnostics = await client.diagnostics()
        let preparedPID = try XCTUnwrap(preparedDiagnostics.processIdentifier)

        try await Task.sleep(for: .milliseconds(1_750))
        let afterIdlePID = await client.diagnostics().processIdentifier
        _ = try await client.commit(prepared)
        await client.shutdown()

        XCTAssertEqual(afterIdlePID, preparedPID)
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "prepared after idle"
        )
    }

    func testExpiredPreparedWriteRestoresPassiveObservationAndIdleReap()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_PREPARED_WRITE_LIFETIME": "0.20",
            ]
        )
        _ = try await client.baseline()
        let abandoned = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("abandoned target")
                ),
            ])],
            expectedChangeCount: originalChangeCount
        ))
        let preparedDiagnostics = await client.diagnostics()
        let preparedProcessIdentifier = try XCTUnwrap(
            preparedDiagnostics.processIdentifier
        )

        do {
            _ = try await client.baseline()
            XCTFail("An unexpired prepared lease must block passive work.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }

        try await Task.sleep(for: .milliseconds(350))
        let processAfterExpiry = await client.diagnostics().processIdentifier
        XCTAssertEqual(processAfterExpiry, preparedProcessIdentifier)
        let restoredBaseline = try await client.baseline()
        XCTAssertEqual(restoredBaseline, originalChangeCount)
        do {
            _ = try await client.commit(abandoned)
            XCTFail("An expired prepared lease must be rejected locally.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }

        try await Task.sleep(for: .milliseconds(1_700))
        let reapedProcessIdentifier = await client.diagnostics().processIdentifier
        XCTAssertNil(reapedProcessIdentifier)
        await client.shutdown()
    }

    func testExpiredFirstPreparedWriteDoesNotUnblockSecondLease()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_PREPARED_WRITE_LIFETIME": "0.50",
            ]
        )
        _ = try await client.baseline()
        let first = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("first")
                ),
            ])],
            expectedChangeCount: originalChangeCount
        ))

        try await Task.sleep(for: .milliseconds(350))
        let second = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("second")
                ),
            ])],
            expectedChangeCount: originalChangeCount
        ))

        try await Task.sleep(for: .milliseconds(300))
        do {
            _ = try await client.cancel(first)
            XCTFail("The first prepared lease must have expired.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }
        do {
            _ = try await client.baseline()
            XCTFail("The still-valid second lease must block passive work.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }

        _ = try await client.commit(second)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "second")
        let restoredBaseline = try await client.baseline()
        XCTAssertEqual(restoredBaseline, fixture.pasteboard.changeCount)

        try await Task.sleep(for: .milliseconds(1_700))
        let reapedProcessIdentifier = await client.diagnostics().processIdentifier
        XCTAssertNil(reapedProcessIdentifier)
        await client.shutdown()
    }

    func testOneExpiredAndOneCancelledPreparedWriteRestoresPassiveWork()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_PREPARED_WRITE_LIFETIME": "0.30",
            ]
        )
        _ = try await client.baseline()
        let first = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("first")
                ),
            ])],
            expectedChangeCount: originalChangeCount
        ))
        let second = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("second")
                ),
            ])],
            expectedChangeCount: originalChangeCount
        ))
        try await client.cancel(second)

        do {
            _ = try await client.baseline()
            XCTFail("The remaining unexpired lease must keep passive work blocked.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }

        try await Task.sleep(for: .milliseconds(450))
        let restoredBaseline = try await client.baseline()
        XCTAssertEqual(restoredBaseline, originalChangeCount)
        do {
            _ = try await client.cancel(first)
            XCTFail("The expired lease must no longer be outstanding in the client.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .requestSuperseded)
        }
        await client.shutdown()
    }

    func testSensitiveExistingRepresentationDoesNotBlockWriteOrPreparedCommit()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let sensitiveType = NSPasteboard.PasteboardType(
            "org.nspasteboard.ConcealedType"
        )
        let privateItem = NSPasteboardItem()
        XCTAssertTrue(privateItem.setData(Data(), forType: sensitiveType))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([privateItem]))

        let client = try makeClient(fixture: fixture)
        let firstBaseline = try await client.baseline()
        _ = try await client.write(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("direct target")
                ),
            ])],
            expectedChangeCount: firstBaseline
        ))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "direct target")

        let secondPrivateItem = NSPasteboardItem()
        XCTAssertTrue(secondPrivateItem.setData(Data(), forType: sensitiveType))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([secondPrivateItem]))
        let secondBaseline = fixture.pasteboard.changeCount
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("prepared target")
                ),
            ])],
            expectedChangeCount: secondBaseline
        ))
        _ = try await client.commit(prepared)
        await client.shutdown()

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "prepared target")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 2)
        XCTAssertEqual(trace.writeCount, 2)
    }

    func testPreparedFileURLMissingAtCommitFailsBeforePasteboardMutation()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("keep me", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let targetURL = try temporaryFileURL(prefix: "blocks-missing-at-commit")
        let client = try makeClient(fixture: fixture)
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(
                representations: [],
                semanticFileURLString: targetURL.absoluteString
            )],
            expectedChangeCount: originalChangeCount
        ))
        try FileManager.default.removeItem(at: targetURL)

        do {
            _ = try await client.commit(prepared)
            XCTFail("A vanished semantic file must fail before clearing the pasteboard.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)
        }
        await client.shutdown()

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "keep me")
        XCTAssertEqual(fixture.pasteboard.changeCount, originalChangeCount)
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 0)
        XCTAssertEqual(trace.writeCount, 0)
    }

    func testPreparedWriteChangedAfterPrepareDoesNotOverwriteNewClipboard()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        let originalURL = try temporaryFileURL(prefix: "blocks-stale-original")
        let targetURL = try temporaryFileURL(prefix: "blocks-stale-target")
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let image = try imageRepresentations()
        let originalItem = NSPasteboardItem()
        XCTAssertTrue(originalItem.setString(
            originalURL.absoluteString,
            forType: .fileURL
        ))
        XCTAssertTrue(originalItem.setData(image.png, forType: .png))
        XCTAssertTrue(originalItem.setData(image.tiff, forType: .tiff))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([originalItem]))
        let originalChangeCount = fixture.pasteboard.changeCount

        let client = try makeClient(fixture: fixture)
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(
                representations: [],
                semanticFileURLString: targetURL.absoluteString
            )],
            expectedChangeCount: originalChangeCount
        ))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("new clipboard", forType: .string))

        do {
            _ = try await client.commit(prepared)
            XCTFail("A prepare-time snapshot must not overwrite a newer clipboard.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }
        await client.shutdown()

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "new clipboard")
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 0)
        XCTAssertEqual(trace.writeCount, 0)
    }

    func testFailedWriteDefaultObserveLeavesClearedClipboardWithoutFalseSelfSuppression()
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "fail_write_after_clear",
            ]
        )
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, originalChangeCount)

        do {
            _ = try await client.write(
                ClipboardBrokerWriteRequest(
                    items: [
                        ClipboardBrokerWriteItem(representations: [
                            ClipboardBrokerWriteRepresentationEntry(
                                pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                                value: .string("replacement")
                            ),
                        ]),
                    ],
                    expectedChangeCount: originalChangeCount
                )
            )
            XCTFail("The injected write failure must be surfaced.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)
        }

        XCTAssertNil(fixture.pasteboard.string(forType: .string))
        let failedChangeCount = fixture.pasteboard.changeCount
        XCTAssertGreaterThan(failedChangeCount, originalChangeCount)

        let observed = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: nil
            )
        )
        await client.shutdown()

        XCTAssertEqual(observed.status, .skipped)
        XCTAssertEqual(observed.skipReason, .unsupported)
        XCTAssertEqual(observed.changeCount, failedChangeCount)
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
        XCTAssertEqual(trace.typesReadCount, 1)
        XCTAssertEqual(trace.stringReadCount, 0)
        XCTAssertEqual(trace.dataReadCount, 0)
    }

    func testFailedWriteFaultDoesNotAttemptRollback() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("original", forType: .string))
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "fail_write_and_rollback_after_clear",
            ]
        )
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, originalChangeCount)

        do {
            _ = try await client.write(
                ClipboardBrokerWriteRequest(
                    items: [
                        ClipboardBrokerWriteItem(representations: [
                            ClipboardBrokerWriteRepresentationEntry(
                                pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                                value: .string("replacement")
                            ),
                        ]),
                    ],
                    expectedChangeCount: originalChangeCount
                )
            )
            XCTFail("The injected target failure must be surfaced.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeFailed)
        }

        XCTAssertNil(fixture.pasteboard.string(forType: .string))
        let failedChangeCount = fixture.pasteboard.changeCount
        XCTAssertGreaterThan(failedChangeCount, originalChangeCount)
        let observed = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: originalChangeCount
            )
        )
        await client.shutdown()

        XCTAssertEqual(observed.status, .skipped)
        XCTAssertEqual(observed.skipReason, .unsupported)
        XCTAssertEqual(observed.changeCount, failedChangeCount)
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
        XCTAssertEqual(trace.stringReadCount, 0)
        XCTAssertEqual(trace.dataReadCount, 0)
    }

    func testFailedPartialWritePreservesPartialTargetAndReportsChanged() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeTrace() }
        fixture.pasteboard.clearContents()
        let originalChangeCount = fixture.pasteboard.changeCount
        let client = try makeClient(
            fixture: fixture,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                "partial_write_then_fail_after_clear",
            ]
        )
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, originalChangeCount)

        do {
            _ = try await client.write(
                ClipboardBrokerWriteRequest(
                    items: [
                        ClipboardBrokerWriteItem(representations: [
                            ClipboardBrokerWriteRepresentationEntry(
                                pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                                value: .string("partial replacement")
                            ),
                        ]),
                    ],
                    expectedChangeCount: originalChangeCount
                )
            )
            XCTFail("A partial write has ambiguous ownership and must report changed.")
        } catch {
            XCTAssertEqual(error as? ClipboardBrokerClientError, .writeChanged)
        }

        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "partial replacement"
        )
        let finalChangeCount = fixture.pasteboard.changeCount
        XCTAssertGreaterThan(finalChangeCount, originalChangeCount)
        let observed = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: originalChangeCount
            )
        )
        await client.shutdown()

        XCTAssertEqual(observed.status, .captured)
        XCTAssertEqual(observed.changeCount, finalChangeCount)
        let trace = try readTrace(fixture.traceURL)
        XCTAssertEqual(trace.clearCount, 1)
        XCTAssertEqual(trace.writeCount, 1)
        XCTAssertEqual(trace.rollbackWriteSuccessCount, 0)
        XCTAssertEqual(trace.rollbackWriteFailureCount, 0)
        XCTAssertEqual(trace.stringReadCount, 1)
        XCTAssertEqual(trace.dataReadCount, 0)
    }

    private func makeFixture() throws -> BrokerFixture {
        let pasteboardName = UUID().uuidString.lowercased()
        let traceURL = URL(
            fileURLWithPath: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "blocks-clipboard-broker-trace-\(UUID().uuidString).plist",
                    isDirectory: false
                ).path
        )
        try? FileManager.default.removeItem(at: traceURL)
        return BrokerFixture(
            pasteboardName: pasteboardName,
            pasteboard: NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ),
            traceURL: traceURL
        )
    }

    private func makeClient(
        fixture: BrokerFixture,
        extraEnvironment: [String: String] = [:]
    ) throws -> ClipboardBrokerClient {
        var environment = extraEnvironment
        environment["BLOCKS_CLIPBOARD_BROKER_TEST_PASTEBOARD_NAME"] =
            fixture.pasteboardName
        environment["BLOCKS_CLIPBOARD_BROKER_TEST_TRACE_PATH"] =
            fixture.traceURL.path
        let brokerURL = try productURL(named: "BlocksClipboardBroker")
        return ClipboardBrokerClient(
            executableURLProvider: { brokerURL },
            environmentOverrides: environment
        )
    }

    private func publish(
        provider: PromisedRepresentationProvider,
        types: [NSPasteboard.PasteboardType],
        to pasteboard: NSPasteboard
    ) throws -> Int {
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: types)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw TestFailure.pasteboardPublishFailed
        }
        return pasteboard.changeCount
    }

    private func readTrace(_ url: URL) throws -> ClipboardBrokerBehaviorTrace {
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(
            ClipboardBrokerBehaviorTrace.self,
            from: data
        )
    }

    private func waitForPasteboardString(
        _ expected: String,
        on pasteboard: NSPasteboard
    ) async throws {
        for _ in 0..<100 where pasteboard.string(forType: .string) != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
    }

    private func brokerPauseSignalURL(id: UUID, suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "blocks-clipboard-broker-pause-\(id.uuidString)-\(suffix).signal",
            isDirectory: false
        )
    }

    private func waitForFile(at url: URL) async throws {
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Timed out waiting for broker pause signal.")
            throw TestFailure.brokerPauseTimedOut
        }
    }

    private func productURL(named name: String) throws -> URL {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: false),
            Bundle(for: Self.self).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: false),
        ]
        guard let match = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("Missing test product \(name).")
        }
        return match
    }

    private func imageRepresentations() throws -> (png: Data, tiff: Data) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ))
        let png = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
        let tiff = try XCTUnwrap(
            bitmap.representation(using: .tiff, properties: [:])
        )
        return (png, tiff)
    }

    private func temporaryFileURL(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data("file fixture".utf8).write(to: url, options: .atomic)
        return url
    }

    private func rtfData(_ text: String) throws -> Data {
        let attributed = NSAttributedString(string: text)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf,
            ]
        )
    }
}

private struct BrokerFixture {
    let pasteboardName: String
    let pasteboard: NSPasteboard
    let traceURL: URL

    func removeTrace() {
        try? FileManager.default.removeItem(at: traceURL)
    }
}

private struct ClipboardBrokerBehaviorTrace: Decodable {
    let changeCountReadCount: Int
    let typesReadCount: Int
    let stringReadCount: Int
    let dataReadCount: Int
    let clearCount: Int
    let writeCount: Int
    let rollbackWriteSuccessCount: Int
    let rollbackWriteFailureCount: Int
    let requestedStringTypes: [String]
    let requestedDataTypes: [String]
}

private final class PromisedRepresentationProvider:
    NSObject,
    NSPasteboardItemDataProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let strings: [NSPasteboard.PasteboardType: String]
    private let dataValues: [NSPasteboard.PasteboardType: Data]
    private var storedRequestedTypes: [NSPasteboard.PasteboardType] = []

    init(
        strings: [NSPasteboard.PasteboardType: String] = [:],
        data: [NSPasteboard.PasteboardType: Data] = [:]
    ) {
        self.strings = strings
        dataValues = data
    }

    var requestedTypes: [NSPasteboard.PasteboardType] {
        lock.withLock { storedRequestedTypes }
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.withLock {
            storedRequestedTypes.append(type)
        }
        if let value = strings[type] {
            item.setString(value, forType: type)
        } else if let value = dataValues[type] {
            item.setData(value, forType: type)
        }
    }
}

private enum TestFailure: Error {
    case pasteboardPublishFailed
    case brokerPauseTimedOut
}
