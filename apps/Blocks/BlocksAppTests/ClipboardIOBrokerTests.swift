import AppKit
import BlocksCore
import Darwin
import Foundation
import XCTest
@testable import Blocks

final class ClipboardBrokerProtocolTests: XCTestCase {
    func testPreparedWriteCommandsRoundTripWithSingleUseID() throws {
        let preparedWriteID = UUID()
        let request = ClipboardBrokerRequestEnvelope(
            command: .commitWrite(ClipboardBrokerCommitWriteRequest(
                preparedWriteID: preparedWriteID
            ))
        )

        let data = try PropertyListEncoder().encode(request)
        let decoded = try PropertyListDecoder().decode(
            ClipboardBrokerRequestEnvelope.self,
            from: data
        )

        guard case let .commitWrite(commit) = decoded.command else {
            return XCTFail("Expected a commit-write command.")
        }
        XCTAssertEqual(commit.preparedWriteID, preparedWriteID)
    }

    func testPreparedWriteResultRoundTripsMonotonicExpiry() throws {
        let expected = ClipboardBrokerPreparedWriteResult(
            preparedWriteID: UUID(),
            itemCount: 2,
            representationCount: 3,
            expiresAtSystemUptime: 123_456.75
        )

        let encoded = try PropertyListEncoder().encode(expected)
        let decoded = try PropertyListDecoder().decode(
            ClipboardBrokerPreparedWriteResult.self,
            from: encoded
        )

        XCTAssertEqual(decoded, expected)
    }

    func testPreparedWriteResultWithoutExpiryFailsClosed() throws {
        let legacyPayload: [String: Any] = [
            "preparedWriteID": UUID().uuidString,
            "itemCount": 1,
            "representationCount": 1,
        ]
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: legacyPayload,
            format: .binary,
            options: 0
        )

        XCTAssertThrowsError(try PropertyListDecoder().decode(
            ClipboardBrokerPreparedWriteResult.self,
            from: encoded
        ))
    }

    func testBinaryPlistFrameWaitsForCompletePayloadAndPreservesInlineData() throws {
        let requestID = UUID()
        let inlineData = Data([0x00, 0x7f, 0x80, 0xff])
        let request = ClipboardBrokerRequestEnvelope(
            requestID: requestID,
            command: .write(ClipboardBrokerWriteRequest(
                items: [
                    ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: "public.png",
                            value: .data(.inline(inlineData))
                        ),
                    ]),
                ],
                expectedChangeCount: 41
            ))
        )

        let frame = try ClipboardBrokerFrameCodec.frame(request)
        XCTAssertGreaterThan(frame.count, MemoryLayout<UInt32>.size)
        XCTAssertEqual(
            frame.prefix(MemoryLayout<UInt32>.size).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            },
            UInt32(frame.count - MemoryLayout<UInt32>.size)
        )

        var buffer = Data(frame.prefix(3))
        XCTAssertNil(try ClipboardBrokerFrameCodec.takePayload(from: &buffer))
        buffer.append(frame.dropFirst(3).dropLast(1))
        XCTAssertNil(try ClipboardBrokerFrameCodec.takePayload(from: &buffer))
        buffer.append(frame.suffix(1))

        let payload = try XCTUnwrap(
            ClipboardBrokerFrameCodec.takePayload(from: &buffer)
        )
        let decoded = try PropertyListDecoder().decode(
            ClipboardBrokerRequestEnvelope.self,
            from: payload
        )
        XCTAssertEqual(decoded.requestID, requestID)
        guard case let .write(decodedWrite) = decoded.command else {
            return XCTFail("Expected the framed command to remain a write request.")
        }
        XCTAssertEqual(decodedWrite.expectedChangeCount, 41)
        XCTAssertEqual(
            decodedWrite.items.first?.representations.first?.value,
            .data(.inline(inlineData))
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFrameDecoderRejectsOversizedPrefixWithoutAllocatingPayload() {
        var oversizedLength = UInt32(
            ClipboardBrokerLimits.maxFrameBytes + 1
        ).bigEndian
        var buffer = Data(
            bytes: &oversizedLength,
            count: MemoryLayout<UInt32>.size
        )

        XCTAssertThrowsError(
            try ClipboardBrokerFrameCodec.takePayload(from: &buffer)
        ) { error in
            XCTAssertEqual(
                error as? ClipboardBrokerFrameError,
                .oversized(ClipboardBrokerLimits.maxFrameBytes + 1)
            )
        }
    }

    func testRecorderPayloadKeepsLegacyJSONBase64KeysAndBinaryPlistData() throws {
        let rtfData = Data([0x7b, 0x5c, 0x72, 0x74, 0x66, 0x31, 0x7d])
        let pngData = Data([0x89, 0x50, 0x4e, 0x47])
        let payload = ClipboardRecorderPayload(
            recordID: "wire-compatible",
            kind: .richText,
            text: "fixture",
            rtfData: rtfData,
            pngData: pngData
        )

        let jsonData = try JSONEncoder().encode(payload)
        let jsonObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )
        XCTAssertEqual(
            jsonObject["rtf_data_base64"] as? String,
            rtfData.base64EncodedString()
        )
        XCTAssertEqual(
            jsonObject["png_data_base64"] as? String,
            pngData.base64EncodedString()
        )

        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "record_id": "legacy-wire",
            "kind": "rich_text",
            "text": "legacy",
            "rtf_data_base64": rtfData.base64EncodedString(),
            "png_data_base64": pngData.base64EncodedString(),
        ])
        let decodedLegacy = try JSONDecoder().decode(
            ClipboardRecorderPayload.self,
            from: legacyJSON
        )
        XCTAssertEqual(decodedLegacy.recordID, "legacy-wire")
        XCTAssertEqual(decodedLegacy.rtfData, rtfData)
        XCTAssertEqual(decodedLegacy.pngData, pngData)

        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        let plistData = try plistEncoder.encode(payload)
        let plistObject = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plistObject["rtf_data_base64"] as? Data, rtfData)
        XCTAssertEqual(plistObject["png_data_base64"] as? Data, pngData)

        let decodedPlist = try PropertyListDecoder().decode(
            ClipboardRecorderPayload.self,
            from: plistData
        )
        XCTAssertEqual(decodedPlist.rtfData, rtfData)
        XCTAssertEqual(decodedPlist.pngData, pngData)
    }
}

final class ClipboardBrokerPolicyTests: XCTestCase {
    func testObserveRequestCanonicalizesSuppressedCountsAndRoundTripsPrefilter() throws {
        let request = ClipboardBrokerObserveRequest(
            baselineChangeCount: 90,
            poisonedChangeCount: 89,
            suppressedChangeCounts: [92, 91, 92, 90],
            prefilterDisposition: .redactExcludedSource,
            screenSharingActive: true
        )

        XCTAssertEqual(request.suppressedChangeCounts, [90, 91, 92])

        let data = try PropertyListEncoder().encode(request)
        let decoded = try PropertyListDecoder().decode(
            ClipboardBrokerObserveRequest.self,
            from: data
        )
        XCTAssertEqual(decoded.baselineChangeCount, 90)
        XCTAssertEqual(decoded.poisonedChangeCount, 89)
        XCTAssertEqual(decoded.suppressedChangeCounts, [90, 91, 92])
        XCTAssertEqual(decoded.prefilterDisposition, .redactExcludedSource)
        XCTAssertTrue(decoded.screenSharingActive)
    }

    func testCapturedObservationWireCarriesExactlyOneChosenRepresentation() throws {
        let chosen = ClipboardBrokerCapturedRepresentation(
            family: .richText,
            pasteboardType: "public.rtf",
            advertisedTypes: [
                "public.utf8-plain-text",
                "public.rtf",
                "public.rtf",
            ],
            plainText: "fixture",
            data: .inline(Data([0x01, 0x02]))
        )
        let result = ClipboardBrokerObservationResult(
            status: .captured,
            changeCount: 14,
            observedAfterChangeCount: 14,
            representation: chosen
        )

        let data = try PropertyListEncoder().encode(result)
        let decoded = try PropertyListDecoder().decode(
            ClipboardBrokerObservationResult.self,
            from: data
        )
        XCTAssertEqual(decoded.status, .captured)
        XCTAssertEqual(decoded.brokerGeneration, 0)
        XCTAssertEqual(decoded.representation?.family, .richText)
        XCTAssertEqual(decoded.representation?.pasteboardType, "public.rtf")
        XCTAssertEqual(
            decoded.representation?.advertisedTypes,
            ["public.rtf", "public.rtf", "public.utf8-plain-text"]
        )
        XCTAssertEqual(decoded.representation?.plainText, "fixture")
        XCTAssertEqual(decoded.representation?.data, .inline(Data([0x01, 0x02])))
    }

    func testDeferredObservationWireCarriesOnlyContentFreeResolutionTicket() throws {
        let ticket = ClipboardBrokerResolutionTicket(
            changeCount: 18,
            family: .richText,
            pasteboardType: "public.rtf",
            advertisedTypes: ["public.rtf", "public.utf8-plain-text"]
        )
        let result = ClipboardBrokerObservationResult(
            status: .deferred,
            changeCount: 18,
            observedAfterChangeCount: 18,
            resolutionTicket: ticket
        )

        let data = try PropertyListEncoder().encode(result)
        let decoded = try PropertyListDecoder().decode(
            ClipboardBrokerObservationResult.self,
            from: data
        )

        XCTAssertEqual(decoded.status, .deferred)
        XCTAssertEqual(decoded.resolutionTicket, ticket)
        XCTAssertNil(decoded.representation)
    }

    func testRemoteAndSensitiveSkipsDoNotCarryRepresentationPayloads() throws {
        for reason in [
            ClipboardBrokerSkipReason.remoteClipboard,
            .sensitiveMarker,
            .poisonedChange,
        ] {
            let result = ClipboardBrokerObservationResult(
                status: .skipped,
                changeCount: 77,
                observedAfterChangeCount: 77,
                representation: nil,
                skipReason: reason
            )
            let data = try PropertyListEncoder().encode(result)
            let decoded = try PropertyListDecoder().decode(
                ClipboardBrokerObservationResult.self,
                from: data
            )

            XCTAssertEqual(decoded.status, .skipped)
            XCTAssertEqual(decoded.skipReason, reason)
            XCTAssertNil(decoded.representation)
        }
    }

    func testStagingTokenCannotEscapeBrokerRoot() {
        let root = URL(fileURLWithPath: "/tmp/blocks-broker-root", isDirectory: true)
        let token = ClipboardBrokerStaging.makeToken()

        let resolved = ClipboardBrokerStaging.fileURL(
            rootDirectory: root,
            token: token
        )
        XCTAssertEqual(
            resolved?.deletingLastPathComponent().standardizedFileURL,
            root.standardizedFileURL
        )
        XCTAssertEqual(resolved?.pathExtension, ClipboardBrokerStaging.fileExtension)
        XCTAssertNil(
            ClipboardBrokerStaging.fileURL(
                rootDirectory: root,
                token: "../\(token)"
            )
        )
        XCTAssertNil(
            ClipboardBrokerStaging.fileURL(
                rootDirectory: root,
                token: token.uppercased()
            )
        )
    }
}

@MainActor
final class ClipboardBrokerProcessIntegrationTests: XCTestCase {
    func testAppTerminationFinalizesEmptyPinnedStagingRoot() throws {
        try ClipboardBrokerDataTransport.resetAfterTerminationForTesting()
        defer {
            try? ClipboardBrokerDataTransport.resetAfterTerminationForTesting()
        }
        try ClipboardBrokerDataTransport.prepareRoot()
        let root = ClipboardBrokerDataTransport.rootDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        AppDelegate().applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try ClipboardBrokerDataTransport.prepareRoot()) {
            XCTAssertEqual(
                $0 as? ClipboardBrokerClientError,
                .brokerTerminated
            )
        }
    }

    func testAppTerminationWaitsForPinnedOperationBeforeRemovingRoot() async throws {
        try ClipboardBrokerDataTransport.resetAfterTerminationForTesting()
        ClipboardBrokerDataTransport.removeRoot()
        try ClipboardBrokerDataTransport.prepareRoot()
        let root = ClipboardBrokerDataTransport.rootDirectory
        let token = ClipboardBrokerStaging.makeToken()
        let payloadName = "\(token).\(ClipboardBrokerStaging.fileExtension)"
        let barrier = ClipboardBrokerRootOperationBarrier()
        defer {
            barrier.release.signal()
            try? ClipboardBrokerDataTransport.resetAfterTerminationForTesting()
        }

        let operationTask = Task.detached {
            try ClipboardBrokerDataTransport.withPinnedRootOperationForTesting {
                rootDescriptor in
                barrier.markAcquired()
                barrier.release.wait()

                let payloadDescriptor = openat(
                    rootDescriptor,
                    payloadName,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
                guard payloadDescriptor >= 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                close(payloadDescriptor)
            }
        }
        let acquisitionDeadline = ContinuousClock.now + .seconds(1)
        while !barrier.hasAcquired,
              ContinuousClock.now < acquisitionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard barrier.hasAcquired else {
            return XCTFail("The staging operation did not acquire its root lease.")
        }

        let finalizerTask = Task.detached {
            ClipboardBrokerDataTransport.finalizeRoot()
            barrier.markFinalized()
        }
        let finalizingDeadline = ContinuousClock.now + .seconds(1)
        while !ClipboardBrokerDataTransport
            .isWaitingForActiveOperationsForTesting(),
            ContinuousClock.now < finalizingDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            ClipboardBrokerDataTransport
                .isWaitingForActiveOperationsForTesting(),
            "The finalizer did not reach the active-operation wait barrier."
        )
        XCTAssertFalse(
            barrier.hasFinalized,
            "Finalization must wait for every acquired root operation lease."
        )

        barrier.release.signal()
        let operationResult = await operationTask.result
        await finalizerTask.value
        if case let .failure(error) = operationResult {
            XCTFail("The in-flight staging operation failed: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "The finalizer must remove payloads created by an operation that "
                + "was already in flight."
        )
        try ClipboardBrokerDataTransport.resetAfterTerminationForTesting()
    }

    func testAppStagingReadStaysBoundToPinnedRootAfterPathReplacement() async throws {
        ClipboardBrokerDataTransport.removeRoot()
        let originalData = Data(
            repeating: 0x41,
            count: ClipboardBrokerLimits.inlineImageBytes + 1
        )
        let replacementData = Data("replacement-must-not-be-read".utf8)
        let reference = try ClipboardBrokerDataTransport.reference(
            for: originalData,
            stagesLargePayload: true
        )
        guard case let .staged(token, _) = reference else {
            return XCTFail("Expected a staged reference.")
        }

        let root = ClipboardBrokerDataTransport.rootDirectory
        let preservedRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "\(root.lastPathComponent)-preserved-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        let replacementPayload = try XCTUnwrap(
            ClipboardBrokerStaging.fileURL(
                rootDirectory: root,
                token: token
            )
        )
        var originalMoved = false
        var replacementCreated = false
        defer {
            ClipboardBrokerDataTransport.removeStagedReference(reference)
            if replacementCreated {
                try? FileManager.default.removeItem(at: root)
            }
            if originalMoved {
                XCTAssertEqual(
                    rename(preservedRoot.path, root.path),
                    0,
                    "The pinned staging root must be restored after the test."
                )
            }
            ClipboardBrokerDataTransport.removeRoot()
        }

        guard rename(root.path, preservedRoot.path) == 0 else {
            return XCTFail("Could not preserve the pinned staging root.")
        }
        originalMoved = true
        guard mkdir(root.path, mode_t(0o700)) == 0 else {
            return XCTFail("Could not create the replacement staging root.")
        }
        replacementCreated = true
        try replacementData.write(
            to: replacementPayload,
            options: .withoutOverwriting
        )
        XCTAssertEqual(chmod(replacementPayload.path, mode_t(0o600)), 0)

        let resolved = try await ClipboardBrokerDataTransport.resolve(
            reference,
            maximumByteCount: ClipboardBrokerLimits.maxRawImageBytes
        )
        XCTAssertEqual(resolved, originalData)
        XCTAssertEqual(try Data(contentsOf: replacementPayload), replacementData)
    }

    func testRunningBrokerLoadsStagedWriteFromPinnedRootAfterPathReplacement() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        let ownerID = UUID()
        await client.updatePassiveMonitoring(
            ownerID: ownerID,
            revision: 1,
            active: true
        )
        let baseline = try await client.baseline()

        let root = ClipboardBrokerDataTransport.rootDirectory
        let preservedRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "\(root.lastPathComponent)-broker-preserved-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        var originalMoved = false
        var replacementCreated = false
        defer {
            if replacementCreated {
                try? FileManager.default.removeItem(at: root)
            }
            if originalMoved {
                XCTAssertEqual(
                    rename(preservedRoot.path, root.path),
                    0,
                    "The pinned staging root must be restored after the test."
                )
            }
            ClipboardBrokerDataTransport.removeRoot()
        }
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
        }
        guard rename(root.path, preservedRoot.path) == 0 else {
            return XCTFail("Could not preserve the pinned staging root.")
        }
        originalMoved = true
        guard mkdir(root.path, mode_t(0o700)) == 0 else {
            return XCTFail("Could not create the replacement staging root.")
        }
        replacementCreated = true

        let tiffData = Data(
            repeating: 0x5a,
            count: ClipboardBrokerLimits.inlineImageBytes + 1
        )
        _ = try await client.write(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.tiff.rawValue,
                        value: .data(.inline(tiffData))
                    ),
                ]),
            ],
            expectedChangeCount: baseline
        ))

        XCTAssertEqual(pasteboard.data(forType: .tiff), tiffData)
        let replacementEntries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(replacementEntries.isEmpty)
    }

    func testBrokerLaunchRejectsReplacementOfPinnedStagingRoot() async throws {
        try ClipboardBrokerDataTransport.prepareRoot()
        let root = ClipboardBrokerDataTransport.rootDirectory
        let preservedRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "\(root.lastPathComponent)-launch-preserved-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        var originalMoved = false
        var replacementCreated = false
        defer {
            if replacementCreated {
                try? FileManager.default.removeItem(at: root)
            }
            if originalMoved {
                XCTAssertEqual(
                    rename(preservedRoot.path, root.path),
                    0,
                    "The pinned staging root must be restored after the test."
                )
            }
            ClipboardBrokerDataTransport.removeRoot()
        }
        guard rename(root.path, preservedRoot.path) == 0 else {
            return XCTFail("Could not preserve the pinned staging root.")
        }
        originalMoved = true
        guard mkdir(root.path, mode_t(0o700)) == 0 else {
            return XCTFail("Could not create the replacement staging root.")
        }
        replacementCreated = true

        let client = try makeBrokerClient(
            pasteboardName: UUID().uuidString.lowercased()
        )
        do {
            _ = try await client.baseline()
            XCTFail("A replacement staging root must fail before Broker launch.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .malformedResponse
            )
        }
        let diagnostics = await client.diagnostics()
        XCTAssertNil(diagnostics.processIdentifier)
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        await client.shutdown()
    }

    func testOneThousandNoChangePollsNeverRequestPromisedContent() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let baseline = 314
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_BASELINE_CHANGE_COUNT":
                    String(baseline),
                "BLOCKS_CLIPBOARD_BROKER_TEST_FIXED_CHANGE_COUNT":
                    String(baseline),
            ]
        )
        addTeardownBlock { await client.shutdown() }
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, baseline)

        for _ in 0..<1_000 {
            let result = try await client.observe(ClipboardBrokerObserveRequest(
                baselineChangeCount: baseline
            ))
            XCTAssertEqual(result.status, .noChange)
            XCTAssertEqual(result.observedAfterChangeCount, baseline)
            XCTAssertGreaterThan(result.brokerGeneration, 0)
        }

        let diagnostics = await client.diagnostics()
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        await client.shutdown()
    }

    func testSuccessfulWriteLeaseUsesRequestGenerationAndRestartInvalidatesIt() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        addTeardownBlock { await client.shutdown() }

        let baseline = try await client.baseline()
        let lease = try await client.write(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("generation-bound-write")
                    ),
                ]),
            ],
            expectedChangeCount: baseline
        ))
        let afterWrite = await client.diagnostics()
        let leaseGenerationIsCurrent = await client.generationIsCurrent(
            lease.brokerGeneration
        )

        XCTAssertEqual(lease.brokerGeneration, afterWrite.generation)
        XCTAssertTrue(leaseGenerationIsCurrent)
        await client.shutdown()
        let leaseGenerationIsCurrentAfterShutdown =
            await client.generationIsCurrent(lease.brokerGeneration)
        let leaseIsValidAfterShutdown = await client.validate(lease)
        XCTAssertFalse(leaseGenerationIsCurrentAfterShutdown)
        XCTAssertFalse(leaseIsValidAfterShutdown)
    }

    func testModernFileURLRepresentationsAreAcceptedByBroker() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocks-file-\(UUID().uuidString).png")
        try Data("file-url-fixture".utf8).write(to: fileURL, options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let baseline = try await client.baseline()
        let lease = try await client.write(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(
                    representations: [],
                    semanticFileURLString: fileURL.absoluteString
                ),
            ],
            expectedChangeCount: baseline
        ))

        XCTAssertEqual(pasteboard.changeCount, lease.changeCount)
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [NSURL]
        XCTAssertEqual(urls?.first as URL?, fileURL)
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
    }

    func testPreparedWriteCancelDoesNotMutatePasteboardAndIsSingleUse() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blocks-clipboard-broker-trace-\(UUID().uuidString).plist"
            )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_TRACE_PATH": traceURL.path,
            ]
        )
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
            try? FileManager.default.removeItem(at: traceURL)
        }

        let baseline = try await client.baseline()
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("replacement")
                    ),
                ]),
            ],
            expectedChangeCount: baseline
        ))

        XCTAssertEqual(pasteboard.changeCount, baseline)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        try await client.cancel(prepared)
        XCTAssertEqual(pasteboard.changeCount, baseline)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        let trace = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: try Data(contentsOf: traceURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(trace["clearCount"] as? Int, 0)
        XCTAssertEqual(trace["writeCount"] as? Int, 0)

        for action in ["commit", "cancel"] {
            do {
                if action == "commit" {
                    _ = try await client.commit(prepared)
                } else {
                    try await client.cancel(prepared)
                }
                XCTFail("A consumed prepared-write ID must fail closed for \(action).")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardBrokerClientError,
                    .requestSuperseded
                )
            }
        }
    }

    func testPreparedWriteCommitWinsOnceAndKeepsOrdinaryWriteCompatible() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
        }

        let baseline = try await client.baseline()
        let prepared = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("prepared")
                    ),
                ]),
            ],
            expectedChangeCount: baseline
        ))
        let lease = try await client.commit(prepared)
        XCTAssertEqual(pasteboard.string(forType: .string), "prepared")
        XCTAssertEqual(pasteboard.changeCount, lease.changeCount)
        do {
            _ = try await client.commit(prepared)
            XCTFail("A committed prepared-write ID must not write twice.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestSuperseded
            )
        }

        let ordinaryLease = try await client.write(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("ordinary")
                    ),
                ]),
            ],
            expectedChangeCount: lease.changeCount
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "ordinary")
        XCTAssertEqual(pasteboard.changeCount, ordinaryLease.changeCount)
    }

    func testCancellingAcceptedCommitDoesNotKillBrokerAndNewerWriteWins()
        async throws
    {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blocks-clipboard-broker-trace-commit-\(UUID().uuidString).plist"
            )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_TRACE_PATH": traceURL.path,
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                    "delay_commit_write_after_clear",
            ]
        )
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
            try? FileManager.default.removeItem(at: traceURL)
        }

        let baseline = try await client.baseline()
        let firstPrepared = try await client.prepare(
            ClipboardBrokerWriteRequest(
                items: [
                    ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string("first")
                        ),
                    ]),
                ],
                expectedChangeCount: baseline
            )
        )
        let firstCommit = Task {
            try await client.commit(firstPrepared)
        }

        let clearDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var observedClear = false
        while ContinuousClock.now < clearDeadline {
            if let data = try? Data(contentsOf: traceURL),
               let propertyList = try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ),
               let trace = propertyList as? [String: Any],
               (trace["clearCount"] as? Int ?? 0) >= 1 {
                observedClear = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(observedClear, "The first commit never reached its mutation boundary.")

        firstCommit.cancel()
        let newerWrite = Task {
            let newerBaseline = try await client.baseline()
            let prepared = try await client.prepare(
                ClipboardBrokerWriteRequest(
                    items: [
                        ClipboardBrokerWriteItem(representations: [
                            ClipboardBrokerWriteRepresentationEntry(
                                pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                                value: .string("newer")
                            ),
                        ]),
                    ],
                    expectedChangeCount: newerBaseline
                )
            )
            return try await client.commit(prepared)
        }

        let firstLease = try await firstCommit.value
        XCTAssertGreaterThan(firstLease.changeCount, baseline)
        let newerLease = try await newerWrite.value

        let trace = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: try Data(contentsOf: traceURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(trace["clearCount"] as? Int, 2)
        XCTAssertEqual(trace["writeCount"] as? Int, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
        XCTAssertEqual(pasteboard.changeCount, newerLease.changeCount)
    }

    func testAcceptedCommitOutlivesGenericTimeoutWithoutClearingPasteboard()
        async throws
    {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                    "delay_commit_write_after_clear_past_request_timeout",
            ]
        )
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
        }

        let baseline = try await client.baseline()
        let prepared = try await client.prepare(
            ClipboardBrokerWriteRequest(
                items: [
                    ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string("settled")
                        ),
                    ]),
                ],
                expectedChangeCount: baseline
            )
        )

        let startedAt = ContinuousClock.now
        let committed = try await client.commit(prepared)
        XCTAssertGreaterThanOrEqual(
            startedAt.duration(to: .now),
            .seconds(1)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "settled")
        XCTAssertEqual(pasteboard.changeCount, committed.changeCount)

        let nextLease = try await client.write(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("next")
                    ),
                ]),
            ],
            expectedChangeCount: try await client.baseline()
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "next")
        XCTAssertEqual(pasteboard.changeCount, nextLease.changeCount)
    }

    func testShutdownWaitsForAcceptedCommitBeforeTerminatingBroker()
        async throws
    {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blocks-clipboard-broker-trace-shutdown-\(UUID().uuidString).plist"
            )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_TRACE_PATH": traceURL.path,
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                    "delay_commit_write_after_clear_past_request_timeout",
            ]
        )
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
            try? FileManager.default.removeItem(at: traceURL)
        }

        let prepared = try await client.prepare(
            ClipboardBrokerWriteRequest(
                items: [
                    ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string("settled-before-shutdown")
                        ),
                    ]),
                ],
                expectedChangeCount: try await client.baseline()
            )
        )
        let commit = Task { try await client.commit(prepared) }
        let clearDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var observedClear = false
        while ContinuousClock.now < clearDeadline {
            if let data = try? Data(contentsOf: traceURL),
               let propertyList = try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ),
               let trace = propertyList as? [String: Any],
               (trace["clearCount"] as? Int ?? 0) >= 1 {
                observedClear = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(observedClear, "The commit never reached its mutation boundary.")

        let shutdown = Task { await client.shutdown() }
        let joiningShutdown = Task { await client.shutdown() }
        try await Task.sleep(for: .milliseconds(100))
        let duringShutdown = await client.diagnostics()
        XCTAssertNotNil(
            duringShutdown.processIdentifier,
            "Shutdown must keep the Broker alive until the accepted commit settles."
        )
        XCTAssertEqual(duringShutdown.pendingRequestCount, 1)

        let committed: ClipboardPasteboardWriteLease
        do {
            committed = try await commit.value
        } catch {
            XCTAssertNotEqual(
                error as? ClipboardBrokerClientError,
                .brokerTerminated,
                "A commit with an accepted terminal must not be invalidated by shutdown."
            )
            throw error
        }
        await shutdown.value
        await joiningShutdown.value
        let trace = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: try Data(contentsOf: traceURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(trace["clearCount"] as? Int, 1)
        XCTAssertEqual(trace["writeCount"] as? Int, 1)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "settled-before-shutdown"
        )
        XCTAssertEqual(pasteboard.changeCount, committed.changeCount)
        let finishedDiagnostics = await client.diagnostics()
        XCTAssertNil(finishedDiagnostics.processIdentifier)
    }

    func testShutdownBoundsHungAcceptedCommitAndConcurrentCallersJoin()
        async throws
    {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blocks-clipboard-broker-trace-hung-shutdown-\(UUID().uuidString).plist"
            )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_TRACE_PATH": traceURL.path,
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                    "hang_commit_write_after_clear",
            ]
        )
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
            try? FileManager.default.removeItem(at: traceURL)
        }

        let prepared = try await client.prepare(
            ClipboardBrokerWriteRequest(
                items: [
                    ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string("never-published")
                        ),
                    ]),
                ],
                expectedChangeCount: try await client.baseline()
            )
        )
        let commit = Task { try await client.commit(prepared) }
        let clearDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var observedClear = false
        while ContinuousClock.now < clearDeadline {
            if let data = try? Data(contentsOf: traceURL),
               let propertyList = try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ),
               let trace = propertyList as? [String: Any],
               (trace["clearCount"] as? Int ?? 0) >= 1 {
                observedClear = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(observedClear, "The hung commit never reached clear.")

        let startedAt = ContinuousClock.now
        async let firstShutdown: Void = client.shutdown()
        try await Task.sleep(for: .milliseconds(50))
        async let secondShutdown: Void = client.shutdown()
        _ = await (firstShutdown, secondShutdown)
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(3),
            "Shutdown must not wait forever for a live but wedged Broker."
        )
        let finishedDiagnostics = await client.diagnostics()
        XCTAssertNil(finishedDiagnostics.processIdentifier)
        do {
            _ = try await commit.value
            XCTFail("Terminating a wedged commit must fail its caller.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .brokerTerminated
            )
        }
    }

    func testConcurrentSecondCommitKeepsLeaseAvailableForCancel()
        async throws
    {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blocks-clipboard-broker-trace-two-commits-\(UUID().uuidString).plist"
            )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_TRACE_PATH": traceURL.path,
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                    "delay_commit_write_after_clear",
            ]
        )
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
            try? FileManager.default.removeItem(at: traceURL)
        }

        let baseline = try await client.baseline()
        func request(_ text: String) -> ClipboardBrokerWriteRequest {
            ClipboardBrokerWriteRequest(
                items: [
                    ClipboardBrokerWriteItem(representations: [
                        ClipboardBrokerWriteRepresentationEntry(
                            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                            value: .string(text)
                        ),
                    ]),
                ],
                expectedChangeCount: baseline
            )
        }
        let first = try await client.prepare(request("first"))
        let second = try await client.prepare(request("second"))
        let firstCommit = Task { try await client.commit(first) }
        let clearDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var observedClear = false
        while ContinuousClock.now < clearDeadline {
            if let data = try? Data(contentsOf: traceURL),
               let propertyList = try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ),
               let trace = propertyList as? [String: Any],
               (trace["clearCount"] as? Int ?? 0) >= 1 {
                observedClear = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(observedClear, "The first commit never reached clear.")

        do {
            _ = try await client.commit(second)
            XCTFail("A concurrent commit must not bypass the active commit.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestSuperseded
            )
        }
        _ = try await firstCommit.value
        try await client.cancel(second)
        do {
            _ = try await client.commit(second)
            XCTFail("Cancellation must consume the preserved second lease.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestSuperseded
            )
        }
    }

    func testExplicitWriteBrokerReapsWithinTwoSecondsWhenPassiveMonitoringIsInactive() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
        }

        let baseline = try await client.baseline()
        _ = try await client.write(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("idle-reap")
                    ),
                ]),
            ],
            expectedChangeCount: baseline
        ))
        let runningDiagnostics = await client.diagnostics()
        let processIdentifier = try XCTUnwrap(
            runningDiagnostics.processIdentifier
        )
        XCTAssertEqual(runningDiagnostics.pendingRequestCount, 0)

        let startedWaitingAt = ContinuousClock.now
        let deadline = startedWaitingAt.advanced(by: .seconds(2))
        var finalDiagnostics = runningDiagnostics
        while ContinuousClock.now < deadline {
            finalDiagnostics = await client.diagnostics()
            if finalDiagnostics.processIdentifier == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(finalDiagnostics.processIdentifier)
        XCTAssertLessThanOrEqual(
            startedWaitingAt.duration(to: .now),
            .seconds(2)
        )
        await assertProcessExits(
            processIdentifier,
            within: .milliseconds(250)
        )
        await client.shutdown()
    }

    func testPassiveMonitoringKeepsBrokerAliveAndReapsWithinTwoSecondsAfterDeactivation() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        addTeardownBlock { await client.shutdown() }
        let ownerID = UUID()

        await client.updatePassiveMonitoring(
            ownerID: ownerID,
            revision: 1,
            active: true
        )
        _ = try await client.baseline()
        let activeDiagnostics = await client.diagnostics()
        let processIdentifier = try XCTUnwrap(
            activeDiagnostics.processIdentifier
        )

        try await Task.sleep(for: .milliseconds(1_750))
        let stillActiveDiagnostics = await client.diagnostics()
        XCTAssertEqual(
            stillActiveDiagnostics.processIdentifier,
            processIdentifier
        )
        XCTAssertEqual(
            stillActiveDiagnostics.generation,
            activeDiagnostics.generation
        )

        let deactivatedAt = ContinuousClock.now
        await client.updatePassiveMonitoring(
            ownerID: ownerID,
            revision: 2,
            active: false
        )
        let deadline = deactivatedAt.advanced(by: .seconds(2))
        var finalDiagnostics = stillActiveDiagnostics
        while ContinuousClock.now < deadline {
            finalDiagnostics = await client.diagnostics()
            if finalDiagnostics.processIdentifier == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(finalDiagnostics.processIdentifier)
        XCTAssertLessThanOrEqual(
            deactivatedAt.duration(to: .now),
            .seconds(2)
        )
        await assertProcessExits(
            processIdentifier,
            within: .milliseconds(250)
        )
    }

    func testStalePassiveActivationCannotOverrideNewerDeactivation() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        addTeardownBlock { await client.shutdown() }
        let ownerID = UUID()

        _ = try await client.baseline()
        let runningDiagnostics = await client.diagnostics()
        let processIdentifier = try XCTUnwrap(
            runningDiagnostics.processIdentifier
        )
        await client.updatePassiveMonitoring(
            ownerID: ownerID,
            revision: 2,
            active: false
        )
        await client.updatePassiveMonitoring(
            ownerID: ownerID,
            revision: 1,
            active: true
        )
        await client.updatePassiveMonitoring(
            ownerID: ownerID,
            revision: 2,
            active: true
        )

        let startedWaitingAt = ContinuousClock.now
        let deadline = startedWaitingAt.advanced(by: .seconds(2))
        var finalDiagnostics = runningDiagnostics
        while ContinuousClock.now < deadline {
            finalDiagnostics = await client.diagnostics()
            if finalDiagnostics.processIdentifier == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(
            finalDiagnostics.processIdentifier,
            "Older or duplicate activation revisions must not override stop."
        )
        await assertProcessExits(
            processIdentifier,
            within: .milliseconds(250)
        )
    }

    func testPNGAboveLimitFailsPreflightBeforeLaunchStagingOrIPC() async {
        await assertOversizedWriteRejectedBeforeLaunch(
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
                        value: .data(.inline(Data(
                            count: ClipboardBrokerLimits.maxCanonicalPNGBytes + 1
                        )))
                    ),
                ]),
            ])
        )
    }

    func testTIFFAboveLimitFailsPreflightBeforeLaunchStagingOrIPC() async {
        await assertOversizedWriteRejectedBeforeLaunch(
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.tiff.rawValue,
                        value: .data(.inline(Data(
                            count: ClipboardBrokerLimits.maxRawImageBytes + 1
                        )))
                    ),
                ]),
            ])
        )
    }

    func testRTFAboveLimitFailsPreflightBeforeLaunchStagingOrIPC() async {
        await assertOversizedWriteRejectedBeforeLaunch(
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.rtf.rawValue,
                        value: .data(.inline(Data(
                            count: ClipboardBrokerLimits.maxRTFBytes + 1
                        )))
                    ),
                ]),
            ])
        )
    }

    func testTextAboveLimitFailsPreflightBeforeLaunchStagingOrIPC() async {
        await assertOversizedWriteRejectedBeforeLaunch(
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string(String(
                            repeating: "x",
                            count: ClipboardBrokerLimits.maxTextBytes + 1
                        ))
                    ),
                ]),
            ])
        )
    }

    func testPreflightAcceptsSmallAndExactBoundaryStructures() async {
        ClipboardBrokerDataTransport.removeRoot()
        defer { ClipboardBrokerDataTransport.removeRoot() }

        let executableProbe = ClipboardBrokerExecutableProbe()
        let client = ClipboardBrokerClient(executableURLProvider: {
            executableProbe.resolveUnavailableExecutable()
        })
        let exactBoundaryRequests = [
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
                        value: .data(.staged(
                            token: ClipboardBrokerStaging.makeToken(),
                            byteCount: ClipboardBrokerLimits.maxCanonicalPNGBytes
                        ))
                    ),
                ]),
            ]),
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.tiff.rawValue,
                        value: .data(.staged(
                            token: ClipboardBrokerStaging.makeToken(),
                            byteCount: ClipboardBrokerLimits.maxRawImageBytes
                        ))
                    ),
                ]),
            ]),
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.rtf.rawValue,
                        value: .data(.staged(
                            token: ClipboardBrokerStaging.makeToken(),
                            byteCount: ClipboardBrokerLimits.maxRTFBytes
                        ))
                    ),
                ]),
            ]),
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string(String(
                            repeating: "x",
                            count: ClipboardBrokerLimits.maxTextBytes
                        ))
                    ),
                ]),
            ]),
            ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
                        value: .data(.inline(Data([0x89, 0x50, 0x4e, 0x47])))
                    ),
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.rtf.rawValue,
                        value: .data(.inline(Data([0x7b, 0x7d])))
                    ),
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string("small")
                    ),
                ]),
            ]),
        ]

        for request in exactBoundaryRequests {
            do {
                _ = try await client.write(request)
                XCTFail("A structurally valid request should reach executable resolution.")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardBrokerClientError,
                    .executableUnavailable
                )
            }
        }

        let diagnostics = await client.diagnostics()
        XCTAssertEqual(
            executableProbe.callCount,
            exactBoundaryRequests.count
        )
        XCTAssertNil(diagnostics.processIdentifier)
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        XCTAssertTrue(stagedPayloadURLs().isEmpty)
        await client.shutdown()
    }

    func testLargePNGWriteKeepsMainActorResponsiveDerivesTIFFAndCleansStaging() async throws {
        let pngData = try makeLargeValidPNG()
        XCTAssertGreaterThan(
            pngData.count,
            ClipboardBrokerLimits.inlineImageBytes
        )
        XCTAssertLessThanOrEqual(
            pngData.count,
            ClipboardBrokerLimits.maxCanonicalPNGBytes
        )

        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
        }
        let baseline = try await client.baseline()

        let heartbeat = HeartbeatRecorder()
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.record()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { heartbeatTask.cancel() }
        try await Task.sleep(for: .milliseconds(30))

        let lease = try await client.write(ClipboardBrokerWriteRequest(
            items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
                        value: .data(.inline(pngData))
                    ),
                ]),
            ],
            expectedChangeCount: baseline
        ))

        try await Task.sleep(for: .milliseconds(30))
        heartbeatTask.cancel()
        _ = await heartbeatTask.result

        XCTAssertGreaterThan(lease.changeCount, baseline)
        XCTAssertLessThan(heartbeat.maximumInterval, 0.100)
        XCTAssertEqual(pasteboard.data(forType: .png), pngData)
        let derivedTIFF = try XCTUnwrap(pasteboard.data(forType: .tiff))
        XCTAssertFalse(derivedTIFF.isEmpty)
        XCTAssertNotNil(NSBitmapImageRep(data: derivedTIFF))

        let stagedPayloads = (
            try? FileManager.default.contentsOfDirectory(
                at: ClipboardBrokerDataTransport.rootDirectory,
                includingPropertiesForKeys: nil
            )
        )?.filter {
            $0.pathExtension == ClipboardBrokerStaging.fileExtension
        } ?? []
        XCTAssertTrue(
            stagedPayloads.isEmpty,
            "Successful writes must remove their staged payload."
        )

        await client.shutdown()
    }

    func testBlockingPromisedDataTimesOutWithoutBlockingHeartbeatAndRestarts() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let fixture = try launchBlockingProvider(pasteboardName: pasteboardName)
        addTeardownBlock {
            Self.stop(fixture.process)
        }
        let readyLine: String
        do {
            readyLine = try await readReadyLine(from: fixture.output)
        } catch {
            Self.stop(fixture.process)
            throw XCTSkip(
                "The macOS pasteboard was already unavailable before the "
                    + "blocking provider fixture could publish."
            )
        }
        let baseline = try XCTUnwrap(
            Int(readyLine.dropFirst("READY ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )

        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_BASELINE_CHANGE_COUNT":
                    String(baseline),
            ]
        )
        addTeardownBlock { await client.shutdown() }
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, baseline)
        let beforeBlock = await client.diagnostics()
        let originalPID = try XCTUnwrap(beforeBlock.processIdentifier)
        let oldLease = ClipboardPasteboardWriteLease(
            changeCount: baseline,
            brokerGeneration: beforeBlock.generation
        )

        let heartbeat = HeartbeatRecorder()
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.record()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let startedAt = ContinuousClock.now
        do {
            _ = try await client.observe(ClipboardBrokerObserveRequest(
                baselineChangeCount: baseline - 1
            ))
            XCTFail("The promised string must block until the Broker is killed.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestTimedOut
            )
        }
        let elapsed = startedAt.duration(to: .now)
        heartbeatTask.cancel()
        _ = await heartbeatTask.result

        XCTAssertLessThanOrEqual(elapsed, .milliseconds(1_250))
        XCTAssertLessThan(heartbeat.maximumInterval, 0.100)
        await assertProcessExits(originalPID, within: .milliseconds(250))

        let afterTimeout = await client.diagnostics()
        XCTAssertEqual(afterTimeout.pendingRequestCount, 0)
        XCTAssertGreaterThan(afterTimeout.generation, oldLease.brokerGeneration)
        let oldLeaseIsCurrent = await client.validate(oldLease)
        XCTAssertFalse(oldLeaseIsCurrent)

        let restartStartedAt = ContinuousClock.now
        _ = try await client.baseline()
        XCTAssertLessThanOrEqual(
            restartStartedAt.duration(to: .now),
            .seconds(2)
        )
        let restarted = await client.diagnostics()
        XCTAssertNotEqual(restarted.processIdentifier, originalPID)
        XCTAssertEqual(restarted.pendingRequestCount, 0)

        Self.stop(fixture.process)
        await client.shutdown()
    }

    func testPreparedWriteDoesNotResolveOldPromiseBeforeCommit()
        async throws
    {
        let pasteboardName = UUID().uuidString.lowercased()
        let fixture = try launchBlockingProvider(pasteboardName: pasteboardName)
        addTeardownBlock {
            Self.stop(fixture.process)
        }
        let readyLine: String
        do {
            readyLine = try await readReadyLine(from: fixture.output)
        } catch {
            Self.stop(fixture.process)
            throw XCTSkip(
                "The named pasteboard was unavailable before the blocking "
                    + "provider fixture could publish."
            )
        }
        let baseline = try XCTUnwrap(
            Int(readyLine.dropFirst("READY ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_BASELINE_CHANGE_COUNT":
                    String(baseline),
            ]
        )
        addTeardownBlock {
            await client.shutdown()
        }
        let brokerBaseline = try await client.baseline()
        XCTAssertEqual(brokerBaseline, baseline)
        let beforeBlock = await client.diagnostics()
        let originalPID = try XCTUnwrap(beforeBlock.processIdentifier)

        let startedAt = ContinuousClock.now
        let lease = try await client.prepare(ClipboardBrokerWriteRequest(
            items: [ClipboardBrokerWriteItem(representations: [
                ClipboardBrokerWriteRepresentationEntry(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    value: .string("replacement")
                ),
            ])],
            expectedChangeCount: baseline
        ))
        XCTAssertLessThanOrEqual(
            startedAt.duration(to: .now),
            .milliseconds(1_250)
        )

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        XCTAssertEqual(pasteboard.changeCount, baseline)
        try await client.cancel(lease)
        let afterCancel = await client.diagnostics()
        XCTAssertEqual(afterCancel.processIdentifier, originalPID)
        XCTAssertEqual(afterCancel.pendingRequestCount, 0)

        Self.stop(fixture.process)
        await client.shutdown()
    }

    func testScreenSharingDeferredPromiseUsesOneSecondThenQuarterSecondAttempts() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let fixture = try launchBlockingProvider(pasteboardName: pasteboardName)
        addTeardownBlock {
            Self.stop(fixture.process)
        }
        let readyLine: String
        do {
            readyLine = try await readReadyLine(from: fixture.output)
        } catch {
            Self.stop(fixture.process)
            throw XCTSkip(
                "The named pasteboard was unavailable before the blocking "
                    + "provider fixture could publish."
            )
        }
        let baseline = try XCTUnwrap(
            Int(readyLine.dropFirst("READY ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_BASELINE_CHANGE_COUNT":
                    String(baseline),
            ]
        )
        addTeardownBlock { await client.shutdown() }
        _ = try await client.baseline()

        let deferred = try await client.observe(
            ClipboardBrokerObserveRequest(
                baselineChangeCount: baseline - 1,
                screenSharingActive: true
            )
        )
        XCTAssertEqual(deferred.status, .deferred)
        let ticket = try XCTUnwrap(deferred.resolutionTicket)

        let heartbeat = HeartbeatRecorder()
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.record()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let firstStartedAt = ContinuousClock.now
        do {
            _ = try await client.resolve(
                ticket: ticket,
                timeout: .seconds(1)
            )
            XCTFail("The first promised-data resolution must time out.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestTimedOut
            )
        }
        XCTAssertLessThanOrEqual(
            firstStartedAt.duration(to: .now),
            .milliseconds(1_250)
        )

        let retryStartedAt = ContinuousClock.now
        do {
            _ = try await client.resolve(
                ticket: ticket,
                timeout: .milliseconds(250)
            )
            XCTFail("The cache-only retry must also time out.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestTimedOut
            )
        }
        XCTAssertLessThanOrEqual(
            retryStartedAt.duration(to: .now),
            .milliseconds(500)
        )
        heartbeatTask.cancel()
        _ = await heartbeatTask.result

        XCTAssertLessThan(heartbeat.maximumInterval, 0.100)
        let diagnostics = await client.diagnostics()
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        XCTAssertFalse(diagnostics.circuitIsOpen)

        Self.stop(fixture.process)
        await client.shutdown()
    }

    func testPipeBackpressureCannotPreventOneSecondKill() async throws {
        let client = ClipboardBrokerClient(
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/tail") },
            executableArguments: ["-f", "/dev/null"]
        )
        addTeardownBlock { await client.shutdown() }
        let text = String(
            repeating: "x",
            count: ClipboardBrokerLimits.maxTextBytes
        )
        let startedAt = ContinuousClock.now
        let requestTask = Task {
            try await client.write(ClipboardBrokerWriteRequest(items: [
                ClipboardBrokerWriteItem(representations: [
                    ClipboardBrokerWriteRepresentationEntry(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        value: .string(text)
                    ),
                ]),
            ]))
        }
        let processIdentifier = try await waitForBrokerPID(client)

        do {
            _ = try await requestTask.value
            XCTFail("A process that never reads stdin must time out.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestTimedOut
            )
        }

        XCTAssertLessThanOrEqual(
            startedAt.duration(to: .now),
            .milliseconds(1_250)
        )
        await assertProcessExits(processIdentifier, within: .milliseconds(250))
        let diagnostics = await client.diagnostics()
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        await client.shutdown()
    }

    func testPassiveBaselineTimeoutsOpenCircuitAfterThreeRestarts() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT": "block_baseline",
            ]
        )
        addTeardownBlock { await client.shutdown() }

        for _ in 0..<3 {
            do {
                _ = try await client.observe(ClipboardBrokerObserveRequest(
                    baselineChangeCount: nil
                ))
                XCTFail("The injected baseline must time out.")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardBrokerClientError,
                    .requestTimedOut
                )
            }
        }

        let circuitStartedAt = ContinuousClock.now
        let skipped = try await client.observe(ClipboardBrokerObserveRequest(
            baselineChangeCount: nil
        ))
        XCTAssertEqual(skipped.status, .noChange)
        XCTAssertLessThan(
            circuitStartedAt.duration(to: .now),
            .milliseconds(100)
        )
        let diagnostics = await client.diagnostics()
        XCTAssertTrue(diagnostics.circuitIsOpen)
        XCTAssertNil(diagnostics.processIdentifier)
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        await client.shutdown()
    }

    func testParentWatchdogExitsOrphanedBrokerWithinTwoSeconds() async throws {
        let brokerURL = try productURL(named: "BlocksClipboardBroker")
        let sessionID = UUID().uuidString.lowercased()
        let stagingToken = ClipboardBrokerStaging.makeToken()
        let pasteboardName = UUID().uuidString.lowercased()
        let launcher = Process()
        let output = Pipe()
        let control = Pipe()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [
            "-c",
            """
            set -eu
            staging_root="$2/\(ClipboardBrokerStaging.directoryName)-$$-$3"
            umask 077
            mkdir -m 700 "$staging_root"
            printf 'orphaned broker payload' > "$staging_root/$4.\(ClipboardBrokerStaging.fileExtension)"
            chmod 600 "$staging_root/$4.\(ClipboardBrokerStaging.fileExtension)"
            staging_device=$(/usr/bin/stat -f '%d' "$staging_root")
            staging_inode=$(/usr/bin/stat -f '%i' "$staging_root")
            sleep 4 | env \
                BLOCKS_CLIPBOARD_STAGING_ROOT="$staging_root" \
                BLOCKS_CLIPBOARD_STAGING_DEVICE="$staging_device" \
                BLOCKS_CLIPBOARD_STAGING_INODE="$staging_inode" \
                BLOCKS_CLIPBOARD_PARENT_PID="$$" \
                BLOCKS_CLIPBOARD_BROKER_TEST_PASTEBOARD_NAME="$5" \
                "$1" >/dev/null 2>/dev/null &
            broker_pid=$!
            sleep 1
            printf 'READY %s %s\\n' "$$" "$broker_pid"
            IFS= read -r release
            """,
            "blocks-watchdog-test",
            brokerURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            sessionID,
            stagingToken,
            pasteboardName,
        ]
        launcher.standardOutput = output
        launcher.standardError = FileHandle.nullDevice
        launcher.standardInput = control
        try launcher.run()
        var processIdentifier: pid_t?
        var stagingRoot: URL?
        defer {
            control.fileHandleForWriting.closeFile()
            Self.stop(launcher)
            if let processIdentifier {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
            if let stagingRoot {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
        }
        let readyLine = try await readReadyLine(
            from: output.fileHandleForReading
        )
        let readyFields = readyLine.split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(readyFields.count, 3)
        XCTAssertEqual(readyFields.first, "READY")
        let parentProcessIdentifier = try XCTUnwrap(
            pid_t(String(readyFields[1]))
        )
        processIdentifier = try XCTUnwrap(
            pid_t(String(readyFields[2]))
        )
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ClipboardBrokerStaging.directoryName)-\(parentProcessIdentifier)-\(sessionID)",
                isDirectory: true
            )
            .standardizedFileURL
        let resolvedProcessIdentifier = try XCTUnwrap(processIdentifier)
        let resolvedStagingRoot = try XCTUnwrap(stagingRoot)
        let payloadURL = try XCTUnwrap(ClipboardBrokerStaging.fileURL(
            rootDirectory: resolvedStagingRoot,
            token: stagingToken
        ))

        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: resolvedStagingRoot.path
        )
        let payloadAttributes = try FileManager.default.attributesOfItem(
            atPath: payloadURL.path
        )
        XCTAssertEqual(
            rootAttributes[.type] as? FileAttributeType,
            .typeDirectory
        )
        XCTAssertEqual(
            (rootAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            payloadAttributes[.type] as? FileAttributeType,
            .typeRegular
        )
        XCTAssertEqual(
            (payloadAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        control.fileHandleForWriting.write(Data([0x0a]))
        control.fileHandleForWriting.closeFile()
        launcher.waitUntilExit()

        await assertProcessExits(resolvedProcessIdentifier, within: .seconds(2))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: resolvedStagingRoot.path),
            "The orphaned Broker must remove its validated staging root."
        )
    }

    func testParentWatchdogHardDeadlineExitsWhenCleanupDoesNotReturn() async throws {
        let brokerURL = try productURL(named: "BlocksClipboardBroker")
        let launcher = Process()
        let output = Pipe()
        let control = Pipe()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [
            "-c",
            """
            set -eu
            sleep 4 | env \
                BLOCKS_CLIPBOARD_PARENT_PID="$$" \
                BLOCKS_CLIPBOARD_BROKER_TEST_WATCHDOG_CLEANUP_HANG="1" \
                "$1" >/dev/null 2>/dev/null &
            broker_pid=$!
            sleep 1
            printf 'READY %s\\n' "$broker_pid"
            IFS= read -r release
            """,
            "blocks-watchdog-hard-deadline-test",
            brokerURL.path,
        ]
        launcher.standardOutput = output
        launcher.standardError = FileHandle.nullDevice
        launcher.standardInput = control
        try launcher.run()
        var processIdentifier: pid_t?
        defer {
            control.fileHandleForWriting.closeFile()
            Self.stop(launcher)
            if let processIdentifier {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
        let readyLine = try await readReadyLine(
            from: output.fileHandleForReading
        )
        let readyFields = readyLine.split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(readyFields.count, 2)
        XCTAssertEqual(readyFields.first, "READY")
        processIdentifier = try XCTUnwrap(
            pid_t(String(readyFields[1]))
        )
        let resolvedProcessIdentifier = try XCTUnwrap(processIdentifier)

        control.fileHandleForWriting.write(Data([0x0a]))
        control.fileHandleForWriting.closeFile()
        launcher.waitUntilExit()

        await assertProcessExits(resolvedProcessIdentifier, within: .seconds(2))
    }

    private func assertOversizedWriteRejectedBeforeLaunch(
        _ request: ClipboardBrokerWriteRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        ClipboardBrokerDataTransport.removeRoot()
        defer { ClipboardBrokerDataTransport.removeRoot() }

        let executableProbe = ClipboardBrokerExecutableProbe()
        let client = ClipboardBrokerClient(executableURLProvider: {
            executableProbe.resolveUnavailableExecutable()
        })
        do {
            _ = try await client.write(request)
            XCTFail(
                "The oversized request must fail during App-side preflight.",
                file: file,
                line: line
            )
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestOversized,
                file: file,
                line: line
            )
        }

        let diagnostics = await client.diagnostics()
        XCTAssertEqual(executableProbe.callCount, 0, file: file, line: line)
        XCTAssertNil(diagnostics.processIdentifier, file: file, line: line)
        XCTAssertEqual(
            diagnostics.pendingRequestCount,
            0,
            file: file,
            line: line
        )
        XCTAssertTrue(
            stagedPayloadURLs().isEmpty,
            "Preflight rejection must happen before staging any payload.",
            file: file,
            line: line
        )
        await client.shutdown()
    }

    private func stagedPayloadURLs() -> [URL] {
        (
            try? FileManager.default.contentsOfDirectory(
                at: ClipboardBrokerDataTransport.rootDirectory,
                includingPropertiesForKeys: nil
            )
        )?.filter {
            $0.pathExtension == ClipboardBrokerStaging.fileExtension
        } ?? []
    }

    private func makeBrokerClient(
        pasteboardName: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> ClipboardBrokerClient {
        var environment = extraEnvironment
        environment["BLOCKS_CLIPBOARD_BROKER_TEST_PASTEBOARD_NAME"] =
            pasteboardName
        let brokerURL = try productURL(named: "BlocksClipboardBroker")
        return ClipboardBrokerClient(
            executableURLProvider: { brokerURL },
            environmentOverrides: environment
        )
    }

    private func launchBlockingProvider(
        pasteboardName: String
    ) throws -> (process: Process, output: FileHandle) {
        let process = Process()
        let output = Pipe()
        process.executableURL = try productURL(
            named: "BlocksClipboardBroker"
        )
        process.standardOutput = output
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in [
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "__CF_USER_TEXT_ENCODING",
            "OS_ACTIVITY_MODE",
        ] {
            environment[key] = inheritedEnvironment[key]
        }
        // The fixture is a standalone AppKit process, not an XCTest host.
        // Inheriting the test bundle injection and DYLD paths prevents its
        // pasteboard owner from reaching READY and turns a real regression
        // into a misleading skip.
        environment[
            "BLOCKS_CLIPBOARD_BROKER_TEST_BLOCKING_PROVIDER_PASTEBOARD_NAME"
        ] = pasteboardName
        process.environment = environment
        // Keep fixture startup failures visible. Silencing this stream turns
        // launch, sandbox and pasteboard publication failures into an
        // indistinguishable two-second skip.
        process.standardError = FileHandle.standardError
        try process.run()
        return (process, output.fileHandleForReading)
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

    private func makeLargeValidPNG() throws -> Data {
        let width = 704
        let height = 704
        let bytesPerRow = width * 4
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: bytesPerRow,
            bitsPerPixel: 32
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        for offset in stride(
            from: 0,
            to: bytesPerRow * height,
            by: 4
        ) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            pixels[offset] = UInt8(truncatingIfNeeded: state)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[offset + 3] = 0xff
        }
        return try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
    }

    private func readReadyLine(from handle: FileHandle) async throws -> String {
        let descriptor = handle.fileDescriptor
        let existingFlags = fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0,
              fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
            throw ClipboardBrokerClientError.malformedResponse
        }
        var buffer = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(Int(count)))
                if buffer.contains(0x0a),
                   let value = String(data: buffer, encoding: .utf8),
                   value.hasPrefix("READY ") {
                    return value
                }
            } else if count == 0 {
                throw ClipboardBrokerClientError.brokerTerminated
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                throw ClipboardBrokerClientError.malformedResponse
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClipboardBrokerClientError.requestTimedOut
    }

    private func waitForBrokerPID(
        _ client: ClipboardBrokerClient
    ) async throws -> pid_t {
        for _ in 0..<200 {
            if let pid = await client.diagnostics().processIdentifier {
                return pid
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ClipboardBrokerClientError.launchFailed
    }

    private func assertProcessExits(
        _ processIdentifier: pid_t,
        within timeout: Duration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Darwin.kill(processIdentifier, 0) != 0, errno == ESRCH {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(
            "Process \(processIdentifier) remained alive past the deadline.",
            file: file,
            line: line
        )
    }

    private nonisolated static func stop(_ process: Process) {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

@MainActor
final class ClipboardPasteboardWriterBrokerTests: XCTestCase {
    func testPreparedAuthorizationRevokedAfterPrepareCancelsRealBrokerLease() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let client = try makeBrokerClient(pasteboardName: pasteboardName)
        let authorization = PreparedWriteAuthorizationGate()
        let broker = PreparedWriteRecordingBroker(
            client: client,
            onPrepared: { authorization.revoke() }
        )
        let writer = ClipboardPasteboardWriter(broker: broker)
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
        }

        let baseline = try await client.baseline()
        do {
            _ = try await writer.write(
                payload: ClipboardRecorderPayload(
                    recordID: "prepared-authorization-revoked",
                    kind: .text,
                    text: "replacement"
                ),
                expectedChangeCount: baseline,
                operationAllowed: { authorization.isAllowed },
                requiresPreparedAuthorization: true
            )
            XCTFail("A revoked authorization must cancel the prepared write.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardAutoPasteError,
                .featureDisabled
            )
        }

        let recordedPreparedLease = await broker.lastPreparedLease()
        let preparedLease = try XCTUnwrap(recordedPreparedLease)
        XCTAssertEqual(pasteboard.changeCount, baseline)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        do {
            _ = try await client.commit(preparedLease)
            XCTFail("The writer must consume the prepared ID when authorization is revoked.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardBrokerClientError,
                .requestSuperseded
            )
        }
    }

    func testCancellingWriterAfterCommitLinearizesStillSettlesBrokerWrite() async throws {
        let pasteboardName = UUID().uuidString.lowercased()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(rawValue: pasteboardName)
        )
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blocks-clipboard-broker-trace-writer-\(UUID().uuidString).plist"
            )
        let client = try makeBrokerClient(
            pasteboardName: pasteboardName,
            extraEnvironment: [
                "BLOCKS_CLIPBOARD_BROKER_TEST_TRACE_PATH": traceURL.path,
                "BLOCKS_CLIPBOARD_BROKER_TEST_FAULT":
                    "delay_commit_write_after_clear_past_request_timeout",
            ]
        )
        let writer = ClipboardPasteboardWriter(broker: client)
        addTeardownBlock {
            await client.shutdown()
            NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            ).clearContents()
            try? FileManager.default.removeItem(at: traceURL)
        }

        let baseline = try await client.baseline()
        let write = Task {
            try await writer.write(
                payload: ClipboardRecorderPayload(
                    recordID: "writer-cancel-after-commit",
                    kind: .text,
                    text: "replacement"
                ),
                expectedChangeCount: baseline,
                requiresPreparedAuthorization: true
            )
        }
        try await waitForTraceCount(
            at: traceURL,
            key: "clearCount",
            atLeast: 1
        )
        write.cancel()

        let lease = try await write.value
        XCTAssertGreaterThan(lease.changeCount, baseline)
        try await waitForTraceCount(
            at: traceURL,
            key: "writeCount",
            atLeast: 1
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }

    func testWriteForwardsExpectedChangeCountAndReturnsBrokerLease() async throws {
        let expectedLease = ClipboardPasteboardWriteLease(
            changeCount: 102,
            brokerGeneration: 7
        )
        let broker = RecordingClipboardBroker(writeLease: expectedLease)
        let writer = ClipboardPasteboardWriter(broker: broker)

        let lease = try await writer.write(
            payload: ClipboardRecorderPayload(
                recordID: "broker-write",
                kind: .text,
                text: "fixture"
            ),
            expectedChangeCount: 100
        )
        let requests = await broker.recordedWrites()

        XCTAssertEqual(lease, expectedLease)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.expectedChangeCount, 100)
        XCTAssertEqual(requests.first?.items.count, 1)
        XCTAssertEqual(requests.first?.items.first?.representations.count, 1)
        XCTAssertEqual(
            requests.first?.items.first?.representations.first?.pasteboardType,
            "public.utf8-plain-text"
        )
        XCTAssertEqual(
            requests.first?.items.first?.representations.first?.value,
            .string("fixture")
        )
    }

    func testBrokerWriteFailureIsReportedAfterOneRequestWithoutRollbackRetry() async {
        let broker = RecordingClipboardBroker(
            writeFailure: .writeFailed
        )
        let writer = ClipboardPasteboardWriter(broker: broker)

        do {
            _ = try await writer.write(
                payload: ClipboardRecorderPayload(
                    recordID: "broker-write-failure",
                    kind: .text,
                    text: "replacement"
                ),
                expectedChangeCount: 12
            )
            XCTFail("The broker failure should be surfaced.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardAutoPasteError,
                .pasteboardWriteFailed
            )
        }

        let requests = await broker.recordedWrites()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.expectedChangeCount, 12)
    }

    func testImagePayloadSendsOnlyInlinePNGWithoutAppTIFFOrStaging() async throws {
        let pngData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        XCTAssertNotNil(NSBitmapImageRep(data: pngData))
        let broker = RecordingClipboardBroker()
        let writer = ClipboardPasteboardWriter(broker: broker)

        _ = try await writer.write(payload: ClipboardRecorderPayload(
            recordID: "inline-png-only",
            kind: .image,
            pngData: pngData
        ))

        let requests = await broker.recordedWrites()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.items.count, 1)
        let item = try XCTUnwrap(request.items.first)
        XCTAssertEqual(item.representations.count, 1)
        let representation = try XCTUnwrap(item.representations.first)
        XCTAssertEqual(
            representation.pasteboardType,
            NSPasteboard.PasteboardType.png.rawValue
        )
        XCTAssertEqual(
            representation.value,
            .data(.inline(pngData))
        )
    }

    func testFileURLPayloadUsesSemanticURLWithoutRawRepresentations() async throws {
        let broker = RecordingClipboardBroker()
        let writer = ClipboardPasteboardWriter(broker: broker)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocks-file-url-\(UUID().uuidString).png")
        try Data("fixture".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        _ = try await writer.write(payload: ClipboardRecorderPayload(
            recordID: "file-url-contract",
            kind: .fileURL,
            text: fileURL.path,
            urlString: fileURL.absoluteString
        ))

        let requests = await broker.recordedWrites()
        let item = try XCTUnwrap(requests.first?.items.first)
        XCTAssertTrue(item.representations.isEmpty)
        XCTAssertEqual(
            item.semanticFileURLString,
            fileURL.absoluteString
        )
    }

    func testLeaseValidationRejectsAnotherBrokerGeneration() async throws {
        let acceptedLease = ClipboardPasteboardWriteLease(
            changeCount: 55,
            brokerGeneration: 3
        )
        let broker = RecordingClipboardBroker(writeLease: acceptedLease)
        let writer = ClipboardPasteboardWriter(broker: broker)
        let issuedLease = try await writer.writePlainText("fixture")
        let staleGenerationLease = ClipboardPasteboardWriteLease(
            changeCount: issuedLease.changeCount,
            brokerGeneration: issuedLease.brokerGeneration + 1
        )

        let issuedLeaseIsCurrent = await writer.validate(issuedLease)
        let staleLeaseIsCurrent = await writer.validate(staleGenerationLease)
        let validations = await broker.recordedValidations()

        XCTAssertTrue(issuedLeaseIsCurrent)
        XCTAssertFalse(staleLeaseIsCurrent)
        XCTAssertEqual(validations, [issuedLease, staleGenerationLease])
    }

    private func makeBrokerClient(
        pasteboardName: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> ClipboardBrokerClient {
        var environment = extraEnvironment
        environment["BLOCKS_CLIPBOARD_BROKER_TEST_PASTEBOARD_NAME"] =
            pasteboardName
        let brokerURL = try productURL(named: "BlocksClipboardBroker")
        return ClipboardBrokerClient(
            executableURLProvider: { brokerURL },
            environmentOverrides: environment
        )
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

    private func waitForTraceCount(
        at traceURL: URL,
        key: String,
        atLeast count: Int
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: traceURL),
               let trace = try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ) as? [String: Any],
               (trace[key] as? Int ?? 0) >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Broker trace \(key) did not reach \(count).")
    }
}

@MainActor
final class ClipboardLiveCaptureBackpressureTests: XCTestCase {
    func testDeferredObservationPublishesAfterOneSuccessfulResolution() async {
        let broker = ControlledObservationBroker(
            resolutionResults: [
                .success(Self.capturedTextResult(
                    text: "resolved once",
                    changeCount: 501
                )),
            ]
        )
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            deferredInitialDelay: .milliseconds(1),
            deferredRetryDelay: .milliseconds(1),
            broker: broker
        )
        var publishedCount = 0
        service.start { _ in publishedCount += 1 }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 1 }

        let completed = await broker.completeNext(
            with: Self.deferredTextResult(changeCount: 501)
        )
        XCTAssertTrue(completed)
        await waitUntil { publishedCount == 1 }

        let resolutionCount = await broker.resolutionCount()
        XCTAssertEqual(resolutionCount, 1)
    }

    func testDeferredObservationRetriesOnceAfterTimeout() async {
        let broker = ControlledObservationBroker(
            resolutionResults: [
                .failure(.requestTimedOut),
                .success(Self.capturedTextResult(
                    text: "resolved from cache",
                    changeCount: 502
                )),
            ]
        )
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            deferredInitialDelay: .milliseconds(1),
            deferredRetryDelay: .milliseconds(1),
            broker: broker
        )
        var publishedCount = 0
        service.start { _ in publishedCount += 1 }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 1 }

        _ = await broker.completeNext(
            with: Self.deferredTextResult(changeCount: 502)
        )
        await waitUntil { publishedCount == 1 }

        let resolutionCount = await broker.resolutionCount()
        let timeouts = await broker.recordedResolutionTimeouts()
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertEqual(
            timeouts,
            [.seconds(1), .milliseconds(250)]
        )
    }

    func testDeferredObservationStopsAfterTwoTimeoutsWithoutPlaceholder() async {
        let broker = ControlledObservationBroker(
            resolutionResults: [
                .failure(.requestTimedOut),
                .failure(.requestTimedOut),
            ]
        )
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            deferredInitialDelay: .milliseconds(1),
            deferredRetryDelay: .milliseconds(1),
            broker: broker
        )
        var publishedCount = 0
        service.start { _ in publishedCount += 1 }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 1 }

        _ = await broker.completeNext(
            with: Self.deferredTextResult(changeCount: 503)
        )
        await waitUntil { await broker.resolutionCount() == 2 }
        for _ in 0..<10 { await Task.yield() }

        let resolutionCount = await broker.resolutionCount()
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertEqual(publishedCount, 0)
    }

    func testStaleDeferredResolutionLeavesFollowingVersionObservable() async {
        let broker = ControlledObservationBroker(
            resolutionResults: [
                .success(ClipboardBrokerObservationResult(
                    status: .skipped,
                    changeCount: 504,
                    observedAfterChangeCount: 505,
                    skipReason: .stale
                )),
            ]
        )
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            deferredInitialDelay: .milliseconds(1),
            deferredRetryDelay: .milliseconds(1),
            broker: broker
        )
        var publishedCount = 0
        service.start { _ in publishedCount += 1 }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 1 }

        _ = await broker.completeNext(
            with: Self.deferredTextResult(changeCount: 504)
        )
        await waitUntil { await broker.generationCheckCount() >= 3 }
        XCTAssertEqual(service.observedChangeCount, 504)

        service.pollPasteboard()
        await waitUntil { await broker.observationCount() == 2 }
        let observations = await broker.recordedObservations()
        XCTAssertEqual(observations.last?.baselineChangeCount, 504)
        _ = await broker.completeNext(
            with: Self.capturedTextResult(
                text: "following version",
                changeCount: 505
            )
        )
        await waitUntil { publishedCount == 1 }

        XCTAssertEqual(service.observedChangeCount, 505)
    }

    func testStartAndStopTogglePassiveMonitoringWithoutShuttingDownSharedBroker() async {
        let broker = ControlledObservationBroker()
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            broker: broker
        )
        service.start { _ in
            XCTFail("No-change observations must not publish a capture.")
        }
        await waitUntil { await broker.observationCount() == 1 }

        service.stop()
        await waitUntil { await broker.passiveMonitoringIsActive() == false }
        let completedObservation = await broker.completeNext(
            with: Self.noChangeResult(100)
        )
        XCTAssertTrue(completedObservation)
        await Task.yield()

        let shutdownCount = await broker.shutdownCount()
        XCTAssertEqual(shutdownCount, 0)
        let monitoringTransitions = await broker.recordedMonitoringTransitions()
        XCTAssertEqual(monitoringTransitions.first, true)
        XCTAssertEqual(monitoringTransitions.last, false)
    }

    func testImmediateStopCannotBeOvertakenByLateMonitoringActivation() async {
        let broker = ControlledObservationBroker()
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            broker: broker
        )

        service.start { _ in
            XCTFail("An immediately stopped service must not publish.")
        }
        service.stop()

        await waitUntil {
            let hasUpdate = await broker.hasMonitoringUpdate()
            let isActive = await broker.passiveMonitoringIsActive()
            return hasUpdate && !isActive
        }
        let isActive = await broker.passiveMonitoringIsActive()
        let shutdownCount = await broker.shutdownCount()
        XCTAssertFalse(isActive)
        XCTAssertEqual(shutdownCount, 0)
    }

    func testOneInflightObservationRunsAndOnlyLatestPendingPollIsRetained() async {
        let broker = ControlledObservationBroker()
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            broker: broker
        )
        var prefilterCallCount = 0
        service.start(
            prefilterProvider: { _ in
                prefilterCallCount += 1
                switch prefilterCallCount {
                case 1:
                    return .allow
                case 2:
                    return ClipboardLiveCapturePrefilter(
                        disposition: .redactPaused,
                        screenSharingActive: false
                    )
                default:
                    return ClipboardLiveCapturePrefilter(
                        disposition: .redactExcludedSource,
                        screenSharingActive: true
                    )
                }
            },
            onCapture: { _ in
                XCTFail("No-change observations must not publish a capture.")
            }
        )
        defer { service.stop() }

        await waitUntil { await broker.observationCount() == 1 }
        service.pollPasteboard()
        service.pollPasteboard()

        let initialObservationCount = await broker.observationCount()
        XCTAssertEqual(prefilterCallCount, 3)
        let completedInitialObservation = await broker.completeNext(
            with: Self.noChangeResult(101)
        )
        XCTAssertEqual(initialObservationCount, 1)
        XCTAssertTrue(completedInitialObservation)

        await waitUntil { await broker.observationCount() == 2 }
        let requests = await broker.recordedObservations()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].baselineChangeCount)
        XCTAssertEqual(requests[0].prefilterDisposition, .allow)
        XCTAssertEqual(requests[1].baselineChangeCount, 101)
        XCTAssertEqual(
            requests[1].prefilterDisposition,
            .redactExcludedSource
        )
        XCTAssertTrue(requests[1].screenSharingActive)

        let completedPendingObservation = await broker.completeNext(
            with: Self.noChangeResult(102)
        )
        XCTAssertTrue(completedPendingObservation)
        await waitUntil { service.observedChangeCount == 102 }
        let finalObservationCount = await broker.observationCount()
        XCTAssertEqual(finalObservationCount, 2)
    }

    func testResponseFromPreviousServiceGenerationIsNotPublishedAfterRestart() async {
        let broker = ControlledObservationBroker()
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            broker: broker
        )
        var firstGenerationCaptureCount = 0
        var secondGenerationCaptureCount = 0

        service.start { _ in
            firstGenerationCaptureCount += 1
        }
        await waitUntil { await broker.observationCount() == 1 }

        service.start { _ in
            secondGenerationCaptureCount += 1
        }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 2 }

        let completedStaleObservation = await broker.completeNext(
            with: Self.capturedTextResult(
                text: "stale generation",
                changeCount: 201
            )
        )
        XCTAssertTrue(completedStaleObservation)
        await Task.yield()
        let completedCurrentObservation = await broker.completeNext(
            with: Self.noChangeResult(202)
        )
        XCTAssertTrue(completedCurrentObservation)
        await waitUntil { service.observedChangeCount == 202 }

        XCTAssertEqual(firstGenerationCaptureCount, 0)
        XCTAssertEqual(secondGenerationCaptureCount, 0)
    }

    func testCompletedCancelledGenerationCannotClearCurrentInflightSlot() async {
        let broker = ControlledObservationBroker()
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            broker: broker
        )

        service.start { _ in
            XCTFail("A stale generation must not publish.")
        }
        await waitUntil { await broker.observationCount() == 1 }

        service.start { _ in
            XCTFail("No-change observations must not publish.")
        }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 2 }

        let completedStaleObservation = await broker.completeNext(
            with: Self.noChangeResult(401)
        )
        XCTAssertTrue(completedStaleObservation)
        // Let the cancelled generation run its defer after its deliberately
        // uncooperative observe continuation has finally resumed.
        for _ in 0..<10 {
            await Task.yield()
        }

        service.pollPasteboard()
        try? await Task.sleep(for: .milliseconds(20))
        let countWhileCurrentObservationIsInflight =
            await broker.observationCount()
        XCTAssertEqual(
            countWhileCurrentObservationIsInflight,
            2,
            "The current generation must still own the sole in-flight slot."
        )

        let completedCurrentObservation = await broker.completeNext(
            with: Self.noChangeResult(402)
        )
        XCTAssertTrue(completedCurrentObservation)
        await waitUntil { await broker.observationCount() == 3 }
        let completedPendingObservation = await broker.completeNext(
            with: Self.noChangeResult(403)
        )
        XCTAssertTrue(completedPendingObservation)
        await waitUntil { service.observedChangeCount == 403 }
    }

    func testBrokerGenerationChangeBeforeStagingResolveCleansPayloadAndDoesNotPublish() async throws {
        let data = Data(
            repeating: 0x5a,
            count: ClipboardBrokerLimits.inlineImageBytes + 1
        )
        let reference = try ClipboardBrokerDataTransport.reference(
            for: data,
            stagesLargePayload: true
        )
        guard case let .staged(token, _) = reference,
              let stagedURL = ClipboardBrokerStaging.fileURL(
                  rootDirectory: ClipboardBrokerDataTransport.rootDirectory,
                  token: token
              ) else {
            return XCTFail("Expected a staged payload.")
        }
        defer {
            ClipboardBrokerDataTransport.removeStagedReference(reference)
            ClipboardBrokerDataTransport.removeRoot()
        }

        let broker = ControlledObservationBroker(
            generationResponses: [true, false]
        )
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            broker: broker
        )
        var publishedCount = 0
        service.start { _ in publishedCount += 1 }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 1 }

        let completed = await broker.completeNext(
            with: Self.capturedImageResult(
                reference: reference,
                changeCount: 301,
                brokerGeneration: 7
            )
        )
        XCTAssertTrue(completed)
        await waitUntil { await broker.generationCheckCount() >= 2 }

        XCTAssertEqual(publishedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testBrokerGenerationChangeAtFinalPublishBarrierDoesNotPublish() async {
        let broker = ControlledObservationBroker(
            generationResponses: [true, true, true, false]
        )
        let service = ClipboardLiveCaptureService(
            pollInterval: 60,
            broker: broker
        )
        var publishedCount = 0
        service.start { _ in publishedCount += 1 }
        defer { service.stop() }
        await waitUntil { await broker.observationCount() == 1 }

        let completed = await broker.completeNext(
            with: Self.capturedTextResult(
                text: "must not publish after generation changes",
                changeCount: 302,
                brokerGeneration: 9
            )
        )
        XCTAssertTrue(completed)
        await waitUntil { await broker.generationCheckCount() >= 4 }

        XCTAssertEqual(publishedCount, 0)
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await predicate() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(
            "Condition did not become true before the test deadline.",
            file: file,
            line: line
        )
    }

    nonisolated private static func noChangeResult(
        _ changeCount: Int
    ) -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .noChange,
            changeCount: changeCount,
            observedAfterChangeCount: changeCount
        )
    }

    nonisolated private static func deferredTextResult(
        changeCount: Int
    ) -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .deferred,
            changeCount: changeCount,
            observedAfterChangeCount: changeCount,
            resolutionTicket: ClipboardBrokerResolutionTicket(
                changeCount: changeCount,
                family: .text,
                pasteboardType: "public.utf8-plain-text",
                advertisedTypes: ["public.utf8-plain-text"]
            )
        )
    }

    nonisolated private static func capturedTextResult(
        text: String,
        changeCount: Int,
        brokerGeneration: UInt64 = 0
    ) -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .captured,
            changeCount: changeCount,
            observedAfterChangeCount: changeCount,
            representation: ClipboardBrokerCapturedRepresentation(
                family: .text,
                pasteboardType: "public.utf8-plain-text",
                advertisedTypes: ["public.utf8-plain-text"],
                value: text
            ),
            brokerGeneration: brokerGeneration
        )
    }

    nonisolated private static func capturedImageResult(
        reference: ClipboardBrokerDataReference,
        changeCount: Int,
        brokerGeneration: UInt64
    ) -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .captured,
            changeCount: changeCount,
            observedAfterChangeCount: changeCount,
            representation: ClipboardBrokerCapturedRepresentation(
                family: .imagePNG,
                pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
                advertisedTypes: [NSPasteboard.PasteboardType.png.rawValue],
                data: reference
            ),
            brokerGeneration: brokerGeneration
        )
    }
}

@MainActor
private final class HeartbeatRecorder {
    private var lastRecordedAt: TimeInterval?
    private(set) var maximumInterval: TimeInterval = 0

    func record() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastRecordedAt {
            maximumInterval = max(maximumInterval, now - lastRecordedAt)
        }
        lastRecordedAt = now
    }
}

private final class ClipboardBrokerRootOperationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired = false
    private var finalized = false
    let release = DispatchSemaphore(value: 0)

    var hasAcquired: Bool {
        lock.withLock { acquired }
    }

    var hasFinalized: Bool {
        lock.withLock { finalized }
    }

    func markAcquired() {
        lock.withLock {
            acquired = true
        }
    }

    func markFinalized() {
        lock.withLock {
            finalized = true
        }
    }
}

private final class ClipboardBrokerExecutableProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedExecutableCount = 0

    var callCount: Int {
        lock.withLock { resolvedExecutableCount }
    }

    func resolveUnavailableExecutable() -> URL? {
        lock.withLock {
            resolvedExecutableCount += 1
        }
        return nil
    }
}

private actor RecordingClipboardBroker: ClipboardBrokerServing {
    private let writeLease: ClipboardPasteboardWriteLease
    private let writeFailure: ClipboardBrokerClientError?
    private var writes: [ClipboardBrokerWriteRequest] = []
    private var validations: [ClipboardPasteboardWriteLease] = []

    init(
        writeLease: ClipboardPasteboardWriteLease = ClipboardPasteboardWriteLease(
            changeCount: 1,
            brokerGeneration: 1
        ),
        writeFailure: ClipboardBrokerClientError? = nil
    ) {
        self.writeLease = writeLease
        self.writeFailure = writeFailure
    }

    func baseline() async throws -> Int {
        writeLease.changeCount
    }

    func observe(
        _ request: ClipboardBrokerObserveRequest
    ) async throws -> ClipboardBrokerObservationResult {
        ClipboardBrokerObservationResult(
            status: .noChange,
            changeCount: request.baselineChangeCount ?? 0,
            observedAfterChangeCount: request.baselineChangeCount ?? 0,
            prefilterDisposition: request.prefilterDisposition
        )
    }

    func write(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPasteboardWriteLease {
        writes.append(request)
        if let writeFailure {
            throw writeFailure
        }
        return writeLease
    }

    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        validations.append(lease)
        return lease == writeLease
    }

    func currentPlainText(
        limit: Int
    ) async throws -> ClipboardBrokerPlainTextResult {
        ClipboardBrokerPlainTextResult(
            text: nil,
            originalCharacterCount: 0,
            truncated: false,
            changeCount: writeLease.changeCount
        )
    }

    func shutdown() async {}

    func recordedWrites() -> [ClipboardBrokerWriteRequest] {
        writes
    }

    func recordedValidations() -> [ClipboardPasteboardWriteLease] {
        validations
    }
}

private actor PreparedWriteRecordingBroker: ClipboardBrokerServing {
    private let client: ClipboardBrokerClient
    private let onPrepared: @Sendable () -> Void
    private var preparedLease: ClipboardPreparedPasteboardWriteLease?

    init(
        client: ClipboardBrokerClient,
        onPrepared: @escaping @Sendable () -> Void = {}
    ) {
        self.client = client
        self.onPrepared = onPrepared
    }

    func baseline() async throws -> Int {
        try await client.baseline()
    }

    func observe(
        _ request: ClipboardBrokerObserveRequest
    ) async throws -> ClipboardBrokerObservationResult {
        try await client.observe(request)
    }

    func write(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPasteboardWriteLease {
        try await client.write(request)
    }

    func supportsPreparedWrites() async -> Bool {
        await client.supportsPreparedWrites()
    }

    func prepare(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPreparedPasteboardWriteLease {
        let lease = try await client.prepare(request)
        preparedLease = lease
        onPrepared()
        return lease
    }

    func commit(
        _ lease: ClipboardPreparedPasteboardWriteLease
    ) async throws -> ClipboardPasteboardWriteLease {
        try await client.commit(lease)
    }

    func cancel(
        _ lease: ClipboardPreparedPasteboardWriteLease
    ) async throws {
        try await client.cancel(lease)
    }

    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        await client.validate(lease)
    }

    func currentPlainText(
        limit: Int
    ) async throws -> ClipboardBrokerPlainTextResult {
        try await client.currentPlainText(limit: limit)
    }

    func shutdown() async {
        await client.shutdown()
    }

    func lastPreparedLease() -> ClipboardPreparedPasteboardWriteLease? {
        preparedLease
    }
}

private final class PreparedWriteAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true

    var isAllowed: Bool {
        lock.withLock { allowed }
    }

    func revoke() {
        lock.withLock {
            allowed = false
        }
    }
}

private actor ControlledObservationBroker: ClipboardBrokerServing {
    private struct PendingObservation {
        let continuation: CheckedContinuation<
            ClipboardBrokerObservationResult,
            Error
        >
    }

    private var observations: [ClipboardBrokerObserveRequest] = []
    private var pending: [PendingObservation] = []
    private var generationResponses: [Bool]
    private var resolutionResults: [
        Result<ClipboardBrokerObservationResult, ClipboardBrokerClientError>
    ]
    private var resolutionTickets: [ClipboardBrokerResolutionTicket] = []
    private var resolutionTimeouts: [Duration] = []
    private var generationChecks = 0
    private var shutdownCalls = 0
    private var monitoringOwners: [UUID: (revision: UInt64, active: Bool)] = [:]
    private var monitoringTransitions: [Bool] = []

    init(
        generationResponses: [Bool] = [],
        resolutionResults: [
            Result<
                ClipboardBrokerObservationResult,
                ClipboardBrokerClientError
            >
        ] = []
    ) {
        self.generationResponses = generationResponses
        self.resolutionResults = resolutionResults
    }

    func baseline() async throws -> Int {
        observations.last?.baselineChangeCount ?? 0
    }

    func observe(
        _ request: ClipboardBrokerObserveRequest
    ) async throws -> ClipboardBrokerObservationResult {
        observations.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingObservation(continuation: continuation))
        }
    }

    func resolve(
        ticket: ClipboardBrokerResolutionTicket,
        timeout: Duration
    ) async throws -> ClipboardBrokerObservationResult {
        resolutionTickets.append(ticket)
        resolutionTimeouts.append(timeout)
        guard !resolutionResults.isEmpty else {
            return ClipboardBrokerObservationResult(
                status: .skipped,
                changeCount: ticket.changeCount,
                observedAfterChangeCount: ticket.changeCount,
                skipReason: .unsupported
            )
        }
        return try resolutionResults.removeFirst().get()
    }

    func write(
        _ request: ClipboardBrokerWriteRequest
    ) async throws -> ClipboardPasteboardWriteLease {
        ClipboardPasteboardWriteLease(changeCount: 1, brokerGeneration: 1)
    }

    func validate(_ lease: ClipboardPasteboardWriteLease) async -> Bool {
        true
    }

    func generationIsCurrent(_ brokerGeneration: UInt64) async -> Bool {
        generationChecks += 1
        guard !generationResponses.isEmpty else {
            return brokerGeneration == 0
        }
        return generationResponses.removeFirst()
    }

    func resolutionCount() -> Int {
        resolutionTickets.count
    }

    func recordedResolutionTimeouts() -> [Duration] {
        resolutionTimeouts
    }

    func currentPlainText(
        limit: Int
    ) async throws -> ClipboardBrokerPlainTextResult {
        ClipboardBrokerPlainTextResult(
            text: nil,
            originalCharacterCount: 0,
            truncated: false,
            changeCount: 0
        )
    }

    func updatePassiveMonitoring(
        ownerID: UUID,
        revision: UInt64,
        active: Bool
    ) async {
        if let current = monitoringOwners[ownerID],
           revision <= current.revision {
            return
        }
        monitoringOwners[ownerID] = (revision, active)
        monitoringTransitions.append(active)
    }

    func shutdown() async {
        shutdownCalls += 1
    }

    func observationCount() -> Int {
        observations.count
    }

    func recordedObservations() -> [ClipboardBrokerObserveRequest] {
        observations
    }

    func generationCheckCount() -> Int {
        generationChecks
    }

    func shutdownCount() -> Int {
        shutdownCalls
    }

    func passiveMonitoringIsActive() -> Bool {
        monitoringOwners.values.contains(where: \.active)
    }

    func recordedMonitoringTransitions() -> [Bool] {
        monitoringTransitions
    }

    func hasMonitoringUpdate() -> Bool {
        !monitoringOwners.isEmpty
    }

    func completeNext(
        with result: ClipboardBrokerObservationResult
    ) -> Bool {
        guard !pending.isEmpty else { return false }
        let next = pending.removeFirst()
        next.continuation.resume(returning: result)
        return true
    }
}
