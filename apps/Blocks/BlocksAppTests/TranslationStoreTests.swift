@testable import BlocksCore
import AppKit
import Combine
import Security
import XCTest
@testable import Blocks

#if canImport(Translation)
import Translation
#endif

@MainActor
final class TranslationStoreTests: XCTestCase {
    func testProductionRegistryContainsBuiltInsAndNoMockService() {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)

        XCTAssertEqual(
            Set(store.availableServices.map(\.id)),
            Set([
                "apple-local",
                "openai-compatible",
                "community:mymemory",
                "community:google-web",
                "community:tencent-web",
            ])
        )
        XCTAssertFalse(
            store.availableServices.contains {
                $0.id == "community:deepl-web"
            },
            "A community source that failed the release request probe must not be exposed."
        )
        XCTAssertEqual(store.enabledServiceIDs, ["apple-local"])
        XCTAssertFalse(
            store.availableServices.contains {
                $0.id.localizedCaseInsensitiveContains("mock")
            }
        )
    }

    func testCommunityWebAdaptersParseIsolatedResponses()
        async throws
    {
        let transport = TranslationCommunityTransportProbe(
            responsesByHost: [
                "api.mymemory.translated.net":
                    Data(
                        #"{"responseStatus":200,"responseData":{"translatedText":"你好"}}"#
                            .utf8
                    ),
                "translate.googleapis.com":
                    Data(#"[[["你好","Hello",null,null,10]],null,"en"]"#.utf8),
                "www2.deepl.com":
                    Data(
                        #"{"result":{"texts":[{"text":"你好"}]}}"#
                            .utf8
                    ),
                "wxapp.translator.qq.com":
                    Data(
                        #"{"errCode":0,"source":"en","target":"zh","targetText":"你好"}"#
                            .utf8
                    ),
            ]
        )
        let request = TranslationServiceRequest(
            sessionID: "community-fixture",
            input: TranslationInput(
                source: .manual,
                text: "Hello"
            ),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("zh-Hans")!
            )
        )

        for source in TranslationCommunityWebSource.allCases {
            let adapter = acknowledgedCommunityAdapter(
                source: source,
                transport: transport
            )
            var output: String?
            for try await event in adapter.translate(request) {
                if case let .completed(text, _, _) = event {
                    output = text
                }
            }
            XCTAssertEqual(output, "你好", source.rawValue)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Cookie") == nil
            }
        )
    }

    func testTencentRejectsUnsupportedDirectedLanguagePairBeforeRequest()
        throws
    {
        let adapter = acknowledgedCommunityAdapter(
            source: .tencentWeb,
            transport: TranslationCommunityTransportProbe(
                responsesByHost: [:]
            )
        )

        XCTAssertNoThrow(
            try adapter.validateLanguageDirection(
                TranslationLanguageDirection(
                    source: TranslationLanguageTag("en"),
                    target: TranslationLanguageTag("zh-Hans")!
                )
            )
        )
        XCTAssertNoThrow(
            try adapter.validateLanguageDirection(
                TranslationLanguageDirection(
                    source: TranslationLanguageTag("zh-Hans"),
                    target: TranslationLanguageTag("th")!
                )
            )
        )
        XCTAssertNoThrow(
            try adapter.validateLanguageDirection(
                TranslationLanguageDirection(
                    source: TranslationLanguageTag("zh-Hans"),
                    target: TranslationLanguageTag("hi")!
                )
            )
        )
        XCTAssertThrowsError(
            try adapter.validateLanguageDirection(
                TranslationLanguageDirection(
                    source: TranslationLanguageTag("en"),
                    target: TranslationLanguageTag("he")!
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? TranslationServiceAdapterError)?.errorCode,
                "translation_language_pair_unsupported"
            )
        }
        XCTAssertThrowsError(
            try adapter.validateLanguageDirection(
                TranslationLanguageDirection(
                    source: TranslationLanguageTag("zh-Hans"),
                    target: TranslationLanguageTag("zh-Hant")!
                )
            )
        )
    }

    func testTencentRejectsResponseWithWrongTargetLanguage()
        async
    {
        let transport = TranslationCommunityTransportProbe(
            responsesByHost: [
                "wxapp.translator.qq.com": Data(
                    #"{"errCode":0,"source":"en","target":"zh","targetText":"你好"}"#
                        .utf8
                ),
            ]
        )
        let adapter = acknowledgedCommunityAdapter(
            source: .tencentWeb,
            transport: transport
        )
        let request = TranslationServiceRequest(
            sessionID: "wrong-target-fixture",
            input: TranslationInput(source: .manual, text: "Hello"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("he")!
            )
        )

        do {
            for try await _ in adapter.translate(request) {}
            XCTFail("Expected the mismatched target language to fail")
        } catch {
            XCTAssertEqual(
                (error as? TranslationServiceAdapterError)?.errorCode,
                "translation_response_language_mismatch"
            )
        }
    }

    func testCommunityWebFailuresExposeStableRecoveryCategories() {
        XCTAssertEqual(
            TranslationCommunityWebError
                .httpStatus(408)
                .adapterErrorCode,
            "network_timed_out"
        )
        XCTAssertEqual(
            TranslationCommunityWebError
                .httpStatus(429)
                .adapterErrorCode,
            "network_rate_limited"
        )
        XCTAssertEqual(
            TranslationCommunityWebError
                .httpStatus(503)
                .adapterErrorCode,
            "network_unavailable"
        )
        XCTAssertEqual(
            TranslationCommunityWebError
                .httpStatus(400)
                .adapterErrorCode,
            "network_http_client_error"
        )
        XCTAssertEqual(
            TranslationCommunityWebError
                .sourceLanguageUndetermined
                .adapterErrorCode,
            "source_language_undetermined"
        )
    }

    func testTranslationLocalizedNumericFormatsUseTypedIntegerContracts() {
        XCTAssertTrue(
            TranslationLocalizedFormat.characterCount(42)
                .contains("42")
        )
        XCTAssertTrue(
            TranslationLocalizedFormat.inputTooLarge(
                maximumCharacterCount: 5_000
            )
            .contains("5000")
                || TranslationLocalizedFormat.inputTooLarge(
                    maximumCharacterCount: 5_000
                )
                .contains("5,000")
        )
        XCTAssertTrue(
            TranslationLocalizedFormat.ocrLines(12)
                .contains("12")
        )
        XCTAssertTrue(
            TranslationLocalizedFormat.duration(milliseconds: 321)
                .contains("321")
        )
        XCTAssertTrue(
            TranslationLocalizedFormat.httpStatus(429)
                .contains("429")
        )
    }

    func testCommunityConnectionTestUsesSelectedGoogleAdapter()
        async throws
    {
        let transport = TranslationCommunityTransportProbe(
            responsesByHost: [
                "translate.googleapis.com":
                    Data(
                        #"[[["你好","Hello",null,null,10]],null,"en"]"#
                            .utf8
                    ),
            ]
        )
        let defaults = isolatedDefaults()
        acknowledgeCommunitySources([.googleWeb], defaults: defaults)
        let store = TranslationStore(
            communityWebTransport: transport,
            defaults: defaults
        )

        try await store.testCommunityService(
            serviceID: "community:google-web"
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.host,
            "translate.googleapis.com"
        )
        XCTAssertEqual(
            URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?
            .queryItems?
            .first(where: { $0.name == "q" })?
            .value,
            "Hello"
        )
    }

    func testServiceCatalogOrderDoesNotChangeWhenEnabledOrderChanges() {
        let store = TranslationStore(defaults: isolatedDefaults())
        let catalogOrder = store.availableServices.map(\.id)

        store.setServiceEnabled(
            true,
            serviceID: "community:google-web"
        )
        store.moveEnabledService(
            serviceID: "community:google-web",
            before: "apple-local"
        )
        store.setServiceEnabled(
            false,
            serviceID: "community:google-web"
        )

        XCTAssertEqual(
            store.availableServices.map(\.id),
            catalogOrder
        )
    }

    func testPanelResultOrderMovePersistsAndUsesBeforeAfterPlacement() {
        let defaults = isolatedDefaults()
        acknowledgeCommunitySources(
            [.myMemory, .googleWeb],
            defaults: defaults
        )
        defaults.set(
            [
                "apple-local",
                "community:mymemory",
                "community:google-web",
            ],
            forKey: "translation.services.enabledIDs"
        )
        let store = TranslationStore(defaults: defaults)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.moveResultService(
            serviceID: "community:google-web",
            relativeTo: "apple-local",
            placement: .before
        )
        XCTAssertEqual(
            store.enabledServiceIDs,
            [
                "community:google-web",
                "apple-local",
                "community:mymemory",
            ]
        )

        model.moveResultService(
            serviceID: "community:google-web",
            relativeTo: "community:mymemory",
            placement: .after
        )
        XCTAssertEqual(
            store.enabledServiceIDs,
            [
                "apple-local",
                "community:mymemory",
                "community:google-web",
            ]
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: "translation.services.enabledIDs"
            ),
            store.enabledServiceIDs
        )
    }

    func testTranslationOrderDragPayloadCarriesStableServiceIdentity()
        throws
    {
        let payload = TranslationServiceOrderDragPayload(
            serviceID: "community:mymemory"
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            TranslationServiceOrderDragPayload.self,
            from: encoded
        )
        XCTAssertEqual(
            decoded,
            payload
        )
    }

    func testTranslationOrderNativeDestinationDecodesPayloadAndCommitsOnce() {
        let coordinator = TranslationServiceOrderDragCoordinator()
        var commits: [TranslationResultOrderDragTarget] = []
        let destination = TranslationServiceOrderNativeDragSource
            .DragSourceView(
                frame: NSRect(x: 0, y: 0, width: 160, height: 28)
            )
        destination.serviceID = "community:google-web"
        destination.dragCoordinator = coordinator
        destination.onPerformDrop = {
            commits.append($0)
        }
        coordinator.begin(serviceID: "apple-local")

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(UUID().uuidString)
        )
        pasteboard.clearContents()
        pasteboard.setData(
            try! XCTUnwrap(
                TranslationServiceOrderDragPayload(
                    serviceID: "apple-local"
                ).encodedData()
            ),
            forType: TranslationServiceOrderDragPayload.pasteboardType
        )

        XCTAssertEqual(
            destination.updateDestination(
                pasteboard: pasteboard,
                locationInView: NSPoint(x: 80, y: 1)
            ),
            .move
        )

        let expected = TranslationResultOrderDragTarget(
            sourceServiceID: "apple-local",
            destinationServiceID: "community:google-web",
            placement: .before
        )
        XCTAssertEqual(coordinator.target, expected)

        XCTAssertTrue(
            destination.performDrop(
                pasteboard: pasteboard,
                locationInView: NSPoint(x: 80, y: 1)
            )
        )
        XCTAssertFalse(
            destination.performDrop(
                pasteboard: pasteboard,
                locationInView: NSPoint(x: 80, y: 1)
            )
        )

        XCTAssertEqual(commits, [expected])
        XCTAssertNil(coordinator.activeServiceID)
        XCTAssertNil(coordinator.target)
    }

    func testTranslationOrderNativeDestinationRejectsForgedAndOutsideDrops() {
        let coordinator = TranslationServiceOrderDragCoordinator()
        var commitCount = 0
        let destination = TranslationServiceOrderNativeDragSource
            .DragSourceView(
                frame: NSRect(x: 0, y: 0, width: 160, height: 28)
            )
        destination.serviceID = "community:mymemory"
        destination.dragCoordinator = coordinator
        destination.onPerformDrop = { _ in
            commitCount += 1
        }
        coordinator.begin(serviceID: "apple-local")

        let forgedPasteboard = NSPasteboard(
            name: NSPasteboard.Name(UUID().uuidString)
        )
        forgedPasteboard.clearContents()
        forgedPasteboard.setData(
            try! XCTUnwrap(
                TranslationServiceOrderDragPayload(
                    serviceID: "forged-source"
                ).encodedData()
            ),
            forType: TranslationServiceOrderDragPayload.pasteboardType
        )
        XCTAssertEqual(
            destination.updateDestination(
                pasteboard: forgedPasteboard,
                locationInView: NSPoint(x: 80, y: 14)
            ),
            []
        )
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(coordinator.activeServiceID, "apple-local")

        let validPasteboard = NSPasteboard(
            name: NSPasteboard.Name(UUID().uuidString)
        )
        validPasteboard.clearContents()
        validPasteboard.setData(
            try! XCTUnwrap(
                TranslationServiceOrderDragPayload(
                    serviceID: "apple-local"
                ).encodedData()
            ),
            forType: TranslationServiceOrderDragPayload.pasteboardType
        )
        XCTAssertEqual(
            destination.updateDestination(
                pasteboard: validPasteboard,
                locationInView: NSPoint(x: 200, y: 40)
            ),
            []
        )
        XCTAssertFalse(
            destination.performDrop(
                pasteboard: validPasteboard,
                locationInView: NSPoint(x: 200, y: 40)
            )
        )
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(coordinator.activeServiceID, "apple-local")
        XCTAssertNil(coordinator.target)
        coordinator.endSession()
    }


    func testTranslationResultHeaderActionsStayPackedWithoutEmptySlots() {
        XCTAssertEqual(
            TranslationResultHeaderActionLayout.actions(
                state: .succeeded,
                isSuccessful: true,
                hasDiagnostics: true
            ),
            [.copy, .speak, .diagnostics, .expand]
        )
        XCTAssertEqual(
            TranslationResultHeaderActionLayout.actions(
                state: .succeeded,
                isSuccessful: true,
                hasDiagnostics: false
            ),
            [.copy, .speak, .expand]
        )
        XCTAssertEqual(
            TranslationResultHeaderActionLayout.actions(
                state: .failed,
                isSuccessful: false,
                hasDiagnostics: true
            ),
            [.diagnostics, .expand]
        )
        XCTAssertEqual(
            TranslationResultHeaderActionLayout.actions(
                state: .running,
                isSuccessful: false,
                hasDiagnostics: true
            ),
            [.cancel, .diagnostics, .expand]
        )
        XCTAssertEqual(TranslationResultHeaderActionLayout.spacing, 1)
        XCTAssertEqual(
            TranslationResultHeaderActionLayout.reservedWidth,
            115
        )
        XCTAssertFalse(
            TranslationResultHeaderStatusLayout
                .showsStateTitle(for: .succeeded)
        )
        XCTAssertTrue(
            TranslationResultHeaderStatusLayout
                .showsRetryControl(for: .failed)
        )
        XCTAssertFalse(
            TranslationResultHeaderStatusLayout
                .showsRetryControl(for: .succeeded)
        )
        XCTAssertEqual(SettingsLayout.rowMinHeight, 44)
        XCTAssertEqual(SettingsLayout.trailingColumnWidth, 280)
        XCTAssertEqual(SettingsLayout.trailingColumnMaximumWidth, 360)
        XCTAssertEqual(
            TranslationResultHeaderStatusLayout.hitTarget,
            TranslationPanelMetrics.compactIconHitTarget
        )
        XCTAssertLessThan(
            TranslationResultHeaderStatusLayout.visualSize,
            TranslationResultHeaderStatusLayout.hitTarget
        )
    }

    func testTranslationOrderDragHandleUsesArrowKeysForReordering() throws {
        let view = TranslationServiceOrderNativeDragSource.DragSourceView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 28)
        )
        var moveUpCount = 0
        var moveDownCount = 0
        view.canMoveUp = true
        view.canMoveDown = true
        view.onMoveUp = { moveUpCount += 1 }
        view.onMoveDown = { moveDownCount += 1 }
        view.accessibilityName = "Fixture translation source"
        view.refreshAccessibilityConfiguration()

        view.keyDown(with: try translationArrowKeyEvent(keyCode: 126))
        view.keyDown(with: try translationArrowKeyEvent(keyCode: 125))

        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(
            view.accessibilityLabel(),
            "Fixture translation source"
        )
        XCTAssertEqual(view.accessibilityCustomActions()?.count, 2)
        XCTAssertEqual(moveUpCount, 1)
        XCTAssertEqual(moveDownCount, 1)

        view.canMoveUp = false
        view.canMoveDown = false
        view.keyDown(with: try translationArrowKeyEvent(keyCode: 126))
        view.keyDown(with: try translationArrowKeyEvent(keyCode: 125))
        XCTAssertEqual(moveUpCount, 1)
        XCTAssertEqual(moveDownCount, 1)
    }

    private func translationArrowKeyEvent(keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    func testMyMemorySplitsEveryRequestAtFiveHundredUTF8Bytes()
        async throws
    {
        let transport = TranslationCommunityTransportProbe(
            responsesByHost: [
                "api.mymemory.translated.net":
                    Data(
                        #"{"responseStatus":200,"responseData":{"translatedText":"片段"}}"#
                            .utf8
                    ),
            ]
        )
        let adapter = acknowledgedCommunityAdapter(
            source: .myMemory,
            transport: transport
        )
        let input = String(repeating: "中", count: 401)
        let request = TranslationServiceRequest(
            sessionID: "mymemory-chunks",
            input: TranslationInput(source: .manual, text: input),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("zh-Hans"),
                target: TranslationLanguageTag("en")!
            )
        )

        for try await _ in adapter.translate(request) {}

        let requests = await transport.requests()
        XCTAssertGreaterThan(requests.count, 1)
        for request in requests {
            let components = try XCTUnwrap(
                URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )
            )
            let query = try XCTUnwrap(
                components.queryItems?.first {
                    $0.name == "q"
                }?.value
            )
            XCTAssertLessThanOrEqual(query.utf8.count, 500)
        }
    }

    func testCommunityDisclosureIsBoundToSourceVersionAndDestination() {
        let defaults = isolatedDefaults()
        let store = TranslationCommunityWebDisclosureStore(
            defaults: defaults
        )

        let current = TranslationCommunityWebDisclosure(
            sourceID: "community:mymemory",
            destinationHosts: ["API.MYMEMORY.TRANSLATED.NET"]
        )
        XCTAssertFalse(store.isAcknowledged(disclosure: current))
        store.acknowledge(disclosure: current)
        XCTAssertTrue(store.isAcknowledged(disclosure: current))
        XCTAssertFalse(
            store.isAcknowledged(disclosure: .init(
                sourceID: "community:google-web",
                destinationHosts: ["translate.googleapis.com"]
            ))
        )
        XCTAssertFalse(
            store.isAcknowledged(disclosure: .init(
                sourceID: current.sourceID,
                disclosureVersion: current.disclosureVersion + 1,
                destinationHosts: current.destinationHosts
            ))
        )
        XCTAssertFalse(
            store.isAcknowledged(disclosure: .init(
                sourceID: current.sourceID,
                destinationHosts: ["other.example.test"]
            ))
        )
        defaults.set(
            ["community:google-web"],
            forKey: "translation.communityWeb.acknowledgedServiceIDs"
        )
        XCTAssertFalse(
            store.isAcknowledged(disclosure: .init(
                sourceID: "community:google-web",
                destinationHosts: ["translate.googleapis.com"]
            ))
        )
    }

    func testCommunityRuntimeAndPersistedEnableFailClosedWithoutCurrentDisclosure()
        async
    {
        let defaults = isolatedDefaults()
        defaults.set(
            ["community:google-web"],
            forKey: "translation.services.enabledIDs"
        )
        let transport = TranslationCommunityTransportProbe(
            responsesByHost: [
                "translate.googleapis.com":
                    Data(#"[[[\"你好\",\"Hello\",null,null,10]],null,\"en\"]"#.utf8),
            ]
        )
        let store = TranslationStore(
            communityWebTransport: transport,
            defaults: defaults
        )

        XCTAssertFalse(
            store.enabledServiceIDs.contains("community:google-web")
        )
        XCTAssertFalse(
            defaults.stringArray(
                forKey: "translation.services.enabledIDs"
            )?.contains("community:google-web") == true
        )

        let adapter = TranslationCommunityWebServiceAdapter(
            source: .googleWeb,
            transport: transport,
            disclosureStore: TranslationCommunityWebDisclosureStore(
                defaults: defaults
            )
        )
        let request = TranslationServiceRequest(
            sessionID: "unacknowledged-community-runtime",
            input: TranslationInput(source: .manual, text: "Hello"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("zh-Hans")!
            )
        )
        do {
            for try await _ in adapter.translate(request) {}
            XCTFail("An unacknowledged community source must not run.")
        } catch {
            XCTAssertEqual(
                (error as? TranslationServiceAdapterError)?.errorCode,
                "confirmation_required"
            )
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCommunityWebTransportRejectsUnlistedInsecureAndCookieRequests()
        async
    {
        let transport =
            URLSessionTranslationCommunityWebHTTPTransport()
        let allowedHosts = Set([
            "api.mymemory.translated.net",
        ])
        var requests = [
            URLRequest(
                url: URL(
                    string:
                        "http://api.mymemory.translated.net/get"
                )!
            ),
            URLRequest(
                url: URL(
                    string: "https://example.com/get"
                )!
            ),
        ]
        var cookieRequest = URLRequest(
            url: URL(
                string:
                    "https://api.mymemory.translated.net/get"
            )!
        )
        cookieRequest.setValue(
            "session=fixture",
            forHTTPHeaderField: "Cookie"
        )
        requests.append(cookieRequest)

        for request in requests {
            do {
                _ = try await transport.data(
                    for: request,
                    allowedHosts: allowedHosts
                )
                XCTFail("Invalid community request reached the network")
            } catch TranslationCommunityWebError.invalidRequest {
            } catch {
                XCTFail("Unexpected validation error: \(error)")
            }
        }
    }

    func testEnabledComparisonGroupKeepsConfigurationOrderAndCapsAtFour() {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let plugins = (1 ... 5).map {
            TestTranslationAdapter(id: "plugin:test-\($0)")
        }
        store.replacePluginAdapters(plugins)

        store.setServiceEnabled(false, serviceID: "apple-local")
        for plugin in plugins {
            store.setServiceEnabled(true, serviceID: plugin.descriptor.id)
        }

        XCTAssertEqual(
            store.enabledServiceIDs,
            Array(plugins.prefix(4).map(\.descriptor.id))
        )
        XCTAssertEqual(
            store.adaptersForEnabledServices().map(\.descriptor.id),
            store.enabledServiceIDs
        )
    }

    func testPersistedEmptyComparisonGroupRemainsEmptyAcrossRefreshAndRestart() {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "translation.services.enabledIDs")

        let first = TranslationStore(defaults: defaults)
        XCTAssertEqual(first.enabledServiceIDs, [])

        first.refreshServiceRegistry()
        XCTAssertEqual(first.enabledServiceIDs, [])

        let restarted = TranslationStore(defaults: defaults)
        XCTAssertEqual(restarted.enabledServiceIDs, [])
    }

    func testEmptyComparisonGroupProducesStableNoServiceSession() {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "translation.services.enabledIDs")
        let store = TranslationStore(defaults: defaults)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.runImmediately()

        XCTAssertEqual(model.snapshot?.results, [])
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.runPhase, .noServices)
    }

    func testFreshInstallDoesNotEnableUnsupportedAppleService() {
        let normalized = TranslationStore.normalizedEnabledServiceIDs(
            nil,
            availableServices: [
                TranslationServiceDescriptor(
                    id: "apple-local",
                    displayName: "Apple",
                    kind: .appleLocal,
                    availability: .unsupported
                ),
                TranslationServiceDescriptor(
                    id: "openai-compatible",
                    displayName: "External",
                    kind: .openAICompatible,
                    availability: .requiresConfiguration
                ),
            ]
        )

        XCTAssertEqual(normalized, [])
    }

    func testPendingPluginServiceSurvivesStartupAndRegistryRefresh() {
        let defaults = isolatedDefaults()
        defaults.set(
            ["plugin:fixture", "apple-local"],
            forKey: "translation.services.enabledIDs"
        )

        let store = TranslationStore(defaults: defaults)
        XCTAssertEqual(
            store.enabledServiceIDs,
            ["plugin:fixture", "apple-local"]
        )

        store.refreshServiceRegistry()
        XCTAssertEqual(
            store.enabledServiceIDs,
            ["plugin:fixture", "apple-local"]
        )

        store.replacePluginAdapters([
            TestTranslationAdapter(id: "plugin:fixture"),
        ])
        XCTAssertEqual(
            store.enabledServiceIDs,
            ["plugin:fixture", "apple-local"]
        )
    }

    func testEnabledPluginServiceSurvivesTemporaryRegistryFailureUntilExplicitRemoval() {
        let defaults = isolatedDefaults()
        defaults.set(
            ["plugin:fixture"],
            forKey: "translation.services.enabledIDs"
        )
        let store = TranslationStore(defaults: defaults)

        store.replacePluginAdapters([
            TestTranslationAdapter(id: "plugin:fixture"),
        ])
        store.replacePluginAdapters([])

        XCTAssertEqual(store.enabledServiceIDs, ["plugin:fixture"])
        XCTAssertEqual(
            store.adaptersForEnabledServices().map(\.descriptor.id),
            [],
            "A temporarily unavailable service may keep its configured order, but must not enter the run queue."
        )
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == "plugin:fixture"
            }?.availability,
            .disabled
        )

        store.removePluginService(pluginID: "fixture")

        XCTAssertEqual(store.enabledServiceIDs, [])
        XCTAssertEqual(
            defaults.stringArray(
                forKey: "translation.services.enabledIDs"
            ),
            []
        )
    }

    func testUnconfiguredOpenAIServiceIsRemovedFromEnabledRunOrder() {
        let defaults = isolatedDefaults()
        acknowledgeCommunitySources([.myMemory], defaults: defaults)
        defaults.set(
            [
                "community:mymemory",
                "openai-compatible",
                "apple-local",
            ],
            forKey: "translation.services.enabledIDs"
        )

        let store = TranslationStore(defaults: defaults)

        XCTAssertEqual(
            store.enabledServiceIDs,
            ["community:mymemory", "apple-local"]
        )
        XCTAssertEqual(
            store.adaptersForEnabledServices().map(\.descriptor.id),
            ["community:mymemory", "apple-local"]
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: "translation.services.enabledIDs"
            ),
            ["community:mymemory", "apple-local"]
        )
    }

    func testAuthoritativePluginSnapshotRemovesUninstalledService() {
        let defaults = isolatedDefaults()
        defaults.set(
            ["plugin:fixture"],
            forKey: "translation.services.enabledIDs"
        )
        let store = TranslationStore(defaults: defaults)

        store.replacePluginAdapters([
            TestTranslationAdapter(id: "plugin:fixture"),
        ])
        store.replacePluginAdapters(
            [],
            snapshotIsAuthoritative: true
        )

        XCTAssertEqual(store.enabledServiceIDs, [])
        XCTAssertFalse(
            store.availableServices.contains {
                $0.id == "plugin:fixture"
            }
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: "translation.services.enabledIDs"
            ),
            []
        )
    }

    func testSupportedLanguagesFollowEnabledServiceCapabilitiesWithoutAppleProvider()
        async
    {
        let defaults = isolatedDefaults()
        let provider = AppleSupportedLanguagesProviderProbe()
        let store = TranslationStore(
            defaults: defaults,
            appleSupportedLanguagesProvider: {
                await provider.languages()
            }
        )
        let plugin = TestTranslationAdapter(
            id: "plugin:language-fixture",
            supportedTargetLanguages: [
                TranslationLanguageTag("fr")!,
                TranslationLanguageTag("de")!,
            ]
        )
        store.replacePluginAdapters([plugin])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: plugin.descriptor.id)

        XCTAssertEqual(
            Set(store.supportedLanguages),
            Set([
                TranslationLanguageTag("fr")!,
                TranslationLanguageTag("de")!,
            ])
        )
        XCTAssertEqual(
            Set(store.supportedSourceLanguages),
            Set(TranslationLanguagePreferences.commonOptions)
        )
        let providerCallCount = await provider.callCount()
        XCTAssertEqual(providerCallCount, 0)
    }

    func testLanguageProviderIsLazyAndInitialAppleFallbackIsUsable()
        async
    {
        let provider = AppleSupportedLanguagesProviderProbe()
        let store = TranslationStore(
            defaults: isolatedDefaults(),
            appleSupportedLanguagesProvider: {
                await provider.languages()
            }
        )

        let providerCallCount = await provider.callCount()
        XCTAssertEqual(providerCallCount, 0)
        for rawValue in ["zh-Hans", "zh-Hant", "en", "ja"] {
            let language = try! XCTUnwrap(TranslationLanguageTag(rawValue))
            XCTAssertTrue(store.supportedLanguages.contains(language))
            XCTAssertTrue(store.supportedSourceLanguages.contains(language))
        }
    }

    func testSourceManagementListDoesNotRefreshAppleLanguages()
        async throws
    {
        let provider = AppleSupportedLanguagesProviderProbe()
        let store = TranslationStore(
            defaults: isolatedDefaults(),
            appleSupportedLanguagesProvider: {
                await provider.languages()
            }
        )
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store
        )

        do {
            _ = try await service.execute(
                TranslationSourceManagementActionInput(operation: .list)
            )
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .pluginStorageUnavailable
            )
        }

        let providerCallCount = await provider.callCount()
        XCTAssertEqual(providerCallCount, 0)
    }

    func testEnsureSupportedLanguagesRefreshesOncePerGeneration()
        async
    {
        let provider = AppleSupportedLanguagesProviderProbe(
            suspendsFirstResponse: true
        )
        defer {
            Task {
                await provider.releaseFirstResponse(
                    with: TranslationLanguagePreferences.commonOptions
                )
            }
        }
        let store = TranslationStore(
            defaults: isolatedDefaults(),
            appleSupportedLanguagesProvider: {
                await provider.languages()
            }
        )

        let consumerToken = UUID()
        store.beginSupportedLanguagesConsumer(token: consumerToken)
        store.ensureSupportedLanguagesRefreshed()
        await provider.waitUntilFirstCallStarts()
        store.ensureSupportedLanguagesRefreshed()

        let providerCallCount = await provider.callCount()
        XCTAssertEqual(providerCallCount, 1)
        store.endSupportedLanguagesConsumer(token: consumerToken)
    }

    func testLateAppleLanguageResultCannotOverrideDisabledOrNewGeneration()
        async
    {
        let staleLanguage = TranslationLanguageTag("cy")!
        let refreshedLanguage = TranslationLanguageTag("gd")!
        let provider = AppleSupportedLanguagesProviderProbe(
            responses: [[refreshedLanguage]],
            suspendsFirstResponse: true
        )
        defer {
            Task {
                await provider.releaseFirstResponse(with: [staleLanguage])
            }
        }
        let store = TranslationStore(
            defaults: isolatedDefaults(),
            appleSupportedLanguagesProvider: {
                await provider.languages()
            }
        )

        let consumerToken = UUID()
        store.beginSupportedLanguagesConsumer(token: consumerToken)
        store.ensureSupportedLanguagesRefreshed()
        await provider.waitUntilFirstCallStarts()
        store.setServiceEnabled(false, serviceID: "apple-local")
        XCTAssertTrue(store.supportedLanguages.isEmpty)
        XCTAssertTrue(store.supportedSourceLanguages.isEmpty)

        let stalePublication = expectation(
            description: "stale Apple result must not publish"
        )
        stalePublication.isInverted = true
        let staleObserver = store.$supportedLanguages.sink { languages in
            if languages.contains(staleLanguage) {
                stalePublication.fulfill()
            }
        }
        await provider.releaseFirstResponse(with: [staleLanguage])
        await fulfillment(of: [stalePublication], timeout: 0.1)
        staleObserver.cancel()

        let refreshedPublication = expectation(
            description: "new Apple result publishes"
        )
        let refreshedObserver = store.$supportedLanguages.sink { languages in
            if languages.contains(refreshedLanguage) {
                refreshedPublication.fulfill()
            }
        }
        store.setServiceEnabled(true, serviceID: "apple-local")
        await fulfillment(of: [refreshedPublication], timeout: 1.0)
        refreshedObserver.cancel()

        let providerCallCount = await provider.callCount()
        XCTAssertEqual(providerCallCount, 2)
        XCTAssertTrue(store.supportedLanguages.contains(refreshedLanguage))
        XCTAssertFalse(store.supportedLanguages.contains(staleLanguage))
        store.endSupportedLanguagesConsumer(token: consumerToken)
    }

    func testActiveLanguageConsumerRefreshesAfterRegistryRebuild()
        async
    {
        let staleLanguage = TranslationLanguageTag("cy")!
        let refreshedLanguage = TranslationLanguageTag("gd")!
        let provider = AppleSupportedLanguagesProviderProbe(
            responses: [[refreshedLanguage]],
            suspendsFirstResponse: true
        )
        defer {
            Task {
                await provider.releaseFirstResponse(with: [staleLanguage])
            }
        }
        let store = TranslationStore(
            defaults: isolatedDefaults(),
            appleSupportedLanguagesProvider: {
                await provider.languages()
            }
        )
        let consumerToken = UUID()
        store.beginSupportedLanguagesConsumer(token: consumerToken)
        await provider.waitUntilFirstCallStarts()

        let refreshedPublication = expectation(
            description: "rebuilt generation publishes its Apple languages"
        )
        let observer = store.$supportedLanguages.sink { languages in
            if languages.contains(refreshedLanguage) {
                refreshedPublication.fulfill()
            }
        }
        store.replacePluginAdapters([
            TestTranslationAdapter(id: "plugin:language-registry-fixture"),
        ])
        await fulfillment(of: [refreshedPublication], timeout: 1.0)
        observer.cancel()

        let stalePublication = expectation(
            description: "old generation must not publish"
        )
        stalePublication.isInverted = true
        let staleObserver = store.$supportedLanguages.sink { languages in
            if languages.contains(staleLanguage) {
                stalePublication.fulfill()
            }
        }
        await provider.releaseFirstResponse(with: [staleLanguage])
        await fulfillment(of: [stalePublication], timeout: 0.1)
        staleObserver.cancel()

        let providerCallCount = await provider.callCount()
        XCTAssertEqual(providerCallCount, 2)
        XCTAssertTrue(store.supportedLanguages.contains(refreshedLanguage))
        XCTAssertFalse(store.supportedLanguages.contains(staleLanguage))
        store.endSupportedLanguagesConsumer(token: consumerToken)
    }

    func testLanguageConsumerDepartureSuppressesRebuildUntilReentry()
        async
    {
        let refreshedLanguage = TranslationLanguageTag("gd")!
        let provider = AppleSupportedLanguagesProviderProbe(
            responses: [[], [refreshedLanguage]]
        )
        let store = TranslationStore(
            defaults: isolatedDefaults(),
            appleSupportedLanguagesProvider: {
                await provider.languages()
            }
        )
        let firstConsumerToken = UUID()
        store.beginSupportedLanguagesConsumer(token: firstConsumerToken)
        await provider.waitUntilFirstCallStarts()
        let initialProviderCallCount = await provider.callCount()
        XCTAssertEqual(initialProviderCallCount, 1)

        store.endSupportedLanguagesConsumer(token: firstConsumerToken)
        store.replacePluginAdapters([
            TestTranslationAdapter(id: "plugin:language-reentry-fixture"),
        ])
        let providerCallCountAfterRebuild = await provider.callCount()
        XCTAssertEqual(providerCallCountAfterRebuild, 1)

        let refreshedPublication = expectation(
            description: "re-entering starts a current-generation query"
        )
        let observer = store.$supportedLanguages.sink { languages in
            if languages.contains(refreshedLanguage) {
                refreshedPublication.fulfill()
            }
        }
        let secondConsumerToken = UUID()
        store.beginSupportedLanguagesConsumer(token: secondConsumerToken)
        await fulfillment(of: [refreshedPublication], timeout: 1.0)
        observer.cancel()

        let finalProviderCallCount = await provider.callCount()
        XCTAssertEqual(finalProviderCallCount, 2)
        store.endSupportedLanguagesConsumer(token: secondConsumerToken)
    }

    func testNoEnabledServicesDoNotAdvertiseUnsupportedLanguageOptions() {
        let defaults = isolatedDefaults()
        defaults.set(
            [String](),
            forKey: "translation.services.enabledIDs"
        )
        let store = TranslationStore(defaults: defaults)
        let current = TranslationLanguageTag("cy")!

        XCTAssertTrue(store.supportedLanguages.isEmpty)
        XCTAssertTrue(store.supportedSourceLanguages.isEmpty)
        XCTAssertEqual(
            TranslationLanguagePreferences.menuOptions(
                available: store.supportedLanguages,
                current: current,
                locale: Locale(identifier: "en")
            ),
            [current]
        )
    }

    func testLanguageMenuPrioritizesNativeRecentAndFocusLanguages() {
        let preferences = TranslationUserLanguagePreferenceSnapshot(
            nativeLanguage: TranslationLanguageTag("zh-Hans")!,
            focusLanguages: [
                TranslationLanguageTag("en")!,
                TranslationLanguageTag("ja")!,
                TranslationLanguageTag("fr")!,
            ],
            recentlyUsedFocusLanguage: TranslationLanguageTag("ja")!
        )
        let sections = TranslationLanguagePreferences.menuSections(
            available: [
                TranslationLanguageTag("fr")!,
                TranslationLanguageTag("de")!,
                TranslationLanguageTag("ja")!,
                TranslationLanguageTag("zh-Hans")!,
                TranslationLanguageTag("en")!,
            ],
            current: TranslationLanguageTag("cy")!,
            preferences: preferences,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(
            sections.common.map(\.rawValue),
            ["zh-Hans", "ja", "en", "fr"]
        )
        XCTAssertEqual(
            sections.all.map(\.rawValue),
            ["de", "cy"]
        )
        XCTAssertEqual(
            Set(sections.common + sections.all).count,
            sections.common.count + sections.all.count
        )
    }

    func testPinnedSessionsOwnDistinctAppleTranslationRuntimeHosts() {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let direction = TranslationLanguageDirection(
            target: TranslationLanguageTag("zh-Hans")!
        )
        let first = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "first"),
            direction: direction,
            translationStore: store
        )
        let second = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "second"),
            direction: direction,
            translationStore: store
        )

        XCTAssertFalse(first.appleRuntimeController === second.appleRuntimeController)
        XCTAssertTrue(
            store.adaptersForEnabledServices(
                appleRuntimeController: first.appleRuntimeController
            ).contains { $0.descriptor.id == "apple-local" }
        )
    }

    func testPanelModelOnlyForwardsTranslationConfigurationChanges() {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )
        var forwardedChanges = 0
        let observation = model.objectWillChange.sink {
            forwardedChanges += 1
        }

        store.refreshFavorites()
        XCTAssertEqual(forwardedChanges, 0)

        store.setServiceEnabled(
            !store.enabledServiceIDs.contains("community:mymemory"),
            serviceID: "community:mymemory"
        )
        XCTAssertGreaterThan(forwardedChanges, 0)
        withExtendedLifetime(observation) {}
    }

    func testStreamingResultInvalidatesOnlyAffectedCardAndKeepsRunningOrder()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let first = ControlledStreamingTranslationAdapter(
            id: "plugin:stream-first"
        )
        let second = ControlledStreamingTranslationAdapter(
            id: "plugin:stream-second"
        )
        store.replacePluginAdapters([first, second])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: first.descriptor.id)
        store.setServiceEnabled(true, serviceID: second.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .manual,
                text: "source"
            ),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.runImmediately()
        await waitUntil {
            model.resultStates.count == 2
                && model.resultStates.allSatisfy {
                    $0.result.state == .running
                }
        }
        guard let firstState = model.resultStates.first(where: {
            $0.serviceID == first.descriptor.id
        }),
        let secondState = model.resultStates.first(where: {
            $0.serviceID == second.descriptor.id
        }) else {
            XCTFail("Expected one observable state per service")
            return
        }

        var panelUpdates = 0
        var firstCardUpdates = 0
        var secondCardUpdates = 0
        let panelObservation = model.objectWillChange.sink {
            panelUpdates += 1
        }
        let firstObservation = firstState.objectWillChange.sink {
            firstCardUpdates += 1
        }
        let secondObservation = secondState.objectWillChange.sink {
            secondCardUpdates += 1
        }

        first.yieldPartial("译")
        first.yieldPartial("译文")
        await waitUntil {
            firstState.result.translatedText == "译文"
        }

        XCTAssertEqual(panelUpdates, 0)
        XCTAssertGreaterThanOrEqual(firstCardUpdates, 2)
        XCTAssertEqual(secondCardUpdates, 0)
        XCTAssertEqual(
            model.snapshot?.results.first(where: {
                $0.service.id == first.descriptor.id
            })?.translatedText,
            "译文"
        )

        model.moveResultService(
            serviceID: first.descriptor.id,
            relativeTo: second.descriptor.id,
            placement: .after
        )
        await waitUntil {
            model.resultStates.map(\.serviceID)
                == [
                    second.descriptor.id,
                    first.descriptor.id,
                ]
        }
        XCTAssertEqual(first.attemptCount, 1)
        XCTAssertEqual(second.attemptCount, 1)

        first.complete("译文")
        second.complete("第二")
        await waitUntil { model.runPhase == .idle }
        model.cancel()
        withExtendedLifetime(
            (
                panelObservation,
                firstObservation,
                secondObservation
            )
        ) {}
    }

    func testLegacyDefaultTargetMigratesToNativeLanguageModel() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: TranslationLanguagePreferences.rememberLastKey)
        defaults.set(
            "fr",
            forKey: TranslationLanguagePreferences.defaultTargetKey
        )

        let preferences =
            TranslationLanguagePreferences.snapshot(defaults: defaults)
        XCTAssertEqual(
            preferences.nativeLanguage,
            TranslationLanguageTag("fr")
        )
        XCTAssertEqual(
            preferences.focusLanguages,
            [TranslationLanguageTag("zh-Hans")!]
        )
        XCTAssertEqual(
            TranslationLanguagePreferences.preferredTarget(defaults: defaults),
            TranslationLanguageTag("zh-Hans")
        )
    }

    func testSmartTargetTranslatesForeignLanguageIntoNativeLanguage() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!
        let resolution = TranslationTargetResolver.resolve(
            text: "Hello",
            explicitSource: english,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english],
                    recentlyUsedFocusLanguage: english
                )
        )

        XCTAssertEqual(resolution.detectedSource, english)
        XCTAssertEqual(resolution.target, native)
        XCTAssertFalse(resolution.usedFallbackDetection)
    }

    func testSmartTargetUsesRecentFocusLanguageForNativeSource() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!
        let japanese = TranslationLanguageTag("ja")!
        let resolution = TranslationTargetResolver.resolve(
            text: "你好",
            explicitSource: native,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english, japanese],
                    recentlyUsedFocusLanguage: japanese
                )
        )

        XCTAssertEqual(resolution.target, japanese)
        XCTAssertFalse(resolution.usedFallbackDetection)
    }

    func testSmartTargetDoesNotInventTargetWithoutFocusLanguage() {
        let native = TranslationLanguageTag("zh-Hans")!
        let resolution = TranslationTargetResolver.resolve(
            text: "你好",
            explicitSource: native,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [],
                    recentlyUsedFocusLanguage: nil
                )
        )

        XCTAssertNil(resolution.target)
    }

    func testSmartTargetResolvesSingleHanCharacterBeforeAdaptersRun() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!

        let resolution = TranslationTargetResolver.resolve(
            text: "好",
            explicitSource: nil,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english],
                    recentlyUsedFocusLanguage: english
                )
        )

        XCTAssertEqual(resolution.detectedSource, native)
        XCTAssertEqual(resolution.target, english)
        XCTAssertEqual(resolution.sourceResolution, .script)
    }

    func testSmartTargetResolvesSingleLatinCharacterBeforeAdaptersRun() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!

        let resolution = TranslationTargetResolver.resolve(
            text: "A",
            explicitSource: nil,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english],
                    recentlyUsedFocusLanguage: english
                )
        )

        XCTAssertEqual(resolution.detectedSource, english)
        XCTAssertEqual(resolution.target, native)
        XCTAssertEqual(resolution.sourceResolution, .script)
    }

    func testSmartTargetDoesNotTrustStatisticalDetectionForTwoLetterLatinWord() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!

        let resolution = TranslationTargetResolver.resolve(
            text: "no",
            explicitSource: nil,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english],
                    recentlyUsedFocusLanguage: english
                )
        )

        XCTAssertEqual(resolution.detectedSource, english)
        XCTAssertEqual(resolution.target, native)
        XCTAssertEqual(resolution.sourceResolution, .script)
    }

    func testExplicitTargetStillUsesSharedSourceResolution() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!

        let resolution = TranslationTargetResolver.resolveDirection(
            text: "好",
            explicitSource: nil,
            explicitTarget: english,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english],
                    recentlyUsedFocusLanguage: english
                )
        )

        XCTAssertEqual(resolution.source, native)
        XCTAssertEqual(resolution.target, english)
        XCTAssertEqual(resolution.sourceResolution, .script)
    }

    func testDistinctiveScriptResolvesOutsideConfiguredLanguagePair() {
        let resolution = TranslationTargetResolver.resolveDirection(
            text: "안",
            explicitSource: nil,
            explicitTarget: TranslationLanguageTag("en")!,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: TranslationLanguageTag("zh-Hans")!,
                    focusLanguages: [TranslationLanguageTag("en")!],
                    recentlyUsedFocusLanguage: nil
                )
        )

        XCTAssertEqual(resolution.source, TranslationLanguageTag("ko"))
        XCTAssertEqual(resolution.target, TranslationLanguageTag("en"))
        XCTAssertEqual(resolution.sourceResolution, .script)
    }

    func testSmartTargetUsesOnlyReasonablePairForScriptlessInput() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!

        let resolution = TranslationTargetResolver.resolve(
            text: "123",
            explicitSource: nil,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english],
                    recentlyUsedFocusLanguage: english
                )
        )

        XCTAssertEqual(resolution.detectedSource, native)
        XCTAssertEqual(resolution.target, english)
        XCTAssertEqual(
            resolution.sourceResolution,
            .languagePairFallback
        )
    }

    func testSmartTargetLeavesSourceUnknownWhenSeveralCandidatesRemain() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!
        let japanese = TranslationLanguageTag("ja")!

        let resolution = TranslationTargetResolver.resolve(
            text: "123",
            explicitSource: nil,
            preferences:
                TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english, japanese],
                    recentlyUsedFocusLanguage: english
                )
        )

        XCTAssertNil(resolution.detectedSource)
        XCTAssertEqual(resolution.target, english)
        XCTAssertEqual(resolution.sourceResolution, .unresolved)
    }

    func testOpenAIAdapterRejectsMissingConfigurationBeforeReadingSecret() async {
        var secretReadCount = 0
        let transport = CountingOpenAIConnectionTransport()
        let auditProbe = TranslationRuntimeAuditProbe()
        let publicationProbe = TranslationPublicationProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: {
                OpenAITranslationServiceConfiguration(
                    baseURL: "",
                    modelName: "",
                    keychainAccountAlias: "",
                    credentialRevision: 0,
                    externalTransferGrant: nil
                )
            },
            readProviderSecret: { _ in
                secretReadCount += 1
                throw TestError.unexpectedSecretRead
            },
            publicationValidator: { _, _, _ in
                publicationProbe.recordCall()
                return false
            }
        )
        let request = TranslationServiceRequest(
            sessionID: UUID().uuidString,
            input: TranslationInput(source: .manual, text: "Blocks"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            )
        )
        var diagnosticsCount = 0
        var terminalEventCount = 0

        do {
            for try await event in adapter.translate(request) {
                switch event {
                case .diagnostics:
                    diagnosticsCount += 1
                case .completed:
                    terminalEventCount += 1
                default:
                    break
                }
            }
            XCTFail("Expected missing configuration")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error.errorCode, ProviderErrorCode.missingConfiguration.rawValue)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(secretReadCount, 0)
        XCTAssertEqual(transportCallCount, 0)
        XCTAssertEqual(publicationProbe.callCount, 0)
        XCTAssertEqual(diagnosticsCount, 0)
        XCTAssertEqual(terminalEventCount, 0)
        XCTAssertNil(auditProbe.result)
    }

    func testOpenAIAdapterRejectsMissingGrantWithoutPublicationValidation()
        async
    {
        let target = ProviderExternalTransferTarget(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "fixture-account",
            credentialRevision: 1
        )!
        let configuration = OpenAITranslationServiceConfiguration(
            baseURL: target.normalizedBaseURL,
            modelName: target.modelName,
            keychainAccountAlias: target.keychainAccountAlias,
            credentialRevision: target.credentialRevision,
            externalTransferGrant: nil
        )
        let secretProbe = TranslationSecretReadProbe()
        let transport = CountingOpenAIConnectionTransport()
        let auditProbe = TranslationRuntimeAuditProbe()
        let publicationProbe = TranslationPublicationProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { configuration },
            readProviderSecret: { _ in
                secretProbe.recordRead()
                return Self.fixtureSecretMaterial
            },
            publicationValidator: { _, _, _ in
                publicationProbe.recordCall()
                return false
            }
        )
        var diagnosticsCount = 0
        var terminalEventCount = 0

        do {
            for try await event in adapter.translate(Self.openAIRequest()) {
                switch event {
                case .diagnostics:
                    diagnosticsCount += 1
                case .completed:
                    terminalEventCount += 1
                default:
                    break
                }
            }
            XCTFail("Expected missing external-transfer grant")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(
                error.errorCode,
                ProviderErrorCode.confirmationRequired.rawValue
            )
            XCTAssertNotEqual(error, .publicationRejected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(secretProbe.callCount, 0)
        XCTAssertEqual(transportCallCount, 0)
        XCTAssertEqual(publicationProbe.callCount, 0)
        XCTAssertEqual(diagnosticsCount, 0)
        XCTAssertEqual(terminalEventCount, 0)
        XCTAssertNil(auditProbe.result)
    }

    func testOpenAIStaticEarlyResultsSkipAuditTokenWhenCaptureIsDisabled() {
        let auditTokenStore = ProviderStore()
        let auditTokenProbe = TranslationAuditTokenSourceProbe(
            source: auditTokenStore.providerAuditTokenSource()
        )
        let auditProbe = TranslationRuntimeAuditProbe()
        let runtime = OpenAITranslationRuntimeService(
            auditTokenSource: { auditTokenProbe.capture() },
            auditHandlerWithToken: { result, _, _, _ in
                auditProbe.record(result)
            }
        )
        let profile = OpenAITranslationRuntimeProfile(
            providerName: "Fixture Provider",
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "fixture-account",
            timeoutSeconds: 60
        )

        _ = runtime.preflightBlockedResult(
            profile: profile,
            errorCode: .confirmationRequired,
            textCharacterCount: 6,
            sourceLanguageMode: "auto",
            targetLanguage: "zh-Hans",
            captureAudit: false
        )
        _ = runtime.inputLimitExceededResult(
            profile: profile,
            textCharacterCount:
                OpenAITranslationRuntimeService
                    .maximumInputCharacterCount + 1,
            sourceLanguageMode: "auto",
            targetLanguage: "zh-Hans",
            captureAudit: false
        )

        XCTAssertEqual(auditTokenProbe.callCount, 0)
        XCTAssertEqual(auditProbe.callCount, 0)
        XCTAssertNil(auditProbe.result)
    }

    func testOpenAIAdapterInvalidPublicationSnapshotsSkipAuditToken()
        async
    {
        func assertPreflight(
            configuration: OpenAITranslationServiceConfiguration,
            expectedErrorCode: String
        ) async {
            let auditTokenStore = ProviderStore()
            let auditTokenProbe = TranslationAuditTokenSourceProbe(
                source: auditTokenStore.providerAuditTokenSource()
            )
            let secretProbe = TranslationSecretReadProbe()
            let transport = CountingOpenAIConnectionTransport()
            let auditProbe = TranslationRuntimeAuditProbe()
            let publicationProbe = TranslationPublicationProbe()
            let adapter = OpenAICompatibleTranslationServiceAdapter(
                runtimeService: OpenAITranslationRuntimeService(
                    transport: transport,
                    auditTokenSource: { auditTokenProbe.capture() },
                    auditHandlerWithToken: { result, _, _, _ in
                        auditProbe.record(result)
                    }
                ),
                configuration: { configuration },
                readProviderSecret: { _ in
                    secretProbe.recordRead()
                    return Self.fixtureSecretMaterial
                },
                publicationValidator: { _, _, _ in
                    publicationProbe.recordCall()
                    return false
                }
            )
            var diagnosticsCount = 0
            var terminalEventCount = 0

            do {
                for try await event in adapter.translate(Self.openAIRequest()) {
                    switch event {
                    case .diagnostics:
                        diagnosticsCount += 1
                    case .completed:
                        terminalEventCount += 1
                    default:
                        break
                    }
                }
                XCTFail("Expected preflight failure")
            } catch let error as TranslationServiceAdapterError {
                XCTAssertEqual(error.errorCode, expectedErrorCode)
                XCTAssertNotEqual(error, .publicationRejected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let transportCallCount = await transport.callCount()
            XCTAssertEqual(auditTokenProbe.callCount, 0)
            XCTAssertEqual(secretProbe.callCount, 0)
            XCTAssertEqual(transportCallCount, 0)
            XCTAssertEqual(publicationProbe.callCount, 0)
            XCTAssertEqual(diagnosticsCount, 0)
            XCTAssertEqual(terminalEventCount, 0)
            XCTAssertEqual(auditProbe.callCount, 0)
            XCTAssertNil(auditProbe.result)
        }

        let target = ProviderExternalTransferTarget(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "fixture-account",
            credentialRevision: 1
        )!
        let differentTarget = ProviderExternalTransferTarget(
            baseURL: "https://other.example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "fixture-account",
            credentialRevision: 1
        )!
        await assertPreflight(
            configuration: OpenAITranslationServiceConfiguration(
                baseURL: target.normalizedBaseURL,
                modelName: target.modelName,
                keychainAccountAlias: target.keychainAccountAlias,
                credentialRevision: target.credentialRevision,
                externalTransferGrant: nil
            ),
            expectedErrorCode: ProviderErrorCode.confirmationRequired.rawValue
        )
        await assertPreflight(
            configuration: OpenAITranslationServiceConfiguration(
                baseURL: target.normalizedBaseURL,
                modelName: target.modelName,
                keychainAccountAlias: target.keychainAccountAlias,
                credentialRevision: target.credentialRevision,
                externalTransferGrant: ProviderExternalTransferGrant(
                    target: differentTarget,
                    generation: 1
                )
            ),
            expectedErrorCode: ProviderErrorCode.confirmationRequired.rawValue
        )
        await assertPreflight(
            configuration: OpenAITranslationServiceConfiguration(
                baseURL: "",
                modelName: "",
                keychainAccountAlias: "",
                credentialRevision: 0,
                externalTransferGrant: nil
            ),
            expectedErrorCode: ProviderErrorCode.missingConfiguration.rawValue
        )
    }

    func testOpenAIAdapterDefersSecretReadFailureUntilFinalPublication()
        async
    {
        let secretProbe = TranslationSecretReadProbe()
        let transport = CountingOpenAIConnectionTransport()
        let auditProbe = TranslationRuntimeAuditProbe()
        let publicationProbe = TranslationPublicationProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { Self.validOpenAIConfiguration },
            readProviderSecret: { _ in
                secretProbe.recordRead()
                throw TestError.fixtureFailure
            },
            authorizationValidator: { _, _ in true },
            publicationValidator: { _, _, publication in
                publicationProbe.recordCall()
                publication()
                return true
            }
        )
        var diagnostics: [TranslationResultDiagnostics] = []
        var terminalEventCount = 0

        do {
            for try await event in adapter.translate(Self.openAIRequest()) {
                switch event {
                case let .diagnostics(value, _):
                    diagnostics.append(value)
                case .completed:
                    terminalEventCount += 1
                default:
                    break
                }
            }
            XCTFail("Expected missing secret failure")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error.errorCode, ProviderErrorCode.missingSecret.rawValue)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(secretProbe.callCount, 1)
        XCTAssertEqual(transportCallCount, 0)
        XCTAssertEqual(publicationProbe.callCount, 1)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(terminalEventCount, 0)
        XCTAssertEqual(auditProbe.callCount, 1)
        XCTAssertEqual(diagnostics.first?.auditID, auditProbe.result?.auditID)
        XCTAssertEqual(auditProbe.result?.status, .missingSecret)
    }

    func testOpenAIAdapterFinalPublicationRejectionSuppressesSecretReadFailureArtifacts()
        async
    {
        let secretProbe = TranslationSecretReadProbe()
        let transport = CountingOpenAIConnectionTransport()
        let auditProbe = TranslationRuntimeAuditProbe()
        let publicationProbe = TranslationPublicationProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { Self.validOpenAIConfiguration },
            readProviderSecret: { _ in
                secretProbe.recordRead()
                throw TestError.fixtureFailure
            },
            authorizationValidator: { _, _ in true },
            publicationValidator: { _, _, _ in
                publicationProbe.recordCall()
                return false
            }
        )
        var diagnosticsCount = 0
        var terminalEventCount = 0

        do {
            for try await event in adapter.translate(Self.openAIRequest()) {
                switch event {
                case .diagnostics:
                    diagnosticsCount += 1
                case .completed:
                    terminalEventCount += 1
                default:
                    break
                }
            }
            XCTFail("Expected final publication rejection")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error, .publicationRejected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(secretProbe.callCount, 1)
        XCTAssertEqual(transportCallCount, 0)
        XCTAssertEqual(publicationProbe.callCount, 1)
        XCTAssertEqual(diagnosticsCount, 0)
        XCTAssertEqual(terminalEventCount, 0)
        XCTAssertEqual(auditProbe.callCount, 0)
        XCTAssertNil(auditProbe.result)
    }

    func testOpenAIAdapterHTTP500FailureDefersSingleDiagnosticAndAudit()
        async
    {
        await assertOpenAIAdapterExternalFailure(
            transport: HTTPStatusOpenAIConnectionTransport(statusCode: 500),
            expectedErrorCode: OpenAIConnectionStatus.serverError.rawValue,
            finalPublicationAccepted: true
        )
    }

    func testOpenAIAdapterTransportFailureDefersSingleDiagnosticAndAudit()
        async
    {
        await assertOpenAIAdapterExternalFailure(
            transport: ThrowingOpenAIConnectionTransport(),
            expectedErrorCode: OpenAIConnectionStatus.networkError.rawValue,
            finalPublicationAccepted: true
        )
    }

    func testOpenAIAdapterFinalPublicationRejectionSuppressesHTTPAndTransportFailureArtifacts()
        async
    {
        await assertOpenAIAdapterExternalFailure(
            transport: HTTPStatusOpenAIConnectionTransport(statusCode: 500),
            expectedErrorCode: OpenAIConnectionStatus.serverError.rawValue,
            finalPublicationAccepted: false
        )
        await assertOpenAIAdapterExternalFailure(
            transport: ThrowingOpenAIConnectionTransport(),
            expectedErrorCode: OpenAIConnectionStatus.networkError.rawValue,
            finalPublicationAccepted: false
        )
    }

    func testOpenAIAdapterSecretReaderDoesNotBlockMainActorAndPreservesRuntimeDiagnostics()
        async throws
    {
        let secretReader = BlockingTranslationSecretReader(
            material: Self.fixtureSecretMaterial
        )
        let runtime = OpenAITranslationRuntimeService(
            transport: SuccessfulTranslationTransport()
        )
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: runtime,
            configuration: { Self.validOpenAIConfiguration },
            readProviderSecret: { _ in
                secretReader.read()
            },
            authorizationValidator: { _, _ in true },
            admissionValidator: { _, _, start in start() },
            publicationValidator: { _, _, publication in
                publication()
                return true
            }
        )
        var diagnostics: TranslationResultDiagnostics?

        let translation = Task { @MainActor in
            for try await event in adapter.translate(Self.openAIRequest()) {
                guard case let .completed(_, _, runtimeDiagnostics) = event else {
                    continue
                }
                diagnostics = runtimeDiagnostics
            }
        }
        let readerDidEnter = await secretReader.waitUntilEntered()
        XCTAssertTrue(readerDidEnter)
        let heartbeat = expectation(description: "main actor remains schedulable")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        secretReader.release()
        try await translation.value

        XCTAssertEqual(secretReader.callCount, 1)
        XCTAssertEqual(diagnostics?.status, OpenAIConnectionStatus.success.rawValue)
        XCTAssertEqual(
            diagnostics?.route,
            "https://example.test · POST /v1/chat/completions"
        )
        XCTAssertTrue(diagnostics?.auditID.hasPrefix("tr_runtime_") == true)
        XCTAssertGreaterThanOrEqual(diagnostics?.durationMS ?? -1, 0)
    }

    func testOpenAIAdapterRejectsCredentialRevisionMismatchBeforeTransport()
        async
    {
        let transport = CountingOpenAIConnectionTransport()
        let mismatchedMaterial = ProviderUserSecretMaterial(
            redactedResult: Self.fixtureSecretMaterial.redactedResult,
            credentialRevision: 2,
            secret: "fixture-secret"
        )
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport
            ),
            configuration: { Self.validOpenAIConfiguration },
            readProviderSecret: { _ in mismatchedMaterial },
            authorizationValidator: { _, _ in true },
            admissionValidator: { _, _, start in start() },
            publicationValidator: { _, _, publication in
                publication()
                return true
            }
        )

        do {
            for try await _ in adapter.translate(Self.openAIRequest()) {}
            XCTFail("A stale credential revision must fail closed.")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(
                error.errorCode,
                ProviderErrorCode.missingSecret.rawValue
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testOpenAIAdapterRejectsOversizedInputBeforeReadingSecret() async {
        let probe = TranslationSecretReadProbe()
        let auditProbe = TranslationRuntimeAuditProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: SuccessfulTranslationTransport(),
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { Self.validOpenAIConfiguration },
            readProviderSecret: { _ in
                probe.recordRead()
                return Self.fixtureSecretMaterial
            },
            authorizationValidator: { _, _ in true },
            publicationValidator: { _, _, publication in
                publication()
                return true
            }
        )
        let oversizedText = String(
            repeating: "a",
            count:
                OpenAITranslationRuntimeService
                    .maximumInputCharacterCount + 1
        )
        var diagnostics: TranslationResultDiagnostics?

        do {
            for try await event in adapter.translate(
                Self.openAIRequest(text: oversizedText)
            ) {
                if case let .diagnostics(value, _) = event {
                    diagnostics = value
                }
            }
            XCTFail("Expected input limit failure")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error.errorCode, "translation_input_too_large")
            let expectedMessage = L10n.format(
                "translation.error.inputTooLarge",
                OpenAITranslationRuntimeService.maximumInputCharacterCount
            )
            XCTAssertEqual(error.localizedDescription, expectedMessage)
            XCTAssertNotEqual(
                expectedMessage,
                "translation.error.inputTooLarge"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(probe.callCount, 0)
        XCTAssertEqual(auditProbe.result?.warnings, [
            "translation_input_too_large",
            "provider_call_not_executed",
        ])
        XCTAssertEqual(
            diagnostics?.auditID,
            auditProbe.result?.auditID
        )
    }

    func testOpenAIAdapterFinalPublicationRevocationSuppressesOversizedInputArtifacts()
        async
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderModelName(
            "fixture-model", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderAccountAlias(
            "fixture-account", defaults: defaults
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target, defaults: defaults
            )
        )
        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let configuration = OpenAITranslationServiceConfiguration.current(
            defaults: authorizationDefaults.value
        )
        let secretProbe = TranslationSecretReadProbe()
        let transport = CountingOpenAIConnectionTransport()
        let auditProbe = TranslationRuntimeAuditProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { configuration },
            readProviderSecret: { _ in
                secretProbe.recordRead()
                return Self.fixtureSecretMaterial(
                    credentialRevision: target.credentialRevision
                )
            },
            authorizationValidator: { target, grant in
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value
                )
            },
            admissionValidator: { target, grant, start in
                ProviderSettingsPersistence.admitExternalTransfer(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value,
                    start: start
                )
            },
            publicationValidator: { target, grant, publication in
                ProviderSettingsPersistence.revokeExternalTransferGrant(
                    defaults: authorizationDefaults.value
                )
                return ProviderSettingsPersistence.publishExternalTransfer(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value,
                    publication: publication
                )
            }
        )
        let oversizedText = String(
            repeating: "a",
            count:
                OpenAITranslationRuntimeService
                    .maximumInputCharacterCount + 1
        )
        var diagnosticsCount = 0
        var terminalEventCount = 0

        do {
            for try await event in adapter.translate(
                Self.openAIRequest(text: oversizedText)
            ) {
                switch event {
                case .diagnostics:
                    diagnosticsCount += 1
                case .completed:
                    terminalEventCount += 1
                default:
                    break
                }
            }
            XCTFail("Expected final publication rejection")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error, .publicationRejected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(secretProbe.callCount, 0)
        XCTAssertEqual(transportCallCount, 0)
        XCTAssertEqual(diagnosticsCount, 0)
        XCTAssertEqual(terminalEventCount, 0)
        XCTAssertNil(auditProbe.result)
    }

    func testOpenAIAdapterFinalPublicationRevocationSuppressesCredentialMismatchAudit()
        async
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderModelName(
            "fixture-model", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderAccountAlias(
            "fixture-account", defaults: defaults
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target, defaults: defaults
            )
        )
        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let configuration = OpenAITranslationServiceConfiguration.current(
            defaults: authorizationDefaults.value
        )
        let secretProbe = TranslationSecretReadProbe()
        let transport = CountingOpenAIConnectionTransport()
        let auditProbe = TranslationRuntimeAuditProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { configuration },
            readProviderSecret: { _ in
                secretProbe.recordRead()
                return Self.fixtureSecretMaterial(
                    credentialRevision: target.credentialRevision + 1
                )
            },
            authorizationValidator: { target, grant in
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value
                )
            },
            admissionValidator: { target, grant, start in
                ProviderSettingsPersistence.admitExternalTransfer(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value,
                    start: start
                )
            },
            publicationValidator: { target, grant, publication in
                ProviderSettingsPersistence.revokeExternalTransferGrant(
                    defaults: authorizationDefaults.value
                )
                return ProviderSettingsPersistence.publishExternalTransfer(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value,
                    publication: publication
                )
            }
        )
        var diagnosticsCount = 0
        var terminalEventCount = 0

        do {
            for try await event in adapter.translate(Self.openAIRequest()) {
                switch event {
                case .diagnostics:
                    diagnosticsCount += 1
                case .completed:
                    terminalEventCount += 1
                default:
                    break
                }
            }
            XCTFail("Expected final publication rejection")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error, .publicationRejected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(secretProbe.callCount, 1)
        XCTAssertEqual(transportCallCount, 0)
        XCTAssertEqual(diagnosticsCount, 0)
        XCTAssertEqual(terminalEventCount, 0)
        XCTAssertNil(auditProbe.result)
    }

    func testRunCoordinatorKeepsStructuredRuntimeDiagnosticsInResultSnapshot()
        async
    {
        let coordinator = TranslationRunCoordinator()
        let diagnostics = TranslationResultDiagnostics(
            auditID: "tr_runtime_fixture",
            durationMS: 42,
            route: "https://example.test · POST /v1/chat/completions",
            status: "success"
        )
        let adapter = DiagnosticTranslationAdapter(
            diagnostics: diagnostics
        )
        let completed = expectation(description: "diagnostics preserved")
        var finalResult: TranslationResultSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "Blocks"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [adapter]
        ) { snapshot in
            guard snapshot.results.first?.state == .succeeded else {
                return
            }
            finalResult = snapshot.results.first
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(finalResult?.diagnostics, diagnostics)
        XCTAssertEqual(finalResult?.warnings, [])
    }

    func testRunCoordinatorPreservesCustomSourceOutputMetadata()
        async
    {
        let coordinator = TranslationRunCoordinator()
        let adapter = SourceOutputTranslationAdapter()
        let completed = expectation(
            description: "custom source output preserved"
        )
        var finalResult: TranslationResultSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "Blocks"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [adapter]
        ) { snapshot in
            guard snapshot.results.first?.state == .succeeded else {
                return
            }
            finalResult = snapshot.results.first
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(
            finalResult?.detectedSourceLanguage,
            TranslationLanguageTag("en")
        )
        XCTAssertEqual(
            finalResult?.sourceMetadata["provider"],
            .string("fixture")
        )
    }

    func testProviderAuditRecordsTranslationRuntimeWithoutResponseBody() {
        let store = ProviderStore()
        let runtime = OpenAITranslationRuntimeService()
        let result = runtime.inputLimitExceededResult(
            profile: OpenAITranslationRuntimeProfile(
                providerName: "Fixture Provider",
                baseURL: "https://example.test/v1",
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 60
            ),
            textCharacterCount: 100_001,
            sourceLanguageMode: "auto",
            targetLanguage: "zh-Hans"
        )

        store.recordTranslationRuntime(result)

        let event = store.providerAuditEvents.first
        XCTAssertEqual(event?.kind, .translationRuntime)
        XCTAssertEqual(event?.auditID, result.auditID)
        XCTAssertEqual(event?.action, .translationRuntime)
        XCTAssertEqual(event?.outcome, .failed)
        XCTAssertEqual(event?.count, 100_001)
        XCTAssertEqual(event?.errorCode, .invalidResponse)
    }

    func testProviderAuditRedactsFreeFormProviderValuesFromMemoryAndPresentation() {
        let store = ProviderStore()
        let alias = "alias-SENTINEL"
        let model = "model-SENTINEL"
        let providerSummary = "provider-SENTINEL"
        let endpoint = "https://private.example/v1?api_key=SENTINEL"
        let prompt = "prompt-SENTINEL"
        let error = ProviderAuditSentinelError(
            message: "error-SENTINEL"
        ).localizedDescription

        _ = store.previewProviderSettingsConfirmation(
            providerSummary: providerSummary,
            requiresExternalTransfer: true
        )
        store.previewProviderConnectionTest(
            summary: "\(endpoint) \(prompt)",
            ready: false,
            providerSummary: providerSummary,
            requiresExternalTransfer: true
        )
        _ = store.previewOpenAIConnection(
            baseURL: endpoint,
            modelName: model,
            keychainAccountAlias: alias
        )
        store.recordProviderAudit(
            ProviderAuditEvent(
                id: "safe-event-id",
                createdAt: Date(),
                kind: .keychainLifecyclePreview,
                providerSummary: providerSummary,
                confirmationLevel: providerSummary,
                sourceSummary: "\(alias) \(model) \(endpoint) \(prompt)",
                resultSummary: error,
                auditID: "safe-audit-id",
                warnings: [error]
            )
        )

        let sentinels = [alias, model, providerSummary, endpoint, prompt, error]
        for event in store.providerAuditEvents {
            let presentation = ProviderAuditPresentation(event: event)
            let visibleStrings = [
                event.providerSummary,
                event.sourceSummary,
                event.resultSummary,
                presentation.title,
                presentation.detail,
                presentation.technicalDetail,
            ] + event.warnings + presentation.warnings
            for sentinel in sentinels {
                XCTAssertFalse(visibleStrings.contains { $0.contains(sentinel) })
            }
        }
        XCTAssertTrue(store.providerAuditEvents.contains {
            $0.action == .openAIConnectionPreview
                && $0.outcome == .previewed
                && $0.confirmationLevel == .externalTransfer
        })
        XCTAssertTrue(store.providerAuditEvents.contains {
            $0.action == .connectionPreview && $0.outcome == .blocked
        })
    }

    func testRunCoordinatorPreservesServiceOrderAcrossOutOfOrderCompletionAndFailure() async {
        let coordinator = TranslationRunCoordinator()
        let adapters: [any TranslationServiceAdapter] = [
            TestTranslationAdapter(
                id: "slow",
                delay: .milliseconds(80),
                result: .success("较慢结果")
            ),
            TestTranslationAdapter(
                id: "failed",
                delay: .milliseconds(5),
                result: .failure(TestError.fixtureFailure)
            ),
            TestTranslationAdapter(
                id: "fast",
                delay: .milliseconds(10),
                result: .success("快速结果")
            ),
            TestTranslationAdapter(
                id: "medium",
                delay: .milliseconds(30),
                result: .success("中速结果")
            ),
        ]
        let completed = expectation(description: "all services completed")
        var finalSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "hello"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: adapters
        ) { snapshot in
            if snapshot.results.allSatisfy({
                $0.state == .succeeded || $0.state == .failed
            }) {
                finalSnapshot = snapshot
                completed.fulfill()
            }
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(
            finalSnapshot?.results.map(\.service.id),
            ["slow", "failed", "fast", "medium"]
        )
        XCTAssertEqual(
            finalSnapshot?.results.map(\.state),
            [.succeeded, .failed, .succeeded, .succeeded]
        )
    }

    func testRunCoordinatorKeepsUnsupportedDirectedSourceInPlaceWhileOtherSourceSucceeds()
        async
    {
        let transport = TranslationCommunityTransportProbe(
            responsesByHost: [:]
        )
        let tencent = acknowledgedCommunityAdapter(
            source: .tencentWeb,
            transport: transport
        )
        let compatible = TestTranslationAdapter(
            id: "compatible",
            result: .success("תרגום")
        )
        let coordinator = TranslationRunCoordinator()
        let completed = expectation(
            description: "unsupported card and compatible result finish"
        )
        var finalSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(
                source: .manual,
                text: "The meeting starts at nine tomorrow."
            ),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("he")!
            ),
            adapters: [tencent, compatible]
        ) { snapshot in
            guard snapshot.results.allSatisfy({
                $0.state == .succeeded || $0.state == .failed
            }) else {
                return
            }
            finalSnapshot = snapshot
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(
            finalSnapshot?.results.map(\.service.id),
            ["community:tencent-web", "compatible"]
        )
        XCTAssertEqual(
            finalSnapshot?.results.map(\.state),
            [.failed, .succeeded]
        )
        XCTAssertEqual(
            finalSnapshot?.results.first?.errorCode,
            "translation_language_pair_unsupported"
        )
        XCTAssertEqual(
            finalSnapshot?.results.last?.translatedText,
            "תרגום"
        )
        let transportRequests = await transport.requests()
        XCTAssertEqual(transportRequests.count, 0)
        XCTAssertEqual(compatible.translateCallCount, 1)
    }

    func testRunCoordinatorReordersRunningResultsWithoutRestartingServices()
        async
    {
        let coordinator = TranslationRunCoordinator()
        let first = TestTranslationAdapter(
            id: "first",
            delay: .milliseconds(80)
        )
        let second = TestTranslationAdapter(
            id: "second",
            delay: .milliseconds(60)
        )
        let third = TestTranslationAdapter(
            id: "third",
            delay: .milliseconds(100)
        )
        var latestSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "hello"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [first, second, third]
        ) {
            latestSnapshot = $0
        }
        await waitUntil {
            latestSnapshot?.results.allSatisfy {
                $0.state == .running
            } == true
        }

        coordinator.reorderServices(["third", "first", "second"])

        XCTAssertEqual(
            latestSnapshot?.results.map(\.service.id),
            ["third", "first", "second"]
        )
        XCTAssertEqual(first.translateCallCount, 1)
        XCTAssertEqual(second.translateCallCount, 1)
        XCTAssertEqual(third.translateCallCount, 1)

        await waitUntil {
            latestSnapshot?.results.allSatisfy {
                $0.state == .succeeded
            } == true
        }
        XCTAssertEqual(
            latestSnapshot?.results.map(\.service.id),
            ["third", "first", "second"]
        )
        XCTAssertEqual(first.translateCallCount, 1)
        XCTAssertEqual(second.translateCallCount, 1)
        XCTAssertEqual(third.translateCallCount, 1)
    }

    func testRunCoordinatorStartsTextSourceBeforeScreenshotAttachmentAndLaunchesImageSourceOnce()
        async
    {
        let coordinator = TranslationRunCoordinator()
        let text = TestTranslationAdapter(
            id: "text",
            delay: .milliseconds(5),
            acceptedInputs: [.text]
        )
        let image = TestTranslationAdapter(
            id: "image",
            delay: .milliseconds(5),
            acceptedInputs: [.screenshotImage]
        )
        var latestSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "recognized text"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [text, image]
        ) {
            latestSnapshot = $0
        }

        await waitUntil {
            latestSnapshot?.results.first {
                $0.service.id == "text"
            }?.state == .succeeded
        }
        XCTAssertEqual(text.translateCallCount, 1)
        XCTAssertEqual(image.translateCallCount, 0)
        XCTAssertEqual(
            latestSnapshot?.results.first {
                $0.service.id == "image"
            }?.state,
            .waiting
        )

        coordinator.installAttachments([
            TranslationSourceAttachmentPayload(
                descriptor: TranslationSourceAttachmentDescriptor(
                    kind: .screenshotImage,
                    mediaType: "image/jpeg",
                    byteCount: 1,
                    pixelWidth: 1,
                    pixelHeight: 1
                ),
                data: Data([0x01])
            ),
        ])

        await waitUntil {
            latestSnapshot?.results.first {
                $0.service.id == "image"
            }?.state == .succeeded
        }
        XCTAssertEqual(text.translateCallCount, 1)
        XCTAssertEqual(image.translateCallCount, 1)
        XCTAssertEqual(image.requestedAttachmentCounts, [1])
    }

    func testDisablingDeferredScreenshotSourcePreventsAttachmentLaunch()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let text = TestTranslationAdapter(
            id: "plugin:deferred-text",
            delay: .milliseconds(5),
            acceptedInputs: [.text]
        )
        let image = TestTranslationAdapter(
            id: "plugin:deferred-image",
            acceptedInputs: [.screenshotImage]
        )
        store.replacePluginAdapters([text, image])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: text.descriptor.id)
        store.setServiceEnabled(true, serviceID: image.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "recognized text"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.expectScreenshotAttachment()
        model.runImmediately()
        await waitUntil {
            model.snapshot?.results.first {
                $0.service.id == image.descriptor.id
            }?.state == .waiting
                && model.snapshot?.results.first {
                    $0.service.id == text.descriptor.id
                }?.state == .succeeded
        }

        store.setServiceEnabled(false, serviceID: image.descriptor.id)
        await waitUntil {
            model.snapshot?.results.first {
                $0.service.id == image.descriptor.id
            }?.state == .cancelled
        }
        model.installScreenshotAttachment(
            TranslationSourceAttachmentPayload(
                descriptor: TranslationSourceAttachmentDescriptor(
                    kind: .screenshotImage,
                    mediaType: "image/jpeg",
                    byteCount: 1,
                    pixelWidth: 1,
                    pixelHeight: 1
                ),
                data: Data([0x01])
            )
        )

        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(image.translateCallCount, 0)
        XCTAssertEqual(
            model.snapshot?.results.first {
                $0.service.id == image.descriptor.id
            }?.state,
            .cancelled
        )
        XCTAssertEqual(text.translateCallCount, 1)
        XCTAssertEqual(
            model.snapshot?.results.first {
                $0.service.id == text.descriptor.id
            }?.state,
            .succeeded
        )
    }

    func testRunCoordinatorAttachmentFailureOnlyFailsWaitingImageSource()
        async
    {
        let coordinator = TranslationRunCoordinator()
        let text = TestTranslationAdapter(
            id: "text",
            delay: .milliseconds(5),
            acceptedInputs: [.text]
        )
        let image = TestTranslationAdapter(
            id: "image",
            acceptedInputs: [.screenshotImage]
        )
        var latestSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "recognized text"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [text, image]
        ) {
            latestSnapshot = $0
        }
        coordinator.failPendingScreenshotAttachment(
            code: "plugin_translation_image_invalid",
            message: "Image attachment could not be encoded."
        )

        await waitUntil {
            latestSnapshot?.results.allSatisfy {
                $0.state == .succeeded || $0.state == .failed
            } == true
        }
        let textResult = latestSnapshot?.results.first {
            $0.service.id == "text"
        }
        let imageResult = latestSnapshot?.results.first {
            $0.service.id == "image"
        }
        XCTAssertEqual(textResult?.state, .succeeded)
        XCTAssertEqual(text.translateCallCount, 1)
        XCTAssertEqual(imageResult?.state, .failed)
        XCTAssertEqual(
            imageResult?.errorCode,
            "plugin_translation_image_invalid"
        )
        XCTAssertEqual(imageResult?.isRetryable, false)
        XCTAssertEqual(image.translateCallCount, 0)
    }

    func testRunCoordinatorDefersMixedScreenshotSourceUntilAttachment()
        async
    {
        let coordinator = TranslationRunCoordinator()
        let mixed = TestTranslationAdapter(
            id: "mixed",
            delay: .milliseconds(5),
            acceptedInputs: [.text, .screenshotImage]
        )
        var latestSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "recognized text"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [mixed]
        ) {
            latestSnapshot = $0
        }

        await waitUntil {
            latestSnapshot?.results.first?.state == .waiting
        }
        XCTAssertEqual(mixed.translateCallCount, 0)

        coordinator.installAttachments([
            TranslationSourceAttachmentPayload(
                descriptor: TranslationSourceAttachmentDescriptor(
                    kind: .screenshotImage,
                    mediaType: "image/jpeg",
                    byteCount: 1,
                    pixelWidth: 1,
                    pixelHeight: 1
                ),
                data: Data([0x01])
            ),
        ])

        await waitUntil {
            latestSnapshot?.results.first?.state == .succeeded
        }
        XCTAssertEqual(mixed.translateCallCount, 1)
        XCTAssertEqual(mixed.requestedAttachmentCounts, [1])
    }

    func testRunCoordinatorCompletesStableSessionWhenAllServicesFail() async {
        let coordinator = TranslationRunCoordinator()
        let adapters: [any TranslationServiceAdapter] = (1 ... 4).map {
            TestTranslationAdapter(
                id: "failed-\($0)",
                delay: .milliseconds($0 * 5),
                result: .failure(TestError.fixtureFailure)
            )
        }
        let completed = expectation(description: "all services failed")
        var finalSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "hello"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: adapters
        ) { snapshot in
            guard snapshot.results.allSatisfy({
                $0.state == .failed
            }) else {
                return
            }
            finalSnapshot = snapshot
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(
            finalSnapshot?.results.map(\.service.id),
            ["failed-1", "failed-2", "failed-3", "failed-4"]
        )
        XCTAssertEqual(finalSnapshot?.successfulResults, [])
    }

    func testRunCoordinatorRejectsUnsupportedTargetBeforeCallingAdapter() async {
        let coordinator = TranslationRunCoordinator()
        let adapter = TestTranslationAdapter(
            id: "restricted",
            supportedTargetLanguages: [TranslationLanguageTag("fr")!]
        )
        let failed = expectation(description: "unsupported pair failed")
        var finalResult: TranslationResultSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "hello"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("ja")!
            ),
            adapters: [adapter]
        ) { snapshot in
            guard let result = snapshot.results.first,
                  result.state == .failed else {
                return
            }
            finalResult = result
            failed.fulfill()
        }

        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(
            finalResult?.errorCode,
            "translation_target_language_unsupported"
        )
        XCTAssertEqual(adapter.translateCallCount, 0)
    }

    func testRunCoordinatorDoesNotLetExplicitSourceServiceRedetectUnknownInput()
        async
    {
        let coordinator = TranslationRunCoordinator()
        let adapter = TestTranslationAdapter(
            id: "explicit-source",
            requiresExplicitSourceLanguage: true
        )
        var finalResult: TranslationResultSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "123"),
            direction: TranslationLanguageDirection(
                source: nil,
                target: TranslationLanguageTag("en")!
            ),
            adapters: [adapter]
        ) { snapshot in
            if snapshot.results.first?.state == .failed {
                finalResult = snapshot.results.first
            }
        }
        await waitUntil { finalResult != nil }

        XCTAssertEqual(
            finalResult?.errorCode,
            "source_language_undetermined"
        )
        XCTAssertEqual(adapter.translateCallCount, 0)
    }

    func testNewRevisionRejectsLateResultFromPreviousSession() async {
        let coordinator = TranslationRunCoordinator()
        let first = TestTranslationAdapter(
            id: "first",
            delay: .milliseconds(120),
            result: .success("stale")
        )
        let second = TestTranslationAdapter(
            id: "second",
            delay: .milliseconds(5),
            result: .success("fresh")
        )
        var observedTexts: [String] = []
        let completed = expectation(description: "new revision completed")
        let direction = TranslationLanguageDirection(
            target: TranslationLanguageTag("zh-Hans")!
        )

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "old"),
            direction: direction,
            adapters: [first]
        ) { _ in }
        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "new"),
            direction: direction,
            adapters: [second]
        ) { snapshot in
            observedTexts.append(contentsOf: snapshot.results.map(\.translatedText))
            if snapshot.results.allSatisfy({ $0.state == .succeeded }) {
                completed.fulfill()
            }
        }

        await fulfillment(of: [completed], timeout: 2)
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(observedTexts.contains("fresh"))
        XCTAssertFalse(observedTexts.contains("stale"))
    }

    func testRetryRejectsCancelledAndLateEventsFromPreviousAttempt() async {
        let coordinator = TranslationRunCoordinator()
        let adapter = ControlledRetryTranslationAdapter()
        let direction = TranslationLanguageDirection(
            target: TranslationLanguageTag("zh-Hans")!
        )
        var latestResult: TranslationResultSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "source"),
            direction: direction,
            adapters: [adapter]
        ) { snapshot in
            latestResult = snapshot.results.first
        }
        await waitUntil { adapter.attemptCount == 1 }

        coordinator.retry(serviceID: adapter.descriptor.id)
        await waitUntil { adapter.attemptCount == 2 }
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(
            latestResult?.state == .waiting
                || latestResult?.state == .running
        )
        adapter.succeed(attempt: 1, text: "fresh")
        await waitUntil {
            latestResult?.state == .succeeded
                && latestResult?.translatedText == "fresh"
        }

        adapter.fail(attempt: 0, error: TestError.fixtureFailure)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(latestResult?.state, .succeeded)
        XCTAssertEqual(latestResult?.translatedText, "fresh")
    }

    func testRunCoordinatorCancelsOnlySelectedService() async {
        let coordinator = TranslationRunCoordinator()
        let cancelledAdapter = TestTranslationAdapter(
            id: "cancelled-service",
            delay: .seconds(2),
            result: .success("late")
        )
        let successfulAdapter = TestTranslationAdapter(
            id: "successful-service",
            delay: .milliseconds(20),
            result: .success("fresh")
        )
        var latestSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [cancelledAdapter, successfulAdapter]
        ) {
            latestSnapshot = $0
        }
        await waitUntil {
            latestSnapshot?.results.first {
                $0.service.id == cancelledAdapter.descriptor.id
            }?.state == .running
        }

        coordinator.cancel(serviceID: cancelledAdapter.descriptor.id)
        await waitUntil {
            latestSnapshot?.results.allSatisfy {
                $0.state == .cancelled || $0.state == .succeeded
            } == true
        }

        XCTAssertEqual(
            latestSnapshot?.results.map(\.state),
            [.cancelled, .succeeded]
        )
        XCTAssertEqual(
            latestSnapshot?.results.last?.translatedText,
            "fresh"
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            latestSnapshot?.results.first?.state,
            .cancelled
        )
    }

    func testUnknownTranslationErrorsUseGenericUserMessage() {
        XCTAssertEqual(
            TranslationErrorPresentation.message(
                for: TestError.fixtureFailure
            ),
            L10n.string("translation.error.generic")
        )
    }

    func testRetryPreservesFavoriteStateInCoordinatorSession() async {
        let coordinator = TranslationRunCoordinator()
        let adapter = TestTranslationAdapter(
            id: "plugin:favorite-retry",
            result: .success("translated")
        )
        var latestSnapshot: TranslationSessionSnapshot?

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            adapters: [adapter]
        ) {
            latestSnapshot = $0
        }
        await waitUntil {
            latestSnapshot?.successfulResults.count == 1
        }

        coordinator.markSessionFavorite(
            sessionID: latestSnapshot?.id ?? ""
        )
        XCTAssertTrue(latestSnapshot?.isFavorite == true)
        coordinator.retry(serviceID: adapter.descriptor.id)
        await waitUntil {
            adapter.translateCallCount == 2
                && latestSnapshot?.successfulResults.count == 1
        }

        XCTAssertTrue(latestSnapshot?.isFavorite == true)
    }

    func testLateFavoriteCompletionCannotMarkReplacementSession() async {
        let coordinator = TranslationRunCoordinator()
        let adapter = TestTranslationAdapter(
            id: "plugin:favorite-session-guard",
            result: .success("translated")
        )
        var latestSnapshot: TranslationSessionSnapshot?
        let direction = TranslationLanguageDirection(
            target: TranslationLanguageTag("zh-Hans")!
        )

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "first"),
            direction: direction,
            adapters: [adapter]
        ) {
            latestSnapshot = $0
        }
        await waitUntil {
            latestSnapshot?.successfulResults.count == 1
        }
        let firstSessionID = latestSnapshot?.id ?? ""

        _ = coordinator.start(
            input: TranslationInput(source: .manual, text: "second"),
            direction: direction,
            adapters: [adapter]
        ) {
            latestSnapshot = $0
        }
        coordinator.markSessionFavorite(sessionID: firstSessionID)

        XCTAssertFalse(latestSnapshot?.isFavorite == true)
        XCTAssertEqual(latestSnapshot?.input.text, "second")
    }

    func testEditingSourceImmediatelyInvalidatesFavoriteCandidate() async {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let plugin = TestTranslationAdapter(
            id: "plugin:favorite-fixture",
            result: .success("译文")
        )
        store.replacePluginAdapters([plugin])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: plugin.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.runImmediately()
        for _ in 0 ..< 50 where !model.canFavorite {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canFavorite)

        model.sourceText = "changed"
        model.scheduleAutomaticTranslation(delay: .seconds(1))

        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.canFavorite)
        model.cancel()
    }

    func testAutomaticTranslationDebounceRunsOnlyLatestInput() async {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let plugin = TestTranslationAdapter(id: "plugin:debounce-fixture")
        store.replacePluginAdapters([plugin])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: plugin.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "first"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.scheduleAutomaticTranslation(delay: .milliseconds(80))
        XCTAssertEqual(model.runPhase, .debouncing)
        try? await Task.sleep(for: .milliseconds(20))
        model.sourceText = "second"
        model.scheduleAutomaticTranslation(delay: .milliseconds(80))
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(plugin.requestedTexts, ["second"])
        XCTAssertEqual(model.snapshot?.input.text, "second")
        model.cancel()
    }

    func testPluginEventsExposePanelAndTranslationSessionIdentity() async {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:event-identity",
            result: .success("translated")
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )
        var events: [BlocksPluginEventEnvelope] = []
        model.configurePluginEvents { envelope in
            events.append(envelope)
            return .allowed(envelope)
        }

        model.runImmediately()
        await waitUntil {
            events.contains { $0.name == .translationSessionCompleted }
        }

        guard let translationSessionID = model.snapshot?.id else {
            return XCTFail("Expected a translation session identity.")
        }
        let expectedNames: Set<BlocksPluginEventName> = [
            .translationInputResolved,
            .translationWillRunSession,
            .translationSourceResult,
            .translationSessionCompleted,
        ]
        let runEvents = events.filter { expectedNames.contains($0.name) }
        XCTAssertEqual(Set(runEvents.map(\.name)), expectedNames)
        XCTAssertNotEqual(translationSessionID, model.id.uuidString)
        let causationID = UUID(uuidString: translationSessionID)
        for event in runEvents {
            XCTAssertEqual(event.sessionID, translationSessionID)
            XCTAssertEqual(event.revision, 1)
            XCTAssertEqual(event.causationID, causationID)
            XCTAssertEqual(
                event.payload.string("panel_id"),
                model.id.uuidString
            )
            XCTAssertEqual(
                event.payload.string("translation_session_id"),
                translationSessionID
            )
        }

        model.runImmediately()
        await waitUntil {
            events.filter {
                $0.name == .translationSessionCompleted
            }.count == 2
        }
        guard let secondTranslationSessionID = model.snapshot?.id else {
            return XCTFail("Expected a second translation session identity.")
        }
        XCTAssertNotEqual(secondTranslationSessionID, translationSessionID)
        model.cancel()
    }

    func testPluginWillRunSessionPreservesInjectedNonUserAuthorization()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:non-user-authorization",
            result: .success("translated")
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store,
            pluginRunAuthorization: .init(userInitiated: false)
        )
        var willRunAuthorization: BlocksPluginAuthorizationContext?
        model.configurePluginEvents { envelope in
            if envelope.name == .translationWillRunSession {
                willRunAuthorization = envelope.authorization
            }
            return .allowed(envelope)
        }

        model.runImmediately()
        await waitUntil { willRunAuthorization != nil }

        XCTAssertFalse(willRunAuthorization?.userInitiated ?? true)
        model.cancel()
    }

    func testTranslatedCopyPluginEventsUseCurrentTranslationIdentity() async {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:copy-event-identity",
            result: .success("translated")
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )
        var events: [BlocksPluginEventEnvelope] = []
        var copiedTexts: [String] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(recordID: recordID, purpose: purpose, text: "")
            },
            copyText: { text in
                copiedTexts.append(text)
                return .copiedAndRecorded
            },
            openMainWindow: { _ in },
            dispatchPluginEvent: { envelope in
                events.append(envelope)
                if envelope.name == .translationWillCommitResult {
                    return .allowed(
                        BlocksPluginEventEnvelope(
                            name: envelope.name,
                            sessionID: "forged-session-id",
                            revision: 999,
                            payload: [
                                "translated_text": .string("plugin rewritten"),
                            ]
                        )
                    )
                }
                return .allowed(envelope)
            }
        )

        model.runImmediately()
        await waitUntil { model.snapshot?.successfulResults.count == 1 }
        guard let identity = model.currentPluginEventIdentity else {
            return XCTFail("Expected an active translation plugin identity.")
        }

        let outcome = await coordinator.commitTranslatedText(
            "translated",
            model: model
        )

        XCTAssertEqual(outcome, .copiedAndRecorded)
        XCTAssertEqual(copiedTexts, ["plugin rewritten"])
        let copyEvents = events.filter {
            $0.name == .translationWillCommitResult
                || $0.name == .translationCopyCompleted
        }
        XCTAssertEqual(copyEvents.count, 2)
        for event in copyEvents {
            XCTAssertEqual(event.sessionID, identity.translationSessionID)
            XCTAssertEqual(event.revision, identity.revision)
            XCTAssertEqual(event.payload.string("panel_id"), model.id.uuidString)
            XCTAssertEqual(
                event.payload.string("translation_session_id"),
                identity.translationSessionID
            )
        }
        model.cancel()
    }

    func testTranslatedCopyDoesNotPublishCompletionAfterSessionInvalidation()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:copy-event-invalidation",
            result: .success("translated")
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )
        let copyProbe = SuspendedTranslationCopyProbe()
        var events: [BlocksPluginEventEnvelope] = []
        let coordinator = TranslationFeatureCoordinator(
            translationStore: store
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeClipboardPanel: { completion in completion() },
            readClipboardText: { recordID, purpose, _ in
                .success(recordID: recordID, purpose: purpose, text: "")
            },
            copyText: { text in
                await copyProbe.copy(text)
                return .copiedAndRecorded
            },
            openMainWindow: { _ in },
            dispatchPluginEvent: { envelope in
                events.append(envelope)
                return .allowed(envelope)
            }
        )

        model.runImmediately()
        await waitUntil { model.snapshot?.successfulResults.count == 1 }
        let copyTask = Task {
            await coordinator.commitTranslatedText(
                "translated",
                model: model
            )
        }
        await copyProbe.waitUntilStarted()

        model.cancel()
        await copyProbe.resume()

        let outcome = await copyTask.value
        let copiedTexts = await copyProbe.copiedTexts
        XCTAssertEqual(outcome, .copiedAndRecorded)
        XCTAssertEqual(copiedTexts, ["translated"])
        XCTAssertEqual(
            events.filter { $0.name == .translationWillCommitResult }.count,
            1
        )
        XCTAssertFalse(
            events.contains { $0.name == .translationCopyCompleted }
        )
    }

    func testStartingPluginPreflightImmediatelyInvalidatesPreviousSession()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:preflight-session-isolation",
            result: .success("translated")
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.runImmediately()
        await waitUntil { model.snapshot?.successfulResults.count == 1 }
        guard let previousSessionID = model.snapshot?.id else {
            return XCTFail("Expected the first translation session.")
        }
        var preflightContinuation: CheckedContinuation<Void, Never>?
        model.configurePluginEvents { envelope in
            if envelope.name == .translationInputResolved {
                await withCheckedContinuation { continuation in
                    preflightContinuation = continuation
                }
            }
            return .allowed(envelope)
        }

        model.runImmediately()
        await waitUntil { preflightContinuation != nil }

        XCTAssertFalse(model.acceptsPluginHostAction(
            translationSessionID: previousSessionID,
            expectedRevision: 2
        ))
        preflightContinuation?.resume()
        preflightContinuation = nil
        model.cancel()
    }

    func testRetryAndServiceCancelInvalidatePriorPluginRevisionAndReplay()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = ControlledRetryTranslationAdapter()
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.runImmediately()
        await waitUntil { adapter.attemptCount == 1 }
        adapter.fail(attempt: 0, error: TestError.fixtureFailure)
        await waitUntil {
            model.snapshot?.results.first?.state == .failed
        }
        guard let sessionID = model.snapshot?.id else {
            return XCTFail("Expected the controlled translation session.")
        }
        XCTAssertTrue(model.acceptsPluginHostAction(
            translationSessionID: sessionID,
            expectedRevision: 1
        ))

        XCTAssertTrue(model.retry(serviceID: adapter.descriptor.id))
        await waitUntil { adapter.attemptCount == 2 }
        XCTAssertEqual(model.snapshot?.id, sessionID)
        XCTAssertFalse(model.acceptsPluginHostAction(
            translationSessionID: sessionID,
            expectedRevision: 1
        ))
        XCTAssertFalse(model.retry(serviceID: adapter.descriptor.id))
        XCTAssertEqual(adapter.attemptCount, 2)

        XCTAssertTrue(model.cancel(serviceID: adapter.descriptor.id))
        XCTAssertFalse(model.acceptsPluginHostAction(
            translationSessionID: sessionID,
            expectedRevision: 2
        ))
        XCTAssertFalse(model.cancel(serviceID: adapter.descriptor.id))
        model.cancel()
    }

    func testAllCancelledTranslationDoesNotEmitSessionFailed() async {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:event-cancelled",
            delay: .seconds(1)
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )
        var events: [BlocksPluginEventEnvelope] = []
        model.configurePluginEvents { envelope in
            events.append(envelope)
            return .allowed(envelope)
        }

        model.runImmediately()
        await waitUntil { model.snapshot?.results.count == 1 }
        model.cancel()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        XCTAssertFalse(events.contains { $0.name == .translationSessionFailed })
    }

    func testFinalPublicationRejectionCancelsPanelResultWithoutPluginTerminalPublication()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:publication-rejected",
            result: .failure(
                TranslationServiceAdapterError.publicationRejected
            )
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(
                source: .manual,
                text: "publication-rejected-source"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )
        var events: [BlocksPluginEventEnvelope] = []
        model.configurePluginEvents { envelope in
            events.append(envelope)
            return .allowed(envelope)
        }

        model.runImmediately()
        await waitUntil {
            model.snapshot?.results.first?.state == .cancelled
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let result = model.snapshot?.results.first
        XCTAssertEqual(result?.state, .cancelled)
        XCTAssertEqual(
            result?.errorCode,
            TranslationServiceAdapterError.publicationRejected.errorCode
        )
        XCTAssertFalse(events.contains {
            $0.name == .translationSourceResult
                || $0.name == .translationSourceFailed
                || $0.name == .translationSessionCompleted
                || $0.name == .translationSessionFailed
        })
        XCTAssertFalse(events.contains {
            $0.name == .translationSourceStatus
                && $0.payload.string("state")
                    == TranslationResultState.cancelled.rawValue
        })
        model.cancel()
    }

    func testFailedTranslationWithoutSuccessfulResultEmitsSessionFailed()
        async
    {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(
            id: "plugin:event-failed",
            result: .failure(TestError.fixtureFailure)
        )
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )
        var events: [BlocksPluginEventEnvelope] = []
        model.configurePluginEvents { envelope in
            events.append(envelope)
            return .allowed(envelope)
        }

        model.runImmediately()
        await waitUntil {
            events.contains { $0.name == .translationSessionFailed }
        }

        XCTAssertFalse(events.contains { $0.name == .translationSessionCompleted })
        model.cancel()
    }

    func testLanguageSwapUsesOneImmediateTranslationRun() async {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let adapter = TestTranslationAdapter(id: "plugin:swap-fixture")
        store.replacePluginAdapters([adapter])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: adapter.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: "source"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en")!,
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.swapLanguagesAndRun()
        await waitUntil { model.snapshot?.successfulResults.count == 1 }

        XCTAssertEqual(adapter.requestedTexts, ["source"])
        XCTAssertEqual(
            model.snapshot?.direction,
            TranslationLanguageDirection(
                source: TranslationLanguageTag("zh-Hans")!,
                target: TranslationLanguageTag("en")!
            )
        )
        model.cancel()
    }

    func testAppleLanguagePreparationReplacesPreviousRequestExactlyOnce() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Apple Translation preparation requires macOS 15")
        }
        let controller = AppleTranslationPreparationController()
        let input = TranslationInput(source: .manual, text: "hello")
        let direction = TranslationLanguageDirection(
            source: TranslationLanguageTag("en")!,
            target: TranslationLanguageTag("zh-Hans")!
        )
        var firstResults: [Result<Void, Error>] = []

        controller.prepare(
            input: input,
            direction: direction
        ) {
            firstResults.append($0)
        }
        controller.prepare(
            input: input,
            direction: direction
        ) { _ in }

        XCTAssertEqual(firstResults.count, 1)
        XCTAssertTrue(
            AppleTranslationSystemInteractionGuard.shared.isActive
        )
        guard case let .failure(error) = firstResults[0] else {
            return XCTFail("The replaced preparation must be cancelled")
        }
        XCTAssertTrue(error is CancellationError)
        controller.cancel()
        XCTAssertFalse(
            AppleTranslationSystemInteractionGuard.shared.isActive
        )
    }

    func testAppleLanguagePreparationCancelCompletesPendingRequestExactlyOnce()
        throws
    {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Apple Translation preparation requires macOS 15")
        }
        let controller = AppleTranslationPreparationController()
        var results: [Result<Void, Error>] = []
        controller.prepare(
            input: TranslationInput(source: .manual, text: "hello"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en")!,
                target: TranslationLanguageTag("zh-Hans")!
            )
        ) {
            results.append($0)
        }
        XCTAssertTrue(
            AppleTranslationSystemInteractionGuard.shared.isActive
        )

        controller.cancel()
        controller.cancel()

        XCTAssertEqual(results.count, 1)
        guard case let .failure(error) = results[0] else {
            return XCTFail("Cancelling preparation must report cancellation")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(
            AppleTranslationSystemInteractionGuard.shared.isActive
        )
    }

    func testAppleTranslationAvailabilityCoalescesAndCachesInstalledPair()
        async
    {
        var queryCount = 0
        let coordinator = AppleTranslationAvailabilityCoordinator {
            _, _ in
            queryCount += 1
            try? await Task.sleep(for: .milliseconds(40))
            return .installed
        }
        let pair = AppleTranslationLanguagePair(
            source: TranslationLanguageTag("en")!,
            target: TranslationLanguageTag("zh-Hans")!
        )

        async let first = coordinator.availability(for: pair)
        await Task.yield()
        async let second = coordinator.availability(for: pair)
        let results = await [first, second]
        let cached = await coordinator.availability(for: pair)

        XCTAssertEqual(results, [.installed, .installed])
        XCTAssertEqual(queryCount, 1)
        XCTAssertEqual(cached, .installed)
        XCTAssertEqual(queryCount, 1)
    }

    func testAppleTranslationReadinessSeparatesDownloadFromNotReady() {
        XCTAssertNil(
            AppleTranslationReadinessPolicy.failure(
                availability: .downloadable,
                sessionIsReady: true
            )
        )
        XCTAssertEqual(
            AppleTranslationReadinessPolicy.failure(
                availability: .downloadable,
                sessionIsReady: false
            )?.errorCode,
            "apple_language_download_required"
        )
        XCTAssertEqual(
            AppleTranslationReadinessPolicy.failure(
                availability: .installed,
                sessionIsReady: false
            )?.errorCode,
            "apple_language_not_ready"
        )
        XCTAssertEqual(
            AppleTranslationReadinessPolicy.failure(
                availability: .unsupported,
                sessionIsReady: false
            )?.errorCode,
            "apple_language_pair_unsupported"
        )
    }

    func testAppleTranslationFailureClassifierDoesNotCallInternalFailureDownload()
    {
        let runtime = AppleTranslationFailureClassifier.classify(
            NSError(domain: "TranslationErrorDomain", code: 14),
            phase: .runtime
        ) as? TranslationServiceAdapterError
        let preparation = AppleTranslationFailureClassifier.classify(
            NSError(domain: "TranslationErrorDomain", code: 14),
            phase: .preparation
        ) as? TranslationServiceAdapterError

        XCTAssertEqual(
            runtime?.errorCode,
            "apple_translation_runtime_unavailable"
        )
        XCTAssertEqual(
            preparation?.errorCode,
            "apple_translation_preparation_failed"
        )
    }

#if canImport(Translation)
    func testAppleTranslationFailureClassifierMapsPublicFrameworkErrors() {
        guard #available(macOS 15.0, *) else { return }
        XCTAssertEqual(
            (
                AppleTranslationFailureClassifier.classify(
                    TranslationError.unsupportedLanguagePairing,
                    phase: .runtime
                ) as? TranslationServiceAdapterError
            )?.errorCode,
            "apple_language_pair_unsupported"
        )
        XCTAssertEqual(
            (
                AppleTranslationFailureClassifier.classify(
                    TranslationError.unableToIdentifyLanguage,
                    phase: .runtime
                ) as? TranslationServiceAdapterError
            )?.errorCode,
            "source_language_undetermined"
        )
        XCTAssertEqual(
            (
                AppleTranslationFailureClassifier.classify(
                    TranslationError.internalError,
                    phase: .runtime
                ) as? TranslationServiceAdapterError
            )?.errorCode,
            "apple_translation_runtime_unavailable"
        )
        if #available(macOS 26.0, *) {
            XCTAssertEqual(
                (
                    AppleTranslationFailureClassifier.classify(
                        TranslationError.notInstalled,
                        phase: .runtime
                    ) as? TranslationServiceAdapterError
                )?.errorCode,
                "apple_language_download_required"
            )
        }
    }
#endif

    func testAppleLanguagePackResolverIncludesBothDirections() {
        let native = TranslationLanguageTag("zh-Hans")!
        let english = TranslationLanguageTag("en")!
        let japanese = TranslationLanguageTag("ja")!

        XCTAssertEqual(
            AppleTranslationLanguagePairResolver.directedPairs(
                for: TranslationUserLanguagePreferenceSnapshot(
                    nativeLanguage: native,
                    focusLanguages: [english, japanese],
                    recentlyUsedFocusLanguage: nil
                )
            ),
            [
                AppleTranslationLanguagePair(
                    source: native,
                    target: english
                ),
                AppleTranslationLanguagePair(
                    source: english,
                    target: native
                ),
                AppleTranslationLanguagePair(
                    source: native,
                    target: japanese
                ),
                AppleTranslationLanguagePair(
                    source: japanese,
                    target: native
                ),
            ]
        )
    }

    func testLeavingLanguageSettingsDoesNotCancelActivePreparation() {
        let coordinator = AppleTranslationAvailabilityCoordinator {
            _, _ in .downloadable
        }
        let controller = AppleTranslationLanguagePackController(
            availabilityCoordinator: coordinator
        )
        defer { controller.cancel() }
        let preferences = TranslationUserLanguagePreferenceSnapshot(
            nativeLanguage: TranslationLanguageTag("en")!,
            focusLanguages: [
                TranslationLanguageTag("zh-Hans")!,
            ],
            recentlyUsedFocusLanguage: nil
        )
        let pair = AppleTranslationLanguagePair(
            source: preferences.nativeLanguage,
            target: preferences.focusLanguages[0]
        )

        controller.prepare(pair, preferences: preferences)
        controller.cancelRefresh()

        XCTAssertEqual(controller.activePair, pair)
        XCTAssertTrue(controller.preparationController.isPreparing)
        XCTAssertTrue(
            AppleTranslationSystemInteractionGuard.shared.isActive
        )
    }

    func testUserSourceUpdateOwnsItsDebounceWithoutViewSideEffects() async {
        let defaults = isolatedDefaults()
        let store = TranslationStore(defaults: defaults)
        let plugin = TestTranslationAdapter(id: "plugin:user-input")
        store.replacePluginAdapters([plugin])
        store.setServiceEnabled(false, serviceID: "apple-local")
        store.setServiceEnabled(true, serviceID: plugin.descriptor.id)
        let model = TranslationPanelSessionModel(
            input: TranslationInput(source: .manual, text: ""),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            ),
            translationStore: store
        )

        model.updateSourceTextFromUser("first")
        try? await Task.sleep(for: .milliseconds(100))
        model.updateSourceTextFromUser("latest")
        try? await Task.sleep(for: .milliseconds(550))

        XCTAssertEqual(plugin.requestedTexts, ["latest"])
        XCTAssertEqual(model.snapshot?.input.text, "latest")
        model.cancel()
    }

    func testFavoriteMutationsPreserveTheActiveSearchQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranslationFavoriteQueryTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let repository = TranslationFavoriteRepository(database: database)
        let defaults = isolatedDefaults()
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let target = try XCTUnwrap(TranslationLanguageTag("zh-Hans"))
        let service = TranslationServiceDescriptor(
            id: "favorite-query-service",
            displayName: "Favorite Query Service",
            kind: .plugin
        )
        func session(_ id: String, source: String) -> TranslationSessionSnapshot {
            TranslationSessionSnapshot(
                id: id,
                input: TranslationInput(source: .manual, text: source),
                direction: TranslationLanguageDirection(target: target),
                results: [
                    TranslationResultSnapshot(
                        service: service,
                        state: .succeeded,
                        translatedText: "result \(source)"
                    ),
                ]
            )
        }
        let matching = try repository.save(
            session: session("favorite-query-needle", source: "needle")
        )
        _ = try repository.save(
            session: session("favorite-query-other", source: "other")
        )
        let store = TranslationStore(
            favoriteRepository: repository,
            defaults: defaults
        )

        store.refreshFavorites(query: "needle")
        await waitUntil {
            !store.isLoadingFavorites
                && store.favoriteSummaries.map(\.sourceText) == ["needle"]
        }

        _ = try await store.saveFavorite(
            session: session(
                "favorite-query-added",
                source: "another value"
            )
        )
        await waitUntil {
            !store.isLoadingFavorites
                && store.favoriteSummaries.map(\.sourceText) == ["needle"]
        }

        let deleted = await store.deleteFavorite(id: matching.id)
        XCTAssertTrue(deleted)
        await waitUntil {
            !store.isLoadingFavorites
                && store.favoriteSummaries.isEmpty
        }
        XCTAssertEqual(store.favoriteSummaries, [])
    }

    func testFavoriteExportsIncludeEveryPageAndCompleteResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranslationStoreExportTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let repository = TranslationFavoriteRepository(database: database)
        let defaults = isolatedDefaults()
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }

        let target = try XCTUnwrap(TranslationLanguageTag("zh-Hans"))
        let service = TranslationServiceDescriptor(
            id: "export-service",
            displayName: "Export Service",
            kind: .plugin
        )
        for index in 0 ... 500 {
            let sourceText = "source-\(index)"
            _ = try repository.save(
                session: TranslationSessionSnapshot(
                    id: "export-session-\(index)",
                    input: TranslationInput(
                        source: .manual,
                        text: sourceText
                    ),
                    direction: TranslationLanguageDirection(target: target),
                    results: [
                        TranslationResultSnapshot(
                            service: service,
                            state: .succeeded,
                            translatedText: "result-\(index)"
                        ),
                    ]
                ),
                at: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }
        let store = TranslationStore(
            favoriteRepository: repository,
            defaults: defaults
        )

        await waitUntil {
            !store.isLoadingFavorites
                && store.favoriteSummaries.count == 100
                && store.favoriteHasMore
        }
        for _ in 0 ..< 6 where store.favoriteHasMore {
            let previousCount = store.favoriteSummaries.count
            store.loadMoreFavorites()
            await waitUntil {
                !store.isLoadingMoreFavorites
                    && store.favoriteSummaries.count > previousCount
            }
        }
        XCTAssertEqual(store.favoriteSummaries.count, 501)
        XCTAssertEqual(store.favoriteSummaries.first?.sourceText, "source-500")
        XCTAssertEqual(store.favoriteSummaries.last?.sourceText, "source-0")

        let jsonData = try await store.exportFavoritesJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let jsonFavorites = try decoder.decode(
            [TranslationFavorite].self,
            from: jsonData
        )
        XCTAssertEqual(jsonFavorites.count, 501)
        XCTAssertEqual(jsonFavorites.first?.sourceText, "source-500")
        XCTAssertEqual(jsonFavorites.last?.sourceText, "source-0")
        XCTAssertEqual(
            jsonFavorites.first?.results.first?.translatedText,
            "result-500"
        )
        XCTAssertEqual(
            jsonFavorites.last?.results.first?.translatedText,
            "result-0"
        )

        let markdownData = try await store.exportFavoritesMarkdown()
        let markdown = try XCTUnwrap(
            String(data: markdownData, encoding: .utf8)
        )
        let favoriteHeadings = markdown.split(separator: "\n").filter {
            $0.hasPrefix("## ")
        }
        XCTAssertEqual(favoriteHeadings.count, 501)
        XCTAssertTrue(markdown.contains("## source-500"))
        XCTAssertTrue(markdown.contains("### Export Service"))
        XCTAssertTrue(markdown.contains("result-0"))
    }

    func testPluginExecutionErrorsUseLocalizedUserFacingMessages() {
        XCTAssertEqual(
            TranslationErrorPresentation.message(
                code: "plugin_disabled",
                fallback: "raw runner message"
            ),
            L10n.string("translation.error.pluginDisabled")
        )
        XCTAssertEqual(
            TranslationErrorPresentation.message(
                code: "progress_budget_exceeded",
                fallback: "raw runner message"
            ),
            L10n.string("translation.error.pluginStopped")
        )
    }

    func testPluginPermissionReviewFailsClosedForCorruptManifest() {
        XCTAssertNil(
            TranslationPluginPermissionManifestResolver.decode(
                #"{"schema_version":1,"id":"broken"}"#
            )
        )
        XCTAssertEqual(
            TranslationPluginPermissionReviewPresentation.systemImage(
                hasValidManifest: false
            ),
            "exclamationmark.shield.fill"
        )
        XCTAssertEqual(
            TranslationPluginPermissionReviewPresentation.systemImage(
                hasValidManifest: true
            ),
            "checkmark.shield"
        )
    }

    func testUnavailableServiceDetailDoesNotHideRecoveryReasonBehindLimit() {
        let enabledServiceIDs = ["one", "two", "three", "four"]
        for availability in [
            TranslationServiceAvailability.requiresConfiguration,
            .requiresDownload,
            .unsupported,
            .disabled,
        ] {
            let service = TranslationServiceDescriptor(
                id: "candidate-\(availability.rawValue)",
                displayName: "Candidate",
                kind: .plugin,
                availability: availability
            )
            let detail = TranslationServiceSettingsDetail.text(
                for: service,
                isEnabled: false,
                enabledServiceIDs: enabledServiceIDs
            )

            XCTAssertTrue(
                detail.contains(
                    L10n.string(
                        "translation.service.availability.\(availability.rawValue)"
                    )
                )
            )
            XCTAssertFalse(
                detail.contains(
                    L10n.string("translation.services.maximumReached")
                )
            )
        }

        let availableService = TranslationServiceDescriptor(
            id: "available-candidate",
            displayName: "Available Candidate",
            kind: .plugin,
            availability: .available
        )
        XCTAssertFalse(
            TranslationServiceSettingsDetail.text(
                for: availableService,
                isEnabled: false,
                enabledServiceIDs: enabledServiceIDs
            )
            .contains(L10n.string("translation.services.maximumReached"))
        )
    }

    func testTranslationServiceEnablementPolicyKeepsRejectedSwitchesOff() {
        XCTAssertEqual(
            TranslationServiceEnablementPolicy.resolve(
                requestedEnabled: false,
                enabledCount: 4,
                availability: .available,
                kind: .appleLocal,
                communityRiskAcknowledged: true
            ),
            .disable
        )
        XCTAssertEqual(
            TranslationServiceEnablementPolicy.resolve(
                requestedEnabled: true,
                enabledCount: 4,
                availability: .available,
                kind: .appleLocal,
                communityRiskAcknowledged: true
            ),
            .maximumReached
        )
        XCTAssertEqual(
            TranslationServiceEnablementPolicy.resolve(
                requestedEnabled: true,
                enabledCount: 1,
                availability: .requiresConfiguration,
                kind: .officialExternal,
                communityRiskAcknowledged: true
            ),
            .requiresConfiguration
        )
        XCTAssertEqual(
            TranslationServiceEnablementPolicy.resolve(
                requestedEnabled: true,
                enabledCount: 1,
                availability: .available,
                kind: .communityWeb,
                communityRiskAcknowledged: false
            ),
            .confirmCommunityRisk
        )
        XCTAssertEqual(
            TranslationServiceEnablementPolicy.resolve(
                requestedEnabled: true,
                enabledCount: 1,
                availability: .available,
                kind: .communityWeb,
                communityRiskAcknowledged: true
            ),
            .enable
        )
    }

    func testServiceSettingsSnapshotPartitionsSourcesWithoutDuplicates() {
        let services = [
            TranslationServiceDescriptor(
                id: "community:mymemory",
                displayName: "MyMemory",
                kind: .communityWeb,
                availability: .available
            ),
            TranslationServiceDescriptor(
                id: "apple-local",
                displayName: "Apple",
                kind: .appleLocal,
                availability: .available
            ),
            TranslationServiceDescriptor(
                id: "profile:deepl",
                displayName: "DeepL",
                kind: .officialExternal,
                availability: .available
            ),
            TranslationServiceDescriptor(
                id: "openai-compatible",
                displayName: "OpenAI",
                kind: .openAICompatible,
                availability: .requiresConfiguration
            ),
        ]
        let snapshot = TranslationServiceSettingsSnapshot(
            services: services,
            enabledServiceIDs: [
                "profile:deepl",
                "apple-local",
            ],
            profiles: [
                TranslationServiceProfile(
                    id: "deepl",
                    templateID: .deepLFree,
                    displayName: "DeepL"
                ),
            ]
        )

        XCTAssertEqual(
            snapshot.enabled.map(\.id),
            ["profile:deepl", "apple-local"]
        )
        XCTAssertEqual(
            snapshot.freeDisabled.map(\.id),
            ["community:mymemory"]
        )
        XCTAssertEqual(
            snapshot.configuredDisabled.map(\.id),
            ["openai-compatible"]
        )
        XCTAssertFalse(
            snapshot.unconfiguredTemplates.contains {
                $0.id == .deepLFree
            }
        )
        XCTAssertEqual(
            Set(
                (
                    snapshot.enabled
                        + snapshot.freeDisabled
                        + snapshot.configuredDisabled
                ).map(\.id)
            ),
            Set(services.map(\.id))
        )
    }

    func testFavoritesLayoutUsesSinglePaneWhenThereAreNoFavorites() {
        XCTAssertEqual(
            TranslationFavoritesLayoutMode.resolve(
                availableWidth: 900,
                hasFavorites: false
            ),
            .singlePane
        )
        XCTAssertEqual(
            TranslationFavoritesLayoutMode.resolve(
                availableWidth: 900,
                hasFavorites: true
            ),
            .columns
        )
        XCTAssertEqual(
            TranslationFavoritesLayoutMode.resolve(
                availableWidth: 600,
                hasFavorites: true
            ),
            .stacked
        )
    }

    func testFavoriteAccessibilitySummaryNormalizesAndTruncatesText() {
        XCTAssertEqual(
            TranslationFavoriteAccessibilitySummary.compact(
                "  first\nsecond\tthird  "
            ),
            "first second third"
        )

        let compacted = TranslationFavoriteAccessibilitySummary.compact(
            String(repeating: "a", count: 80)
        )
        XCTAssertEqual(compacted.count, 73)
        XCTAssertTrue(compacted.hasSuffix("…"))
    }

    func testFavoriteLoadMoreFeedbackOnlyAppearsForActiveFailedRequest() {
        var state = TranslationFavoriteLoadMoreFeedbackState()

        XCTAssertNil(
            state.visibleFailure(
                isLoading: false,
                errorMessage: "failure"
            )
        )

        state.begin(currentCount: 50)
        XCTAssertNil(
            state.visibleFailure(
                isLoading: true,
                errorMessage: "failure"
            )
        )
        XCTAssertEqual(
            state.visibleFailure(
                isLoading: false,
                errorMessage: "failure"
            ),
            "failure"
        )

        state.summariesDidChange(currentCount: 100)
        XCTAssertNil(
            state.visibleFailure(
                isLoading: false,
                errorMessage: "failure"
            )
        )
    }

    func testResultRecoveryPolicySeparatesConfigurationAndTransientFailures() {
        for errorCode in [
            "missing_configuration",
            "missing_secret",
            "plugin_disabled",
            "plugin_not_approved",
            "network_policy_denied",
        ] {
            XCTAssertTrue(
                TranslationResultRecoveryPolicy.shouldOpenSettings(
                    errorCode: errorCode
                ),
                errorCode
            )
            XCTAssertFalse(
                TranslationResultRecoveryPolicy.isRetryable(
                    errorCode: errorCode
                ),
                errorCode
            )
        }

        for errorCode in [
            "timeout",
            "network_error",
            "network_timed_out",
            "network_unavailable",
            "network_rate_limited",
            "remote_invalid_response",
            "rate_limited",
            "server_error",
            "runner_timeout",
            "plugin_execution_failed",
        ] {
            XCTAssertFalse(
                TranslationResultRecoveryPolicy.shouldOpenSettings(
                    errorCode: errorCode
                ),
                errorCode
            )
            XCTAssertTrue(
                TranslationResultRecoveryPolicy.isRetryable(
                    errorCode: errorCode
                ),
                errorCode
            )
        }

        XCTAssertFalse(
            TranslationResultRecoveryPolicy.shouldOpenSettings(
                errorCode: "translation_input_too_large"
            )
        )
        XCTAssertFalse(
            TranslationResultRecoveryPolicy.isRetryable(
                errorCode: "translation_input_too_large"
            )
        )
        XCTAssertFalse(
            TranslationResultRecoveryPolicy.isRetryable(
                errorCode: "network_http_client_error"
            )
        )

        XCTAssertEqual(
            TranslationResultRecoveryPolicy.resolve(
                errorCode: "apple_language_download_required"
            ),
            TranslationResultRecoveryOptions(
                shouldDownloadLanguage: true,
                shouldOpenSettings: false,
                canRetry: false
            )
        )
        XCTAssertEqual(
            TranslationResultRecoveryPolicy.resolve(
                errorCode: "apple_language_not_ready"
            ),
            TranslationResultRecoveryOptions(
                shouldDownloadLanguage: false,
                shouldOpenSettings: true,
                canRetry: true
            )
        )
        XCTAssertEqual(
            TranslationResultRecoveryPolicy.resolve(
                errorCode: "apple_translation_runtime_unavailable"
            ),
            TranslationResultRecoveryOptions(
                shouldDownloadLanguage: false,
                shouldOpenSettings: true,
                canRetry: true
            )
        )
    }

    func testOfficialProfileEditorSaveSessionInvalidationRejectsLateContinuation()
        async
    {
        let session = TranslationOfficialServiceProfileEditorSaveSession()
        let sessionID = session.begin()
        let continuationStarted = expectation(
            description: "official profile save reaches its suspended boundary"
        )
        var suspendedContinuation: CheckedContinuation<Void, Never>?
        var validationCount = 0
        var publishCount = 0
        let task = Task { @MainActor in
            continuationStarted.fulfill()
            await withCheckedContinuation { suspendedContinuation = $0 }
            guard session.isCurrent(sessionID) else { return }
            validationCount += 1
            guard session.finishSuccess(ifCurrent: sessionID) else { return }
            publishCount += 1
        }
        defer {
            suspendedContinuation?.resume()
            task.cancel()
        }

        await fulfillment(of: [continuationStarted], timeout: 1)
        session.invalidate()
        task.cancel()
        suspendedContinuation?.resume()
        suspendedContinuation = nil
        await task.value

        XCTAssertFalse(session.isCurrent(sessionID))
        XCTAssertFalse(session.finishSuccess(ifCurrent: sessionID))
        XCTAssertEqual(validationCount, 0)
        XCTAssertEqual(publishCount, 0)
    }

    func testColdRefreshDisabledOfficialProfileRegistersClosedDisplayAdapter()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-cold-disabled-fixture",
                templateID: .deepLFree,
                displayName: "Cold disabled official fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "translation.services.enabledIDs")
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let transport = TranslationOfficialSuspendedTransport()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(profile.id)::auth_key": "fixture-key"]
            ),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )

        let displayAdapter = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertNil(gate.admit(gate.token(for: profile.id)))
        await assertOfficialAdapterStreamIsCancelled(
            displayAdapter,
            transport: transport,
            expectedRequestCount: 0,
            sessionID: "cold-disabled-display"
        )
    }

    func testSuccessfulOfficialProfileSaveLeavesOldAndDisplayAdaptersClosedUntilExplicitEnable()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-save-closed-fixture",
                templateID: .deepLFree,
                displayName: "Original official save fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let updated = TranslationServiceProfile(
            id: original.id,
            templateID: original.templateID,
            displayName: "Updated official save fixture",
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let oldRequestStarted = expectation(
            description: "pre-save official request starts"
        )
        let oldRequestFinished = expectation(
            description: "late pre-save official request finishes"
        )
        let freshRequestStarted = expectation(
            description: "fresh enabled official request starts"
        )
        let freshRequestFinished = expectation(
            description: "fresh enabled official request finishes"
        )
        let oldStartSignal = TranslationTestExpectationSignal(
            oldRequestStarted
        )
        let oldFinishedSignal = TranslationTestExpectationSignal(
            oldRequestFinished
        )
        let freshStartSignal = TranslationTestExpectationSignal(
            freshRequestStarted
        )
        let freshFinishedSignal = TranslationTestExpectationSignal(
            freshRequestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                switch requestID {
                case 1:
                    oldStartSignal.fulfill()
                case 2:
                    freshStartSignal.fulfill()
                default:
                    break
                }
            },
            onRequestFinished: { requestID in
                switch requestID {
                case 1:
                    oldFinishedSignal.fulfill()
                case 2:
                    freshFinishedSignal.fulfill()
                default:
                    break
                }
            }
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [original.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(original.id)::auth_key": "old-key"]
            ),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )
        let oldAdapter = try await registeredAdapter(
            in: registry,
            serviceID: original.serviceID
        )
        let oldStreamTerminated = expectation(
            description: "save terminates old official stream"
        )
        var oldCompletedEventCount = 0
        var oldBusinessTerminalCount = 0
        var oldCancelled = false
        let oldConsumer = Task { @MainActor in
            defer { oldStreamTerminated.fulfill() }
            do {
                for try await event in oldAdapter.translate(
                    officialServiceRequest(sessionID: "save-old-in-flight")
                ) {
                    if case .completed = event {
                        oldCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                oldCancelled = true
            } catch {
                oldBusinessTerminalCount += 1
            }
        }
        defer { oldConsumer.cancel() }

        await fulfillment(of: [oldRequestStarted], timeout: 1)
        do {
            _ = try await store.saveServiceProfile(
                updated,
                credentials: ["auth_key": "new-key"]
            )
        } catch {
            await transport.succeed(
                requestID: 1,
                with: #"{"translations":[{"text":"old-late"}]}"#
            )
            await fulfillment(of: [oldRequestFinished], timeout: 1)
            throw error
        }

        await fulfillment(of: [oldStreamTerminated], timeout: 1)
        XCTAssertTrue(oldCancelled)
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)
        XCTAssertFalse(store.enabledServiceIDs.contains(original.serviceID))
        XCTAssertFalse(
            defaults.stringArray(forKey: "translation.services.enabledIDs")?
                .contains(original.serviceID) == true
        )
        XCTAssertNil(gate.admit(gate.token(for: original.id)))

        await assertOfficialAdapterStreamIsCancelled(
            oldAdapter,
            transport: transport,
            expectedRequestCount: 1,
            sessionID: "save-old-stale"
        )
        guard let displayAdapter = registry.adapter(
            serviceID: original.serviceID
        ) else {
            await transport.succeed(
                requestID: 1,
                with: #"{"translations":[{"text":"old-late"}]}"#
            )
            await fulfillment(of: [oldRequestFinished], timeout: 1)
            XCTFail("Expected the saved profile display adapter")
            return
        }
        await assertOfficialAdapterStreamIsCancelled(
            displayAdapter,
            transport: transport,
            expectedRequestCount: 1,
            sessionID: "save-display-closed"
        )

        store.setServiceEnabled(true, serviceID: original.serviceID)
        guard let freshAdapter = registry.adapter(serviceID: original.serviceID)
        else {
            await transport.succeed(
                requestID: 1,
                with: #"{"translations":[{"text":"old-late"}]}"#
            )
            await fulfillment(of: [oldRequestFinished], timeout: 1)
            XCTFail("Expected an explicitly enabled fresh adapter")
            return
        }
        XCTAssertTrue(store.enabledServiceIDs.contains(original.serviceID))
        let freshStreamTerminated = expectation(
            description: "fresh enabled stream terminates"
        )
        var freshCompletedEventCount = 0
        var freshBusinessTerminalCount = 0
        var freshCancelled = false
        let freshConsumer = Task { @MainActor in
            defer { freshStreamTerminated.fulfill() }
            do {
                for try await event in freshAdapter.translate(
                    officialServiceRequest(sessionID: "save-fresh-enabled")
                ) {
                    if case .completed = event {
                        freshCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                freshCancelled = true
            } catch {
                freshBusinessTerminalCount += 1
            }
        }
        defer { freshConsumer.cancel() }

        await fulfillment(of: [freshRequestStarted], timeout: 1)
        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"old-late"}]}"#
        )
        await transport.succeed(
            requestID: 2,
            with: #"{"translations":[{"text":"fresh-current"}]}"#
        )
        await fulfillment(
            of: [
                oldRequestFinished,
                freshRequestFinished,
                freshStreamTerminated,
            ],
            timeout: 1
        )
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)
        XCTAssertFalse(freshCancelled)
        XCTAssertEqual(freshCompletedEventCount, 1)
        XCTAssertEqual(freshBusinessTerminalCount, 0)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testDisabledOfficialConnectionTestUsesIsolatedGateAndLeavesDisplayClosed()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-disabled-connection-fixture",
                templateID: .deepLFree,
                displayName: "Disabled connection fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let requestStarted = expectation(
            description: "isolated connection request starts"
        )
        let requestFinished = expectation(
            description: "isolated connection request finishes"
        )
        let requestStartedSignal = TranslationTestExpectationSignal(
            requestStarted
        )
        let requestFinishedSignal = TranslationTestExpectationSignal(
            requestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                requestStartedSignal.fulfill()
            },
            onRequestFinished: { requestID in
                guard requestID == 1 else { return }
                requestFinishedSignal.fulfill()
            }
        )
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "translation.services.enabledIDs")
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(profile.id)::auth_key": "fixture-key"]
            ),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )
        let displayAdapter = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        let connectionFinished = expectation(
            description: "disabled connection test finishes"
        )
        var connectionText: String?
        var connectionError: Error?
        let connectionTask = Task { @MainActor in
            defer { connectionFinished.fulfill() }
            do {
                connectionText = try await store.connectionTest(profile: profile)
            } catch {
                connectionError = error
            }
        }
        defer { connectionTask.cancel() }

        await fulfillment(of: [requestStarted], timeout: 1)
        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"isolated"}]}"#
        )
        await fulfillment(
            of: [requestFinished, connectionFinished],
            timeout: 1
        )
        XCTAssertNil(connectionError)
        XCTAssertEqual(connectionText, "isolated")
        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertNil(gate.admit(gate.token(for: profile.id)))
        #if DEBUG
        XCTAssertEqual(gate.activeLeaseCount(profileID: profile.id), 0)
        #endif
        await assertOfficialAdapterStreamIsCancelled(
            displayAdapter,
            transport: transport,
            expectedRequestCount: 1,
            sessionID: "disabled-connection-display"
        )
    }

    func testEnabledOfficialConnectionTestPreservesGlobalAdmission()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-enabled-connection-fixture",
                templateID: .deepLFree,
                displayName: "Enabled connection fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let connectionRequestStarted = expectation(
            description: "enabled connection request starts"
        )
        let connectionRequestFinished = expectation(
            description: "enabled connection request finishes"
        )
        let registryRequestStarted = expectation(
            description: "enabled registry request starts"
        )
        let registryRequestFinished = expectation(
            description: "enabled registry request finishes"
        )
        let connectionStartedSignal = TranslationTestExpectationSignal(
            connectionRequestStarted
        )
        let connectionFinishedSignal = TranslationTestExpectationSignal(
            connectionRequestFinished
        )
        let registryStartedSignal = TranslationTestExpectationSignal(
            registryRequestStarted
        )
        let registryFinishedSignal = TranslationTestExpectationSignal(
            registryRequestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                switch requestID {
                case 1:
                    connectionStartedSignal.fulfill()
                case 2:
                    registryStartedSignal.fulfill()
                default:
                    break
                }
            },
            onRequestFinished: { requestID in
                switch requestID {
                case 1:
                    connectionFinishedSignal.fulfill()
                case 2:
                    registryFinishedSignal.fulfill()
                default:
                    break
                }
            }
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(profile.id)::auth_key": "fixture-key"]
            ),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )
        let registryAdapter = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        let tokenBeforeConnection = gate.token(for: profile.id)
        let connectionFinished = expectation(
            description: "enabled connection test finishes"
        )
        var connectionText: String?
        var connectionError: Error?
        let connectionTask = Task { @MainActor in
            defer { connectionFinished.fulfill() }
            do {
                connectionText = try await store.connectionTest(profile: profile)
            } catch {
                connectionError = error
            }
        }
        defer { connectionTask.cancel() }

        await fulfillment(of: [connectionRequestStarted], timeout: 1)
        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"validated"}]}"#
        )
        await fulfillment(
            of: [connectionRequestFinished, connectionFinished],
            timeout: 1
        )
        XCTAssertNil(connectionError)
        XCTAssertEqual(connectionText, "validated")
        XCTAssertTrue(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertEqual(gate.token(for: profile.id), tokenBeforeConnection)
        let admissionProbe = try XCTUnwrap(
            gate.admit(gate.token(for: profile.id))
        )
        gate.finish(admissionProbe)

        let registryStreamTerminated = expectation(
            description: "enabled registry adapter stream terminates"
        )
        var registryCompletedEventCount = 0
        var registryBusinessTerminalCount = 0
        var registryCancelled = false
        let registryConsumer = Task { @MainActor in
            defer { registryStreamTerminated.fulfill() }
            do {
                for try await event in registryAdapter.translate(
                    officialServiceRequest(sessionID: "enabled-connection-registry")
                ) {
                    if case .completed = event {
                        registryCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                registryCancelled = true
            } catch {
                registryBusinessTerminalCount += 1
            }
        }
        defer { registryConsumer.cancel() }

        await fulfillment(of: [registryRequestStarted], timeout: 1)
        await transport.succeed(
            requestID: 2,
            with: #"{"translations":[{"text":"registry"}]}"#
        )
        await fulfillment(
            of: [registryRequestFinished, registryStreamTerminated],
            timeout: 1
        )
        XCTAssertFalse(registryCancelled)
        XCTAssertEqual(registryCompletedEventCount, 1)
        XCTAssertEqual(registryBusinessTerminalCount, 0)
    }

    func testRefreshReplacingOfficialProfileRevokesOldRequestAndKeepsDisabledReplacementClosed()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-refresh-replacement-fixture",
                templateID: .deepLFree,
                displayName: "Original refresh fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let replacement = TranslationServiceProfile(
            id: original.id,
            templateID: original.templateID,
            displayName: "Replacement refresh fixture",
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let disabledReplacement = TranslationServiceProfile(
            id: original.id,
            templateID: original.templateID,
            displayName: "Disabled replacement refresh fixture",
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let oldRequestStarted = expectation(
            description: "replacement refresh old request starts"
        )
        let oldRequestFinished = expectation(
            description: "replacement refresh old request returns late"
        )
        let oldRequestStartedSignal = TranslationTestExpectationSignal(
            oldRequestStarted
        )
        let oldRequestFinishedSignal = TranslationTestExpectationSignal(
            oldRequestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                oldRequestStartedSignal.fulfill()
            },
            onRequestFinished: { requestID in
                guard requestID == 1 else { return }
                oldRequestFinishedSignal.fulfill()
            }
        )
        let refreshLoader = TranslationServiceProfileRefreshSequenceLoader(
            batches: [
                TranslationOfficialServiceProfileBatch(
                    profiles: [original],
                    preparations: [
                        TranslationOfficialServiceProfilePreparation(
                            profile: original,
                            credentialState: .configured
                        ),
                    ],
                    loadIssues: []
                ),
                TranslationOfficialServiceProfileBatch(
                    profiles: [replacement],
                    preparations: [
                        TranslationOfficialServiceProfilePreparation(
                            profile: replacement,
                            credentialState: .configured
                        ),
                    ],
                    loadIssues: []
                ),
                TranslationOfficialServiceProfileBatch(
                    profiles: [disabledReplacement],
                    preparations: [
                        TranslationOfficialServiceProfilePreparation(
                            profile: disabledReplacement,
                            credentialState: .configured
                        ),
                    ],
                    loadIssues: []
                ),
            ]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [original.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(original.id)::auth_key": "fixture-key"]
            ),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate,
            serviceProfileRefreshLoader: {
                try await refreshLoader.load()
            }
        )
        let oldAdapter = try await registeredAdapter(
            in: registry,
            serviceID: original.serviceID
        )
        let oldStreamTerminated = expectation(
            description: "replacement refresh terminates old stream"
        )
        var oldCompletedEventCount = 0
        var oldBusinessTerminalCount = 0
        var oldCancelled = false
        let oldConsumer = Task { @MainActor in
            defer { oldStreamTerminated.fulfill() }
            do {
                for try await event in oldAdapter.translate(
                    officialServiceRequest(
                        sessionID: "replacement-refresh-old"
                    )
                ) {
                    if case .completed = event {
                        oldCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                oldCancelled = true
            } catch {
                oldBusinessTerminalCount += 1
            }
        }
        defer { oldConsumer.cancel() }

        await fulfillment(of: [oldRequestStarted], timeout: 1)
        XCTAssertNoThrow(
            try fixture.repository.save(
                replacement,
                now: replacement.updatedAt
            )
        )
        let replacementRegistered = expectation(
            description: "replacement profile adapter is registered"
        )
        let replacementRegisteredSignal = TranslationTestExpectationSignal(
            replacementRegistered
        )
        let replacementObserver = registry.$descriptors.sink { descriptors in
            guard descriptors.contains(where: {
                $0.id == replacement.serviceID
                    && $0.displayName == replacement.displayName
            }) else {
                return
            }
            replacementRegisteredSignal.fulfill()
        }
        store.refreshServiceProfiles()
        await fulfillment(
            of: [oldStreamTerminated, replacementRegistered],
            timeout: 1
        )
        replacementObserver.cancel()
        XCTAssertTrue(oldCancelled)
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)

        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"old-late"}]}"#
        )
        await fulfillment(of: [oldRequestFinished], timeout: 1)
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)

        guard let replacementAdapter = registry.adapter(
            serviceID: replacement.serviceID
        ) else {
            XCTFail("Expected the replacement profile adapter")
            return
        }
        XCTAssertEqual(
            replacementAdapter.descriptor.displayName,
            replacement.displayName
        )
        store.setServiceEnabled(false, serviceID: replacement.serviceID)
        XCTAssertFalse(store.enabledServiceIDs.contains(replacement.serviceID))
        XCTAssertNoThrow(
            try fixture.repository.save(
                disabledReplacement,
                now: disabledReplacement.updatedAt
            )
        )
        let disabledReplacementRegistered = expectation(
            description: "disabled replacement profile adapter is registered"
        )
        let disabledReplacementRegisteredSignal =
            TranslationTestExpectationSignal(disabledReplacementRegistered)
        let disabledReplacementObserver = registry.$descriptors.sink {
            descriptors in
            guard descriptors.contains(where: {
                $0.id == disabledReplacement.serviceID
                    && $0.displayName == disabledReplacement.displayName
            }) else {
                return
            }
            disabledReplacementRegisteredSignal.fulfill()
        }
        store.refreshServiceProfiles()
        await fulfillment(
            of: [disabledReplacementRegistered],
            timeout: 1
        )
        disabledReplacementObserver.cancel()
        guard let disabledReplacementAdapter = registry.adapter(
            serviceID: disabledReplacement.serviceID
        ) else {
            XCTFail("Expected the disabled replacement profile adapter")
            return
        }
        XCTAssertEqual(
            disabledReplacementAdapter.descriptor.displayName,
            disabledReplacement.displayName
        )
        XCTAssertNil(gate.admit(gate.token(for: disabledReplacement.id)))
        await assertOfficialAdapterStreamIsCancelled(
            disabledReplacementAdapter,
            transport: transport,
            expectedRequestCount: 1,
            sessionID: "disabled-replacement-refresh-display"
        )
        let transportCallCount = await transport.requestCount()
        XCTAssertEqual(transportCallCount, 1)
    }

    func testRefreshRemovingOfficialProfileRevokesOldRequestBeforeLateResponse()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-refresh-removal-fixture",
                templateID: .deepLFree,
                displayName: "Removal refresh fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let oldRequestStarted = expectation(
            description: "removal refresh old request starts"
        )
        let oldRequestFinished = expectation(
            description: "removal refresh old request returns late"
        )
        let oldRequestStartedSignal = TranslationTestExpectationSignal(
            oldRequestStarted
        )
        let oldRequestFinishedSignal = TranslationTestExpectationSignal(
            oldRequestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                oldRequestStartedSignal.fulfill()
            },
            onRequestFinished: { requestID in
                guard requestID == 1 else { return }
                oldRequestFinishedSignal.fulfill()
            }
        )
        let refreshLoader = TranslationServiceProfileRefreshSequenceLoader(
            batches: [
                TranslationOfficialServiceProfileBatch(
                    profiles: [profile],
                    preparations: [
                        TranslationOfficialServiceProfilePreparation(
                            profile: profile,
                            credentialState: .configured
                        ),
                    ],
                    loadIssues: []
                ),
                TranslationOfficialServiceProfileBatch(
                    profiles: [],
                    preparations: [],
                    loadIssues: []
                ),
            ]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(profile.id)::auth_key": "fixture-key"]
            ),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate,
            serviceProfileRefreshLoader: {
                try await refreshLoader.load()
            }
        )
        let oldAdapter = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        let oldStreamTerminated = expectation(
            description: "removal refresh terminates old stream"
        )
        var oldCompletedEventCount = 0
        var oldBusinessTerminalCount = 0
        var oldCancelled = false
        let oldConsumer = Task { @MainActor in
            defer { oldStreamTerminated.fulfill() }
            do {
                for try await event in oldAdapter.translate(
                    officialServiceRequest(sessionID: "removal-refresh-old")
                ) {
                    if case .completed = event {
                        oldCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                oldCancelled = true
            } catch {
                oldBusinessTerminalCount += 1
            }
        }
        defer { oldConsumer.cancel() }

        await fulfillment(of: [oldRequestStarted], timeout: 1)
        XCTAssertNoThrow(try fixture.repository.delete(id: profile.id))
        let profileRemoved = expectation(
            description: "removed profile is published"
        )
        let profileRemovedSignal = TranslationTestExpectationSignal(
            profileRemoved
        )
        let profileObserver = store.$serviceProfiles.sink { profiles in
            guard !profiles.contains(where: { $0.id == profile.id }) else {
                return
            }
            profileRemovedSignal.fulfill()
        }
        store.refreshServiceProfiles()
        await fulfillment(
            of: [oldStreamTerminated, profileRemoved],
            timeout: 1
        )
        profileObserver.cancel()
        XCTAssertTrue(oldCancelled)
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)
        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertNil(registry.adapter(serviceID: profile.serviceID))
        XCTAssertNil(gate.admit(gate.token(for: profile.id)))

        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"old-late"}]}"#
        )
        await fulfillment(of: [oldRequestFinished], timeout: 1)
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)
        let transportCallCount = await transport.requestCount()
        XCTAssertEqual(transportCallCount, 1)
    }

    func testProfileMutationDisablesBeforeSaveAndCanRemoveOptionalCredential()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.repository.save(
            TranslationServiceProfile(
                id: "libre-fixture",
                templateID: .libreTranslate,
                displayName: "Libre",
                configuration: [
                    "base_url": .string("https://old.example.test"),
                ],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(original.id)::api_key": "old-key"]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [original.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [original.id: original.updatedAt.timeIntervalSince1970],
            forKey: "translation.services.validatedProfileRevisions"
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )

        let updated = TranslationServiceProfile(
            id: original.id,
            templateID: original.templateID,
            displayName: original.displayName,
            configuration: [
                "base_url": .string("https://new.example.test"),
            ],
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try await store.saveServiceProfile(
            updated,
            credentials: [:],
            credentialFieldIDsToDelete: ["api_key"]
        )

        XCTAssertFalse(store.enabledServiceIDs.contains(original.serviceID))
        XCTAssertFalse(
            store.validatedServiceProfileIDs.contains(original.id)
        )
        XCTAssertNil(
            try credentials.value(
                profileID: original.id,
                fieldID: "api_key"
            )
        )
    }

    func testStartupKeepsConfiguredProfileWithoutCurrentValidatedRevision()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-stale-fixture",
                templateID: .deepLFree,
                displayName: "DeepL",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            now: Date(timeIntervalSince1970: 200)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(profile.id)::auth_key": "fixture-key"]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [profile.id: 100.0],
            forKey: "translation.services.validatedProfileRevisions"
        )

        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )
        await waitUntil {
            !store.isLoadingServiceProfiles
                && store.serviceProfiles.contains {
                    $0.id == profile.id
                }
        }

        XCTAssertTrue(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertFalse(
            store.validatedServiceProfileIDs.contains(profile.id)
        )
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == profile.serviceID
            }?.availability,
            .available
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: "translation.services.enabledIDs"
            ),
            [profile.serviceID]
        )
    }

    func testProfileRefreshChecksCredentialsOffMainAndIsolatesFailure()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let healthyProfile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-healthy-fixture",
                templateID: .deepLFree,
                displayName: "Healthy DeepL",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let inaccessibleProfile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-inaccessible-fixture",
                templateID: .deepLFree,
                displayName: "Inaccessible DeepL",
                createdAt: Date(timeIntervalSince1970: 200),
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            now: Date(timeIntervalSince1970: 200)
        )
        let inaccessibleCredentialKey =
            "\(inaccessibleProfile.id)::auth_key"
        let credentials = TranslationOfficialCredentialFixture(
            values: [
                "\(healthyProfile.id)::auth_key": "healthy-key",
                inaccessibleCredentialKey: "inaccessible-key",
            ],
            failingKeys: [inaccessibleCredentialKey]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [healthyProfile.serviceID, inaccessibleProfile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [
                healthyProfile.id:
                    healthyProfile.updatedAt.timeIntervalSince1970,
                inaccessibleProfile.id:
                    inaccessibleProfile.updatedAt.timeIntervalSince1970,
            ],
            forKey: "translation.services.validatedProfileRevisions"
        )

        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )
        await waitUntil {
            !store.isLoadingServiceProfiles
                && store.serviceProfiles.count == 2
                && store.availableServices.contains {
                    $0.id == inaccessibleProfile.serviceID
                }
        }

        XCTAssertFalse(credentials.didReadOnMainThread)
        XCTAssertTrue(
            store.enabledServiceIDs.contains(healthyProfile.serviceID)
        )
        XCTAssertFalse(
            store.enabledServiceIDs.contains(inaccessibleProfile.serviceID)
        )
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == healthyProfile.serviceID
            }?.availability,
            .available
        )
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == inaccessibleProfile.serviceID
            }?.availability,
            .requiresConfiguration
        )
        XCTAssertTrue(
            store.serviceProfileErrorMessage?.contains(
                inaccessibleProfile.displayName
            ) == true
        )
    }

    func testProfileRefreshKeepsHealthyServicesWhenOneStoredRowIsInvalid()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let healthyProfile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-valid-alongside-corrupt",
                templateID: .deepLFree,
                displayName: "Healthy DeepL",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        try fixture.database.connection.execute(
            """
            INSERT INTO translation_service_profiles (
                id,
                template_id,
                display_name,
                schema_version,
                non_sensitive_configuration_json,
                created_at,
                updated_at
            ) VALUES (
                'corrupt-profile-fixture',
                'deepl-free',
                'Corrupt',
                99,
                '{}',
                200,
                200
            )
            """
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: [
                "\(healthyProfile.id)::auth_key": "healthy-key",
            ]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [healthyProfile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [
                healthyProfile.id:
                    healthyProfile.updatedAt.timeIntervalSince1970,
            ],
            forKey: "translation.services.validatedProfileRevisions"
        )

        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )
        await waitUntil {
            !store.isLoadingServiceProfiles
                && store.serviceProfiles.contains {
                    $0.id == healthyProfile.id
                }
        }

        XCTAssertEqual(store.serviceProfiles.map(\.id), [healthyProfile.id])
        XCTAssertTrue(
            store.enabledServiceIDs.contains(healthyProfile.serviceID)
        )
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == healthyProfile.serviceID
            }?.availability,
            .available
        )
        XCTAssertTrue(
            store.serviceProfileErrorMessage?.contains(
                "corrupt-profile-fixture"
            ) == true
        )
    }

    func testSecondCredentialWriteFailureRestoresProfileAndCredentials()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.repository.save(
            TranslationServiceProfile(
                id: "alibaba-rollback-fixture",
                templateID: .alibabaMachineTranslation,
                displayName: "Original",
                configuration: ["region": .string("cn-hangzhou")],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: [
                "\(original.id)::access_key_id": "old-id",
                "\(original.id)::access_key_secret": "old-secret",
            ],
            failingSaveAttempts: [2]
        )
        let defaults = isolatedDefaults()
        acknowledgeCommunitySources([.myMemory], defaults: defaults)
        let originalEnabledOrder = [
            "community:mymemory",
            original.serviceID,
            "apple-local",
        ]
        defaults.set(
            originalEnabledOrder,
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [original.id: original.updatedAt.timeIntervalSince1970],
            forKey: "translation.services.validatedProfileRevisions"
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )
        await waitUntil {
            !store.isLoadingServiceProfiles
                && store.validatedServiceProfileIDs.contains(original.id)
        }
        XCTAssertEqual(store.enabledServiceIDs, originalEnabledOrder)
        let updated = TranslationServiceProfile(
            id: original.id,
            templateID: original.templateID,
            displayName: "Updated",
            configuration: ["region": .string("ap-southeast-1")],
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        do {
            _ = try await store.saveServiceProfile(
                updated,
                credentials: [
                    "access_key_id": "new-id",
                    "access_key_secret": "new-secret",
                ]
            )
            XCTFail("Expected credential write failure")
        } catch TranslationServiceCredentialFailpointError.save {
            // Expected.
        }

        let restored = try fixture.repository.profile(id: original.id)
        XCTAssertEqual(restored.displayName, "Original")
        XCTAssertEqual(
            credentials.snapshot(),
            [
                "\(original.id)::access_key_id": "old-id",
                "\(original.id)::access_key_secret": "old-secret",
            ]
        )
        XCTAssertEqual(store.enabledServiceIDs, originalEnabledOrder)
        XCTAssertTrue(
            store.validatedServiceProfileIDs.contains(original.id)
        )
        let restoredRevisions = defaults.dictionary(
            forKey: "translation.services.validatedProfileRevisions"
        ) as? [String: Double]
        XCTAssertEqual(
            restoredRevisions?[original.id],
            original.updatedAt.timeIntervalSince1970
        )
    }

    func testCancellingProfileSaveWhileCredentialWriteIsSuspendedRollsBackMutation()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-cancelled-save-fixture",
                templateID: .deepLFree,
                displayName: "Original",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialSuspendedStore(
            values: ["\(original.id)::auth_key": "old-key"]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [original.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [original.id: original.updatedAt.timeIntervalSince1970],
            forKey: "translation.services.validatedProfileRevisions"
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )
        await waitUntil {
            !store.isLoadingServiceProfiles
                && store.validatedServiceProfileIDs.contains(original.id)
        }
        let updated = TranslationServiceProfile(
            id: original.id,
            templateID: original.templateID,
            displayName: "Updated",
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let task = Task { @MainActor in
            try await store.saveServiceProfile(
                updated,
                credentials: ["auth_key": "new-key"]
            )
        }
        defer {
            credentials.resumeSave()
            task.cancel()
        }
        let saveStarted = await credentials.waitUntilSaveStarted()
        XCTAssertTrue(saveStarted)
        task.cancel()
        credentials.resumeSave()

        do {
            _ = try await task.value
            XCTFail("A cancelled pre-commit profile save must not succeed")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(
            try fixture.repository.profile(id: original.id),
            original
        )
        XCTAssertEqual(
            credentials.snapshot(),
            ["\(original.id)::auth_key": "old-key"]
        )
        XCTAssertTrue(store.enabledServiceIDs.contains(original.serviceID))
        XCTAssertTrue(store.validatedServiceProfileIDs.contains(original.id))
    }

    func testFailedMutationRestoresRunnableAdapterWhenRefreshReloadFails()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-refresh-failure-rollback-fixture",
                templateID: .deepLFree,
                displayName: "DeepL refresh failure rollback fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(profile.id)::auth_key": "old-key"],
            failingSaveAttempts: [1]
        )
        let refreshReloadAttempted = expectation(
            description: "rollback refresh reload attempts and fails"
        )
        let refreshReloadSignal = TranslationTestExpectationSignal(
            refreshReloadAttempted
        )
        let refreshLoader = TranslationServiceProfileRefreshFailpoint(
            initialBatch: TranslationOfficialServiceProfileBatch(
                profiles: [profile],
                preparations: [
                    TranslationOfficialServiceProfilePreparation(
                        profile: profile,
                        credentialState: .configured
                    ),
                ],
                loadIssues: []
            ),
            onReloadAttempt: {
                refreshReloadSignal.fulfill()
            }
        )
        let requestStarted = expectation(
            description: "restored adapter starts official request"
        )
        let requestFinished = expectation(
            description: "restored adapter request finishes"
        )
        let requestStartedSignal = TranslationTestExpectationSignal(
            requestStarted
        )
        let requestFinishedSignal = TranslationTestExpectationSignal(
            requestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                requestStartedSignal.fulfill()
            },
            onRequestFinished: { requestID in
                guard requestID == 1 else { return }
                requestFinishedSignal.fulfill()
            }
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let registry = TranslationServiceRegistry()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            serviceProfileRefreshLoader: {
                try await refreshLoader.load()
            }
        )
        _ = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )

        do {
            _ = try await store.saveServiceProfile(
                profile,
                credentials: ["auth_key": "new-key"]
            )
            XCTFail("Expected credential write failure")
        } catch TranslationServiceCredentialFailpointError.save {
            // Expected.
        }

        // No refresh completion is awaited before using the synchronously
        // rebuilt adapter; the injected reload is guaranteed to fail.
        guard let restoredAdapter = registry.adapter(
            serviceID: profile.serviceID
        ) else {
            XCTFail("Expected rollback to synchronously rebuild the adapter")
            return
        }
        let streamTerminated = expectation(
            description: "restored adapter stream terminates"
        )
        var completedEventCount = 0
        var businessTerminalCount = 0
        let consumer = Task { @MainActor in
            defer { streamTerminated.fulfill() }
            do {
                for try await event in restoredAdapter.translate(
                    officialServiceRequest(sessionID: "refresh-failure-rollback")
                ) {
                    if case .completed = event {
                        completedEventCount += 1
                    }
                }
            } catch {
                businessTerminalCount += 1
            }
        }
        defer { consumer.cancel() }

        await fulfillment(of: [requestStarted], timeout: 1)
        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"restored"}]}"#
        )
        await fulfillment(
            of: [
                requestFinished,
                streamTerminated,
                refreshReloadAttempted,
            ],
            timeout: 1
        )
        XCTAssertTrue(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertEqual(completedEventCount, 1)
        XCTAssertEqual(businessTerminalCount, 0)
    }

    #if DEBUG
    func testFailedMutationWithUnavailableCredentialsKeepsProfileDisabled()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-unavailable-rollback-fixture",
                templateID: .deepLFree,
                displayName: "DeepL unavailable rollback fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(profile.id)::auth_key": "old-key"]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate(
            testInitialGenerations: [:]
        )
        let transport = TranslationOfficialSuspendedTransport()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )
        _ = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        credentials.failReads()

        do {
            _ = try await store.saveServiceProfile(
                profile,
                credentials: ["auth_key": "new-key"]
            )
            XCTFail("Expected credential read failure")
        } catch TranslationServiceCredentialFailpointError.read {
            // Expected.
        }

        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertNil(gate.admit(gate.token(for: profile.id)))
        XCTAssertEqual(
            registry.adapter(serviceID: profile.serviceID)?
                .descriptor.availability,
            .requiresConfiguration
        )
        XCTAssertNotNil(store.serviceProfileErrorMessage)
        let unavailableAdapter = try XCTUnwrap(
            registry.adapter(serviceID: profile.serviceID)
        )
        let unavailableStreamTerminated = expectation(
            description: "unavailable credential registry stream terminates"
        )
        var unavailableErrorCode: String?
        var unexpectedTerminal = false
        let unavailableConsumer = Task { @MainActor in
            defer { unavailableStreamTerminated.fulfill() }
            do {
                for try await _ in unavailableAdapter.translate(
                    officialServiceRequest(
                        sessionID: "unavailable-rollback-registry"
                    )
                ) {}
                unexpectedTerminal = true
            } catch let error as TranslationServiceAdapterError {
                unavailableErrorCode = error.errorCode
            } catch {
                unexpectedTerminal = true
            }
        }
        defer { unavailableConsumer.cancel() }
        await fulfillment(of: [unavailableStreamTerminated], timeout: 1)
        XCTAssertEqual(
            unavailableErrorCode,
            "official_credential_unavailable"
        )
        XCTAssertFalse(unexpectedTerminal)
        let transportCallCount = await transport.requestCount()
        XCTAssertEqual(transportCallCount, 0)
    }
    #endif

    func testProfileRollbackPreservesConcurrentServiceOrderChanges()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-concurrent-rollback-fixture",
                templateID: .deepLFree,
                displayName: "DeepL",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialSuspendedFailureStore(
            values: ["\(original.id)::auth_key": "old-key"]
        )
        let defaults = isolatedDefaults()
        acknowledgeCommunitySources([.myMemory], defaults: defaults)
        defaults.set(
            [
                original.serviceID,
                "community:mymemory",
                "apple-local",
            ],
            forKey: "translation.services.enabledIDs"
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )
        await waitUntil {
            !store.isLoadingServiceProfiles
                && store.serviceProfiles.contains { $0.id == original.id }
        }

        let saveTask = Task {
            try await store.saveServiceProfile(
                original,
                credentials: ["auth_key": "new-key"]
            )
        }
        let saveDidStart = await credentials.waitUntilSaveStarted()
        XCTAssertTrue(saveDidStart)

        store.moveEnabledService(
            serviceID: "apple-local",
            before: "community:mymemory"
        )
        XCTAssertEqual(
            store.enabledServiceIDs,
            ["apple-local", "community:mymemory"]
        )
        credentials.resumeWithFailure()

        do {
            _ = try await saveTask.value
            XCTFail("Expected suspended credential save to fail")
        } catch TranslationServiceCredentialFailpointError.save {
            // Expected.
        }

        XCTAssertEqual(
            store.enabledServiceIDs,
            [
                "apple-local",
                original.serviceID,
                "community:mymemory",
            ]
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: "translation.services.enabledIDs"
            ),
            store.enabledServiceIDs
        )
    }

    func testRollbackFailureKeepsProfileDisabled() async throws {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "rollback-failed-fixture",
                templateID: .alibabaMachineTranslation,
                displayName: "Alibaba",
                configuration: ["region": .string("cn-hangzhou")],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: [
                "\(profile.id)::access_key_id": "old-id",
                "\(profile.id)::access_key_secret": "old-secret",
            ],
            failingSaveAttempts: [2, 3]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [profile.id: profile.updatedAt.timeIntervalSince1970],
            forKey: "translation.services.validatedProfileRevisions"
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )

        do {
            _ = try await store.saveServiceProfile(
                profile,
                credentials: [
                    "access_key_id": "new-id",
                    "access_key_secret": "new-secret",
                ]
            )
            XCTFail("Expected rollback failure")
        } catch TranslationServiceProfileMutationError.rollbackFailed {
            // Expected.
        }

        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertFalse(
            store.validatedServiceProfileIDs.contains(profile.id)
        )
    }

    func testLateConnectionTestCannotValidateNewProfileRevision()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profileA = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-race-fixture",
                templateID: .deepLFree,
                displayName: "DeepL A",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(profileA.id)::auth_key": "fixture-key"]
        )
        let requestStarted = expectation(
            description: "official connection request starts"
        )
        let requestStartedSignal = TranslationTestExpectationSignal(
            requestStarted
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                requestStartedSignal.fulfill()
            }
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            officialTransport: transport,
            defaults: isolatedDefaults()
        )
        let validationTask = Task {
            try await store.connectionTest(profile: profileA)
        }
        await fulfillment(of: [requestStarted], timeout: 1)

        let profileB = TranslationServiceProfile(
            id: profileA.id,
            templateID: profileA.templateID,
            displayName: "DeepL B",
            createdAt: profileA.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try await store.saveServiceProfile(
            profileB,
            credentials: ["auth_key": "new-key"]
        )

        do {
            _ = try await validationTask.value
            XCTFail("Expected stale validation rejection")
        } catch is CancellationError {
            // The save revoked the validation lease and cancelled transport.
        } catch TranslationServiceProfileMutationError
            .configurationChangedDuringValidation {
            // Expected.
        }
        XCTAssertFalse(
            store.validatedServiceProfileIDs.contains(profileA.id)
        )
        XCTAssertFalse(store.enabledServiceIDs.contains(profileA.serviceID))
    }

    func testProfileMutationRevokesOnlyMatchingConnectionValidationLeases()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profileA = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-validation-revoke-a",
                templateID: .deepLFree,
                displayName: "Validation A",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let profileB = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-validation-revoke-b",
                templateID: .deepLFree,
                displayName: "Validation B",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let firstStarted = expectation(description: "first A validation started")
        let replacementStarted = expectation(description: "replacement A validation started")
        let otherProfileStarted = expectation(description: "B validation started")
        let firstCancelled = expectation(description: "first A validation cancelled")
        let replacementCancelled = expectation(description: "replacement A validation cancelled")
        let firstStartedSignal = TranslationTestExpectationSignal(firstStarted)
        let replacementStartedSignal = TranslationTestExpectationSignal(replacementStarted)
        let otherProfileStartedSignal = TranslationTestExpectationSignal(otherProfileStarted)
        let firstCancelledSignal = TranslationTestExpectationSignal(firstCancelled)
        let replacementCancelledSignal = TranslationTestExpectationSignal(replacementCancelled)
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                switch requestID {
                case 1:
                    firstStartedSignal.fulfill()
                case 2:
                    replacementStartedSignal.fulfill()
                case 3:
                    otherProfileStartedSignal.fulfill()
                default:
                    break
                }
            },
            onRequestCancelled: { requestID in
                switch requestID {
                case 1:
                    firstCancelledSignal.fulfill()
                case 2:
                    replacementCancelledSignal.fulfill()
                default:
                    break
                }
            }
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: [
                    "\(profileA.id)::auth_key": "fixture-a",
                    "\(profileB.id)::auth_key": "fixture-b",
                ]
            ),
            officialTransport: transport,
            defaults: isolatedDefaults()
        )

        let firstValidation = Task {
            try await store.connectionTest(profile: profileA)
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let replacement = TranslationServiceProfile(
            id: profileA.id,
            templateID: profileA.templateID,
            displayName: "Validation A replacement",
            createdAt: profileA.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try await store.saveServiceProfile(
            replacement,
            credentials: ["auth_key": "replacement-a"]
        )
        await fulfillment(of: [firstCancelled], timeout: 1)
        do {
            _ = try await firstValidation.value
            XCTFail("Replacing A must revoke its validation")
        } catch is CancellationError {
            // Expected.
        }

        let replacementValidation = Task {
            try await store.connectionTest(profile: replacement)
        }
        await fulfillment(of: [replacementStarted], timeout: 1)
        let otherProfileValidation = Task {
            try await store.connectionTest(profile: profileB)
        }
        await fulfillment(of: [otherProfileStarted], timeout: 1)

        try await store.deleteServiceProfile(id: replacement.id)
        await fulfillment(of: [replacementCancelled], timeout: 1)
        do {
            _ = try await replacementValidation.value
            XCTFail("Removing A must revoke its validation")
        } catch is CancellationError {
            // Expected.
        }

        await transport.succeed(
            requestID: 3,
            with: #"{"translations":[{"text":"B survives"}]}"#
        )
        let otherProfileText = try await otherProfileValidation.value
        XCTAssertEqual(otherProfileText, "B survives")
        XCTAssertFalse(store.validatedServiceProfileIDs.contains(profileA.id))
        XCTAssertTrue(store.validatedServiceProfileIDs.contains(profileB.id))
        let cancellationCount = await transport.cancelledRequestCount()
        XCTAssertEqual(cancellationCount, 2)
    }

    func testRefreshReplacementAndRemovalRevokeMatchingConnectionValidationLeases()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profileA = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-validation-refresh-a",
                templateID: .deepLFree,
                displayName: "Validation refresh A",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let profileB = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-validation-refresh-b",
                templateID: .deepLFree,
                displayName: "Validation refresh B",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let replacementA = TranslationServiceProfile(
            id: profileA.id,
            templateID: profileA.templateID,
            displayName: "Validation refresh A replacement",
            createdAt: profileA.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let firstAStarted = expectation(description: "initial A validation started")
        let profileBStarted = expectation(description: "B validation started")
        let replacementAStarted = expectation(description: "replacement A validation started")
        let firstACancelled = expectation(description: "initial A validation cancelled by refresh")
        let replacementACancelled = expectation(description: "replacement A validation cancelled by removal refresh")
        let firstAStartedSignal = TranslationTestExpectationSignal(firstAStarted)
        let profileBStartedSignal = TranslationTestExpectationSignal(profileBStarted)
        let replacementAStartedSignal = TranslationTestExpectationSignal(replacementAStarted)
        let firstACancelledSignal = TranslationTestExpectationSignal(firstACancelled)
        let replacementACancelledSignal = TranslationTestExpectationSignal(replacementACancelled)
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                switch requestID {
                case 1: firstAStartedSignal.fulfill()
                case 2: profileBStartedSignal.fulfill()
                case 3: replacementAStartedSignal.fulfill()
                default: break
                }
            },
            onRequestCancelled: { requestID in
                switch requestID {
                case 1: firstACancelledSignal.fulfill()
                case 3: replacementACancelledSignal.fulfill()
                default: break
                }
            }
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: TranslationServiceCredentialFailpointStore(
                values: [
                    "\(profileA.id)::auth_key": "fixture-a",
                    "\(profileB.id)::auth_key": "fixture-b",
                ]
            ),
            officialTransport: transport,
            defaults: isolatedDefaults()
        )
        await waitUntil {
            !store.isLoadingServiceProfiles && store.serviceProfiles.count == 2
        }

        let firstAValidation = Task {
            try await store.connectionTest(profile: profileA)
        }
        defer { firstAValidation.cancel() }
        await fulfillment(of: [firstAStarted], timeout: 1)
        let requestCountAfterFirstA = await transport.requestCount()
        guard requestCountAfterFirstA >= 1 else {
            return XCTFail("Initial A validation did not start.")
        }
        let profileBValidation = Task {
            try await store.connectionTest(profile: profileB)
        }
        defer { profileBValidation.cancel() }
        await fulfillment(of: [profileBStarted], timeout: 1)
        let requestCountAfterB = await transport.requestCount()
        guard requestCountAfterB >= 2 else {
            return XCTFail("B validation did not start.")
        }

        _ = try fixture.repository.save(
            replacementA,
            now: replacementA.updatedAt
        )
        store.refreshServiceProfiles()
        await fulfillment(of: [firstACancelled], timeout: 1)
        let cancellationCountAfterReplacement =
            await transport.cancelledRequestCount()
        guard cancellationCountAfterReplacement >= 1 else {
            return XCTFail("Replacement refresh did not revoke A validation.")
        }
        await waitUntil {
            !store.isLoadingServiceProfiles
                && store.serviceProfiles.contains(replacementA)
        }
        do {
            _ = try await firstAValidation.value
            XCTFail("Replacement refresh must reject stale A validation.")
        } catch is CancellationError {
            // Expected.
        } catch TranslationServiceProfileMutationError
            .configurationChangedDuringValidation {
            // Expected.
        }

        await transport.succeed(
            requestID: 2,
            with: #"{"translations":[{"text":"B survives refresh"}]}"#
        )
        let profileBText = try await profileBValidation.value
        XCTAssertEqual(profileBText, "B survives refresh")

        let replacementAValidation = Task {
            try await store.connectionTest(profile: replacementA)
        }
        defer { replacementAValidation.cancel() }
        await fulfillment(of: [replacementAStarted], timeout: 1)
        let requestCountAfterReplacementA = await transport.requestCount()
        guard requestCountAfterReplacementA >= 3 else {
            return XCTFail("Replacement A validation did not start.")
        }
        try fixture.repository.delete(id: replacementA.id)
        store.refreshServiceProfiles()
        await fulfillment(of: [replacementACancelled], timeout: 1)
        let cancellationCountAfterRemoval =
            await transport.cancelledRequestCount()
        guard cancellationCountAfterRemoval >= 2 else {
            return XCTFail("Removal refresh did not revoke replacement A validation.")
        }
        await waitUntil {
            !store.isLoadingServiceProfiles
                && !store.serviceProfiles.contains { $0.id == replacementA.id }
        }
        do {
            _ = try await replacementAValidation.value
            XCTFail("Removal refresh must reject stale A validation.")
        } catch is CancellationError {
            // Expected.
        } catch TranslationServiceProfileMutationError
            .configurationChangedDuringValidation {
            // Expected.
        }

        let cancellationCount = await transport.cancelledRequestCount()
        XCTAssertEqual(cancellationCount, 2)
        XCTAssertFalse(store.validatedServiceProfileIDs.contains(profileA.id))
        XCTAssertTrue(store.validatedServiceProfileIDs.contains(profileB.id))
    }

    func testDeletingProfileTerminatesSuspendedOfficialStreamBeforeTransportReturns()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-delete-stream-fixture",
                templateID: .deepLFree,
                displayName: "Official delete stream fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(profile.id)::auth_key": "fixture-key"]
        )
        let registry = TranslationServiceRegistry()
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let transportStarted = expectation(
            description: "suspended official transport started"
        )
        let transportFinished = expectation(
            description: "suspended official transport finished"
        )
        let transportStartSignal = TranslationTestExpectationSignal(
            transportStarted
        )
        let transportFinishedSignal = TranslationTestExpectationSignal(
            transportFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                transportStartSignal.fulfill()
            },
            onRequestFinished: { requestID in
                guard requestID == 1 else { return }
                transportFinishedSignal.fulfill()
            }
        )
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry
        )
        let adapter = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        let streamTerminated = expectation(
            description: "deleted profile terminates suspended stream"
        )
        var completedEventCount = 0
        var businessTerminalCount = 0
        var cancelled = false
        var finishedCleanly = false
        let consumer = Task { @MainActor in
            defer { streamTerminated.fulfill() }
            do {
                for try await event in adapter.translate(
                    officialServiceRequest(sessionID: "delete-stream")
                ) {
                    if case .completed = event {
                        completedEventCount += 1
                    }
                }
                finishedCleanly = true
            } catch is CancellationError {
                cancelled = true
            } catch {
                businessTerminalCount += 1
            }
        }
        defer { consumer.cancel() }

        await fulfillment(of: [transportStarted], timeout: 1)
        do {
            try await store.deleteServiceProfile(id: profile.id)
        } catch {
            await transport.succeed(
                requestID: 1,
                with: #"{"translations":[{"text":"fixture"}]}"#
            )
            throw error
        }

        await fulfillment(of: [streamTerminated], timeout: 1)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(finishedCleanly)
        XCTAssertEqual(completedEventCount, 0)
        XCTAssertEqual(businessTerminalCount, 0)
        XCTAssertThrowsError(try fixture.repository.profile(id: profile.id))
        XCTAssertNil(
            try credentials.value(profileID: profile.id, fieldID: "auth_key")
        )

        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"fixture"}]}"#
        )
        await fulfillment(of: [transportFinished], timeout: 1)
    }

    func testStaleOfficialExecutionTokenCannotAdmitAfterProfileReactivation()
        async
    {
        let profile = TranslationServiceProfile(
            id: "official-stale-token-fixture",
            templateID: .deepLFree,
            displayName: "Official stale token fixture",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let gate = TranslationOfficialServiceExecutionGate()
        let staleToken = gate.token(for: profile.id)
        gate.invalidate(profileID: profile.id)
        gate.activate(profileID: profile.id)
        let transport = TranslationOfficialSuspendedTransport()
        let adapter = TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: .configured,
            credentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(profile.id)::auth_key": "fixture-key"]
            ),
            transport: transport,
            executionGate: gate,
            executionToken: staleToken
        )
        let streamTerminated = expectation(
            description: "stale token stream is cancelled without admission"
        )
        var completedEventCount = 0
        var businessTerminalCount = 0
        var cancelled = false
        let consumer = Task { @MainActor in
            defer { streamTerminated.fulfill() }
            do {
                for try await event in adapter.translate(
                    officialServiceRequest(sessionID: "stale-token")
                ) {
                    if case .completed = event {
                        completedEventCount += 1
                    }
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                businessTerminalCount += 1
            }
        }
        defer { consumer.cancel() }

        await fulfillment(of: [streamTerminated], timeout: 1)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(completedEventCount, 0)
        XCTAssertEqual(businessTerminalCount, 0)
        let transportCallCount = await transport.requestCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    #if DEBUG
    func testCancellingOfficialStreamReleasesLeaseBeforeSuspendedTransportReturns()
        async
    {
        let profile = TranslationServiceProfile(
            id: "official-cancel-stream-fixture",
            templateID: .deepLFree,
            displayName: "Official cancel stream fixture",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let requestStarted = expectation(
            description: "official request started before cancellation"
        )
        let requestFinished = expectation(
            description: "cancelled official request returns after release"
        )
        let leaseReleased = expectation(
            description: "cancelled stream lease removed from gate"
        )
        let publicationFinished = expectation(
            description: "cancelled stream publication finished after release"
        )
        let requestStartedSignal = TranslationTestExpectationSignal(
            requestStarted
        )
        let requestFinishedSignal = TranslationTestExpectationSignal(
            requestFinished
        )
        let leaseReleasedSignal = TranslationTestExpectationSignal(
            leaseReleased
        )
        let publicationFinishedSignal = TranslationTestExpectationSignal(
            publicationFinished
        )
        let gate = TranslationOfficialServiceExecutionGate(
            testInitialGenerations: [:],
            onLeaseReleased: { profileID in
                guard profileID == profile.id else { return }
                leaseReleasedSignal.fulfill()
            },
            onPublicationFinished: { profileID in
                guard profileID == profile.id else { return }
                publicationFinishedSignal.fulfill()
            }
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                requestStartedSignal.fulfill()
            },
            onRequestFinished: { requestID in
                guard requestID == 1 else { return }
                requestFinishedSignal.fulfill()
            }
        )
        let adapter = TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: .configured,
            credentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(profile.id)::auth_key": "fixture-key"]
            ),
            transport: transport,
            executionGate: gate,
            executionToken: gate.token(for: profile.id)
        )
        let streamTerminated = expectation(
            description: "consumer cancellation terminates official stream"
        )
        var completedEventCount = 0
        var businessTerminalCount = 0
        let consumer = Task { @MainActor in
            defer { streamTerminated.fulfill() }
            do {
                for try await event in adapter.translate(
                    officialServiceRequest(sessionID: "consumer-cancel")
                ) {
                    if case .completed = event {
                        completedEventCount += 1
                    }
                }
            } catch is CancellationError {
                // Consumer-initiated cancellation is an expected terminal.
            } catch {
                businessTerminalCount += 1
            }
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        consumer.cancel()
        await fulfillment(
            of: [streamTerminated, leaseReleased],
            timeout: 1
        )
        XCTAssertEqual(completedEventCount, 0)
        XCTAssertEqual(businessTerminalCount, 0)
        XCTAssertEqual(gate.activeLeaseCount(profileID: profile.id), 0)

        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"fixture"}]}"#
        )
        await fulfillment(
            of: [requestFinished, publicationFinished],
            timeout: 1
        )
        XCTAssertEqual(completedEventCount, 0)
        XCTAssertEqual(businessTerminalCount, 0)
    }

    func testOfficialExecutionGenerationExhaustionFailsClosed() async {
        let profile = TranslationServiceProfile(
            id: "official-generation-exhaustion-fixture",
            templateID: .deepLFree,
            displayName: "Official generation exhaustion fixture",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let gate = TranslationOfficialServiceExecutionGate(
            testInitialGenerations: [profile.id: UInt64.max]
        )
        let oldToken = gate.token(for: profile.id)
        gate.invalidate(profileID: profile.id)
        gate.activate(profileID: profile.id)
        let newToken = gate.token(for: profile.id)
        XCTAssertNil(gate.admit(oldToken))
        XCTAssertNil(gate.admit(newToken))

        let transport = TranslationOfficialSuspendedTransport()
        let adapter = TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: .configured,
            credentialStore: TranslationServiceCredentialFailpointStore(
                values: ["\(profile.id)::auth_key": "fixture-key"]
            ),
            transport: transport,
            executionGate: gate,
            executionToken: newToken
        )
        let streamTerminated = expectation(
            description: "exhausted generation rejects adapter admission"
        )
        var completedEventCount = 0
        var businessTerminalCount = 0
        var cancelled = false
        let consumer = Task { @MainActor in
            defer { streamTerminated.fulfill() }
            do {
                for try await event in adapter.translate(
                    officialServiceRequest(sessionID: "generation-exhaustion")
                ) {
                    if case .completed = event {
                        completedEventCount += 1
                    }
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                businessTerminalCount += 1
            }
        }
        defer { consumer.cancel() }

        await fulfillment(of: [streamTerminated], timeout: 1)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(completedEventCount, 0)
        XCTAssertEqual(businessTerminalCount, 0)
        let transportCallCount = await transport.requestCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testDisablingOfficialProfileRevokesOldStreamBeforeReenableBuildsFreshAdapter()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "official-disable-reenable-fixture",
                templateID: .deepLFree,
                displayName: "Official disable reenable fixture",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let oldRequestStarted = expectation(
            description: "old official request started"
        )
        let newRequestStarted = expectation(
            description: "new official request started"
        )
        let oldRequestFinished = expectation(
            description: "late old official request finished"
        )
        let newRequestFinished = expectation(
            description: "new official request finished"
        )
        let oldStreamTerminated = expectation(
            description: "disable terminates old official stream"
        )
        let newStreamTerminated = expectation(
            description: "new official stream terminates"
        )
        let oldLeaseReleased = expectation(
            description: "disable removes old official lease"
        )
        oldLeaseReleased.assertForOverFulfill = false
        let publicationsFinished = expectation(
            description: "old and new official publications finished"
        )
        publicationsFinished.expectedFulfillmentCount = 2
        let oldRequestStartedSignal = TranslationTestExpectationSignal(
            oldRequestStarted
        )
        let newRequestStartedSignal = TranslationTestExpectationSignal(
            newRequestStarted
        )
        let oldRequestFinishedSignal = TranslationTestExpectationSignal(
            oldRequestFinished
        )
        let newRequestFinishedSignal = TranslationTestExpectationSignal(
            newRequestFinished
        )
        let oldLeaseReleasedSignal = TranslationTestExpectationSignal(
            oldLeaseReleased
        )
        let publicationsFinishedSignal = TranslationTestExpectationSignal(
            publicationsFinished
        )
        let gate = TranslationOfficialServiceExecutionGate(
            testInitialGenerations: [:],
            onLeaseReleased: { profileID in
                guard profileID == profile.id else { return }
                oldLeaseReleasedSignal.fulfill()
            },
            onPublicationFinished: { profileID in
                guard profileID == profile.id else { return }
                publicationsFinishedSignal.fulfill()
            }
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                switch requestID {
                case 1:
                    oldRequestStartedSignal.fulfill()
                case 2:
                    newRequestStartedSignal.fulfill()
                default:
                    break
                }
            },
            onRequestFinished: { requestID in
                switch requestID {
                case 1:
                    oldRequestFinishedSignal.fulfill()
                case 2:
                    newRequestFinishedSignal.fulfill()
                default:
                    break
                }
            }
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(profile.id)::auth_key": "fixture-key"]
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        let registry = TranslationServiceRegistry()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )
        let oldAdapter = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        var oldCompletedEventCount = 0
        var oldBusinessTerminalCount = 0
        var oldCancelled = false
        var oldFinishedCleanly = false
        let oldConsumer = Task { @MainActor in
            defer { oldStreamTerminated.fulfill() }
            do {
                for try await event in oldAdapter.translate(
                    officialServiceRequest(sessionID: "disable-old")
                ) {
                    if case .completed = event {
                        oldCompletedEventCount += 1
                    }
                }
                oldFinishedCleanly = true
            } catch is CancellationError {
                oldCancelled = true
            } catch {
                oldBusinessTerminalCount += 1
            }
        }
        defer { oldConsumer.cancel() }

        await fulfillment(of: [oldRequestStarted], timeout: 1)
        store.setServiceEnabled(false, serviceID: profile.serviceID)
        await fulfillment(
            of: [oldStreamTerminated, oldLeaseReleased],
            timeout: 1
        )
        XCTAssertTrue(oldCancelled)
        XCTAssertFalse(oldFinishedCleanly)
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)
        XCTAssertEqual(gate.activeLeaseCount(profileID: profile.id), 0)
        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertFalse(
            defaults.stringArray(forKey: "translation.services.enabledIDs")?
                .contains(profile.serviceID) == true
        )

        store.setServiceEnabled(true, serviceID: profile.serviceID)
        guard let newAdapter = registry.adapter(serviceID: profile.serviceID)
        else {
            await transport.succeed(
                requestID: 1,
                with: #"{"translations":[{"text":"old-late"}]}"#
            )
            await fulfillment(of: [oldRequestFinished], timeout: 1)
            XCTFail("Expected a fresh enabled official adapter")
            return
        }
        XCTAssertTrue(store.enabledServiceIDs.contains(profile.serviceID))
        var newCompletedEventCount = 0
        var newBusinessTerminalCount = 0
        var newCancelled = false
        let newConsumer = Task { @MainActor in
            defer { newStreamTerminated.fulfill() }
            do {
                for try await event in newAdapter.translate(
                    officialServiceRequest(sessionID: "disable-new")
                ) {
                    if case .completed = event {
                        newCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                newCancelled = true
            } catch {
                newBusinessTerminalCount += 1
            }
        }
        defer { newConsumer.cancel() }

        await fulfillment(of: [newRequestStarted], timeout: 1)
        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"old-late"}]}"#
        )
        await transport.succeed(
            requestID: 2,
            with: #"{"translations":[{"text":"new-current"}]}"#
        )
        await fulfillment(
            of: [
                oldRequestFinished,
                newRequestFinished,
                publicationsFinished,
                newStreamTerminated,
            ],
            timeout: 1
        )
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)
        XCTAssertFalse(newCancelled)
        XCTAssertEqual(newCompletedEventCount, 1)
        XCTAssertEqual(newBusinessTerminalCount, 0)
        XCTAssertEqual(gate.activeLeaseCount(profileID: profile.id), 0)
    }
    #endif

    func testLateOldOfficialLeaseCannotDisruptNewGenerationStream()
        async throws
    {
        let profile = TranslationServiceProfile(
            id: "official-new-generation-fixture",
            templateID: .deepLFree,
            displayName: "Official new generation fixture",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let oldRequestStarted = expectation(
            description: "old official request started"
        )
        let newRequestStarted = expectation(
            description: "new official request started"
        )
        let oldRequestFinished = expectation(
            description: "old official request finished"
        )
        let newRequestFinished = expectation(
            description: "new official request finished"
        )
        let oldRequestStartSignal = TranslationTestExpectationSignal(
            oldRequestStarted
        )
        let newRequestStartSignal = TranslationTestExpectationSignal(
            newRequestStarted
        )
        let oldRequestFinishedSignal = TranslationTestExpectationSignal(
            oldRequestFinished
        )
        let newRequestFinishedSignal = TranslationTestExpectationSignal(
            newRequestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                switch requestID {
                case 1:
                    oldRequestStartSignal.fulfill()
                case 2:
                    newRequestStartSignal.fulfill()
                default:
                    break
                }
            },
            onRequestFinished: { requestID in
                switch requestID {
                case 1:
                    oldRequestFinishedSignal.fulfill()
                case 2:
                    newRequestFinishedSignal.fulfill()
                default:
                    break
                }
            }
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: ["\(profile.id)::auth_key": "fixture-key"]
        )
        #if DEBUG
        let publicationsFinished = expectation(
            description: "old and new publication tasks finished"
        )
        publicationsFinished.expectedFulfillmentCount = 2
        let publicationFinishedSignal = TranslationTestExpectationSignal(
            publicationsFinished
        )
        let gate = TranslationOfficialServiceExecutionGate(
            testInitialGenerations: [:],
            onLeaseReleased: { _ in },
            onPublicationFinished: { profileID in
                guard profileID == profile.id else { return }
                publicationFinishedSignal.fulfill()
            }
        )
        #else
        let gate = TranslationOfficialServiceExecutionGate()
        #endif
        let oldToken = gate.token(for: profile.id)
        let oldLease = try XCTUnwrap(gate.admit(oldToken))
        let oldAdapter = TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: .configured,
            credentialStore: credentials,
            transport: transport,
            executionGate: gate,
            executionToken: oldToken
        )
        let oldTerminated = expectation(
            description: "old generation stream terminates"
        )
        var oldCompletedEventCount = 0
        var oldBusinessTerminalCount = 0
        var oldCancelled = false
        let oldConsumer = Task { @MainActor in
            defer { oldTerminated.fulfill() }
            do {
                for try await event in oldAdapter.translate(
                    officialServiceRequest(sessionID: "old-generation")
                ) {
                    if case .completed = event {
                        oldCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                oldCancelled = true
            } catch {
                oldBusinessTerminalCount += 1
            }
        }
        defer { oldConsumer.cancel() }

        await fulfillment(of: [oldRequestStarted], timeout: 1)
        gate.invalidate(profileID: profile.id)
        await fulfillment(of: [oldTerminated], timeout: 1)
        gate.activate(profileID: profile.id)
        let newToken = gate.token(for: profile.id)
        guard let newLease = gate.admit(newToken) else {
            await transport.succeed(
                requestID: 1,
                with: #"{"translations":[{"text":"fixture"}]}"#
            )
            XCTFail("Expected a current-generation lease")
            return
        }
        defer { gate.finish(newLease) }
        gate.finish(oldLease)
        XCTAssertTrue(gate.isCurrent(newLease))

        let newAdapter = TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: .configured,
            credentialStore: credentials,
            transport: transport,
            executionGate: gate,
            executionToken: newToken
        )
        let newTerminated = expectation(
            description: "new generation stream terminates"
        )
        var newCompletedEventCount = 0
        var newBusinessTerminalCount = 0
        var newCancelled = false
        let newConsumer = Task { @MainActor in
            defer { newTerminated.fulfill() }
            do {
                for try await event in newAdapter.translate(
                    officialServiceRequest(sessionID: "new-generation")
                ) {
                    if case .completed = event {
                        newCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                newCancelled = true
            } catch {
                newBusinessTerminalCount += 1
            }
        }
        defer { newConsumer.cancel() }

        await fulfillment(of: [newRequestStarted], timeout: 1)
        await transport.succeed(
            requestID: 1,
            with: #"{"translations":[{"text":"old"}]}"#
        )
        await transport.succeed(
            requestID: 2,
            with: #"{"translations":[{"text":"new"}]}"#
        )
        await fulfillment(
            of: [oldRequestFinished, newRequestFinished],
            timeout: 1
        )
        #if DEBUG
        await fulfillment(of: [publicationsFinished], timeout: 1)
        #endif
        await fulfillment(of: [newTerminated], timeout: 1)

        XCTAssertTrue(oldCancelled)
        XCTAssertEqual(oldCompletedEventCount, 0)
        XCTAssertEqual(oldBusinessTerminalCount, 0)
        XCTAssertFalse(newCancelled)
        XCTAssertEqual(newCompletedEventCount, 1)
        XCTAssertEqual(newBusinessTerminalCount, 0)
        XCTAssertTrue(gate.isCurrent(newLease))
        let transportCallCount = await transport.requestCount()
        XCTAssertEqual(transportCallCount, 2)
    }

    func testLibreConnectionDiscoversInstanceLanguagesAndCachesCapabilities()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "libre-capability-fixture",
                templateID: .libreTranslate,
                displayName: "Libre Fixture",
                configuration: [
                    "base_url": .string(
                        "https://libre.example.test/api"
                    ),
                ],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "translation.services.enabledIDs")
        let transport = LibreTranslateCapabilityTransport()
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore:
                TranslationServiceCredentialFailpointStore(values: [:]),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )
        _ = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )

        let translated = try await store.connectionTest(profile: profile)

        XCTAssertEqual(translated, "Hallo")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map { $0.url?.path },
            ["/api/languages", "/api/translate"]
        )
        let translationBody = try XCTUnwrap(requests.last?.httpBody)
        let translationJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: translationBody)
                as? [String: Any]
        )
        XCTAssertEqual(translationJSON["source"] as? String, "fr")
        XCTAssertEqual(translationJSON["target"] as? String, "de")
        XCTAssertEqual(translationJSON["q"] as? String, "Bonjour.")
        let descriptor = try XCTUnwrap(
            store.availableServices.first { $0.id == profile.serviceID }
        )
        XCTAssertEqual(
            Set(descriptor.supportedSourceLanguages.map(\.rawValue)),
            Set(["de", "fr"])
        )
        XCTAssertEqual(
            Set(descriptor.supportedTargetLanguages.map(\.rawValue)),
            Set(["de", "fr"])
        )
        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertNil(gate.admit(gate.token(for: profile.id)))
        #if DEBUG
        XCTAssertEqual(gate.activeLeaseCount(profileID: profile.id), 0)
        #endif

        let displayAdapter = try XCTUnwrap(
            registry.adapter(serviceID: profile.serviceID)
        )
        let displayStreamTerminated = expectation(
            description: "disabled Libre display adapter stream terminates"
        )
        var displayCompletedEventCount = 0
        var displayBusinessTerminalCount = 0
        var displayCancelled = false
        let displayConsumer = Task { @MainActor in
            defer { displayStreamTerminated.fulfill() }
            do {
                for try await event in displayAdapter.translate(
                    officialServiceRequest(sessionID: "libre-isolated-display")
                ) {
                    if case .completed = event {
                        displayCompletedEventCount += 1
                    }
                }
            } catch is CancellationError {
                displayCancelled = true
            } catch {
                displayBusinessTerminalCount += 1
            }
        }
        defer { displayConsumer.cancel() }
        await fulfillment(of: [displayStreamTerminated], timeout: 1)
        XCTAssertTrue(displayCancelled)
        XCTAssertEqual(displayCompletedEventCount, 0)
        XCTAssertEqual(displayBusinessTerminalCount, 0)
        let requestsAfterDisplayStream = await transport.recordedRequests()
        XCTAssertEqual(requestsAfterDisplayStream.count, 2)

        let reloadedRegistry = TranslationServiceRegistry()
        let reloaded = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore:
                TranslationServiceCredentialFailpointStore(values: [:]),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: reloadedRegistry
        )
        _ = try await registeredAdapter(
            in: reloadedRegistry,
            serviceID: profile.serviceID
        )
        XCTAssertEqual(
            Set(
                reloaded.availableServices.first {
                    $0.id == profile.serviceID
                }?.supportedSourceLanguages.map(\.rawValue) ?? []
            ),
            Set(["de", "fr"])
        )
    }

    func testCancellingDisabledLibreConnectionLeavesGlobalGateClosed()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "libre-cancel-isolated-gate-fixture",
                templateID: .libreTranslate,
                displayName: "Libre cancelled connection fixture",
                configuration: [
                    "base_url": .string("https://libre.example.test/api"),
                ],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let requestStarted = expectation(
            description: "cancelled Libre discovery starts"
        )
        let requestFinished = expectation(
            description: "cancelled Libre discovery returns after release"
        )
        let requestStartedSignal = TranslationTestExpectationSignal(
            requestStarted
        )
        let requestFinishedSignal = TranslationTestExpectationSignal(
            requestFinished
        )
        let transport = TranslationOfficialSuspendedTransport(
            onRequestReceived: { requestID in
                guard requestID == 1 else { return }
                requestStartedSignal.fulfill()
            },
            onRequestFinished: { requestID in
                guard requestID == 1 else { return }
                requestFinishedSignal.fulfill()
            }
        )
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "translation.services.enabledIDs")
        let registry = TranslationServiceRegistry()
        let gate = TranslationOfficialServiceExecutionGate()
        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore:
                TranslationServiceCredentialFailpointStore(values: [:]),
            officialTransport: transport,
            defaults: defaults,
            serviceRegistry: registry,
            officialServiceExecutionGate: gate
        )
        let displayAdapter = try await registeredAdapter(
            in: registry,
            serviceID: profile.serviceID
        )
        let connectionFinished = expectation(
            description: "cancelled Libre connection finishes"
        )
        var cancelled = false
        var unexpectedError: Error?
        let connectionTask = Task { @MainActor in
            defer { connectionFinished.fulfill() }
            do {
                _ = try await store.connectionTest(profile: profile)
            } catch is CancellationError {
                cancelled = true
            } catch {
                unexpectedError = error
            }
        }
        defer { connectionTask.cancel() }

        await fulfillment(of: [requestStarted], timeout: 1)
        connectionTask.cancel()
        await transport.succeed(
            requestID: 1,
            with: #"[{"code":"fr","name":"French","targets":["de"]}]"#
        )
        await fulfillment(
            of: [requestFinished, connectionFinished],
            timeout: 1
        )
        XCTAssertTrue(cancelled)
        XCTAssertNil(unexpectedError)
        XCTAssertFalse(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertNil(gate.admit(gate.token(for: profile.id)))
        #if DEBUG
        XCTAssertEqual(gate.activeLeaseCount(profileID: profile.id), 0)
        #endif
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
        await assertOfficialAdapterStreamIsCancelled(
            displayAdapter,
            transport: transport,
            expectedRequestCount: 1,
            sessionID: "cancelled-libre-display"
        )
    }

    func testLibreWithoutCapabilitySnapshotRemainsRunnableAndUnverified()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let profile = try fixture.repository.save(
            TranslationServiceProfile(
                id: "libre-missing-capability-fixture",
                templateID: .libreTranslate,
                displayName: "Libre Missing Cache",
                configuration: [
                    "base_url": .string(
                        "https://libre.example.test"
                    ),
                ],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [profile.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [
                profile.id:
                    profile.updatedAt.timeIntervalSince1970,
            ],
            forKey: "translation.services.validatedProfileRevisions"
        )

        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore:
                TranslationServiceCredentialFailpointStore(values: [:]),
            defaults: defaults
        )
        await waitUntil { !store.isLoadingServiceProfiles }

        XCTAssertFalse(
            store.validatedServiceProfileIDs.contains(profile.id)
        )
        XCTAssertTrue(store.enabledServiceIDs.contains(profile.serviceID))
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == profile.serviceID
            }?.availability,
            .available
        )
    }

    func testCorruptLibreCapabilitySnapshotIsIsolatedToItsProfile()
        async throws
    {
        let fixture = try TranslationProfileDatabaseFixture()
        defer { fixture.cleanUp() }
        let libre = try fixture.repository.save(
            TranslationServiceProfile(
                id: "libre-corrupt-capability-fixture",
                templateID: .libreTranslate,
                displayName: "Libre Corrupt Cache",
                configuration: [
                    "base_url": .string(
                        "https://libre.example.test"
                    ),
                ],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            now: Date(timeIntervalSince1970: 100)
        )
        let deepL = try fixture.repository.save(
            TranslationServiceProfile(
                id: "deepl-healthy-fixture",
                templateID: .deepLFree,
                displayName: "DeepL Healthy",
                configuration: [:],
                createdAt: Date(timeIntervalSince1970: 101),
                updatedAt: Date(timeIntervalSince1970: 101)
            ),
            now: Date(timeIntervalSince1970: 101)
        )
        let defaults = isolatedDefaults()
        defaults.set(
            [libre.serviceID, deepL.serviceID],
            forKey: "translation.services.enabledIDs"
        )
        defaults.set(
            [
                libre.id: libre.updatedAt.timeIntervalSince1970,
                deepL.id: deepL.updatedAt.timeIntervalSince1970,
            ],
            forKey: "translation.services.validatedProfileRevisions"
        )
        defaults.set(
            Data(#"{"schemaVersion":1,"entries":"invalid"}"#.utf8),
            forKey: "translation.services.libreCapabilities.\(libre.id)"
        )
        let credentials = TranslationServiceCredentialFailpointStore(
            values: [
                "\(deepL.id)::auth_key": "fixture-key",
            ]
        )

        let store = TranslationStore(
            serviceProfileRepository: fixture.repository,
            serviceCredentialStore: credentials,
            defaults: defaults
        )
        await waitUntil { !store.isLoadingServiceProfiles }

        XCTAssertFalse(
            store.validatedServiceProfileIDs.contains(libre.id)
        )
        XCTAssertTrue(store.enabledServiceIDs.contains(libre.serviceID))
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == libre.serviceID
            }?.availability,
            .available
        )
        XCTAssertTrue(
            store.validatedServiceProfileIDs.contains(deepL.id)
        )
        XCTAssertTrue(store.enabledServiceIDs.contains(deepL.serviceID))
        XCTAssertEqual(
            store.availableServices.first {
                $0.id == deepL.serviceID
            }?.availability,
            .available
        )
    }

    func testTranslationSourceManagementReorderRequiresTheExactEnabledSet()
        async throws
    {
        let store = TranslationStore(defaults: isolatedDefaults())
        store.setServiceEnabled(
            true,
            serviceID: "community:mymemory"
        )
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause:
                    TestError.fixtureFailure
            ),
            translationStore: store
        )
        let expected = [
            "community:mymemory",
            "apple-local",
        ]

        let result = try await service.execute(
            TranslationSourceManagementActionInput(
                operation: .reorder,
                orderedSourceIDs: expected
            )
        )

        XCTAssertEqual(result.enabledSourceIDs, expected)
        XCTAssertEqual(store.enabledServiceIDs, expected)

        do {
            _ = try await service.execute(
                TranslationSourceManagementActionInput(
                    operation: .reorder,
                    orderedSourceIDs: ["apple-local"]
                )
            )
            XCTFail("A partial order must be rejected.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .invalidSourceOrder
            )
        }
    }

    func testTranslationSourceManagementUIFacadeSharesEnableAndOrderState()
        async throws
    {
        let store = TranslationStore(defaults: isolatedDefaults())
        let disclosures = TranslationCommunityWebDisclosureStore(
            defaults: isolatedDefaults()
        )
        disclosures.acknowledge(source: .myMemory)
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause:
                    TestError.fixtureFailure
            ),
            translationStore: store,
            communityDisclosureStore: disclosures
        )

        try await service.setSourceEnabled(
            true,
            sourceID: "community:mymemory"
        )
        XCTAssertTrue(
            store.enabledServiceIDs.contains("community:mymemory")
        )

        service.moveEnabledSource(
            sourceID: "community:mymemory",
            before: "apple-local"
        )
        XCTAssertEqual(
            store.enabledServiceIDs,
            ["community:mymemory", "apple-local"]
        )

        try await service.setSourceEnabled(
            false,
            sourceID: "community:mymemory"
        )
        XCTAssertEqual(store.enabledServiceIDs, ["apple-local"])
    }

    func testTranslationSourceManagementEnableIsIdempotentAtMaximumAndRejectsFifth()
        async throws
    {
        let targetSourceID = "plugin:idempotent-at-limit"
        let otherSourceID = "plugin:other-at-limit"
        let fourthSourceID = "plugin:fourth-at-limit"
        let fifthSourceID = "plugin:fifth-at-limit"
        let store = TranslationStore(defaults: isolatedDefaults())
        store.replacePluginAdapters([
            TestTranslationAdapter(id: targetSourceID),
            TestTranslationAdapter(id: otherSourceID),
            TestTranslationAdapter(id: fourthSourceID),
            TestTranslationAdapter(id: fifthSourceID),
        ])
        store.setServiceEnabled(true, serviceID: targetSourceID)
        store.setServiceEnabled(true, serviceID: otherSourceID)
        store.setServiceEnabled(true, serviceID: fourthSourceID)
        XCTAssertEqual(store.enabledServiceIDs.count, 4)

        let runtime = SuspendedPluginRuntimeEnableProbe()
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            pluginRuntimeEnabled: { enabled, pluginID in
                await runtime.setEnabled(enabled, pluginID: pluginID)
            }
        )
        let enabledBeforeRetry = store.enabledServiceIDs

        try await service.setSourceEnabled(
            true,
            sourceID: targetSourceID
        )

        XCTAssertEqual(store.enabledServiceIDs, enabledBeforeRetry)
        let runtimeCallsAfterRetry = await runtime.callCount
        XCTAssertEqual(runtimeCallsAfterRetry, 0)

        do {
            try await service.setSourceEnabled(
                true,
                sourceID: fifthSourceID
            )
            XCTFail("Only a genuinely new fifth source must be rejected.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .maximumEnabledSourcesReached
            )
        }
        XCTAssertEqual(store.enabledServiceIDs, enabledBeforeRetry)
        let runtimeCallsAfterRejection = await runtime.callCount
        XCTAssertEqual(runtimeCallsAfterRejection, 0)
    }

    func testPluginSourceDisableInvalidatesSuspendedEnableBeforeStoreWrite()
        async throws
    {
        let store = TranslationStore(defaults: isolatedDefaults())
        let adapter = TestTranslationAdapter(id: "plugin:race-fixture")
        store.replacePluginAdapters([adapter])
        let runtime = SuspendedPluginRuntimeEnableProbe()
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            pluginRuntimeEnabled: { enabled, pluginID in
                await runtime.setEnabled(enabled, pluginID: pluginID)
            }
        )

        let enable = Task { @MainActor in
            try await service.setSourceEnabled(
                true,
                sourceID: "plugin:race-fixture"
            )
        }
        await runtime.waitUntilFirstEnableStarts()

        let disable = Task { @MainActor in
            try await service.setSourceEnabled(
                false,
                sourceID: "plugin:race-fixture"
            )
        }
        await Task.yield()
        await runtime.releaseFirstEnable()

        try await enable.value
        try await disable.value

        XCTAssertFalse(store.enabledServiceIDs.contains("plugin:race-fixture"))
        let runtimeEnabled = await runtime.isEnabled(pluginID: "race-fixture")
        XCTAssertFalse(runtimeEnabled)
        XCTAssertEqual(adapter.translateCallCount, 0)
    }

    func testPluginSourceEnableDisableEnableLeavesLatestIntentEnabled()
        async throws
    {
        let store = TranslationStore(defaults: isolatedDefaults())
        store.replacePluginAdapters([
            TestTranslationAdapter(id: "plugin:race-fixture"),
        ])
        let runtime = SuspendedPluginRuntimeEnableProbe()
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            pluginRuntimeEnabled: { enabled, pluginID in
                await runtime.setEnabled(enabled, pluginID: pluginID)
            }
        )

        let firstEnable = Task { @MainActor in
            try await service.setSourceEnabled(
                true,
                sourceID: "plugin:race-fixture"
            )
        }
        await runtime.waitUntilFirstEnableStarts()
        let disable = Task { @MainActor in
            try await service.setSourceEnabled(
                false,
                sourceID: "plugin:race-fixture"
            )
        }
        await Task.yield()
        let finalEnable = Task { @MainActor in
            try await service.setSourceEnabled(
                true,
                sourceID: "plugin:race-fixture"
            )
        }
        await Task.yield()
        await runtime.releaseFirstEnable()

        try await firstEnable.value
        try await disable.value
        try await finalEnable.value

        XCTAssertTrue(store.enabledServiceIDs.contains("plugin:race-fixture"))
        let runtimeEnabled = await runtime.isEnabled(pluginID: "race-fixture")
        XCTAssertTrue(runtimeEnabled)
    }

    func testCancelledPluginSourceTransitionWaiterDoesNotBlockOnPredecessor()
        async throws
    {
        let sourceID = "plugin:transition-cancellation-fixture"
        let store = TranslationStore(defaults: isolatedDefaults())
        store.replacePluginAdapters([TestTranslationAdapter(id: sourceID)])
        let runtime = SuspendedPluginRuntimeEnableProbe()
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            pluginRuntimeEnabled: { enabled, pluginID in
                await runtime.setEnabled(enabled, pluginID: pluginID)
            }
        )

        let firstCompleted = expectation(
            description: "first transition completed"
        )
        let firstEnable = Task { @MainActor () -> Error? in
            defer { firstCompleted.fulfill() }
            do {
                try await service.setSourceEnabled(true, sourceID: sourceID)
                return nil
            } catch {
                return error
            }
        }
        await runtime.waitUntilFirstEnableStarts()

        let cancelledRequestID = ActionRequestID.make()
        let waiterCompleted = expectation(
            description: "cancelled transition waiter completed"
        )
        let cancelledWaiter = Task { @MainActor () -> Error? in
            defer { waiterCompleted.fulfill() }
            do {
                _ = try await service.execute(
                    TranslationSourceManagementActionInput(
                        operation: .enable,
                        sourceID: sourceID
                    ),
                    requestID: cancelledRequestID
                )
                return nil
            } catch {
                return error
            }
        }
        await Task.yield()

        XCTAssertTrue(
            service.cancelActionRequest(cancelledRequestID.rawValue)
        )
        await fulfillment(of: [waiterCompleted], timeout: 1)
        let cancellationError = await cancelledWaiter.value
        XCTAssertTrue(cancellationError is CancellationError)
        XCTAssertFalse(
            service.cancelActionRequest(cancelledRequestID.rawValue),
            "Cancelled requests must release their requestID ownership."
        )
        let callsBeforeFirstRelease = await runtime.callCount
        XCTAssertEqual(callsBeforeFirstRelease, 1)
        XCTAssertFalse(store.enabledServiceIDs.contains(sourceID))

        let survivingCompleted = expectation(
            description: "surviving transition completed"
        )
        let survivingEnable = Task { @MainActor () -> Error? in
            defer { survivingCompleted.fulfill() }
            do {
                try await service.setSourceEnabled(true, sourceID: sourceID)
                return nil
            } catch {
                return error
            }
        }
        await Task.yield()
        await runtime.releaseFirstEnable()

        await fulfillment(
            of: [firstCompleted, survivingCompleted],
            timeout: 1
        )
        let firstEnableError = await firstEnable.value
        let survivingEnableError = await survivingEnable.value
        XCTAssertNil(firstEnableError)
        XCTAssertNil(survivingEnableError)

        let finalCallCount = await runtime.callCount
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertTrue(store.enabledServiceIDs.contains(sourceID))
    }

    func testCancelledPluginDisableIntentDoesNotOverrideSuspendedEnable()
        async throws
    {
        let sourceID = "plugin:cancelled-disable-intent-fixture"
        let store = TranslationStore(defaults: isolatedDefaults())
        store.replacePluginAdapters([TestTranslationAdapter(id: sourceID)])
        let runtime = SuspendedPluginRuntimeEnableProbe()
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            pluginRuntimeEnabled: { enabled, pluginID in
                await runtime.setEnabled(enabled, pluginID: pluginID)
            }
        )

        let firstEnable = Task { @MainActor in
            try await service.setSourceEnabled(true, sourceID: sourceID)
        }
        await runtime.waitUntilFirstEnableStarts()

        let requestID = ActionRequestID.make()
        let cancelledWaiter = Task { @MainActor () -> Error? in
            do {
                _ = try await service.execute(
                    TranslationSourceManagementActionInput(
                        operation: .disable,
                        sourceID: sourceID
                    ),
                    requestID: requestID
                )
                return nil
            } catch {
                return error
            }
        }
        await Task.yield()

        XCTAssertTrue(service.cancelActionRequest(requestID.rawValue))
        let cancellationError = await cancelledWaiter.value
        XCTAssertTrue(cancellationError is CancellationError)
        XCTAssertFalse(service.cancelActionRequest(requestID.rawValue))
        let callsBeforeFirstRelease = await runtime.callCount
        XCTAssertEqual(callsBeforeFirstRelease, 1)

        await runtime.releaseFirstEnable()
        try await firstEnable.value

        let callsAfterFirstRelease = await runtime.callCount
        XCTAssertEqual(callsAfterFirstRelease, 1)
        XCTAssertTrue(store.enabledServiceIDs.contains(sourceID))
        let isEnabledAfterCancellation = await runtime.isEnabled(
            pluginID: "cancelled-disable-intent-fixture"
        )
        XCTAssertTrue(isEnabledAfterCancellation)

        try await service.setSourceEnabled(false, sourceID: sourceID)
        let finalRuntimeCallCount = await runtime.callCount
        XCTAssertEqual(finalRuntimeCallCount, 2)
        XCTAssertFalse(store.enabledServiceIDs.contains(sourceID))
        let isEnabledAfterDisable = await runtime.isEnabled(
            pluginID: "cancelled-disable-intent-fixture"
        )
        XCTAssertFalse(isEnabledAfterDisable)
    }

    func testCancelledPluginDisableKeepsStoreAndRuntimeEnabled()
        async throws
    {
        let sourceID = "plugin:cancelled-runtime-disable-fixture"
        let store = TranslationStore(defaults: isolatedDefaults())
        store.replacePluginAdapters([TestTranslationAdapter(id: sourceID)])
        store.setServiceEnabled(true, serviceID: sourceID)
        let runtime = SuspendedPluginRuntimeDisableProbe(
            initiallyEnabledPluginIDs: ["cancelled-runtime-disable-fixture"]
        )
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            pluginRuntimeEnabled: { enabled, pluginID in
                try await runtime.setEnabled(enabled, pluginID: pluginID)
            }
        )

        let requestID = ActionRequestID.make()
        let disable = Task { @MainActor () -> Error? in
            do {
                _ = try await service.execute(
                    TranslationSourceManagementActionInput(
                        operation: .disable,
                        sourceID: sourceID
                    ),
                    requestID: requestID
                )
                return nil
            } catch {
                return error
            }
        }
        await runtime.waitUntilFirstDisableStarts()

        XCTAssertTrue(service.cancelActionRequest(requestID.rawValue))
        let error = await disable.value

        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(service.cancelActionRequest(requestID.rawValue))
        XCTAssertTrue(store.enabledServiceIDs.contains(sourceID))
        let runtimeEnabled = await runtime.isEnabled(
            pluginID: "cancelled-runtime-disable-fixture"
        )
        XCTAssertTrue(runtimeEnabled)
    }

    func testTranslationSourceManagementRejectsUnacknowledgedCommunityEnableAndTestBeforeNetwork()
        async throws
    {
        let transport = TranslationCommunityTransportProbe(
            responsesByHost: [
                "translate.googleapis.com":
                    Data(#"[[[\"你好\",\"Hello\",null,null,10]],null,\"en\"]"#.utf8),
            ]
        )
        let store = TranslationStore(
            communityWebTransport: transport,
            defaults: isolatedDefaults()
        )
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            communityDisclosureStore: TranslationCommunityWebDisclosureStore(
                defaults: isolatedDefaults()
            )
        )

        do {
            try await service.setSourceEnabled(
                true,
                sourceID: "community:google-web"
            )
            XCTFail("Community enable must require persisted disclosure consent.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .confirmationRequired
            )
        }
        XCTAssertFalse(store.enabledServiceIDs.contains("community:google-web"))

        do {
            try await service.testCommunitySource(
                sourceID: "community:google-web"
            )
            XCTFail("Community connection tests must require persisted disclosure consent.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .confirmationRequired
            )
        }

        let result = await service.testSource(
            sourceID: "community:google-web"
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.errorCode, "confirmation_required")
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testTranslationSourceManagementAllowsAcknowledgedCommunityAndLocalSources()
        async throws
    {
        let defaults = isolatedDefaults()
        let disclosures = TranslationCommunityWebDisclosureStore(
            defaults: defaults
        )
        disclosures.acknowledge(source: .googleWeb)
        let store = TranslationStore(defaults: defaults)
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: store,
            communityDisclosureStore: disclosures
        )

        try await service.setSourceEnabled(
            true,
            sourceID: "community:google-web"
        )
        XCTAssertTrue(store.enabledServiceIDs.contains("community:google-web"))
        try await service.setSourceEnabled(
            false,
            sourceID: "community:google-web"
        )
        try await service.setSourceEnabled(true, sourceID: "apple-local")
        XCTAssertTrue(store.enabledServiceIDs.contains("apple-local"))
    }

    func testTranslationSourceManagementUIFacadeClassifiesUnsupportedTest()
        async
    {
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause:
                    TestError.fixtureFailure
            ),
            translationStore:
                TranslationStore(defaults: isolatedDefaults())
        )

        let result = await service.testSource(
            sourceID: "missing-source"
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(
            result.errorCode,
            "connection_test_unsupported"
        )
    }

    func testTranslationSourceManagementActionFailsWhenConnectionTestFails()
        async
    {
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause:
                    TestError.fixtureFailure
            ),
            translationStore:
                TranslationStore(defaults: isolatedDefaults())
        )

        do {
            _ = try await service.execute(
                TranslationSourceManagementActionInput(
                    operation: .test,
                    sourceID: "missing-source"
                )
            )
            XCTFail("A failed connection test must fail the action.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .connectionTestFailed(
                    code: "connection_test_unsupported",
                    message:
                        "This translation source does not expose a CLI connection test."
                )
            )
        }
    }

    func testTranslationSourceRemovalRequiresExplicitConfirmation()
        async throws
    {
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause:
                    TestError.fixtureFailure
            ),
            translationStore:
                TranslationStore(defaults: isolatedDefaults())
        )

        do {
            _ = try await service.execute(
                TranslationSourceManagementActionInput(
                    operation: .remove,
                    sourceID: "plugin:fixture"
                )
            )
            XCTFail("Removal must require explicit confirmation.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .confirmationRequired
            )
        }
    }

    func testTranslationSourceScaffoldUsesVersionThreeCompletedResultContract()
        async throws
    {
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause:
                    TestError.fixtureFailure
            ),
            translationStore:
                TranslationStore(defaults: isolatedDefaults())
        )

        let result = try await service.execute(
            TranslationSourceManagementActionInput(
                operation: .scaffold,
                scaffoldID: "com.example.fixture",
                scaffoldDisplayName: "Fixture"
            )
        )
        let scaffold = try XCTUnwrap(result.scaffold)
        let manifestData = try XCTUnwrap(
            scaffold.files[
                BlocksNativePluginManifest.manifestFileName
            ]
        )
        let manifest = try JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: manifestData
        )
        let source = try XCTUnwrap(
            String(data: try XCTUnwrap(scaffold.files["main.js"]), encoding: .utf8)
        )

        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(
            manifest.translation?.acceptedInputs,
            [.text]
        )
        XCTAssertTrue(source.contains(#"status: "completed""#))
    }

    func testGenericPluginScaffoldUsesManifestV6PlatformContract()
        async throws
    {
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(
                storageUnavailableBecause: TestError.fixtureFailure
            ),
            translationStore: TranslationStore(defaults: isolatedDefaults())
        )

        let result = try await service.execute(
            TranslationSourceManagementActionInput(
                operation: .scaffold,
                scaffoldID: "com.example.platform-fixture",
                scaffoldDisplayName: "Platform Fixture",
                pluginScope: true
            )
        )
        let scaffold = try XCTUnwrap(result.scaffold)
        let manifest = try JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: try XCTUnwrap(
                scaffold.files[BlocksNativePluginManifest.manifestFileName]
            )
        )
        let source = try XCTUnwrap(String(
            data: try XCTUnwrap(scaffold.files["main.js"]),
            encoding: .utf8
        ))

        XCTAssertEqual(manifest.schemaVersion, 6)
        XCTAssertNotNil(manifest.presentation)
        XCTAssertEqual(manifest.platform?.hooks.first?.event, .appLaunched)
        XCTAssertEqual(manifest.platform?.actions.first?.id, "run")
        XCTAssertEqual(
            manifest.platform?.storage?.kinds,
            [.keyValue, .document, .queue]
        )
        XCTAssertTrue(source.contains("function performAction"))
    }

    func testCustomSourceInputWhitelistsContextAndScreenshotData()
        throws
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.context-whitelist",
            displayName: "Context Whitelist",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.text, .screenshotImage],
                contextFields: [.ocrSummary]
            ),
            permissions: .init(data: [.screenshotImage])
        )
        let data = Data(repeating: 1, count: 32)
        let payload = TranslationSourceAttachmentPayload(
            descriptor: TranslationSourceAttachmentDescriptor(
                kind: .screenshotImage,
                mediaType: "image/jpeg",
                byteCount: data.count,
                pixelWidth: 10,
                pixelHeight: 10,
                sha256: TranslationAttachmentDigest.sha256Hex(data)
            ),
            data: data,
            base64EncodedData: data.base64EncodedString()
        )
        let request = TranslationServiceRequest(
            sessionID: "session",
            input: TranslationInput(
                source: .screenshotOCR,
                text: "fixture"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("en")!
            ),
            context: TranslationSourceContext(
                inputSource: .screenshotOCR,
                sourceApplicationBundleID: "com.example.private",
                ocrSummary: .init(lineCount: 3)
            ),
            attachments: [payload]
        )

        let input = try TranslationPluginServiceAdapter
            .invocationInput(
                request,
                manifest: manifest,
                approvedPermissions: ["data:screenshot_image"]
            )

        XCTAssertEqual(
            input["context"],
            .object([
                "ocr_summary": .object([
                    "line_count": .int(3),
                ]),
            ])
        )
        guard case let .array(attachments)? = input["attachments"] else {
            return XCTFail("Expected one screenshot attachment.")
        }
        XCTAssertEqual(attachments.count, 1)
        guard case let .object(attachment) = attachments[0] else {
            return XCTFail("Expected attachment metadata.")
        }
        XCTAssertEqual(
            attachment["sha256"],
            .string(TranslationAttachmentDigest.sha256Hex(data))
        )
        XCTAssertThrowsError(
            try TranslationPluginServiceAdapter.invocationInput(
                request,
                manifest: manifest,
                approvedPermissions: []
            )
        )
    }

    func testTranslationSnapshotEncodingDoesNotPersistAttachmentData()
        throws
    {
        let attachmentData = Data([0x01])
        let attachment = TranslationSourceAttachmentPayload(
            descriptor: TranslationSourceAttachmentDescriptor(
                kind: .screenshotImage,
                mediaType: "image/jpeg",
                byteCount: attachmentData.count,
                pixelWidth: 1,
                pixelHeight: 1
            ),
            data: attachmentData,
            base64EncodedData: attachmentData.base64EncodedString()
        )
        let request = TranslationServiceRequest(
            sessionID: "session",
            input: TranslationInput(
                source: .screenshotOCR,
                text: "recognized"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("en")!
            ),
            attachments: [attachment]
        )
        let invocationEncoded = String(
            decoding: try JSONEncoder().encode(request.invocation),
            as: UTF8.self
        )
        let snapshot = TranslationSessionSnapshot(
            input: TranslationInput(
                source: .screenshotOCR,
                text: "recognized"
            ),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("en")!
            ),
            results: []
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(snapshot),
            as: UTF8.self
        )

        XCTAssertFalse(invocationEncoded.contains("data_base64"))
        XCTAssertFalse(invocationEncoded.contains("base64EncodedData"))
        XCTAssertFalse(encoded.contains("data_base64"))
        XCTAssertFalse(encoded.contains("base64EncodedData"))
    }

    func testTranslationSourceImageEncoderRejectsInvalidInput() {
        XCTAssertThrowsError(
            try TranslationSourceImageEncoder.encode(
                sourceData: Data("not-an-image".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? TranslationSourceImageEncodingError,
                .unsupportedFormat
            )
        }
    }

    func testTranslationSourceTestImageRoundTripsOnlyInActionPayload()
        throws
    {
        let image = TranslationSourceEncodedImage(
            data: Data([0xff, 0xd8, 0xff, 0xd9]),
            mediaType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        let input = TranslationSourceManagementActionInput(
            operation: .test,
            sourceID: "plugin:fixture",
            testImage: image
        )

        let decoded = try JSONDecoder().decode(
            TranslationSourceManagementActionInput.self,
            from: JSONEncoder().encode(input)
        )

        XCTAssertEqual(decoded.testImage, image)
        XCTAssertNil(decoded.testText)
    }

    func testProviderSecretUpdateFailurePreservesExistingSecret()
        throws
    {
        let securityAPI = ProviderKeychainSecurityFailureProbe(
            storedSecret: "old-provider-secret",
            updateStatus: errSecAuthFailed
        )
        let service = ProviderKeychainService(securityAPI: securityAPI)

        let result = try service.performUserSecret(
            action: .saveOrReplace,
            alias: "fixture-account",
            secret: "replacement-provider-secret",
            credentialRevision: 1
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.osStatus, Int(errSecAuthFailed))
        XCTAssertEqual(securityAPI.updateCallCount, 1)
        XCTAssertEqual(securityAPI.addCallCount, 0)
        XCTAssertEqual(securityAPI.deleteCallCount, 0)
        XCTAssertEqual(
            try service.readUserSecretForProviderCall(alias: "fixture-account")
                .withSecret { $0 },
            "old-provider-secret"
        )
    }

    func testLegacyRawProviderSecretRequiresResaveBeforeExternalTransfer()
        throws
    {
        let securityAPI = ProviderKeychainSecurityFailureProbe(
            storedSecret: "legacy-raw-secret",
            updateStatus: errSecSuccess,
            storesLegacyRawSecret: true
        )
        let service = ProviderKeychainService(securityAPI: securityAPI)

        XCTAssertThrowsError(
            try service.readUserSecretForProviderCall(alias: "fixture-account")
        ) { error in
            XCTAssertEqual(
                error as? ProviderKeychainServiceError,
                .userSecretRequiresResave
            )
        }
    }

    func testCredentialBearingProviderURLIsNotPersistedAndDoesNotCallTransport()
        async
    {
        let defaults = isolatedDefaults()
        let credentialBearingURL = "https://user:password@example.test/v1?token=secret#fragment"

        XCTAssertNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                credentialBearingURL,
                defaults: defaults
            )
        )
        XCTAssertNil(defaults.object(forKey: ProviderSettingsPersistence.baseURLKey))
        XCTAssertEqual(
            ProviderSettingsPersistence.saveProviderBaseURL(
                " HTTPS://EXAMPLE.test/v1 ",
                defaults: defaults
            ),
            "https://example.test/v1"
        )
        XCTAssertNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                credentialBearingURL,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.baseURLKey),
            "https://example.test/v1"
        )

        let transport = CountingOpenAIConnectionTransport()
        let service = OpenAICompatibleConnectionService(transport: transport)
        let result = await service.testConnection(
            profile: OpenAIConnectionTestProfile(
                providerName: "Fixture Provider",
                baseURL: credentialBearingURL,
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 60
            ),
            secretMaterial: Self.fixtureSecretMaterial
        )

        XCTAssertEqual(result.status, .invalidBaseURL)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 0)
    }

    func testOpenAIConnectionRechecksAuthorizationImmediatelyBeforeTransport()
        async
    {
        let transport = CountingOpenAIConnectionTransport()
        let authorizationProbe = AuthorizationCheckSequenceProbe(
            values: [true, false]
        )
        let service = OpenAICompatibleConnectionService(transport: transport)

        let result = await service.testConnection(
            profile: OpenAIConnectionTestProfile(
                providerName: "Fixture Provider",
                baseURL: "https://example.test/v1",
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 60
            ),
            secretMaterial: Self.fixtureSecretMaterial,
            authorizationCheck: { authorizationProbe.nextValue() }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertEqual(result.warnings, [
            "confirmation_required",
            "provider_call_not_executed",
        ])
        XCTAssertEqual(authorizationProbe.callCount, 2)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testOpenAIConnectionRedactsResponseWhenAuthorizationRevokedAfterTransport()
        async
    {
        let transport = CountingOpenAIConnectionTransport()
        let authorizationProbe = AuthorizationCheckSequenceProbe(
            values: [true, true, false]
        )
        let service = OpenAICompatibleConnectionService(transport: transport)

        let result = await service.testConnection(
            profile: OpenAIConnectionTestProfile(
                providerName: "Fixture Provider",
                baseURL: "https://example.test/v1",
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 60
            ),
            secretMaterial: Self.fixtureSecretMaterial,
            authorizationCheck: { authorizationProbe.nextValue() }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertEqual(result.httpStatusCode, 200)
        XCTAssertEqual(result.requestID, "fixture-request")
        XCTAssertGreaterThanOrEqual(result.durationMS, 0)
        XCTAssertNil(result.responseTextCharacterCount)
        XCTAssertNil(result.secretLength)
        XCTAssertEqual(result.warnings, [
            "external_transfer_disabled",
            "authorization_revoked_after_transport",
            "provider_response_redacted",
        ])
        XCTAssertEqual(authorizationProbe.callCount, 3)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 1)
    }

    func testOpenAITranslationRuntimeRechecksAuthorizationImmediatelyBeforeTransport()
        async
    {
        let transport = CountingOpenAIConnectionTransport()
        let authorizationProbe = AuthorizationCheckSequenceProbe(
            values: [true, false]
        )
        let auditProbe = TranslationRuntimeAuditProbe()
        let runtime = OpenAITranslationRuntimeService(
            transport: transport,
            auditHandler: { auditProbe.record($0) }
        )
        let profile = OpenAITranslationRuntimeProfile(
            providerName: "Fixture Provider",
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "fixture-account",
            timeoutSeconds: 60
        )

        let result = await runtime.translate(
            text: "Blocks",
            sourceLanguageMode: "auto",
            targetLanguage: "zh-Hans",
            profile: profile,
            secretMaterial: Self.fixtureSecretMaterial,
            authorizationCheck: { authorizationProbe.nextValue() }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertEqual(result.warnings, [
            "external_transfer_disabled",
            "provider_call_not_executed",
        ])
        XCTAssertEqual(auditProbe.result?.auditID, result.auditID)
        XCTAssertEqual(auditProbe.result?.warnings, result.warnings)
        XCTAssertEqual(authorizationProbe.callCount, 2)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testOpenAITranslationRedactsResponseWhenAuthorizationRevokedAfterTransport()
        async
    {
        let transport = CountingOpenAIConnectionTransport()
        let authorizationProbe = AuthorizationCheckSequenceProbe(
            values: [true, true, false]
        )
        let auditProbe = TranslationRuntimeAuditProbe()
        let runtime = OpenAITranslationRuntimeService(
            transport: transport,
            auditHandler: { auditProbe.record($0) }
        )
        let profile = OpenAITranslationRuntimeProfile(
            providerName: "Fixture Provider",
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "fixture-account",
            timeoutSeconds: 60
        )

        let result = await runtime.translate(
            text: "Blocks",
            sourceLanguageMode: "auto",
            targetLanguage: "zh-Hans",
            profile: profile,
            secretMaterial: Self.fixtureSecretMaterial,
            authorizationCheck: { authorizationProbe.nextValue() }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertEqual(result.textCharacterCount, 6)
        XCTAssertNil(result.outputText)
        XCTAssertEqual(result.httpStatusCode, 200)
        XCTAssertEqual(result.requestID, "fixture-request")
        XCTAssertGreaterThanOrEqual(result.durationMS, 0)
        XCTAssertNil(result.secretLength)
        XCTAssertEqual(result.warnings, [
            "external_transfer_disabled",
            "authorization_revoked_after_transport",
            "provider_response_redacted",
        ])
        XCTAssertEqual(auditProbe.result?.auditID, result.auditID)
        XCTAssertFalse(auditProbe.result?.ok ?? true)
        XCTAssertNil(auditProbe.result?.outputText)
        let auditStore = ProviderStore()
        auditStore.recordTranslationRuntime(result)
        let auditEvent = auditStore.providerAuditEvents.first
        XCTAssertEqual(auditEvent?.outcome, .failed)
        XCTAssertEqual(auditEvent?.count, result.textCharacterCount)
        XCTAssertFalse(String(describing: auditEvent).contains("fixture"))
        XCTAssertEqual(authorizationProbe.callCount, 3)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 1)
    }

    func testOpenAIConnectionAdmissionDoesNotStartAfterGrantRevokedBeforeAdmission()
        async
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL("https://example.test/v1", defaults: defaults)
        _ = ProviderSettingsPersistence.saveProviderModelName("fixture-model", defaults: defaults)
        _ = ProviderSettingsPersistence.saveProviderAccountAlias("fixture-account", defaults: defaults)
        let target = try! XCTUnwrap(ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults))
        XCTAssertTrue(ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(for: target, defaults: defaults))
        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let transport = SynchronousStartOpenAIConnectionTransportProbe()
        let result = await OpenAICompatibleConnectionService(transport: transport).testConnection(
            profile: OpenAIConnectionTestProfile(providerName: "Fixture", baseURL: target.normalizedBaseURL, modelName: target.modelName, keychainAccountAlias: target.keychainAccountAlias, timeoutSeconds: 60),
            secretMaterial: Self.fixtureSecretMaterial,
            authorizationCheck: {
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target,
                    defaults: authorizationDefaults.value
                )
            },
            admission: { start in
                ProviderSettingsPersistence.revokeExternalTransferGrant(
                    defaults: authorizationDefaults.value
                )
                return ProviderSettingsPersistence.admitExternalTransfer(
                    target: target,
                    defaults: authorizationDefaults.value,
                    start: start
                )
            }
        )
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertTrue(result.warnings.contains("provider_call_not_executed"))
        XCTAssertEqual(transport.startCount(), 0)
    }

    func testOpenAITranslationAdmissionRedactsWhenGrantRevokedAfterSynchronousStart()
        async
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL("https://example.test/v1", defaults: defaults)
        _ = ProviderSettingsPersistence.saveProviderModelName("fixture-model", defaults: defaults)
        _ = ProviderSettingsPersistence.saveProviderAccountAlias("fixture-account", defaults: defaults)
        let target = try! XCTUnwrap(ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults))
        XCTAssertTrue(ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(for: target, defaults: defaults))
        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let transport = SynchronousStartOpenAIConnectionTransportProbe()
        let result = await OpenAITranslationRuntimeService(transport: transport).translate(
            text: "Blocks", sourceLanguageMode: "auto", targetLanguage: "zh-Hans",
            profile: OpenAITranslationRuntimeProfile(providerName: "Fixture", baseURL: target.normalizedBaseURL, modelName: target.modelName, keychainAccountAlias: target.keychainAccountAlias, timeoutSeconds: 60),
            secretMaterial: Self.fixtureSecretMaterial,
            authorizationCheck: {
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target,
                    defaults: authorizationDefaults.value
                )
            },
            admission: { start in
                let admitted = ProviderSettingsPersistence.admitExternalTransfer(
                    target: target,
                    defaults: authorizationDefaults.value,
                    start: start
                )
                ProviderSettingsPersistence.revokeExternalTransferGrant(
                    defaults: authorizationDefaults.value
                )
                return admitted
            }
        )
        XCTAssertEqual(transport.startCount(), 1)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertTrue(result.warnings.contains("authorization_revoked_after_transport"))
        XCTAssertNil(result.outputText)
        XCTAssertNil(result.secretLength)
    }

    func testOpenAIConnectionCancellationBeforeAdmissionDoesNotStartTransport()
        async
    {
        let transport = SynchronousStartOpenAIConnectionTransportProbe()
        let task = Task { @MainActor in
            await OpenAICompatibleConnectionService(transport: transport)
                .testConnection(
                    profile: OpenAIConnectionTestProfile(
                        providerName: "Fixture",
                        baseURL: "https://example.test/v1",
                        modelName: "fixture-model",
                        keychainAccountAlias: "fixture-account",
                        timeoutSeconds: 60
                    ),
                    secretMaterial: Self.fixtureSecretMaterial,
                    authorizationCheck: {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return true
                    },
                    admission: { start in start() }
                )
        }

        let result = await task.value
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertTrue(result.warnings.contains("provider_call_not_executed"))
        XCTAssertEqual(transport.startCount(), 0)
    }

    func testOpenAITranslationCancellationBeforeAdmissionDoesNotStartTransport()
        async
    {
        let transport = SynchronousStartOpenAIConnectionTransportProbe()
        let task = Task {
            await OpenAITranslationRuntimeService(transport: transport)
                .translate(
                    text: "Blocks",
                    sourceLanguageMode: "auto",
                    targetLanguage: "zh-Hans",
                    profile: OpenAITranslationRuntimeProfile(
                        providerName: "Fixture",
                        baseURL: "https://example.test/v1",
                        modelName: "fixture-model",
                        keychainAccountAlias: "fixture-account",
                        timeoutSeconds: 60
                    ),
                    secretMaterial: Self.fixtureSecretMaterial,
                    authorizationCheck: {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return true
                    },
                    admission: { start in start() }
                )
        }

        let result = await task.value
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertTrue(result.warnings.contains("provider_call_not_executed"))
        XCTAssertEqual(transport.startCount(), 0)
    }

    func testOpenAITransportDenies307And308RedirectsBeforeTargetRequest()
        async throws
    {
        for statusCode in [307, 308] {
            let session = OpenAIRedirectSessionProbe(statusCode: statusCode)
            let transport = URLSessionOpenAIConnectionTransport(
                session: session
            )
            var request = URLRequest(
                url: URL(string: "https://authorized.example.test/original")!
            )
            request.httpMethod = "POST"
            request.httpBody = Data("private-source-text".utf8)

            let response = try await transport.perform(
                request,
                timeoutSeconds: 2
            )

            XCTAssertEqual(response.httpResponse.statusCode, statusCode)
            XCTAssertEqual(response.httpResponse.url, request.url)
            XCTAssertEqual(session.redirectTargetRequestCount, 0)
        }
    }

    func testOpenAIRedirectDelegateRejectsEveryFollowableHTTPStatus()
        async throws
    {
        for statusCode in [301, 302, 303, 307, 308] {
            let session = OpenAIRedirectSessionProbe(statusCode: statusCode)
            let transport = URLSessionOpenAIConnectionTransport(
                session: session
            )
            var request = URLRequest(
                url: URL(string: "https://authorized.example.test/original")!
            )
            request.httpMethod = "POST"
            request.setValue(
                "Bearer fixture-secret-must-not-forward",
                forHTTPHeaderField: "Authorization"
            )
            request.httpBody = Data("private-source-text".utf8)

            let response = try await transport.perform(
                request,
                timeoutSeconds: 2
            )

            XCTAssertEqual(response.httpResponse.statusCode, statusCode)
            XCTAssertEqual(session.redirectTargetRequestCount, 0)
            XCTAssertNil(session.redirectedAuthorizationHeader)
            XCTAssertNil(session.redirectedBody)
        }
    }

    func testFoundationURLSessionDispatchesRedirectToPerTaskDenyDelegate()
        async throws
    {
        for statusCode in [301, 302, 303, 307, 308] {
            let fixture = OpenAIFoundationRedirectURLProtocolFixture.State(
                statusCode: statusCode
            )
            OpenAIFoundationRedirectURLProtocolFixture.install(fixture)
            defer { OpenAIFoundationRedirectURLProtocolFixture.reset() }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                OpenAIFoundationRedirectURLProtocolFixture.self,
            ]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let transport = URLSessionOpenAIConnectionTransport(
                session: session
            )
            var request = URLRequest(
                url: URL(
                    string: "https://authorized.example.test/original"
                )!
            )
            request.httpMethod = "POST"
            request.setValue(
                "Bearer foundation-secret-must-not-forward",
                forHTTPHeaderField: "Authorization"
            )
            request.httpBody = Data("foundation-private-source-text".utf8)

            let response = try await transport.perform(
                request,
                timeoutSeconds: 2
            )

            XCTAssertEqual(response.httpResponse.statusCode, statusCode)
            XCTAssertEqual(response.httpResponse.url, request.url)
            XCTAssertEqual(fixture.sourceRequestCount, 1)
            XCTAssertEqual(fixture.targetRequestCount, 0)
            XCTAssertNil(fixture.targetAuthorizationHeader)
            XCTAssertNil(fixture.targetBody)
            XCTAssertTrue(fixture.redirectWasProposed)
        }
    }

    func testOpenAIConnectionAndTranslationClassifyRedirectAsDeniedHTTPError()
        async
    {
        let connection = OpenAICompatibleConnectionService(
            transport: RedirectOpenAIConnectionTransport(statusCode: 307)
        )
        let connectionResult = await connection.testConnection(
            profile: OpenAIConnectionTestProfile(
                providerName: "Fixture Provider",
                baseURL: "https://authorized.example.test/v1",
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 60
            ),
            secretMaterial: Self.fixtureSecretMaterial
        )

        XCTAssertFalse(connectionResult.ok)
        XCTAssertEqual(connectionResult.status, .httpError)
        XCTAssertEqual(connectionResult.httpStatusCode, 307)
        XCTAssertTrue(connectionResult.warnings.contains("redirect_denied"))

        let runtime = OpenAITranslationRuntimeService(
            transport: RedirectOpenAIConnectionTransport(statusCode: 308)
        )
        let translationResult = await runtime.translate(
            text: "private source text",
            sourceLanguageMode: "auto",
            targetLanguage: "zh-Hans",
            profile: OpenAITranslationRuntimeProfile(
                providerName: "Fixture Provider",
                baseURL: "https://authorized.example.test/v1",
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 60
            ),
            secretMaterial: Self.fixtureSecretMaterial
        )

        XCTAssertFalse(translationResult.ok)
        XCTAssertEqual(translationResult.status, .httpError)
        XCTAssertEqual(translationResult.httpStatusCode, 308)
        XCTAssertTrue(translationResult.warnings.contains("redirect_denied"))
        XCTAssertNil(translationResult.outputText)

        let notModified = OpenAICompatibleConnectionService(
            transport: RedirectOpenAIConnectionTransport(statusCode: 304)
        )
        let notModifiedResult = await notModified.testConnection(
            profile: OpenAIConnectionTestProfile(
                providerName: "Fixture Provider",
                baseURL: "https://authorized.example.test/v1",
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 60
            ),
            secretMaterial: Self.fixtureSecretMaterial
        )
        XCTAssertEqual(notModifiedResult.status, .httpError)
        XCTAssertFalse(notModifiedResult.warnings.contains("redirect_denied"))
    }

    func testOpenAIInjectedFoundationTransportBoundsResponseHeaders()
        async throws
    {
        let transport = URLSessionOpenAIConnectionTransport(
            session: OpenAIHeaderSessionProbe()
        )
        let request = URLRequest(
            url: URL(string: "https://provider.example.test/v1")!
        )
        let response = try await transport.perform(request, timeoutSeconds: 1)
        let requestID = response.httpResponse.value(forHTTPHeaderField: "x-request-id")
        XCTAssertEqual(requestID?.utf8.count, 4_096)
        XCTAssertNil(response.httpResponse.value(forHTTPHeaderField: "Set-Cookie"))
    }

    func testNativeOpenAIOperationFailsOversizedResponseOnce()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationOfficialURLProtocolFixture.self]
        let oversized = BlocksNativePluginNetworkPolicy.maximumResponseBytes + 1
        TranslationOfficialURLProtocolFixture.setMode(
            .oversized(contentLength: oversized)
        )
        let operation = NativeURLSessionOpenAIOperation(
            sessionConfiguration: configuration,
            request: URLRequest(url: URL(string: "http://127.0.0.1:5000/v1")!),
            timeoutSeconds: 2
        )
        XCTAssertTrue(operation.start())
        do {
            _ = try await operation.response()
            XCTFail("Expected incremental response-size rejection")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case .responseTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.stopCount, 1)
    }

    func testNativeOpenAIOperationRejectsSynchronousSuccessAfterDeadline()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationOfficialURLProtocolFixture.self]
        TranslationOfficialURLProtocolFixture.setMode(.success)
        let operation = NativeURLSessionOpenAIOperation(
            sessionConfiguration: configuration,
            request: URLRequest(url: URL(string: "http://127.0.0.1:5000/v1")!),
            timeoutSeconds: 1,
            deadlineElapsedOverrideForTesting: true
        )
        let startedAt = ContinuousClock.now

        XCTAssertTrue(operation.start())
        do {
            _ = try await operation.response()
            XCTFail("Expected synchronous success to be rejected at the deadline")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }
        let duration = startedAt.duration(to: .now)
        XCTAssertLessThan(duration, .seconds(0.75))
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.startCount, 1)
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.stopCount, 1)
    }

    func testNativeOpenAIOperationRejectsOversizedContentLengthBeforeBody()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationOfficialURLProtocolFixture.self]
        let oversized = BlocksNativePluginNetworkPolicy.maximumResponseBytes + 1
        TranslationOfficialURLProtocolFixture.setMode(
            .oversizedHeaderOnly(contentLength: oversized)
        )
        let operation = NativeURLSessionOpenAIOperation(
            sessionConfiguration: configuration,
            request: URLRequest(url: URL(string: "http://127.0.0.1:5000/v1")!),
            timeoutSeconds: 2
        )
        XCTAssertTrue(operation.start())
        do {
            _ = try await operation.response()
            XCTFail("Expected content-length response-size rejection")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case .responseTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.bodySendCount, 0)
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.stopCount, 1)
    }

    func testNativeOpenAIOperationRejectsConcurrentSecondResponse()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationOfficialURLProtocolFixture.self]
        TranslationOfficialURLProtocolFixture.setMode(.blocking)
        let operation = NativeURLSessionOpenAIOperation(
            sessionConfiguration: configuration,
            request: URLRequest(url: URL(string: "http://127.0.0.1:5000/v1")!),
            timeoutSeconds: 2
        )
        let firstWaiterInstalled = expectation(
            description: "native first waiter installed"
        )
        let firstWaiterInstalledSignal = TranslationTestExpectationSignal(
            firstWaiterInstalled
        )
        operation.setWaiterInstalledObserverForTesting {
            firstWaiterInstalledSignal.fulfill()
        }
        XCTAssertTrue(operation.start())
        let first = Task { try await operation.response() }
        await fulfillment(of: [firstWaiterInstalled], timeout: 1)
        do {
            _ = try await operation.response()
            XCTFail("Expected single-subscriber rejection")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotLoadFromNetwork)
        }
        operation.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected first waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testNativeOpenAIOperationZeroTimeoutCompletesBeforeURLSessionStart()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationOfficialURLProtocolFixture.self]
        TranslationOfficialURLProtocolFixture.setMode(.blocking)
        let operation = NativeURLSessionOpenAIOperation(
            sessionConfiguration: configuration,
            request: URLRequest(url: URL(string: "http://127.0.0.1:5000/v1")!),
            timeoutSeconds: 0
        )
        XCTAssertFalse(operation.start())
        do {
            _ = try await operation.response()
            XCTFail("Expected shared deadline timeout")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.startCount, 0)
    }

    func testNativeOpenAIOperationBoundsTimeoutInputsBeforeStarting() {
        XCTAssertEqual(
            NativeURLSessionOpenAIOperation.boundedTimeoutSeconds(-1),
            0
        )
        XCTAssertEqual(
            NativeURLSessionOpenAIOperation.boundedTimeoutSeconds(60),
            60
        )
        XCTAssertEqual(
            NativeURLSessionOpenAIOperation.boundedTimeoutSeconds(Int.max),
            86_400
        )
    }

    func testNativeOpenAIOperationNegativeTimeoutCompletesBeforeURLSessionStart()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationOfficialURLProtocolFixture.self]
        TranslationOfficialURLProtocolFixture.setMode(.blocking)
        let operation = NativeURLSessionOpenAIOperation(
            sessionConfiguration: configuration,
            request: URLRequest(url: URL(string: "http://127.0.0.1:5000/v1")!),
            timeoutSeconds: -1
        )
        XCTAssertFalse(operation.start())
        do {
            _ = try await operation.response()
            XCTFail("Expected shared deadline timeout")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.startCount, 0)
    }

    func testOpenAITransportAndConnectionMapLiteralLoopbackZeroTimeout()
        async throws
    {
        let transport = URLSessionOpenAIConnectionTransport()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:5000/v1")!)
        do {
            _ = try await transport.perform(request, timeoutSeconds: 0)
            XCTFail("Expected shared deadline timeout")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }

        let result = await OpenAICompatibleConnectionService(
            transport: transport
        ).testConnection(
            profile: OpenAIConnectionTestProfile(
                providerName: "Fixture",
                baseURL: "http://127.0.0.1:5000/v1",
                modelName: "fixture-model",
                keychainAccountAlias: "fixture-account",
                timeoutSeconds: 0
            ),
            secretMaterial: Self.fixtureSecretMaterial
        )
        XCTAssertEqual(result.status, .timeout)
    }

    func testProviderHTTPRejectsHostnamesThatOnlyLookLikeLoopback()
        async
    {
        let defaults = isolatedDefaults()
        let deceptiveURLs = [
            "http://127.attacker.example/v1",
            "http://127.0.0.1.attacker.example/v1"
        ]
        let transport = CountingOpenAIConnectionTransport()
        let service = OpenAICompatibleConnectionService(transport: transport)

        for deceptiveURL in deceptiveURLs {
            XCTAssertNil(
                ProviderSettingsPersistence.saveProviderBaseURL(
                    deceptiveURL,
                    defaults: defaults
                )
            )
            let result = await service.testConnection(
                profile: OpenAIConnectionTestProfile(
                    providerName: "Fixture Provider",
                    baseURL: deceptiveURL,
                    modelName: "fixture-model",
                    keychainAccountAlias: "fixture-account",
                    timeoutSeconds: 60
                ),
                secretMaterial: Self.fixtureSecretMaterial
            )
            XCTAssertEqual(result.status, .invalidBaseURL)
        }

        XCTAssertEqual(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "http://127.0.0.1:8080/v1",
                defaults: defaults
            ),
            "http://127.0.0.1:8080/v1"
        )
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 0)
    }

    func testOpenAIPinnedHTTPSRejectsPrivateResolutionBeforePinnedTransport()
        async
    {
        let pinned = OpenAIPinnedTransportProbe()
        let transport = URLSessionOpenAIConnectionTransport(
            addressResolver: { _ in [.ipv4("127.0.0.1")] },
            pinnedTransport: { request in try await pinned.perform(request) }
        )
        let request = URLRequest(
            url: URL(string: "https://provider.example.test/v1/chat/completions")!
        )

        do {
            _ = try await transport.perform(request, timeoutSeconds: 1)
            XCTFail("Expected private resolution to be rejected")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case .resolvedAddressDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let invocationCount = await pinned.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testOpenAIPinnedHTTPSDeadlineBoundsNonCooperativeResolver()
        async throws
    {
        let started = expectation(description: "resolver started")
        let finished = expectation(description: "resolver released")
        let startedSignal = TranslationTestExpectationSignal(started)
        let finishedSignal = TranslationTestExpectationSignal(finished)
        let resolver = OpenAISuspendedResolver(
            onStarted: { startedSignal.fulfill() },
            onFinished: { finishedSignal.fulfill() }
        )
        let pinned = OpenAIPinnedTransportProbe()
        let transport = URLSessionOpenAIConnectionTransport(
            addressResolver: { _ in try await resolver.resolve() },
            pinnedTransport: { request in try await pinned.perform(request) }
        )
        let request = URLRequest(url: URL(string: "https://provider.example.test/v1")!)
        let began = ContinuousClock.now
        let task = Task { try await transport.perform(request, timeoutSeconds: 1) }
        await fulfillment(of: [started], timeout: 1)

        do {
            _ = try await task.value
            XCTFail("Expected deadline timeout")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
        let invocationCount = await pinned.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        await resolver.release()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testOpenAIPinnedHTTPSPassesRemainingDeadlineBudget()
        async throws
    {
        let pinned = OpenAIPinnedTransportProbe()
        let transport = URLSessionOpenAIConnectionTransport(
            addressResolver: { _ in
                let began = ContinuousClock.now
                while ContinuousClock.now - began < .milliseconds(50) {}
                return [.ipv4("8.8.8.8")]
            },
            pinnedTransport: { request in try await pinned.perform(request) }
        )
        let request = URLRequest(url: URL(string: "https://provider.example.test/v1")!)
        _ = try await transport.perform(request, timeoutSeconds: 1)
        let observedTimeoutSeconds = await pinned.timeoutSeconds()
        let remaining = try XCTUnwrap(observedTimeoutSeconds)
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThan(remaining, 0.95)
    }

    func testOpenAIPinnedHTTPSDeadlineBoundsNonCooperativePinnedTransport()
        async throws
    {
        let started = expectation(description: "pinned transport started")
        let finished = expectation(description: "pinned transport released")
        let startedSignal = TranslationTestExpectationSignal(started)
        let finishedSignal = TranslationTestExpectationSignal(finished)
        let pinned = OpenAISuspendedPinnedTransport(
            onStarted: { startedSignal.fulfill() },
            onFinished: { finishedSignal.fulfill() }
        )
        let transport = URLSessionOpenAIConnectionTransport(
            addressResolver: { _ in [.ipv4("8.8.8.8")] },
            pinnedTransport: { request in try await pinned.perform(request) }
        )
        let request = URLRequest(url: URL(string: "https://provider.example.test/v1")!)
        let task = Task { try await transport.perform(request, timeoutSeconds: 1) }
        await fulfillment(of: [started], timeout: 1)

        do {
            _ = try await task.value
            XCTFail("Expected deadline timeout")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "The request timed out.")
        }
        await pinned.release()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testProviderRuntimeGateRejectsLocalhostButAllowsLiteralLoopback()
        throws
    {
        XCTAssertNil(ProviderRuntimeGate.normalizedProviderBaseURL("http://localhost:8080/v1"))
        XCTAssertEqual(
            ProviderRuntimeGate.normalizedProviderBaseURL("http://127.0.0.1:8080/v1"),
            "http://127.0.0.1:8080/v1"
        )
        XCTAssertEqual(
            ProviderRuntimeGate.normalizedProviderBaseURL("http://[::1]:8080/v1"),
            "http://[::1]:8080/v1"
        )
    }

    func testProviderRuntimeGateRejectsInvalidExplicitPortsAndPreservesValidPorts()
        throws
    {
        for invalidURL in [
            "https://provider.example.test:0/v1",
            "https://provider.example.test:65536/v1",
            "https://provider.example.test:/v1",
            "https://provider.example.test:999999999999999999999/v1",
        ] {
            XCTAssertNil(
                ProviderRuntimeGate.normalizedProviderBaseURL(invalidURL),
                invalidURL
            )
        }
        XCTAssertEqual(
            ProviderRuntimeGate.normalizedProviderBaseURL(
                "https://provider.example.test:1/v1"
            ),
            "https://provider.example.test:1/v1"
        )
        XCTAssertEqual(
            ProviderRuntimeGate.normalizedProviderBaseURL(
                "https://provider.example.test:65535/v1"
            ),
            "https://provider.example.test:65535/v1"
        )
    }

    func testInvalidProviderPortBlocksConnectionBeforeSecretDNSOrPinnedTransport()
        async
    {
        let defaults = isolatedDefaults()
        let keychain = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret",
            updateStatus: errSecSuccess
        )
        let resolver = TranslationOfficialResolverProbe()
        let pinned = OpenAIPinnedTransportProbe()
        let transport = URLSessionOpenAIConnectionTransport(
            addressResolver: { host in
                await resolver.resolve(host: host)
            },
            pinnedTransport: { request in
                try await pinned.perform(request)
            }
        )
        let store = providerStoreForConnectionTest(
            defaults: defaults,
            transport: transport,
            keychain: keychain
        )

        for invalidURL in [
            "https://provider.example.test:0/v1",
            "https://provider.example.test:65536/v1",
            "https://provider.example.test:/v1",
            "https://provider.example.test:999999999999999999999/v1",
        ] {
            let result = await store.runOpenAIConnectionTest(
                baseURL: invalidURL,
                modelName: "model-a",
                keychainAccountAlias: "account-a"
            )
            XCTAssertEqual(result.status, .invalidBaseURL, invalidURL)
        }

        XCTAssertEqual(keychain.copyMatchingCallCount, 0)
        let resolverCallCount = await resolver.callCount()
        let pinnedInvocationCount = await pinned.invocationCount()
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(pinnedInvocationCount, 0)
    }

    func testOpenAIPinnedHTTPSCallerCancellationReleasesResolverAndPinned()
        async throws
    {
        let resolverStarted = expectation(description: "resolver cancellation started")
        let resolverFinished = expectation(description: "resolver cancellation released")
        let resolverStartedSignal = TranslationTestExpectationSignal(resolverStarted)
        let resolverFinishedSignal = TranslationTestExpectationSignal(resolverFinished)
        let resolver = OpenAISuspendedResolver(
            onStarted: { resolverStartedSignal.fulfill() },
            onFinished: { resolverFinishedSignal.fulfill() }
        )
        let noPinnedTransport = OpenAIPinnedTransportProbe()
        let resolverTransport = URLSessionOpenAIConnectionTransport(
            addressResolver: { _ in try await resolver.resolve() },
            pinnedTransport: { request in
                try await noPinnedTransport.perform(request)
            }
        )
        let request = URLRequest(url: URL(string: "https://provider.example.test/v1")!)
        let resolverTask = Task { try await resolverTransport.perform(request, timeoutSeconds: 10) }
        await fulfillment(of: [resolverStarted], timeout: 1)
        resolverTask.cancel()
        do {
            _ = try await resolverTask.value
            XCTFail("Expected resolver cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let resolverInvocationCount = await noPinnedTransport.invocationCount()
        XCTAssertEqual(resolverInvocationCount, 0)
        await resolver.release()
        await fulfillment(of: [resolverFinished], timeout: 1)

        let pinnedStarted = expectation(description: "pinned cancellation started")
        let pinnedFinished = expectation(description: "pinned cancellation released")
        let pinnedStartedSignal = TranslationTestExpectationSignal(pinnedStarted)
        let pinnedFinishedSignal = TranslationTestExpectationSignal(pinnedFinished)
        let pinned = OpenAISuspendedPinnedTransport(
            onStarted: { pinnedStartedSignal.fulfill() },
            onFinished: { pinnedFinishedSignal.fulfill() }
        )
        let pinnedTransport = URLSessionOpenAIConnectionTransport(
            addressResolver: { _ in [.ipv4("8.8.8.8")] },
            pinnedTransport: { request in try await pinned.perform(request) }
        )
        let pinnedTask = Task { try await pinnedTransport.perform(request, timeoutSeconds: 10) }
        await fulfillment(of: [pinnedStarted], timeout: 1)
        pinnedTask.cancel()
        do {
            _ = try await pinnedTask.value
            XCTFail("Expected pinned cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await pinned.release()
        await fulfillment(of: [pinnedFinished], timeout: 1)
    }

    func testLegacyExternalTransferBooleanFailsClosedUntilTargetIsConfirmed()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1/",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "fixture-account",
                defaults: defaults
            )
        )
        defaults.set(
            true,
            forKey: ProviderSettingsPersistence
                .legacyExternalTransferEnabledKey
        )

        let configuration = OpenAITranslationServiceConfiguration.current(
            defaults: defaults
        )

        XCTAssertFalse(configuration.isComplete)
        XCTAssertNil(configuration.externalTransferGrant)
        XCTAssertNil(
            defaults.object(
                forKey: ProviderSettingsPersistence
                    .legacyExternalTransferEnabledKey
            )
        )
    }

    func testLegacyAndMalformedExternalTransferGrantBlobsFailClosed()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "fixture-account",
                defaults: defaults
            )
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        let targetObject: [String: Any] = [
            "normalizedBaseURL": target.normalizedBaseURL,
            "modelName": target.modelName,
            "keychainAccountAlias": target.keychainAccountAlias,
            "credentialRevision": target.credentialRevision,
        ]
        let blobs = [
            try! JSONSerialization.data(withJSONObject: [
                "version": 1,
                "target": targetObject,
                "generation": 7,
            ]),
            try! JSONSerialization.data(withJSONObject: [
                "version": ProviderExternalTransferGrant.currentVersion,
                "target": targetObject,
            ]),
            Data("not-json".utf8),
        ]

        for blob in blobs {
            defaults.set(
                blob,
                forKey: ProviderSettingsPersistence.externalTransferGrantKey
            )
            XCTAssertNil(
                ProviderSettingsPersistence.externalTransferGrant(
                    defaults: defaults
                )
            )
            XCTAssertNil(
                defaults.data(
                    forKey:
                        ProviderSettingsPersistence.externalTransferGrantKey
                )
            )
            XCTAssertFalse(
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target,
                    defaults: defaults
                )
            )
            XCTAssertFalse(
                ProviderSettingsPersistence.publishExternalTransfer(
                    target: target,
                    grant: nil,
                    defaults: defaults,
                    publication: {}
                )
            )
        }
    }

    func testExternalTransferGrantGenerationExhaustionFailsClosed()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "fixture-account",
                defaults: defaults
            )
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        let historicalGrant = ProviderExternalTransferGrant(
            target: target,
            generation: 1
        )
        defaults.set(
            NSNumber(value: UInt64.max),
            forKey:
                ProviderSettingsPersistence.externalTransferGrantGenerationKey
        )

        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.publishExternalTransfer(
                target: target,
                grant: historicalGrant,
                defaults: defaults,
                publication: {}
            )
        )
    }

    func testExternalTransferGrantBindsDestinationModelAliasAndCredentialRevision()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "HTTPS://EXAMPLE.test:443/v1/",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "model-a",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "account-a",
                defaults: defaults
            )
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertEqual(target.normalizedBaseURL, "https://example.test/v1")
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: target,
                defaults: defaults
            )
        )

        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "model-b",
                defaults: defaults
            )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: target,
                defaults: defaults
            )
        )

        let modelBTarget = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: modelBTarget,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                defaults: defaults
            ),
            1
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
        XCTAssertNotEqual(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            ),
            modelBTarget
        )
    }

    func testExternalTransferGrantReissueInvalidatesCapturedGeneration()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-a", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-a", defaults: defaults
        ))
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        XCTAssertTrue(ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
            for: target, defaults: defaults
        ))
        let grantA = try! XCTUnwrap(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )
        ProviderSettingsPersistence.revokeExternalTransferGrant(defaults: defaults)
        XCTAssertTrue(ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
            for: target, defaults: defaults
        ))
        let grantB = try! XCTUnwrap(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )

        XCTAssertNotEqual(grantA.generation, grantB.generation)
        XCTAssertFalse(ProviderSettingsPersistence.isExternalTransferAuthorized(
            target: target, grant: grantA, defaults: defaults
        ))
        XCTAssertFalse(ProviderSettingsPersistence.publishExternalTransfer(
            target: target, grant: grantA, defaults: defaults, publication: {}
        ))
        XCTAssertTrue(ProviderSettingsPersistence.publishExternalTransfer(
            target: target, grant: grantB, defaults: defaults, publication: {}
        ))
    }

    func testExistingExternalTransferGrantWithoutRevocationFenceMigratesAsAuthorized()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-a", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-a", defaults: defaults
        ))
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence
                .issueExternalTransferGrantForImmediateConfirmation(
                    for: target,
                    defaults: defaults
                )
        )
        let existingGrant = try! XCTUnwrap(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )

        // Builds created before the revocation fence key existed already
        // persisted v2 grants and their allocator. A missing new key migrates
        // as zero rather than revoking a still-valid explicit grant.
        defaults.removeObject(
            forKey: ProviderSettingsPersistence
                .externalTransferRevokedThroughGenerationKey
        )

        XCTAssertEqual(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            ),
            existingGrant
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: target,
                grant: existingGrant,
                defaults: defaults
            )
        )
    }

    func testDurableExternalTransferRevocationRejectsRestoredHistoricalGrant()
    {
        let suite = "TranslationStoreTests.ProviderRevoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-a", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-a", defaults: defaults
        ))
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence
                .issueExternalTransferGrantForImmediateConfirmation(
                    for: target,
                    defaults: defaults
                )
        )
        let historicalGrant = try! XCTUnwrap(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
        let historicalGrantData = try! XCTUnwrap(
            defaults.data(
                forKey: ProviderSettingsPersistence.externalTransferGrantKey
            )
        )

        XCTAssertTrue(
            ProviderSettingsPersistence.revokeExternalTransferGrant(
                defaults: defaults
            )
        )
        let reopened = UserDefaults(suiteName: suite)!
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: reopened
            )
        )

        // Simulate a delayed stale write restoring only the old grant bytes.
        reopened.set(
            historicalGrantData,
            forKey: ProviderSettingsPersistence.externalTransferGrantKey
        )
        XCTAssertTrue(reopened.synchronize())
        let restored = UserDefaults(suiteName: suite)!
        var startCount = 0
        XCTAssertFalse(
            ProviderSettingsPersistence.admitExternalTransfer(
                target: target,
                grant: historicalGrant,
                defaults: restored,
                start: {
                    startCount += 1
                    return true
                }
            )
        )
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: restored
            )
        )
        let revokedThrough = (
            restored.object(
                forKey: ProviderSettingsPersistence
                    .externalTransferRevokedThroughGenerationKey
            ) as? NSNumber
        )?.uint64Value
        XCTAssertNotNil(revokedThrough)
        XCTAssertGreaterThan(
            revokedThrough ?? 0,
            historicalGrant.generation
        )
    }

    func testExternalTransferRevocationPersistenceFailureRemainsFailClosed()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-a", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-a", defaults: defaults
        ))
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence
                .issueExternalTransferGrantForImmediateConfirmation(
                    for: target,
                    defaults: defaults
                )
        )

        var synchronizationResults = [true, false]
        var synchronizationCount = 0
        XCTAssertFalse(
            ProviderSettingsPersistence.revokeExternalTransferGrant(
                defaults: defaults,
                synchronize: { defaults in
                    synchronizationCount += 1
                    let result = synchronizationResults.removeFirst()
                    if result {
                        _ = defaults.synchronize()
                    }
                    return result
                }
            )
        )
        XCTAssertEqual(synchronizationCount, 2)
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
        var startCount = 0
        XCTAssertFalse(
            ProviderSettingsPersistence.admitExternalTransfer(
                target: target,
                defaults: defaults,
                start: {
                    startCount += 1
                    return true
                }
            )
        )
        XCTAssertEqual(startCount, 0)
    }

    func testExternalTransferRevocationInvalidatesSuspendedConfirmationIntent()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-a", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-a", defaults: defaults
        ))
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        let suspendedIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)

        XCTAssertTrue(
            ProviderSettingsPersistence.revokeExternalTransferGrant(
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ProviderSettingsPersistence
                .isExternalTransferAuthorizationIntentCurrent(
                    suspendedIntent,
                    defaults: defaults
                )
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: suspendedIntent,
                defaults: defaults
            )
        )

        let freshIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: freshIntent,
                defaults: defaults
            )
        )
        let freshGrant = try! XCTUnwrap(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
        let revokedThrough = try! XCTUnwrap(
            defaults.object(
                forKey: ProviderSettingsPersistence
                    .externalTransferRevokedThroughGenerationKey
            ) as? NSNumber
        ).uint64Value
        XCTAssertGreaterThan(freshGrant.generation, revokedThrough)
    }

    func testConfigurationSavePreservesOnlyItsCurrentAuthorizationIntent()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://old.example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-old", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-old", defaults: defaults
        ))
        let authorizationIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)

        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-new",
            preserving: authorizationIntent,
            defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://new.example.test/v1",
            preserving: authorizationIntent,
            defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-new",
            preserving: authorizationIntent,
            defaults: defaults
        ))
        XCTAssertTrue(
            ProviderSettingsPersistence
                .isExternalTransferAuthorizationIntentCurrent(
                    authorizationIntent,
                    defaults: defaults
                )
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: authorizationIntent,
                defaults: defaults
            )
        )

        let staleIntent = authorizationIntent
        XCTAssertTrue(
            ProviderSettingsPersistence.revokeExternalTransferGrant(
                defaults: defaults
            )
        )
        XCTAssertNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-must-not-commit",
            preserving: staleIntent,
            defaults: defaults
        ))
        XCTAssertEqual(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )?.modelName,
            "model-new"
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
    }

    func testLaterCredentialMutationSupersedesEarlierConfirmationIntent()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-a", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-a", defaults: defaults
        ))

        let firstIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: firstIntent,
                defaults: defaults
            ),
            1
        )
        let secondIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        XCTAssertFalse(
            ProviderSettingsPersistence
                .isExternalTransferAuthorizationIntentCurrent(
                    firstIntent,
                    defaults: defaults
                )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: firstIntent,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: secondIntent,
                defaults: defaults
            ),
            2
        )

        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: firstIntent,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: secondIntent,
                defaults: defaults
            )
        )

        let pendingThirdConfirmation = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                defaults: defaults
            ),
            3
        )
        XCTAssertFalse(
            ProviderSettingsPersistence
                .isExternalTransferAuthorizationIntentCurrent(
                    pendingThirdConfirmation,
                    defaults: defaults
                )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
    }

    func testBoundAuthorizationIntentPreparesOnlyOneCredentialRevision()
    {
        let defaults = isolatedDefaults()
        configureProviderTarget(defaults: defaults)
        let intent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)

        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: intent,
                defaults: defaults
            ),
            1
        )
        XCTAssertNil(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: intent,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            ProviderSettingsPersistence.credentialRevision(defaults: defaults),
            1
        )

        let boundTarget = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        let differentRevisionTarget = ProviderExternalTransferTarget(
            baseURL: boundTarget.normalizedBaseURL,
            modelName: boundTarget.modelName,
            keychainAccountAlias: boundTarget.keychainAccountAlias,
            credentialRevision: 2
        )!
        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: differentRevisionTarget,
                authorizationIntent: intent,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: boundTarget,
                authorizationIntent: intent,
                defaults: defaults
            )
        )
    }

    func testBoundIntentGrantIsConsumedWhileImmediateConfirmationRemainsUsable()
    {
        let defaults = isolatedDefaults()
        configureProviderTarget(defaults: defaults)
        let intent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: intent,
                defaults: defaults
            ),
            1
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )

        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: intent,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: intent,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
    }

    func testIntentInvalidationPreservesGrantAndMalformedBindingRecoversOnlyAfterCapture()
    {
        let defaults = isolatedDefaults()
        configureProviderTarget(defaults: defaults)
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        let intent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)

        XCTAssertTrue(
            ProviderSettingsPersistence.invalidateExternalTransferAuthorizationIntent(
                ifCurrent: intent,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: target,
                defaults: defaults
            )
        )

        let malformedIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        defaults.set(
            Data("malformed binding".utf8),
            forKey: ProviderSettingsPersistence
                .externalTransferAuthorizationIntentMutationBindingKey
        )
        XCTAssertNil(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: malformedIntent,
                defaults: defaults
            )
        )
        let halfPersistedIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        defaults.set(
            "half-persisted binding",
            forKey: ProviderSettingsPersistence
                .externalTransferAuthorizationIntentMutationBindingKey
        )
        XCTAssertNil(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: halfPersistedIntent,
                defaults: defaults
            )
        )
        let recoveredIntent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)
        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                preserving: recoveredIntent,
                defaults: defaults
            ),
            1
        )
    }

    @MainActor
    func testCancelledSameAliasSaveRecoveryNeverRestoresStoredStateOrAuthorization()
        async throws
    {
        let suite = "TranslationStoreTests.ProviderCancel.sameAlias.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let alias = "cancelled-save-alias"
        let originalTarget = configureProviderUserSecretMutationDefaults(
            defaults: defaults,
            alias: alias
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: originalTarget,
                defaults: defaults
            )
        )
        let securityAPI = BlockingProviderKeychainSecurityAPI(blockPoint: .update)
        securityAPI.seedUserSecret(alias: alias, credentialRevision: 0)
        defer { securityAPI.release() }
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )
        let session = TranslationOpenAIServiceEditorSaveSession()
        let operation = session.begin(defaults: defaults)
        let mutation = Task { @MainActor in
            await store.performProviderUserSecretGate(
                action: .saveOrReplace,
                accountAlias: alias,
                secretCandidate: "fixture-secret",
                authorizationIntent: operation.authorizationIntent
            )
        }

        let securityBlocked = await securityAPI.waitUntilBlocked()
        XCTAssertTrue(securityBlocked)
        mutation.cancel()
        XCTAssertTrue(session.invalidate(defaults: defaults) ?? false)
        securityAPI.release()
        let cancelledOutcome = await mutation.value

        XCTAssertFalse(cancelledOutcome.operationSucceeded)
        XCTAssertTrue(securityAPI.containsUserSecret(alias: alias))
        XCTAssertTrue(
            ProviderSettingsPersistence.hasPendingCredentialMutation(defaults: defaults)
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))

        let transport = CountingOpenAIConnectionTransport()
        let restartedStore = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: UserDefaults(suiteName: suite)!
        )
        await waitForPendingCredentialMutationRecovery(defaults: defaults, pending: false)

        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.missing.rawValue
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        let recoveredTarget = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        let keychainReadsBeforeAdmission = securityAPI.copyMatchingCalls()
        let rejected = await restartedStore.runOpenAIConnectionTest(
            baseURL: recoveredTarget.normalizedBaseURL,
            modelName: recoveredTarget.modelName,
            keychainAccountAlias: recoveredTarget.keychainAccountAlias
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.status, .confirmationRequired)
        XCTAssertEqual(
            securityAPI.copyMatchingCalls(),
            keychainReadsBeforeAdmission
        )
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)

        let explicitSave = await restartedStore.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: alias,
            secretCandidate: "replacement-secret"
        )
        XCTAssertTrue(explicitSave.operationSucceeded)
        XCTAssertEqual(
            explicitSave.lifecycleRawValue,
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
    }

    @MainActor
    func testCancelledAliasMigrationRecoveryPersistsDestinationNoticeUntilExactRemoval()
        async throws
    {
        let suite = "TranslationStoreTests.ProviderCancel.aliasMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let sourceAlias = "cancelled-source-alias"
        let destinationAlias = "cancelled-destination-alias"
        let originalTarget = configureProviderUserSecretMutationDefaults(
            defaults: defaults,
            alias: sourceAlias
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: originalTarget,
                defaults: defaults
            )
        )
        let securityAPI = BlockingProviderKeychainSecurityAPI(blockPoint: .update)
        securityAPI.seedUserSecret(alias: sourceAlias, credentialRevision: 0)
        defer { securityAPI.release() }
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )
        let session = TranslationOpenAIServiceEditorSaveSession()
        let operation = session.begin(defaults: defaults)
        let mutation = Task { @MainActor in
            await store.performProviderUserSecretGate(
                action: .saveOrReplace,
                accountAlias: destinationAlias,
                secretCandidate: "fixture-secret",
                replacingAccountAlias: sourceAlias,
                authorizationIntent: operation.authorizationIntent
            )
        }

        let securityBlocked = await securityAPI.waitUntilBlocked()
        XCTAssertTrue(securityBlocked)
        mutation.cancel()
        XCTAssertTrue(session.invalidate(defaults: defaults) ?? false)
        securityAPI.release()
        let cancelledOutcome = await mutation.value
        XCTAssertFalse(cancelledOutcome.operationSucceeded)

        let transport = CountingOpenAIConnectionTransport()
        let restartedStore = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: UserDefaults(suiteName: suite)!
        )
        let recoveryNoticePublished = expectation(
            description: "cancelled alias migration notice is published after startup recovery"
        )
        var publishedRecoveryNotice: ProviderCancelledAliasMigrationRecoveryNotice?
        let recoveryNoticeObserver = restartedStore
            .$cancelledAliasMigrationRecoveryNoticeState
            .sink { state in
                guard publishedRecoveryNotice == nil,
                      case let .valid(notice) = state else {
                    return
                }
                publishedRecoveryNotice = notice
                recoveryNoticePublished.fulfill()
            }
        defer { recoveryNoticeObserver.cancel() }
        await fulfillment(of: [recoveryNoticePublished], timeout: 1)
        await waitForAliasMigrationRecovery(defaults: defaults, pending: false)

        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            sourceAlias
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            sourceAlias
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.missing.rawValue
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertTrue(securityAPI.containsUserSecret(alias: destinationAlias))
        XCTAssertFalse(securityAPI.containsUserSecret(alias: sourceAlias))
        let notice = try XCTUnwrap({
            if case let .valid(notice) =
                ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeState(
                    defaults: defaults
                ) {
                return notice
            }
            return nil
        }())
        XCTAssertEqual(notice.destinationAlias, destinationAlias)
        XCTAssertEqual(notice.sourceAlias, sourceAlias)
        XCTAssertEqual(publishedRecoveryNotice, notice)
        XCTAssertEqual(
            restartedStore.cancelledAliasMigrationRecoveryNoticeState,
            .valid(notice)
        )

        let recoveredTarget = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        let keychainReadsBeforeAdmission = securityAPI.copyMatchingCalls()
        let rejected = await restartedStore.runOpenAIConnectionTest(
            baseURL: recoveredTarget.normalizedBaseURL,
            modelName: recoveredTarget.modelName,
            keychainAccountAlias: recoveredTarget.keychainAccountAlias
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.status, .confirmationRequired)
        XCTAssertEqual(
            securityAPI.copyMatchingCalls(),
            keychainReadsBeforeAdmission
        )
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)

        let blockedSave = await restartedStore.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: sourceAlias,
            secretCandidate: "replacement-secret"
        )
        XCTAssertFalse(blockedSave.operationSucceeded)
        let recoveryDelete = await restartedStore.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: destinationAlias
        )
        XCTAssertTrue(recoveryDelete.operationSucceeded)
        XCTAssertFalse(securityAPI.containsUserSecret(alias: destinationAlias))
        XCTAssertEqual(
            ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeState(
                defaults: defaults
            ),
            .absent
        )
        XCTAssertEqual(
            restartedStore.cancelledAliasMigrationRecoveryNoticeState,
            .absent
        )
        let explicitSave = await restartedStore.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: sourceAlias,
            secretCandidate: "replacement-secret"
        )
        XCTAssertTrue(explicitSave.operationSucceeded)
    }

    @MainActor
    func testCancelledAliasMigrationNoticeRetainsBlockWhenDestinationRemovalFails()
        async throws
    {
        let defaults = isolatedDefaults()
        let sourceAlias = "notice-source"
        let destinationAlias = "notice-destination"
        _ = configureProviderUserSecretMutationDefaults(defaults: defaults, alias: sourceAlias)
        let notice = try XCTUnwrap(
            ProviderCancelledAliasMigrationRecoveryNotice(
                sourceAlias: sourceAlias,
                destinationAlias: destinationAlias,
                credentialRevision: 1
            )
        )
        defaults.set(
            try JSONEncoder().encode(notice),
            forKey: ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI(
            deleteStatus: errSecAuthFailed
        )
        securityAPI.seedUserSecret(alias: destinationAlias, credentialRevision: 1)
        let transport = CountingOpenAIConnectionTransport()
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            openAIConnectionService: OpenAICompatibleConnectionService(transport: transport),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )

        let failedDelete = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: destinationAlias
        )
        XCTAssertFalse(failedDelete.operationSucceeded)
        let blockedSave = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: sourceAlias,
            secretCandidate: "replacement-secret"
        )
        XCTAssertFalse(blockedSave.operationSucceeded)
        XCTAssertEqual(
            ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeState(
                defaults: defaults
            ),
            .valid(notice)
        )
        let target = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        let rejected = await store.runOpenAIConnectionTest(
            baseURL: target.normalizedBaseURL,
            modelName: target.modelName,
            keychainAccountAlias: target.keychainAccountAlias
        )
        XCTAssertFalse(rejected.ok)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    @MainActor
    func testMalformedCancelledAliasMigrationNoticeBlocksCredentialMutation()
        async
    {
        let defaults = isolatedDefaults()
        defaults.set(
            Data("malformed notice".utf8),
            forKey: ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeKey
        )
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: AliasTrackingProviderKeychainSecurityAPI()
            ),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )
        let outcome = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: "blocked-by-malformed-notice",
            secretCandidate: "fixture-secret"
        )
        XCTAssertFalse(outcome.operationSucceeded)
        XCTAssertEqual(
            ProviderSettingsPersistence.cancelledAliasMigrationRecoveryNoticeState(
                defaults: defaults
            ),
            .malformed
        )
    }

    @MainActor
    func testStaleCancellationIntentDoesNotTombstoneCurrentPendingMutation()
        async
    {
        let defaults = isolatedDefaults()
        let alias = "stale-cancel-alias"
        _ = configureProviderUserSecretMutationDefaults(defaults: defaults, alias: alias)
        let securityAPI = BlockingProviderKeychainSecurityAPI(blockPoint: .update)
        securityAPI.seedUserSecret(alias: alias, credentialRevision: 0)
        defer { securityAPI.release() }
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )
        let staleSession = TranslationOpenAIServiceEditorSaveSession()
        _ = staleSession.begin(defaults: defaults)
        let currentSession = TranslationOpenAIServiceEditorSaveSession()
        let currentOperation = currentSession.begin(defaults: defaults)
        let mutation = Task { @MainActor in
            await store.performProviderUserSecretGate(
                action: .saveOrReplace,
                accountAlias: alias,
                secretCandidate: "fixture-secret",
                authorizationIntent: currentOperation.authorizationIntent
            )
        }

        let securityBlocked = await securityAPI.waitUntilBlocked()
        XCTAssertTrue(securityBlocked)
        XCTAssertFalse(staleSession.invalidate(defaults: defaults) ?? true)
        securityAPI.release()
        let outcome = await mutation.value

        XCTAssertTrue(outcome.operationSucceeded)
        XCTAssertFalse(
            ProviderSettingsPersistence.hasPendingCredentialMutation(defaults: defaults)
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
    }

    func testDismissedSaveSessionRejectsResumedPersistenceAndGrant()
        async
    {
        let defaults = isolatedDefaults()
        configureProviderTarget(defaults: defaults)
        let session = TranslationOpenAIServiceEditorSaveSession()
        let operation = session.begin(defaults: defaults)
        let suspended = expectation(description: "save operation suspended")
        let suspensionSignal = TranslationTestExpectationSignal(suspended)
        let resume = ProviderSaveSessionSuspension(
            onSuspend: { suspensionSignal.fulfill() }
        )
        var didPersistAfterResume = false
        var didIssueGrantAfterResume = false

        let saveTask = Task { @MainActor in
            await resume.wait()
            guard session.isCurrent(
                sessionID: operation.sessionID,
                authorizationIntent: operation.authorizationIntent,
                confirmsSecretStorage: true,
                confirmsExternalTransfer: true,
                defaults: defaults
            ) else {
                return
            }
            didPersistAfterResume = ProviderSettingsPersistence
                .saveProviderModelName(
                    "must-not-persist",
                    preserving: operation.authorizationIntent,
                    defaults: defaults
                ) != nil
            if let target = ProviderSettingsPersistence
                .currentExternalTransferTarget(defaults: defaults) {
                didIssueGrantAfterResume = ProviderSettingsPersistence
                    .issueExternalTransferGrant(
                        for: target,
                        authorizationIntent: operation.authorizationIntent,
                        defaults: defaults
                    )
            }
        }

        await fulfillment(of: [suspended], timeout: 1)
        XCTAssertTrue(session.shouldInvalidateOnDisappear)
        XCTAssertTrue(session.invalidate(defaults: defaults) ?? false)
        await resume.release()
        await saveTask.value

        XCTAssertFalse(didPersistAfterResume)
        XCTAssertFalse(didIssueGrantAfterResume)
        XCTAssertEqual(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )?.modelName,
            "fixture-model"
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )
    }

    func testSavingInteractionPolicyKeepsCancellationAndDismissalAvailable()
    {
        let policy = TranslationOpenAIServiceEditorInteractionPolicy(
            isSaving: true,
            canSave: true
        )

        XCTAssertTrue(policy.formDisabled)
        XCTAssertTrue(policy.saveDisabled)
        XCTAssertFalse(policy.cancelDisabled)
        XCTAssertFalse(policy.interactiveDismissDisabled)
    }

    @MainActor
    func testBlockedAliasMigrationInvalidationReturnsBeforeSecurityAndLeavesRecovery()
        async
    {
        let suite = "TranslationStoreTests.ProviderLock.alias.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldAlias = "lock-old-alias"
        let newAlias = "lock-new-alias"
        let oldTarget = configureProviderUserSecretMutationDefaults(
            defaults: defaults,
            alias: oldAlias
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: oldTarget,
                defaults: defaults
            )
        )
        let securityAPI = BlockingProviderKeychainSecurityAPI(
            blockPoint: .update
        )
        securityAPI.seedUserSecret(alias: oldAlias, credentialRevision: 0)
        defer { securityAPI.release() }
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )
        let session = TranslationOpenAIServiceEditorSaveSession()
        let operation = session.begin(defaults: defaults)
        let mutation = Task { @MainActor in
            await store.performProviderUserSecretGate(
                action: .saveOrReplace,
                accountAlias: newAlias,
                secretCandidate: "fixture-secret",
                replacingAccountAlias: oldAlias,
                authorizationIntent: operation.authorizationIntent
            )
        }

        let securityBlocked = await securityAPI.waitUntilBlocked()
        XCTAssertTrue(securityBlocked)
        let invalidationReturned = expectation(
            description: "intent invalidation returns while Security is blocked"
        )
        var invalidationResult: Bool?
        mutation.cancel()
        Task { @MainActor in
            invalidationResult = session.invalidate(defaults: defaults)
            invalidationReturned.fulfill()
        }
        await fulfillment(of: [invalidationReturned], timeout: 1)
        XCTAssertTrue(invalidationResult ?? false)

        securityAPI.release()
        let outcome = await mutation.value

        XCTAssertFalse(outcome.operationSucceeded)
        XCTAssertTrue(
            securityAPI.containsUserSecret(alias: newAlias)
        )
        XCTAssertFalse(
            securityAPI.containsUserSecret(alias: oldAlias)
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            oldAlias
        )
        XCTAssertEqual(
            defaults.string(
                forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
            ),
            oldAlias
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            "missing"
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.hasPendingAliasMigration(
                defaults: defaults
            )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )
    }

    @MainActor
    func testAliasMigrationSettlementBeforeDismissalKeepsCommittedDefaults()
        async
    {
        let suite = "TranslationStoreTests.ProviderLock.settlement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldAlias = "settlement-old-alias"
        let newAlias = "settlement-new-alias"
        _ = configureProviderUserSecretMutationDefaults(
            defaults: defaults,
            alias: oldAlias
        )
        let securityAPI = BlockingProviderKeychainSecurityAPI(blockPoint: .none)
        securityAPI.seedUserSecret(alias: oldAlias, credentialRevision: 0)
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )
        let session = TranslationOpenAIServiceEditorSaveSession()
        let operation = session.begin(defaults: defaults)

        let outcome = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: newAlias,
            secretCandidate: "fixture-secret",
            replacingAccountAlias: oldAlias,
            authorizationIntent: operation.authorizationIntent
        )
        XCTAssertTrue(outcome.operationSucceeded)
        session.finishSuccess()

        XCTAssertFalse(session.shouldInvalidateOnDisappear)
        XCTAssertTrue(securityAPI.containsUserSecret(alias: newAlias))
        XCTAssertFalse(securityAPI.containsUserSecret(alias: oldAlias))
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            newAlias
        )
        XCTAssertEqual(
            defaults.string(
                forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
            ),
            newAlias
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            "user_secret_stored"
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.hasPendingAliasMigration(
                defaults: defaults
            )
        )
    }

    @MainActor
    func testBlockedCredentialRecoveryQueryDoesNotDelayIntentInvalidation()
        async
    {
        let suite = "TranslationStoreTests.ProviderLock.recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let alias = "recovery-alias"
        let target = configureProviderUserSecretMutationDefaults(
            defaults: defaults,
            alias: alias
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        let securityAPI = BlockingProviderKeychainSecurityAPI(
            blockPoint: .copyMatching(call: 2)
        )
        securityAPI.seedUserSecret(alias: alias, credentialRevision: 0)
        defer { securityAPI.release() }
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )
        let session = TranslationOpenAIServiceEditorSaveSession()
        let operation = session.begin(defaults: defaults)
        let mutation = Task { @MainActor in
            await store.performProviderUserSecretGate(
                action: .saveOrReplace,
                accountAlias: alias,
                secretCandidate: "fixture-secret",
                authorizationIntent: operation.authorizationIntent
            )
        }

        let securityBlocked = await securityAPI.waitUntilBlocked()
        XCTAssertTrue(securityBlocked)
        let invalidationReturned = expectation(
            description: "intent invalidation returns during recovery query"
        )
        var invalidationResult: Bool?
        mutation.cancel()
        Task { @MainActor in
            invalidationResult = session.invalidate(defaults: defaults)
            invalidationReturned.fulfill()
        }
        await fulfillment(of: [invalidationReturned], timeout: 1)
        XCTAssertTrue(invalidationResult ?? false)

        securityAPI.release()
        let outcome = await mutation.value

        XCTAssertFalse(outcome.operationSucceeded)
        XCTAssertTrue(securityAPI.containsUserSecret(alias: alias))
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            alias
        )
        XCTAssertEqual(
            defaults.string(
                forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
            ),
            alias
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            "missing"
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.hasPendingCredentialMutation(
                defaults: defaults
            )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )
    }

    @MainActor
    func testNilIntentUserSecretMutationStillSettlesNormally()
        async
    {
        let suite = "TranslationStoreTests.ProviderLock.nilIntent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let alias = "nil-intent-alias"
        let target = configureProviderUserSecretMutationDefaults(
            defaults: defaults,
            alias: alias
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        let securityAPI = BlockingProviderKeychainSecurityAPI(blockPoint: .none)
        securityAPI.seedUserSecret(alias: alias, credentialRevision: 0)
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults,
            recoverPendingCredentialStateOnInitialization: false
        )

        let outcome = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: alias,
            secretCandidate: "fixture-secret"
        )

        XCTAssertTrue(outcome.operationSucceeded)
        XCTAssertTrue(securityAPI.containsUserSecret(alias: alias))
        XCTAssertEqual(
            ProviderSettingsPersistence.credentialRevision(defaults: defaults),
            1
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            alias
        )
        XCTAssertEqual(
            defaults.string(
                forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
            ),
            alias
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            "user_secret_stored"
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.hasPendingCredentialMutation(
                defaults: defaults
            )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )
    }

    func testMalformedExternalTransferWatermarkPermanentlyFailsClosed()
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "model-a", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            "account-a", defaults: defaults
        ))
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        defaults.set(
            "corrupted-watermark",
            forKey: ProviderSettingsPersistence
                .externalTransferRevokedThroughGenerationKey
        )
        let intent = ProviderSettingsPersistence
            .captureExternalTransferAuthorizationIntent(defaults: defaults)

        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrant(
                for: target,
                authorizationIntent: intent,
                defaults: defaults
            )
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: defaults
            )
        )
        XCTAssertEqual(
            (
                defaults.object(
                    forKey: ProviderSettingsPersistence
                        .externalTransferRevokedThroughGenerationKey
                ) as? NSNumber
            )?.uint64Value,
            UInt64.max
        )
        XCTAssertEqual(
            (
                defaults.object(
                    forKey: ProviderSettingsPersistence
                        .externalTransferGrantGenerationKey
                ) as? NSNumber
            )?.uint64Value,
            UInt64.max
        )
    }

    func testProviderAuditIDsKeepFullIdentityWhileDisplayRemainsCompact()
        throws
    {
        let uuidA = try XCTUnwrap(
            UUID(uuidString: "12345678-0000-4000-8000-000000000001")
        )
        let uuidB = try XCTUnwrap(
            UUID(uuidString: "12345678-0000-4000-8000-000000000002")
        )
        let auditIDA = ProviderAuditID.make(prefix: "llm_test", uuid: uuidA)
        let auditIDB = ProviderAuditID.make(prefix: "llm_test", uuid: uuidB)
        let eventA = ProviderAuditEvent(
            id: auditIDA,
            createdAt: Date(timeIntervalSince1970: 1),
            kind: .openAIConnectionTest,
            action: .connectionTest,
            outcome: .completed,
            confirmationLevel: .externalTransfer,
            auditID: auditIDA
        )
        let eventB = ProviderAuditEvent(
            id: auditIDB,
            createdAt: Date(timeIntervalSince1970: 2),
            kind: .openAIConnectionTest,
            action: .connectionTest,
            outcome: .completed,
            confirmationLevel: .externalTransfer,
            auditID: auditIDB
        )

        XCTAssertNotEqual(auditIDA, auditIDB)
        XCTAssertNotEqual(eventA.id, eventB.id)
        XCTAssertEqual(
            ProviderAuditID.display(auditIDA),
            "llm_test_12345678"
        )
        XCTAssertEqual(
            ProviderAuditID.display(auditIDB),
            "llm_test_12345678"
        )
        XCTAssertEqual(
            ProviderAuditID.display("legacy_short_id"),
            "legacy_short_id"
        )
    }

    func testOpenAIAdapterFinalPublicationRevocationRedactsCompletedEvent()
        async
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderModelName(
            "fixture-model", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderAccountAlias(
            "fixture-account", defaults: defaults
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target, defaults: defaults
            )
        )
        let secretMaterial = Self.fixtureSecretMaterial(
            credentialRevision: target.credentialRevision
        )
        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let currentConfiguration = OpenAITranslationServiceConfiguration.current(
            defaults: authorizationDefaults.value
        )
        let transport = CountingOpenAIConnectionTransport()
        let auditProbe = TranslationRuntimeAuditProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { currentConfiguration },
            readProviderSecret: { _ in secretMaterial },
            authorizationValidator: { target, grant in
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target, grant: grant,
                    defaults: authorizationDefaults.value
                )
            },
            admissionValidator: { target, grant, start in
                ProviderSettingsPersistence.admitExternalTransfer(
                    target: target, grant: grant,
                    defaults: authorizationDefaults.value, start: start
                )
            },
            publicationValidator: { target, grant, publication in
                ProviderSettingsPersistence.revokeExternalTransferGrant(
                    defaults: authorizationDefaults.value
                )
                return ProviderSettingsPersistence.publishExternalTransfer(
                    target: target, grant: grant,
                    defaults: authorizationDefaults.value, publication: publication
                )
            }
        )
        var completedTexts: [String] = []
        var completedAuditIDs: [String] = []

        do {
            for try await event in adapter.translate(Self.openAIRequest()) {
                guard case let .completed(text, _, diagnostics) = event else {
                    continue
                }
                completedTexts.append(text)
                if let diagnostics {
                    completedAuditIDs.append(diagnostics.auditID)
                }
            }
            XCTFail("Expected final publication rejection")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error, .publicationRejected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 1)
        XCTAssertTrue(completedTexts.isEmpty)
        XCTAssertTrue(completedAuditIDs.isEmpty)
        XCTAssertNil(auditProbe.result)
        XCTAssertFalse(String(describing: completedTexts).contains("fixture"))
    }

    func testOpenAIAdapterRejectsStaleGrantAfterReissueAndAllowsCurrentGrant()
        async throws
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderModelName(
            "fixture-model", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderAccountAlias(
            "fixture-account", defaults: defaults
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target, defaults: defaults
            )
        )
        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let configurationA = OpenAITranslationServiceConfiguration.current(
            defaults: authorizationDefaults.value
        )
        let secretMaterial = Self.fixtureSecretMaterial(
            credentialRevision: configurationA.credentialRevision
        )
        let grantA = try! XCTUnwrap(configurationA.externalTransferGrant)
        let validator: @Sendable (ProviderExternalTransferTarget,
            ProviderExternalTransferGrant?) -> Bool = { target, grant in
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: target, grant: grant,
                defaults: authorizationDefaults.value
            )
        }
        let publicationValidator: @Sendable (ProviderExternalTransferTarget,
            ProviderExternalTransferGrant?, () -> Void) -> Bool = {
                target, grant, publication in
                ProviderSettingsPersistence.publishExternalTransfer(
                    target: target, grant: grant,
                    defaults: authorizationDefaults.value, publication: publication
                )
        }
        let staleTransport = CountingOpenAIConnectionTransport()
        let staleAuditProbe = TranslationRuntimeAuditProbe()
        let staleAdapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: staleTransport,
                auditHandler: { staleAuditProbe.record($0) }
            ),
            configuration: { configurationA },
            readProviderSecret: { _ in secretMaterial },
            authorizationValidator: validator,
            admissionValidator: { target, grant, start in
                ProviderSettingsPersistence.admitExternalTransfer(
                    target: target, grant: grant,
                    defaults: authorizationDefaults.value, start: start
                )
            },
            publicationValidator: { target, grant, publication in
                ProviderSettingsPersistence.revokeExternalTransferGrant(
                    defaults: authorizationDefaults.value
                )
                guard ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                    for: target, defaults: authorizationDefaults.value
                ) else { return false }
                return ProviderSettingsPersistence.publishExternalTransfer(
                    target: target, grant: grant,
                    defaults: authorizationDefaults.value, publication: publication
                )
            }
        )

        do {
            for try await _ in staleAdapter.translate(Self.openAIRequest()) {}
            XCTFail("A stale grant must not publish after reissue")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(error, .publicationRejected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let staleTransportCallCount = await staleTransport.callCount()
        XCTAssertEqual(staleTransportCallCount, 1)
        XCTAssertNil(staleAuditProbe.result)
        let grantB = try! XCTUnwrap(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: authorizationDefaults.value
            )
        )
        XCTAssertNotEqual(grantA.generation, grantB.generation)

        let currentTransport = CountingOpenAIConnectionTransport()
        let currentAuditProbe = TranslationRuntimeAuditProbe()
        let currentAdapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: currentTransport,
                auditHandler: { currentAuditProbe.record($0) }
            ),
            configuration: { .current(defaults: authorizationDefaults.value) },
            readProviderSecret: { _ in secretMaterial },
            authorizationValidator: validator,
            admissionValidator: { target, grant, start in
                ProviderSettingsPersistence.admitExternalTransfer(
                    target: target, grant: grant,
                    defaults: authorizationDefaults.value, start: start
                )
            },
            publicationValidator: publicationValidator
        )
        var completedText: String?
        for try await event in currentAdapter.translate(Self.openAIRequest()) {
            if case let .completed(text, _, _) = event {
                completedText = text
            }
        }

        let currentTransportCallCount = await currentTransport.callCount()
        XCTAssertEqual(currentTransportCallCount, 1)
        XCTAssertEqual(completedText, "fixture")
        XCTAssertEqual(currentAuditProbe.result?.outputText, "fixture")
    }

    func testConnectionFinalPublicationRevocationRedactsSuccessfulResponse()
        async
    {
        let defaults = isolatedDefaults()
        let transport = CountingOpenAIConnectionTransport()
        let keychain = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret", updateStatus: errSecSuccess
        )
        let store = providerStoreForConnectionTest(
            defaults: defaults, transport: transport, keychain: keychain
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        store.openAIConnectionFinalPublicationHook = {
            ProviderSettingsPersistence.revokeExternalTransferGrant(defaults: defaults)
        }

        let result = await store.runOpenAIConnectionTest(
            baseURL: target.normalizedBaseURL,
            modelName: target.modelName,
            keychainAccountAlias: target.keychainAccountAlias
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertNil(result.responseTextCharacterCount)
        XCTAssertNil(result.secretLength)
        XCTAssertTrue(result.warnings.contains("result_publication_rejected"))
        XCTAssertTrue(result.warnings.contains("provider_response_redacted"))
        XCTAssertFalse(result.warnings.contains("provider_call_not_executed"))
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 1)
        XCTAssertFalse(store.providerAuditEvents.contains {
            $0.kind == .openAIConnectionTest
        })
        XCTAssertNil(store.openAIConnectionLastResult)
        XCTAssertNil(store.providerUserSecretLastResult)
    }

    func testConnectionSecretReadRunsOffMainActorAndDoesNotBlockMainActor()
        async
    {
        let defaults = isolatedDefaults()
        let readStarted = expectation(description: "provider keychain read started")
        let securityAPI = BlockingThreadTrackingProviderKeychainSecurityAPI(
            storedSecret: "fixture-secret",
            onCopyMatching: { readStarted.fulfill() }
        )
        let store = providerStoreForConnectionTest(
            defaults: defaults,
            transport: SuccessfulTranslationTransport(),
            keychain: securityAPI
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )

        let run = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: target.normalizedBaseURL,
                modelName: target.modelName,
                keychainAccountAlias: target.keychainAccountAlias
            )
        }
        await fulfillment(of: [readStarted], timeout: 1)

        let heartbeat = expectation(description: "main actor remains schedulable")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)

        let blockedSnapshot = securityAPI.snapshot
        XCTAssertEqual(blockedSnapshot.copyMatchingCallCount, 1)
        XCTAssertEqual(blockedSnapshot.mainThreadCallCount, 0)
        securityAPI.release()

        let result = await run.value
        XCTAssertTrue(result.ok)
        XCTAssertFalse(securityAPI.snapshot.didTimeOutWaitingForRelease)
    }

    func testConnectionRejectsCredentialRevisionMismatchBeforeTransport()
        async
    {
        let defaults = isolatedDefaults()
        let transport = CountingOpenAIConnectionTransport()
        let keychain = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret",
            updateStatus: errSecSuccess,
            storedCredentialRevision: 1
        )
        let store = providerStoreForConnectionTest(
            defaults: defaults,
            transport: transport,
            keychain: keychain
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )

        let result = await store.runOpenAIConnectionTest(
            baseURL: target.normalizedBaseURL,
            modelName: target.modelName,
            keychainAccountAlias: target.keychainAccountAlias
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .missingSecret)
        XCTAssertEqual(store.openAIConnectionLastResult?.status, .missingSecret)
        XCTAssertEqual(keychain.copyMatchingCallCount, 1)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testProviderKeychainSecurityOperationsRunOffMainActor()
        async
    {
        let defaults = isolatedDefaults()
        let underlying = AliasTrackingProviderKeychainSecurityAPI()
        let securityAPI = ThreadTrackingProviderKeychainSecurityAPI(
            underlying: underlying
        )
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )

        let firstSave = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: "account-a",
            secretCandidate: "fixture-secret-a"
        )
        XCTAssertTrue(firstSave.operationSucceeded)
        let replacement = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: "account-b",
            secretCandidate: "fixture-secret-b",
            replacingAccountAlias: "account-a"
        )
        XCTAssertTrue(replacement.operationSucceeded)
        let deletion = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: "account-b"
        )
        XCTAssertTrue(deletion.operationSucceeded)

        for action in [
            ProviderKeychainGateAction.saveTestSecret,
            .rotateTestSecret,
            .deleteTestSecret,
            .verifyMissing,
        ] {
            let outcome = await store.performProviderKeychainGate(
                action: action,
                accountAlias: "fixture-low-sensitive",
                providerSummary: "Fixture Provider"
            )
            XCTAssertTrue(outcome.operationSucceeded)
        }

        let snapshot = securityAPI.snapshot
        XCTAssertEqual(snapshot.mainThreadCallCount, 0)
        XCTAssertTrue(snapshot.calls.contains(.add))
        XCTAssertTrue(snapshot.calls.contains(.update))
        XCTAssertTrue(snapshot.calls.contains(.delete))
        XCTAssertTrue(snapshot.calls.contains(.copyMatching))
    }

    func testCredentialMutationRevokesGrantBeforeFirstSecurityCall()
        async
    {
        let suiteName =
            "TranslationStoreTests.CredentialMutation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://a.example.test/v1", defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "model-a", defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "account-a", defaults: defaults
            )
        )
        let grantedTarget = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: grantedTarget, defaults: defaults
            )
        )

        let orderingProbe = ProviderCredentialMutationOrderingSecurityAPI(
            suiteName: suiteName,
            previouslyGrantedTarget: grantedTarget,
            underlying: AliasTrackingProviderKeychainSecurityAPI()
        )
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: orderingProbe
            ),
            defaults: defaults
        )
        let save = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: "account-a",
            secretCandidate: "fixture-secret"
        )
        XCTAssertTrue(save.operationSucceeded)

        let orderingSnapshot = orderingProbe.snapshot
        XCTAssertTrue(orderingSnapshot.didObserveSecurityCall)
        XCTAssertFalse(orderingSnapshot.oldGrantWasAuthorized)
        XCTAssertEqual(orderingSnapshot.credentialRevision, 1)

        let restartedDefaults = UserDefaults(suiteName: suiteName)!
        let restartedTransport = CountingOpenAIConnectionTransport()
        let restartedKeychain = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret", updateStatus: errSecSuccess
        )
        let restartedStore = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: restartedKeychain
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: restartedTransport
            ),
            defaults: restartedDefaults
        )
        let rejected = await restartedStore.runOpenAIConnectionTest(
            baseURL: grantedTarget.normalizedBaseURL,
            modelName: grantedTarget.modelName,
            keychainAccountAlias: grantedTarget.keychainAccountAlias
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.status, .confirmationRequired)
        let restartedTransportCallCount = await restartedTransport.callCount()
        XCTAssertEqual(restartedTransportCallCount, 0)
        XCTAssertEqual(restartedKeychain.copyMatchingCallCount, 0)
    }

    func testCredentialMutationPreparationFailsClosedBeforeJournalExists()
    {
        let suiteName =
            "TranslationStoreTests.CredentialPreparation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let alias = "account-a"
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "model-a",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                alias,
                defaults: defaults
            )
        )
        defaults.set(
            alias,
            forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
        )
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        let oldTarget = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: oldTarget,
                defaults: defaults
            )
        )

        XCTAssertEqual(
            ProviderSettingsPersistence.prepareCredentialMutation(
                defaults: defaults
            ),
            1
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.hasPendingCredentialMutation(
                defaults: defaults
            )
        )

        let restartedDefaults = UserDefaults(suiteName: suiteName)!
        let lifecycle = ProviderSecretLifecycleState(
            rawValue: restartedDefaults.string(
                forKey: ProviderSettingsPersistence.secretLifecycleStateKey
            ) ?? ""
        ) ?? .missing
        XCTAssertEqual(lifecycle, .missing)
        XCTAssertEqual(
            restartedDefaults.string(
                forKey:
                    ProviderSettingsPersistence.storedSecretAccountAliasKey
            ),
            alias
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(
                defaults: restartedDefaults
            )
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.hasStoredSecret(
                lifecycleStateRawValue: lifecycle.rawValue,
                storedAccountAlias: alias,
                currentAccountAlias: alias
            )
        )

        let readiness = ProviderConnectionReadiness.make(
            apiKeychainAccountAlias: alias,
            apiBaseURL: "https://example.test/v1",
            apiModelName: "model-a",
            secretLifecycleState: lifecycle
        )
        XCTAssertFalse(readiness.ready)
        XCTAssertFalse(
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: oldTarget,
                defaults: restartedDefaults
            )
        )
    }

    func testChangingProviderBaseURLPathRevokesGrantBeforeSecretOrTransport()
        async
    {
        await assertProviderDestinationChangeRevokesGrantBeforeExternalTransfer {
            defaults in
            XCTAssertNotNil(
                ProviderSettingsPersistence.saveProviderBaseURL(
                    "https://host.example.test/tenant-b",
                    defaults: defaults
                )
            )
        }
    }

    func testChangingProviderAccountAliasRevokesGrantBeforeSecretOrTransport()
        async
    {
        await assertProviderDestinationChangeRevokesGrantBeforeExternalTransfer {
            defaults in
            XCTAssertNotNil(
                ProviderSettingsPersistence.saveProviderAccountAlias(
                    "alias-b",
                    defaults: defaults
                )
            )
        }
    }

    func testTranslationRevalidatesExternalGrantAfterSecretReadBeforeTransport()
        async
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1",
            defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderModelName(
            "fixture-model",
            defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderAccountAlias(
            "fixture-account",
            defaults: defaults
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let transport = CountingOpenAIConnectionTransport()
        var secretReadCount = 0
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport
            ),
            defaults: authorizationDefaults.value,
            configuration: {
                .current(defaults: defaults)
            },
            readProviderSecret: { _ in
                secretReadCount += 1
                ProviderSettingsPersistence.revokeExternalTransferGrant(
                    defaults: defaults
                )
                return Self.fixtureSecretMaterial
            },
            authorizationValidator: { target, grant in
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value
                )
            }
        )

        do {
            for try await _ in adapter.translate(Self.openAIRequest()) {}
            XCTFail("Expected revoked transfer publication to be rejected")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(
                error,
                .publicationRejected
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transportCallCount = await transport.callCount()
        XCTAssertEqual(secretReadCount, 1)
        XCTAssertEqual(transportCallCount, 0)
    }

    func testInvalidProviderBaseURLPreservesPreviouslyPersistedBaseURL() {
        let defaults = isolatedDefaults()
        let committedBaseURL = "https://example.test/v1"
        defaults.set(
            committedBaseURL,
            forKey: ProviderSettingsPersistence.baseURLKey
        )

        XCTAssertNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "not a URL",
                defaults: defaults
            )
        )
        XCTAssertEqual(
            ProviderSettingsPersistence.storedProviderBaseURL(defaults: defaults),
            committedBaseURL
        )
    }

    func testStoredSecretDeletionUsesSavedAliasAfterAliasIsEdited()
        async throws
    {
        let defaults = isolatedDefaults()
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )
        let aliasA = "account-a"
        let aliasB = "account-b"
        let save = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasA,
            secretCandidate: "fixture-secret"
        )
        XCTAssertEqual(
            save.lifecycleRawValue,
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            aliasA
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            aliasA
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )

        let storedAlias = ProviderSettingsPersistence.normalizedAccountAlias(aliasA)
        XCTAssertFalse(
            ProviderSettingsPersistence.hasStoredSecret(
                lifecycleStateRawValue: save.lifecycleRawValue,
                storedAccountAlias: storedAlias,
                currentAccountAlias: aliasB
            )
        )

        let deletion = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: storedAlias
        )
        XCTAssertEqual(
            deletion.lifecycleRawValue,
            ProviderSecretLifecycleState.userSecretDeletedVerified.rawValue
        )
        XCTAssertEqual(securityAPI.deletedAccounts, ["openai-compatible:\(aliasA)"])
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasA)"))
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.userSecretDeletedVerified.rawValue
        )
        XCTAssertNil(defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey))
    }

    func testPendingSameAliasSaveRecoveryCommitsDefaultsAndRejectsOldGrant()
        async throws
    {
        let defaults = isolatedDefaults()
        let oldAlias = "account-old"
        let newAlias = "account-new"
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderModelName(
            "fixture-model", defaults: defaults
        ))
        XCTAssertNotNil(ProviderSettingsPersistence.saveProviderAccountAlias(
            oldAlias, defaults: defaults
        ))
        defaults.set(NSNumber(value: 7), forKey: ProviderSettingsPersistence.credentialRevisionKey)
        let oldTarget = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        defaults.set(
            try JSONEncoder().encode(ProviderExternalTransferGrant(target: oldTarget, generation: 1)),
            forKey: ProviderSettingsPersistence.externalTransferGrantKey
        )
        XCTAssertNotNil(ProviderSettingsPersistence.beginPendingCredentialMutation(
            kind: .save, alias: newAlias, credentialRevision: 7, defaults: defaults
        ))
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        securityAPI.seedUserSecret(alias: newAlias, credentialRevision: 7)

        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            defaults: defaults
        )
        await waitForPendingCredentialMutationRecovery(defaults: defaults, pending: false)
        _ = store

        XCTAssertEqual(defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey), newAlias)
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            newAlias
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertFalse(ProviderSettingsPersistence.isExternalTransferAuthorized(
            target: oldTarget,
            defaults: defaults
        ))
    }

    func testPendingSameAliasDeleteRecoveryCommitsDefaults() async {
        let defaults = isolatedDefaults()
        let alias = "account-delete"
        defaults.set(alias, forKey: ProviderSettingsPersistence.accountAliasKey)
        defaults.set(alias, forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey)
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(NSNumber(value: 9), forKey: ProviderSettingsPersistence.credentialRevisionKey)
        XCTAssertNotNil(ProviderSettingsPersistence.beginPendingCredentialMutation(
            kind: .delete, alias: alias, credentialRevision: 9, defaults: defaults
        ))

        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: AliasTrackingProviderKeychainSecurityAPI()
            ),
            defaults: defaults
        )
        await waitForPendingCredentialMutationRecovery(defaults: defaults, pending: false)
        _ = store

        XCTAssertEqual(defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey), alias)
        XCTAssertNil(defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey))
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.userSecretDeletedVerified.rawValue
        )
    }

    func testUnsubmittedPendingSameAliasSaveMarksMissingAndStaysRevoked() async {
        let defaults = isolatedDefaults()
        let alias = "account-unsubmitted"
        defaults.set(alias, forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey)
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(NSNumber(value: 10), forKey: ProviderSettingsPersistence.credentialRevisionKey)
        XCTAssertNotNil(ProviderSettingsPersistence.beginPendingCredentialMutation(
            kind: .save, alias: alias, credentialRevision: 10, defaults: defaults
        ))

        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: AliasTrackingProviderKeychainSecurityAPI()
            ),
            defaults: defaults
        )
        await waitForPendingCredentialMutationRecovery(defaults: defaults, pending: false)
        _ = store

        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.missing.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            alias
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
    }

    func testInconsistentPendingSameAliasSaveRemainsFailClosed() async {
        let defaults = isolatedDefaults()
        let alias = "account-inconsistent"
        defaults.set(NSNumber(value: 11), forKey: ProviderSettingsPersistence.credentialRevisionKey)
        XCTAssertNotNil(ProviderSettingsPersistence.beginPendingCredentialMutation(
            kind: .save, alias: alias, credentialRevision: 11, defaults: defaults
        ))
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        securityAPI.seedUserSecret(alias: alias, credentialRevision: 10)
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(securityAPI: securityAPI),
            defaults: defaults
        )
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(ProviderSettingsPersistence.hasPendingCredentialMutation(defaults: defaults))
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        let outcome = await store.performProviderUserSecretGate(
            action: .verifyStored,
            accountAlias: alias
        )
        XCTAssertFalse(outcome.operationSucceeded)
        XCTAssertTrue(ProviderSettingsPersistence.hasPendingCredentialMutation(defaults: defaults))
    }

    func testProviderStoreWithoutPendingAliasMigrationKeepsActiveConfiguration()
        async
    {
        let defaults = isolatedDefaults()
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )
        let fingerprint = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "account-a",
            credentialRevision: 0
        )
        store.activateOpenAIConnectionConfiguration(fingerprint)

        _ = await store.performProviderUserSecretGate(
            action: .verifyMissing,
            accountAlias: "account-a"
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertTrue(store.isActiveOpenAIConnectionConfiguration(fingerprint))
    }

    func testSavingSecretUnderNewAliasAtomicallyReplacesPreviousAlias()
        async throws
    {
        let defaults = isolatedDefaults()
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )
        let aliasA = "account-a"
        let aliasB = "account-b"

        let firstSave = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasA,
            secretCandidate: "fixture-secret-a"
        )
        XCTAssertTrue(firstSave.operationSucceeded)

        let replacement = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasB,
            secretCandidate: "fixture-secret-b",
            replacingAccountAlias: aliasA
        )
        XCTAssertTrue(replacement.operationSucceeded)
        XCTAssertEqual(
            replacement.lifecycleRawValue,
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
        XCTAssertFalse(
            securityAPI.containsSecret(for: "openai-compatible:\(aliasA)")
        )
        XCTAssertTrue(
            securityAPI.containsSecret(for: "openai-compatible:\(aliasB)")
        )
        XCTAssertTrue(securityAPI.deletedAccounts.isEmpty)
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            aliasB
        )
        XCTAssertEqual(
            defaults.string(
                forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
            ),
            aliasB
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.hasPendingAliasMigration(defaults: defaults)
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))

        let deletion = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: aliasB
        )
        XCTAssertTrue(deletion.operationSucceeded)
        XCTAssertFalse(
            securityAPI.containsSecret(for: "openai-compatible:\(aliasA)")
        )
        XCTAssertFalse(
            securityAPI.containsSecret(for: "openai-compatible:\(aliasB)")
        )
    }

    func testAliasMigrationRecoveryCommitsDestinationAndAllowsDeletion()
        async throws
    {
        let defaults = isolatedDefaults()
        let aliasA = "account-a"
        let aliasB = "account-b"
        let revision: UInt64 = 7
        defaults.set(aliasA, forKey: ProviderSettingsPersistence.accountAliasKey)
        defaults.set(aliasA, forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey)
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(
            NSNumber(value: revision),
            forKey: ProviderSettingsPersistence.credentialRevisionKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        securityAPI.seedUserSecret(alias: aliasB, credentialRevision: revision)
        XCTAssertNotNil(
            ProviderSettingsPersistence.beginPendingAliasMigration(
                sourceAlias: aliasA,
                destinationAlias: aliasB,
                credentialRevision: revision,
                defaults: defaults
            )
        )

        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )
        await waitForAliasMigrationRecovery(defaults: defaults, pending: false)

        XCTAssertEqual(defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey), aliasB)
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            aliasB
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))

        let deletion = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: aliasB
        )
        XCTAssertTrue(deletion.operationSucceeded)
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))
    }

    func testRecoveredAliasMigrationRejectsStaleReplacingAliasWithoutSideEffects()
        async throws
    {
        let defaults = isolatedDefaults()
        let aliasA = "account-a"
        let aliasB = "account-b"
        let aliasC = "account-c"
        let revision: UInt64 = 7
        defaults.set(aliasA, forKey: ProviderSettingsPersistence.accountAliasKey)
        defaults.set(
            aliasA,
            forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
        )
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(
            NSNumber(value: revision),
            forKey: ProviderSettingsPersistence.credentialRevisionKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        securityAPI.seedUserSecret(alias: aliasB, credentialRevision: revision)
        XCTAssertNotNil(
            ProviderSettingsPersistence.beginPendingAliasMigration(
                sourceAlias: aliasA,
                destinationAlias: aliasB,
                credentialRevision: revision,
                defaults: defaults
            )
        )

        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )
        await waitForAliasMigrationRecovery(defaults: defaults, pending: false)
        let securityOperationCountAfterRecovery = securityAPI.operationCount

        let outcome = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasC,
            secretCandidate: "fixture-secret-c",
            replacingAccountAlias: aliasA
        )

        XCTAssertFalse(outcome.operationSucceeded)
        XCTAssertEqual(securityAPI.operationCount, securityOperationCountAfterRecovery)
        XCTAssertEqual(
            ProviderSettingsPersistence.credentialRevision(defaults: defaults),
            revision
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.hasPendingAliasMigration(defaults: defaults)
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.hasPendingCredentialMutation(defaults: defaults)
        )
        XCTAssertEqual(
            defaults.string(
                forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
            ),
            aliasB
        )
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasC)"))
    }

    func testAliasMigrationRecoveryClearsUncommittedJournalAndKeepsSourceDefaults()
        async throws
    {
        let defaults = isolatedDefaults()
        let aliasA = "account-a"
        let aliasB = "account-b"
        let revision: UInt64 = 8
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        defaults.set(aliasA, forKey: ProviderSettingsPersistence.accountAliasKey)
        defaults.set(aliasA, forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey)
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(
            NSNumber(value: revision),
            forKey: ProviderSettingsPersistence.credentialRevisionKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        securityAPI.seedUserSecret(alias: aliasA, credentialRevision: revision - 1)
        XCTAssertNotNil(
            ProviderSettingsPersistence.beginPendingAliasMigration(
                sourceAlias: aliasA,
                destinationAlias: aliasB,
                credentialRevision: revision,
                defaults: defaults
            )
        )

        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )
        _ = store
        await waitForAliasMigrationRecovery(defaults: defaults, pending: false)

        XCTAssertEqual(defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey), aliasA)
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            aliasA
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.missing.rawValue
        )
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasA)"))
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))

        let target = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        defaults.set(
            try JSONEncoder().encode(
                ProviderExternalTransferGrant(target: target, generation: 1)
            ),
            forKey: ProviderSettingsPersistence.externalTransferGrantKey
        )
        let transport = CountingOpenAIConnectionTransport()
        let recoveredStore = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: defaults
        )
        _ = await recoveredStore.runOpenAIConnectionTest(
            baseURL: target.normalizedBaseURL,
            modelName: target.modelName,
            keychainAccountAlias: target.keychainAccountAlias
        )
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testAliasMigrationDestinationConflictClearsJournalWithoutTouchingEitherSecret()
        async throws
    {
        let defaults = isolatedDefaults()
        let aliasA = "account-a"
        let aliasB = "account-b"
        let revision: UInt64 = 10
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                aliasA,
                defaults: defaults
            )
        )
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(
            NSNumber(value: revision),
            forKey: ProviderSettingsPersistence.credentialRevisionKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        let rawSecretA = Data("legacy-raw-secret-a".utf8)
        let rawSecretB = Data("legacy-raw-secret-b".utf8)
        securityAPI.seedRawUserSecret(alias: aliasA, data: rawSecretA)
        securityAPI.seedRawUserSecret(alias: aliasB, data: rawSecretB)
        XCTAssertNotNil(
            ProviderSettingsPersistence.beginPendingAliasMigration(
                sourceAlias: aliasA,
                destinationAlias: aliasB,
                credentialRevision: revision,
                defaults: defaults
            )
        )
        let target = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        defaults.set(
            try JSONEncoder().encode(
                ProviderExternalTransferGrant(target: target, generation: 1)
            ),
            forKey: ProviderSettingsPersistence.externalTransferGrantKey
        )
        let transport = CountingOpenAIConnectionTransport()

        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: defaults
        )
        await waitForAliasMigrationRecovery(defaults: defaults, pending: false)

        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.missing.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            aliasA
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertEqual(
            securityAPI.rawSecret(for: "openai-compatible:\(aliasA)"),
            rawSecretA
        )
        XCTAssertEqual(
            securityAPI.rawSecret(for: "openai-compatible:\(aliasB)"),
            rawSecretB
        )
        _ = await store.runOpenAIConnectionTest(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: aliasA
        )
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)

        let deleteA = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: aliasA
        )
        XCTAssertTrue(deleteA.operationSucceeded)
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasA)"))
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))

        let saveB = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasB,
            secretCandidate: "fixture-secret-b"
        )
        XCTAssertTrue(saveB.operationSucceeded)
        XCTAssertEqual(
            saveB.lifecycleRawValue,
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
    }

    func testAliasMigrationDestinationConflictWithIdenticalBytesClearsJournalAfterStoreRebuild()
        async throws
    {
        let defaults = isolatedDefaults()
        let aliasA = "account-a"
        let aliasB = "account-b"
        let revision: UInt64 = 10
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                aliasA,
                defaults: defaults
            )
        )
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(
            NSNumber(value: revision),
            forKey: ProviderSettingsPersistence.credentialRevisionKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        securityAPI.seedUserSecret(alias: aliasA, credentialRevision: revision)
        let identicalSecret = try XCTUnwrap(
            securityAPI.rawSecret(for: "openai-compatible:\(aliasA)")
        )
        securityAPI.seedRawUserSecret(alias: aliasB, data: identicalSecret)
        XCTAssertEqual(
            securityAPI.rawSecret(for: "openai-compatible:\(aliasA)"),
            securityAPI.rawSecret(for: "openai-compatible:\(aliasB)")
        )
        let target = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.beginPendingAliasMigration(
                sourceAlias: aliasA,
                destinationAlias: aliasB,
                credentialRevision: revision,
                defaults: defaults
            )
        )
        let transport = CountingOpenAIConnectionTransport()
        let recoveredStore = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: defaults
        )

        await waitForAliasMigrationRecovery(defaults: defaults, pending: false)

        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.missing.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey),
            aliasA
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasA)"))
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))
        _ = await recoveredStore.runOpenAIConnectionTest(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: aliasA
        )
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)

        let deleteA = await recoveredStore.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: aliasA
        )
        XCTAssertTrue(deleteA.operationSucceeded)
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasA)"))
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))

        let saveB = await recoveredStore.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasB,
            secretCandidate: "fixture-secret-b"
        )
        XCTAssertTrue(saveB.operationSucceeded)
        XCTAssertEqual(
            saveB.lifecycleRawValue,
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
    }

    func testAliasMigrationDuplicateDestinationClearsJournalInSameMutation()
        async throws
    {
        let defaults = isolatedDefaults()
        let aliasA = "account-a"
        let aliasB = "account-b"
        let revision: UInt64 = 10
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                aliasA,
                defaults: defaults
            )
        )
        defaults.set(
            aliasA,
            forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
        )
        defaults.set(
            ProviderSecretLifecycleState.userSecretStored.rawValue,
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        defaults.set(
            NSNumber(value: revision),
            forKey: ProviderSettingsPersistence.credentialRevisionKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        let rawSecretA = Data("legacy-raw-secret-a".utf8)
        let rawSecretB = Data("legacy-raw-secret-b".utf8)
        securityAPI.seedRawUserSecret(alias: aliasA, data: rawSecretA)
        securityAPI.seedRawUserSecret(alias: aliasB, data: rawSecretB)
        let target = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        let transport = CountingOpenAIConnectionTransport()
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: defaults
        )

        let replacement = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasB,
            secretCandidate: "fixture-secret-b",
            replacingAccountAlias: aliasA
        )
        XCTAssertFalse(replacement.operationSucceeded)
        await waitForAliasMigrationRecovery(defaults: defaults, pending: false)

        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.secretLifecycleStateKey),
            ProviderSecretLifecycleState.missing.rawValue
        )
        XCTAssertEqual(
            ProviderSettingsPersistence.credentialRevision(defaults: defaults),
            revision + 1
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertEqual(
            securityAPI.rawSecret(for: "openai-compatible:\(aliasA)"),
            rawSecretA
        )
        XCTAssertEqual(
            securityAPI.rawSecret(for: "openai-compatible:\(aliasB)"),
            rawSecretB
        )
        _ = await store.runOpenAIConnectionTest(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: aliasA
        )
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)

        let deleteA = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: aliasA
        )
        XCTAssertTrue(deleteA.operationSucceeded)
        XCTAssertFalse(securityAPI.containsSecret(for: "openai-compatible:\(aliasA)"))
        XCTAssertTrue(securityAPI.containsSecret(for: "openai-compatible:\(aliasB)"))

        let saveB = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasB,
            secretCandidate: "fixture-secret-b"
        )
        XCTAssertTrue(saveB.operationSucceeded)
        XCTAssertEqual(
            saveB.lifecycleRawValue,
            ProviderSecretLifecycleState.userSecretStored.rawValue
        )
    }

    func testMalformedAliasMigrationJournalStaysPendingAndBlocksSecurityGrantAndTransport()
        async throws
    {
        let defaults = isolatedDefaults()
        defaults.set(
            Data("not-a-journal".utf8),
            forKey: ProviderSettingsPersistence.pendingAliasMigrationJournalKey
        )
        try await assertInvalidAliasMigrationJournalFailsClosed(defaults: defaults)
    }

    func testWrongTypeAliasMigrationJournalStaysPendingAndBlocksSecurityGrantAndTransport()
        async throws
    {
        let defaults = isolatedDefaults()
        defaults.set(
            "not-journal-data",
            forKey: ProviderSettingsPersistence.pendingAliasMigrationJournalKey
        )
        try await assertInvalidAliasMigrationJournalFailsClosed(defaults: defaults)
    }

    func testInconsistentAliasMigrationStaysPendingAndBlocksGrantAndTransport()
        async throws
    {
        let defaults = isolatedDefaults()
        let aliasA = "account-a"
        let aliasB = "account-b"
        let revision: UInt64 = 9
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                aliasA,
                defaults: defaults
            )
        )
        defaults.set(
            NSNumber(value: revision),
            forKey: ProviderSettingsPersistence.credentialRevisionKey
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI()
        securityAPI.seedUserSecret(alias: aliasB, credentialRevision: revision - 1)
        XCTAssertNotNil(
            ProviderSettingsPersistence.beginPendingAliasMigration(
                sourceAlias: aliasA,
                destinationAlias: aliasB,
                credentialRevision: revision,
                defaults: defaults
            )
        )
        let target = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        defaults.set(
            try JSONEncoder().encode(
                ProviderExternalTransferGrant(target: target, generation: 1)
            ),
            forKey: ProviderSettingsPersistence.externalTransferGrantKey
        )
        let transport = CountingOpenAIConnectionTransport()
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: defaults
        )

        await waitForAliasMigrationRecovery(defaults: defaults, pending: true)
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        _ = await store.runOpenAIConnectionTest(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: aliasA
        )
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testFailedSecretAliasMigrationKeepsPreviousAliasManageable()
        async throws
    {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "account-a",
                defaults: defaults
            )
        )
        let securityAPI = AliasTrackingProviderKeychainSecurityAPI(
            aliasMigrationStatus: errSecAuthFailed
        )
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            defaults: defaults
        )
        let aliasA = "account-a"
        let aliasB = "account-b"

        let firstSave = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasA,
            secretCandidate: "fixture-secret-a"
        )
        XCTAssertTrue(firstSave.operationSucceeded)
        let grantedTarget = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertEqual(grantedTarget.credentialRevision, 1)
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: grantedTarget,
                defaults: defaults
            )
        )

        let replacement = await store.performProviderUserSecretGate(
            action: .saveOrReplace,
            accountAlias: aliasB,
            secretCandidate: "fixture-secret-b",
            replacingAccountAlias: aliasA
        )
        XCTAssertFalse(replacement.operationSucceeded)
        XCTAssertTrue(
            securityAPI.containsSecret(for: "openai-compatible:\(aliasA)")
        )
        XCTAssertFalse(
            securityAPI.containsSecret(for: "openai-compatible:\(aliasB)")
        )
        XCTAssertEqual(
            defaults.string(forKey: ProviderSettingsPersistence.accountAliasKey),
            aliasA
        )
        XCTAssertEqual(
            ProviderSettingsPersistence.credentialRevision(defaults: defaults),
            2
        )
        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: grantedTarget,
                defaults: defaults
            )
        )
    }

    func testLegacyStoredProviderSecretAliasMigratesWithoutLosingLifecycle()
    {
        XCTAssertEqual(
            ProviderSettingsPersistence.migratedStoredAccountAlias(
                lifecycleStateRawValue:
                    ProviderSecretLifecycleState.userSecretStored.rawValue,
                storedAccountAlias: "",
                currentAccountAlias: " legacy-account "
            ),
            "legacy-account"
        )
        XCTAssertNil(
            ProviderSettingsPersistence.migratedStoredAccountAlias(
                lifecycleStateRawValue:
                    ProviderSecretLifecycleState.missing.rawValue,
                storedAccountAlias: "",
                currentAccountAlias: "legacy-account"
            )
        )
    }

    func testStaleOpenAIConnectionResultDoesNotReplaceActiveConfiguration()
        async throws
    {
        let transport = SuspendedOpenAIConnectionTransport()
        let store = providerStoreForConnectionTest(transport: transport)
        let configurationA = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        let configurationB = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://b.example.test/v1",
            modelName: "model-b",
            keychainAccountAlias: "account-b"
        )
        store.activateOpenAIConnectionConfiguration(configurationA)

        let runA = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configurationA.baseURL,
                modelName: configurationA.modelName,
                keychainAccountAlias: configurationA.keychainAccountAlias,
                configurationFingerprint: configurationA
            )
        }
        await transport.waitUntilStarted()
        store.activateOpenAIConnectionConfiguration(configurationB)
        await transport.resume()
        let completedResult = await runA.value

        XCTAssertNil(store.openAIConnectionLastResult)
        let connectionAudit = try XCTUnwrap(
            store.providerAuditEvents.first { $0.kind == .openAIConnectionTest }
        )
        XCTAssertEqual(connectionAudit.auditID, completedResult.auditID)
        XCTAssertEqual(connectionAudit.action, .connectionTest)
    }

    func testDeactivatingConnectionConfigurationDropsLateResult()
        async
    {
        let transport = SuspendedOpenAIConnectionTransport()
        let store = providerStoreForConnectionTest(transport: transport)
        let configuration = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        store.activateOpenAIConnectionConfiguration(configuration)

        let run = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilStarted()
        store.deactivateOpenAIConnectionConfiguration()
        await transport.resume()
        _ = await run.value

        XCTAssertNil(store.openAIConnectionLastResult)
    }

    func testCredentialDeletionInvalidatesInFlightConnectionResult()
        async throws
    {
        let defaults = isolatedDefaults()
        let transport = SuspendedOpenAIConnectionTransport()
        let keychain = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret",
            updateStatus: errSecSuccess
        )
        let store = providerStoreForConnectionTest(
            defaults: defaults,
            transport: transport,
            keychain: keychain
        )
        let configuration = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a",
            credentialRevision: store.providerCredentialRevision
        )
        store.activateOpenAIConnectionConfiguration(configuration)

        let run = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilStarted()

        let deletion = await store.performProviderUserSecretGate(
            action: .deleteStored,
            accountAlias: configuration.keychainAccountAlias
        )
        XCTAssertEqual(deletion.lifecycleRawValue, "user_secret_deleted_verified")
        XCTAssertEqual(store.providerCredentialRevision, 1)
        XCTAssertNil(store.openAIConnectionLastResult)

        await transport.resume()
        _ = await run.value

        XCTAssertNil(store.openAIConnectionLastResult)
        XCTAssertFalse(store.providerAuditEvents.contains {
            $0.kind == .openAIConnectionTest
        })
    }

    func testProviderCoordinatorDoesNotPublishHookRewrittenModelForActiveConfiguration()
        async
    {
        let defaults = isolatedDefaults()
        let transport = CountingOpenAIConnectionTransport()
        let keychain = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret",
            updateStatus: errSecSuccess
        )
        let store = providerStoreForConnectionTest(
            defaults: defaults,
            transport: transport,
            keychain: keychain
        )
        var recordedStatuses: [AppStatus] = []
        var dispatchedEvents: [BlocksPluginEventName] = []
        let configurationA = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        store.activateOpenAIConnectionConfiguration(configurationA)
        let coordinator = ProviderFeatureCoordinator(providerStore: store)
        coordinator.configure(
            statusRecorder: { recordedStatuses.append($0) },
            selectedProviderSummary: { "Fixture Provider" },
            selectedProviderRequiresExternalTransfer: { true },
            publishRouteResolution: { _ in },
            dispatchPluginEvent: { envelope in
                dispatchedEvents.append(envelope.name)
                guard envelope.name == .providerWillSendRequest else {
                    return .allowed(envelope)
                }
                var payload = envelope.payload
                payload["model"] = .string("model-b")
                return .allowed(
                    BlocksPluginEventEnvelope(
                        name: envelope.name,
                        causationID: envelope.causationID,
                        authorization: envelope.authorization,
                        payload: payload
                    )
                )
            }
        )

        await coordinator.runOpenAIConnectionTest(
            baseURL: configurationA.baseURL,
            modelName: configurationA.modelName,
            keychainAccountAlias: configurationA.keychainAccountAlias,
            configurationFingerprint: configurationA
        )

        XCTAssertNil(store.openAIConnectionLastResult)
        let connectionAudit = store.providerAuditEvents.first {
            $0.kind == .openAIConnectionTest
        }
        XCTAssertEqual(connectionAudit?.action, .connectionTest)
        XCTAssertEqual(connectionAudit?.outcome, .failed)
        XCTAssertEqual(connectionAudit?.errorCode, .confirmationRequired)
        XCTAssertTrue(recordedStatuses.isEmpty)
        XCTAssertEqual(dispatchedEvents, [.providerWillSendRequest])
        XCTAssertEqual(keychain.copyMatchingCallCount, 0)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    func testProviderCoordinatorPublishesConnectionWhenHookLeavesModelUnchanged()
        async
    {
        let store = providerStoreForConnectionTest()
        let configuration = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        store.activateOpenAIConnectionConfiguration(configuration)
        let coordinator = ProviderFeatureCoordinator(providerStore: store)

        await coordinator.runOpenAIConnectionTest(
            baseURL: configuration.baseURL,
            modelName: configuration.modelName,
            keychainAccountAlias: configuration.keychainAccountAlias,
            configurationFingerprint: configuration
        )

        XCTAssertEqual(store.openAIConnectionLastResult?.modelName, "model-a")
    }

    func testClearingProviderAuditSuppressesInFlightConnectionCompletion()
        async
    {
        let transport = QueuedOpenAIConnectionTransport()
        let store = providerStoreForConnectionTest(transport: transport)
        let configuration = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        store.activateOpenAIConnectionConfiguration(configuration)

        let run = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilPendingRequestCount(1)
        let requestID = await transport.pendingRequestIDs().first!

        store.clearProviderAuditEvents()
        await transport.resume(requestID: requestID)
        _ = await run.value

        XCTAssertTrue(store.providerAuditEvents.isEmpty)
        XCTAssertNil(store.openAIConnectionLastResult)
    }

    func testPostClearConnectionRecordsAndOldCompletionCannotReplaceIt()
        async
    {
        let transport = QueuedOpenAIConnectionTransport()
        let store = providerStoreForConnectionTest(transport: transport)
        let configuration = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        store.activateOpenAIConnectionConfiguration(configuration)

        let runA = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilPendingRequestCount(1)
        let requestA = await transport.pendingRequestIDs().first!

        store.clearProviderAuditEvents()
        store.activateOpenAIConnectionConfiguration(configuration)
        let runB = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilPendingRequestCount(2)
        let requestB = await transport.pendingRequestIDs().first {
            $0 != requestA
        }!

        await transport.resume(requestID: requestB)
        let resultB = await runB.value
        await transport.resume(requestID: requestA)
        _ = await runA.value

        XCTAssertEqual(store.providerAuditEvents.map(\.auditID), [resultB.auditID])
        XCTAssertEqual(store.openAIConnectionLastResult?.auditID, resultB.auditID)
    }

    func testCancelledAndDeactivatedConnectionStillAuditsWithinCurrentEpoch()
        async
    {
        let transport = QueuedOpenAIConnectionTransport()
        let store = providerStoreForConnectionTest(transport: transport)
        let configuration = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        store.activateOpenAIConnectionConfiguration(configuration)

        let run = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilPendingRequestCount(1)
        let requestID = await transport.pendingRequestIDs().first!

        run.cancel()
        store.deactivateOpenAIConnectionConfiguration()
        await transport.resume(requestID: requestID)
        _ = await run.value

        XCTAssertEqual(store.providerAuditEvents.count, 1)
        XCTAssertNil(store.openAIConnectionLastResult)
    }

    func testSecondAuditClearDropsEarlierEpochsAndKeepsNewConnection()
        async
    {
        let transport = QueuedOpenAIConnectionTransport()
        let store = providerStoreForConnectionTest(transport: transport)
        let configuration = ProviderConnectionConfigurationFingerprint(
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a"
        )
        store.activateOpenAIConnectionConfiguration(configuration)

        let runA = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilPendingRequestCount(1)
        let requestA = await transport.pendingRequestIDs().first!

        store.clearProviderAuditEvents()
        let runB = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilPendingRequestCount(2)
        let requestB = await transport.pendingRequestIDs().first {
            $0 != requestA
        }!

        store.clearProviderAuditEvents()
        let runC = Task { @MainActor in
            await store.runOpenAIConnectionTest(
                baseURL: configuration.baseURL,
                modelName: configuration.modelName,
                keychainAccountAlias: configuration.keychainAccountAlias,
                configurationFingerprint: configuration
            )
        }
        await transport.waitUntilPendingRequestCount(3)
        let requestC = await transport.pendingRequestIDs().first {
            $0 != requestA && $0 != requestB
        }!

        await transport.resume(requestID: requestC)
        let resultC = await runC.value
        await transport.resume(requestID: requestB)
        _ = await runB.value
        await transport.resume(requestID: requestA)
        _ = await runA.value

        XCTAssertEqual(store.providerAuditEvents.map(\.auditID), [resultC.auditID])
        XCTAssertEqual(store.openAIConnectionLastResult?.auditID, resultC.auditID)
    }

    func testTranslationRuntimeAuditTokenDropsInFlightFailureAfterClear()
        async
    {
        let transport = QueuedOpenAIConnectionTransport()
        let store = ProviderStore()
        let auditProbe = TranslationRuntimeAuditTokenProbe()
        let runtime = OpenAITranslationRuntimeService(
            transport: transport,
            auditTokenSource: store.providerAuditTokenSource(),
            auditHandlerWithToken: { result, token, _, _ in
                auditProbe.record(result, token: token)
            }
        )
        let profile = OpenAITranslationRuntimeProfile(
            providerName: "Fixture Provider",
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a",
            timeoutSeconds: 60
        )

        let run = Task {
            await runtime.translate(
                text: "Blocks",
                sourceLanguageMode: "auto",
                targetLanguage: "zh-Hans",
                profile: profile,
                secretMaterial: Self.fixtureSecretMaterial
            )
        }
        await transport.waitUntilPendingRequestCount(1)
        let requestID = await transport.pendingRequestIDs().first!

        store.clearProviderAuditEvents()
        await transport.resume(requestID: requestID, statusCode: 500)
        let result = await run.value

        guard let delivered = auditProbe.delivery else {
            return XCTFail("Expected runtime audit delivery")
        }
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .serverError)
        XCTAssertEqual(delivered.result.auditID, result.auditID)
        store.recordAcceptedTranslationRuntime(
            delivered.result,
            auditToken: delivered.token
        )
        XCTAssertTrue(store.providerAuditEvents.isEmpty)
    }

    func testTranslationRuntimeAuditTokenRecordsRequestStartedAfterClear()
        async
    {
        let transport = QueuedOpenAIConnectionTransport()
        let store = ProviderStore()
        let auditProbe = TranslationRuntimeAuditTokenProbe()
        let runtime = OpenAITranslationRuntimeService(
            transport: transport,
            auditTokenSource: store.providerAuditTokenSource(),
            auditHandlerWithToken: { result, token, _, _ in
                auditProbe.record(result, token: token)
            }
        )
        let profile = OpenAITranslationRuntimeProfile(
            providerName: "Fixture Provider",
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a",
            timeoutSeconds: 60
        )

        store.clearProviderAuditEvents()
        let run = Task {
            await runtime.translate(
                text: "Blocks",
                sourceLanguageMode: "auto",
                targetLanguage: "zh-Hans",
                profile: profile,
                secretMaterial: Self.fixtureSecretMaterial
            )
        }
        await transport.waitUntilPendingRequestCount(1)
        let requestID = await transport.pendingRequestIDs().first!

        await transport.resume(requestID: requestID)
        let result = await run.value

        guard let delivered = auditProbe.delivery else {
            return XCTFail("Expected runtime audit delivery")
        }
        XCTAssertTrue(result.ok)
        XCTAssertEqual(delivered.result.auditID, result.auditID)
        store.recordAcceptedTranslationRuntime(
            delivered.result,
            auditToken: delivered.token
        )
        XCTAssertEqual(store.providerAuditEvents.map(\.auditID), [result.auditID])
    }

    func testTranslationRuntimeAuditTokenDropsDeferredHandlerDeliveryAfterClear()
        async
    {
        let transport = QueuedOpenAIConnectionTransport()
        let store = ProviderStore()
        let auditProbe = TranslationRuntimeAuditTokenProbe()
        let runtime = OpenAITranslationRuntimeService(
            transport: transport,
            auditTokenSource: store.providerAuditTokenSource(),
            auditHandlerWithToken: { result, token, _, _ in
                auditProbe.record(result, token: token)
            }
        )
        let profile = OpenAITranslationRuntimeProfile(
            providerName: "Fixture Provider",
            baseURL: "https://a.example.test/v1",
            modelName: "model-a",
            keychainAccountAlias: "account-a",
            timeoutSeconds: 60
        )

        let run = Task {
            await runtime.translate(
                text: "Blocks",
                sourceLanguageMode: "auto",
                targetLanguage: "zh-Hans",
                profile: profile,
                secretMaterial: Self.fixtureSecretMaterial
            )
        }
        await transport.waitUntilPendingRequestCount(1)
        let requestID = await transport.pendingRequestIDs().first!

        await transport.resume(requestID: requestID)
        let result = await run.value
        guard let delivered = auditProbe.delivery else {
            return XCTFail("Expected runtime audit delivery")
        }

        store.clearProviderAuditEvents()
        store.recordAcceptedTranslationRuntime(
            delivered.result,
            auditToken: delivered.token
        )
        XCTAssertTrue(result.ok)
        XCTAssertTrue(store.providerAuditEvents.isEmpty)
    }

    func testAcceptedTranslationRuntimeAuditSurvivesGrantRevocationBeforeMainActorDelivery()
        async
    {
        let defaults = isolatedDefaults()
        _ = ProviderSettingsPersistence.saveProviderBaseURL(
            "https://example.test/v1", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderModelName(
            "fixture-model", defaults: defaults
        )
        _ = ProviderSettingsPersistence.saveProviderAccountAlias(
            "fixture-account", defaults: defaults
        )
        let target = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target, defaults: defaults
            )
        )
        let store = ProviderStore(defaults: defaults)
        let auditToken = store.providerAuditTokenSource()()
        let result = await OpenAITranslationRuntimeService(
            transport: SuccessfulTranslationTransport()
        ).translate(
            text: "Blocks",
            sourceLanguageMode: "auto",
            targetLanguage: "zh-Hans",
            profile: OpenAITranslationRuntimeProfile(
                providerName: "Fixture Provider",
                baseURL: target.normalizedBaseURL,
                modelName: target.modelName,
                keychainAccountAlias: target.keychainAccountAlias,
                timeoutSeconds: 60
            ),
            secretMaterial: Self.fixtureSecretMaterial
        )
        XCTAssertTrue(result.ok)

        ProviderSettingsPersistence.revokeExternalTransferGrant(
            defaults: defaults
        )
        store.recordAcceptedTranslationRuntime(
            result,
            auditToken: auditToken
        )

        XCTAssertEqual(store.providerAuditEvents.count, 1)
        XCTAssertEqual(store.providerAuditEvents.first?.kind, .translationRuntime)
        XCTAssertEqual(store.providerAuditEvents.first?.auditID, result.auditID)
        XCTAssertEqual(store.providerAuditEvents.first?.outcome, .completed)
    }

    private func assertOpenAIAdapterExternalFailure(
        transport: some OpenAIConnectionTransport,
        expectedErrorCode: String,
        finalPublicationAccepted: Bool
    ) async {
        let auditProbe = TranslationRuntimeAuditProbe()
        let publicationProbe = TranslationPublicationProbe()
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(
                transport: transport,
                auditHandler: { auditProbe.record($0) }
            ),
            configuration: { Self.validOpenAIConfiguration },
            readProviderSecret: { _ in Self.fixtureSecretMaterial },
            authorizationValidator: { _, _ in true },
            admissionValidator: { _, _, start in start() },
            publicationValidator: { _, _, publication in
                publicationProbe.recordCall()
                guard finalPublicationAccepted else { return false }
                publication()
                return true
            }
        )
        var diagnostics: [TranslationResultDiagnostics] = []
        var terminalEventCount = 0

        do {
            for try await event in adapter.translate(Self.openAIRequest()) {
                switch event {
                case let .diagnostics(value, _):
                    diagnostics.append(value)
                case .completed:
                    terminalEventCount += 1
                default:
                    break
                }
            }
            XCTFail("Expected external provider failure")
        } catch let error as TranslationServiceAdapterError {
            if finalPublicationAccepted {
                XCTAssertEqual(error.errorCode, expectedErrorCode)
            } else {
                XCTAssertEqual(error, .publicationRejected)
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(publicationProbe.callCount, 1)
        XCTAssertEqual(
            diagnostics.count,
            finalPublicationAccepted ? 1 : 0
        )
        XCTAssertEqual(terminalEventCount, 0)
        XCTAssertEqual(
            auditProbe.callCount,
            finalPublicationAccepted ? 1 : 0
        )
        if finalPublicationAccepted {
            XCTAssertEqual(diagnostics.first?.auditID, auditProbe.result?.auditID)
        } else {
            XCTAssertNil(auditProbe.result)
        }
    }

    private func providerStoreForConnectionTest(
        transport: some OpenAIConnectionTransport = SuccessfulTranslationTransport()
    ) -> ProviderStore {
        let defaults = isolatedDefaults()
        let keychain = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret",
            updateStatus: errSecSuccess
        )
        return providerStoreForConnectionTest(
            defaults: defaults,
            transport: transport,
            keychain: keychain
        )
    }

    private func providerStoreForConnectionTest(
        defaults: UserDefaults,
        transport: some OpenAIConnectionTransport,
        keychain: any ProviderKeychainSecurityAPI
    ) -> ProviderStore {
        precondition(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://a.example.test/v1",
                defaults: defaults
            ) != nil
        )
        precondition(
            ProviderSettingsPersistence.saveProviderModelName(
                "model-a",
                defaults: defaults
            ) != nil
        )
        precondition(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "account-a",
                defaults: defaults
            ) != nil
        )
        let target = ProviderSettingsPersistence.currentExternalTransferTarget(
            defaults: defaults
        )!
        precondition(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )
        return ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: keychain
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: defaults
        )
    }

    private func assertProviderDestinationChangeRevokesGrantBeforeExternalTransfer(
        _ changeDestination: (UserDefaults) -> Void
    ) async {
        let defaults = isolatedDefaults()
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://host.example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "alias-a",
                defaults: defaults
            )
        )
        let grantedTarget = try! XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: grantedTarget,
                defaults: defaults
            )
        )

        changeDestination(defaults)

        XCTAssertNil(
            ProviderSettingsPersistence.externalTransferGrant(defaults: defaults)
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.isExternalTransferAuthorized(
                target: grantedTarget,
                defaults: defaults
            )
        )

        let authorizationDefaults = ProviderAuthorizationDefaultsFixture(
            defaults
        )
        let transport = CountingOpenAIConnectionTransport()
        var secretReadCount = 0
        let adapter = OpenAICompatibleTranslationServiceAdapter(
            runtimeService: OpenAITranslationRuntimeService(transport: transport),
            configuration: {
                .current(defaults: authorizationDefaults.value)
            },
            readProviderSecret: { _ in
                secretReadCount += 1
                return Self.fixtureSecretMaterial
            },
            authorizationValidator: { target, grant in
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: target,
                    grant: grant,
                    defaults: authorizationDefaults.value
                )
            }
        )

        do {
            for try await _ in adapter.translate(Self.openAIRequest()) {}
            XCTFail("A changed provider destination must require a new grant.")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(
                error.errorCode,
                ProviderErrorCode.confirmationRequired.rawValue
            )
            XCTAssertNotEqual(error, .publicationRejected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(secretReadCount, 0)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    private func assertInvalidAliasMigrationJournalFailsClosed(
        defaults: UserDefaults
    ) async throws {
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "account-a",
                defaults: defaults
            )
        )
        let target = try XCTUnwrap(
            ProviderSettingsPersistence.currentExternalTransferTarget(defaults: defaults)
        )
        XCTAssertFalse(
            ProviderSettingsPersistence.issueExternalTransferGrantForImmediateConfirmation(
                for: target,
                defaults: defaults
            )
        )

        let securityAPI = ProviderKeychainSecurityFailureProbe(
            storedSecret: "fixture-secret",
            updateStatus: errSecSuccess
        )
        let transport = CountingOpenAIConnectionTransport()
        let store = ProviderStore(
            providerKeychainService: ProviderKeychainService(
                securityAPI: securityAPI
            ),
            openAIConnectionService: OpenAICompatibleConnectionService(
                transport: transport
            ),
            defaults: defaults
        )
        _ = await store.runOpenAIConnectionTest(
            baseURL: target.normalizedBaseURL,
            modelName: target.modelName,
            keychainAccountAlias: target.keychainAccountAlias
        )

        XCTAssertTrue(
            ProviderSettingsPersistence.hasPendingAliasMigration(defaults: defaults)
        )
        XCTAssertNil(ProviderSettingsPersistence.externalTransferGrant(defaults: defaults))
        XCTAssertEqual(securityAPI.copyMatchingCallCount, 0)
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(transportCallCount, 0)
    }

    private func registeredAdapter(
        in registry: TranslationServiceRegistry,
        serviceID: String
    ) async throws -> any TranslationServiceAdapter {
        if let adapter = registry.adapter(serviceID: serviceID) {
            return adapter
        }
        let registered = expectation(
            description: "official profile adapter registered"
        )
        let observer = registry.$descriptors.sink { descriptors in
            guard descriptors.contains(where: { $0.id == serviceID }) else {
                return
            }
            registered.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        observer.cancel()
        return try XCTUnwrap(registry.adapter(serviceID: serviceID))
    }

    private func assertOfficialAdapterStreamIsCancelled(
        _ adapter: any TranslationServiceAdapter,
        transport: TranslationOfficialSuspendedTransport,
        expectedRequestCount: Int,
        sessionID: String
    ) async {
        let terminated = expectation(
            description: "closed official adapter stream terminates"
        )
        var completedEventCount = 0
        var businessTerminalCount = 0
        var cancelled = false
        var finishedCleanly = false
        let consumer = Task { @MainActor in
            defer { terminated.fulfill() }
            do {
                for try await event in adapter.translate(
                    officialServiceRequest(sessionID: sessionID)
                ) {
                    if case .completed = event {
                        completedEventCount += 1
                    }
                }
                finishedCleanly = true
            } catch is CancellationError {
                cancelled = true
            } catch {
                businessTerminalCount += 1
            }
        }
        defer { consumer.cancel() }

        await fulfillment(of: [terminated], timeout: 1)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(finishedCleanly)
        XCTAssertEqual(completedEventCount, 0)
        XCTAssertEqual(businessTerminalCount, 0)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, expectedRequestCount)
    }

    private func officialServiceRequest(
        sessionID: String
    ) -> TranslationServiceRequest {
        TranslationServiceRequest(
            sessionID: sessionID,
            input: TranslationInput(source: .manual, text: "Fixture source"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("zh-Hans")!
            )
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "TranslationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { [suite] in
            UserDefaults(suiteName: suite)?.removePersistentDomain(
                forName: suite
            )
        }
        return defaults
    }

    private func configureProviderTarget(defaults: UserDefaults) {
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                "fixture-account",
                defaults: defaults
            )
        )
    }

    private func configureProviderUserSecretMutationDefaults(
        defaults: UserDefaults,
        alias: String
    ) -> ProviderExternalTransferTarget {
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderBaseURL(
                "https://example.test/v1",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderModelName(
                "fixture-model",
                defaults: defaults
            )
        )
        XCTAssertNotNil(
            ProviderSettingsPersistence.saveProviderAccountAlias(
                alias,
                defaults: defaults
            )
        )
        defaults.set(
            alias,
            forKey: ProviderSettingsPersistence.storedSecretAccountAliasKey
        )
        defaults.set(
            "user_secret_stored",
            forKey: ProviderSettingsPersistence.secretLifecycleStateKey
        )
        return ProviderSettingsPersistence.currentExternalTransferTarget(
            defaults: defaults
        )!
    }

    private func waitForAliasMigrationRecovery(
        defaults: UserDefaults,
        pending: Bool
    ) async {
        for _ in 0..<200 {
            if ProviderSettingsPersistence.hasPendingAliasMigration(
                defaults: defaults
            ) == pending {
                return
            }
            await Task.yield()
        }
        XCTFail("Alias migration recovery did not reach its expected state.")
    }

    private func waitForPendingCredentialMutationRecovery(
        defaults: UserDefaults,
        pending: Bool
    ) async {
        for _ in 0..<200 {
            if ProviderSettingsPersistence.hasPendingCredentialMutation(
                defaults: defaults
            ) == pending {
                return
            }
            await Task.yield()
        }
        XCTFail("Credential mutation recovery did not reach its expected state.")
    }

    private func acknowledgedCommunityAdapter(
        source: TranslationCommunityWebSource,
        transport: any TranslationCommunityWebHTTPTransport
    ) -> TranslationCommunityWebServiceAdapter {
        let disclosures = TranslationCommunityWebDisclosureStore(
            defaults: isolatedDefaults()
        )
        disclosures.acknowledge(source: source)
        return TranslationCommunityWebServiceAdapter(
            source: source,
            transport: transport,
            disclosureStore: disclosures
        )
    }

    private func acknowledgeCommunitySources(
        _ sources: [TranslationCommunityWebSource],
        defaults: UserDefaults
    ) {
        let disclosures = TranslationCommunityWebDisclosureStore(
            defaults: defaults
        )
        sources.forEach(disclosures.acknowledge(source:))
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 200 {
            if predicate() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }

    private struct ProviderAuditSentinelError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private enum TestError: Error {
        case unexpectedSecretRead
        case fixtureFailure
    }

    private static var validOpenAIConfiguration:
        OpenAITranslationServiceConfiguration
    {
        let target = ProviderExternalTransferTarget(
            baseURL: "https://example.test/v1",
            modelName: "fixture-model",
            keychainAccountAlias: "fixture-account",
            credentialRevision: 1
        )!
        return OpenAITranslationServiceConfiguration(
            baseURL: target.normalizedBaseURL,
            modelName: target.modelName,
            keychainAccountAlias: target.keychainAccountAlias,
            credentialRevision: target.credentialRevision,
            externalTransferGrant: ProviderExternalTransferGrant(
                target: target,
                generation: 1
            )
        )
    }

    private static var fixtureSecretMaterial: ProviderUserSecretMaterial {
        fixtureSecretMaterial(credentialRevision: 1)
    }

    private static func fixtureSecretMaterial(
        credentialRevision: UInt64
    ) -> ProviderUserSecretMaterial {
        ProviderUserSecretMaterial(
            redactedResult: ProviderUserSecretOperationResult(
                ok: true,
                step: "read_for_provider_call",
                service: "fixture-service",
                account: "fixture-account",
                osStatus: 0,
                found: true,
                secretLength: 14,
                message: "Fixture secret read."
            ),
            credentialRevision: credentialRevision,
            secret: "fixture-secret"
        )
    }

    private static func openAIRequest(
        text: String = "Blocks"
    ) -> TranslationServiceRequest {
        TranslationServiceRequest(
            sessionID: UUID().uuidString,
            input: TranslationInput(source: .manual, text: text),
            direction: TranslationLanguageDirection(
                target: TranslationLanguageTag("zh-Hans")!
            )
        )
    }
}

private final class ProviderAuthorizationDefaultsFixture: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private final class ProviderKeychainSecurityFailureProbe:
    ProviderKeychainSecurityAPI
{
    private let storedSecret: String
    private let storedCredentialRevision: UInt64
    private let storesLegacyRawSecret: Bool
    private let updateStatus: OSStatus
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var copyMatchingCallCount = 0

    init(
        storedSecret: String,
        updateStatus: OSStatus,
        storedCredentialRevision: UInt64 = 0,
        storesLegacyRawSecret: Bool = false
    ) {
        self.storedSecret = storedSecret
        self.updateStatus = updateStatus
        self.storedCredentialRevision = storedCredentialRevision
        self.storesLegacyRawSecret = storesLegacyRawSecret
    }

    func add(_: CFDictionary) -> OSStatus {
        addCallCount += 1
        return errSecSuccess
    }

    func update(_: CFDictionary, attributes _: CFDictionary) -> OSStatus {
        updateCallCount += 1
        return updateStatus
    }

    func delete(_: CFDictionary) -> OSStatus {
        deleteCallCount += 1
        return errSecSuccess
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        copyMatchingCallCount += 1
        if let result {
            if storesLegacyRawSecret {
                result.pointee = Data(storedSecret.utf8) as CFData
            } else {
                result.pointee = try! JSONEncoder().encode(
                    ProviderStoredUserSecretEnvelope(
                        credentialRevision: storedCredentialRevision,
                        secret: storedSecret
                    )
                ) as CFData
            }
        }
        return errSecSuccess
    }
}

private final class AliasTrackingProviderKeychainSecurityAPI:
    ProviderKeychainSecurityAPI
{
    private var secrets: [String: Data] = [:]
    private(set) var deletedAccounts: [String] = []
    private(set) var operationCount = 0

    private let aliasMigrationStatus: OSStatus?
    private let deleteStatus: OSStatus?

    init(
        aliasMigrationStatus: OSStatus? = nil,
        deleteStatus: OSStatus? = nil
    ) {
        self.aliasMigrationStatus = aliasMigrationStatus
        self.deleteStatus = deleteStatus
    }

    func add(_ query: CFDictionary) -> OSStatus {
        operationCount += 1
        guard let account = account(from: query), let data = secret(from: query)
        else {
            return errSecParam
        }
        guard secrets[account] == nil else { return errSecDuplicateItem }
        secrets[account] = data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        operationCount += 1
        guard let account = account(from: query), secrets[account] != nil else {
            return errSecItemNotFound
        }
        guard let data = secret(from: attributes) else { return errSecParam }
        let destinationAccount = self.account(from: attributes) ?? account
        if destinationAccount != account {
            if let aliasMigrationStatus {
                return aliasMigrationStatus
            }
            guard secrets[destinationAccount] == nil else {
                return errSecDuplicateItem
            }
            secrets.removeValue(forKey: account)
        }
        secrets[destinationAccount] = data
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        operationCount += 1
        guard let account = account(from: query) else { return errSecParam }
        deletedAccounts.append(account)
        if let deleteStatus { return deleteStatus }
        guard secrets.removeValue(forKey: account) != nil else {
            return errSecItemNotFound
        }
        return errSecSuccess
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        operationCount += 1
        guard let account = account(from: query), let data = secrets[account]
        else {
            return errSecItemNotFound
        }
        result?.pointee = data as CFData
        return errSecSuccess
    }

    func containsSecret(for account: String) -> Bool {
        secrets[account] != nil
    }

    func seedUserSecret(alias: String, credentialRevision: UInt64) {
        secrets["openai-compatible:\(alias)"] = try! JSONEncoder().encode(
            ProviderStoredUserSecretEnvelope(
                credentialRevision: credentialRevision,
                secret: "fixture-secret"
            )
        )
    }

    func seedRawUserSecret(alias: String, data: Data) {
        secrets["openai-compatible:\(alias)"] = data
    }

    func rawSecret(for account: String) -> Data? {
        secrets[account]
    }

    private func account(from query: CFDictionary) -> String? {
        (query as NSDictionary)[kSecAttrAccount] as? String
    }

    private func secret(from query: CFDictionary) -> Data? {
        (query as NSDictionary)[kSecValueData] as? Data
    }
}

private final class BlockingProviderKeychainSecurityAPI:
    ProviderKeychainSecurityAPI,
    @unchecked Sendable
{
    enum BlockPoint {
        case none
        case update
        case copyMatching(call: Int)
    }

    private let lock = NSLock()
    private let blockPoint: BlockPoint
    private let blockedSignal = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var secrets: [String: Data] = [:]
    private var copyMatchingCallCount = 0
    private var updateDidBlock = false

    init(blockPoint: BlockPoint) {
        self.blockPoint = blockPoint
    }

    func add(_ query: CFDictionary) -> OSStatus {
        guard let account = account(from: query), let data = secret(from: query)
        else {
            return errSecParam
        }
        return lock.withLock {
            guard secrets[account] == nil else { return errSecDuplicateItem }
            secrets[account] = data
            return errSecSuccess
        }
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        guard let sourceAccount = account(from: query),
              let data = secret(from: attributes) else {
            return errSecParam
        }
        let destinationAccount = account(from: attributes) ?? sourceAccount
        let outcome = lock.withLock { () -> (OSStatus, Bool) in
            guard secrets[sourceAccount] != nil else {
                return (errSecItemNotFound, false)
            }
            guard destinationAccount == sourceAccount
                || secrets[destinationAccount] == nil else {
                return (errSecDuplicateItem, false)
            }
            if destinationAccount != sourceAccount {
                secrets.removeValue(forKey: sourceAccount)
            }
            secrets[destinationAccount] = data
            guard case .update = blockPoint, !updateDidBlock else {
                return (errSecSuccess, false)
            }
            updateDidBlock = true
            return (errSecSuccess, true)
        }
        if outcome.1 {
            blockUntilReleased()
        }
        return outcome.0
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        guard let account = account(from: query) else { return errSecParam }
        return lock.withLock {
            secrets.removeValue(forKey: account) == nil
                ? errSecItemNotFound
                : errSecSuccess
        }
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        guard let account = account(from: query) else { return errSecParam }
        let outcome = lock.withLock { () -> (OSStatus, Data?, Bool) in
            copyMatchingCallCount += 1
            let shouldBlock: Bool
            if case let .copyMatching(call) = blockPoint {
                shouldBlock = copyMatchingCallCount == call
            } else {
                shouldBlock = false
            }
            guard let data = secrets[account] else {
                return (errSecItemNotFound, nil, shouldBlock)
            }
            return (errSecSuccess, data, shouldBlock)
        }
        if outcome.2 {
            blockUntilReleased()
        }
        if let data = outcome.1 {
            result?.pointee = data as CFData
        }
        return outcome.0
    }

    func seedUserSecret(alias: String, credentialRevision: UInt64) {
        let account = "openai-compatible:\(alias)"
        let data = try! JSONEncoder().encode(
            ProviderStoredUserSecretEnvelope(
                credentialRevision: credentialRevision,
                secret: "fixture-secret"
            )
        )
        lock.withLock { secrets[account] = data }
    }

    func containsUserSecret(alias: String) -> Bool {
        lock.withLock { secrets["openai-compatible:\(alias)"] != nil }
    }

    func copyMatchingCalls() -> Int {
        lock.withLock { copyMatchingCallCount }
    }

    func waitUntilBlocked() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [blockedSignal] in
                continuation.resume(
                    returning: blockedSignal.wait(timeout: .now() + 1) == .success
                )
            }
        }
    }

    func release() {
        releaseSignal.signal()
    }

    private func blockUntilReleased() {
        blockedSignal.signal()
        _ = releaseSignal.wait(timeout: .now() + 5)
    }

    private func account(from query: CFDictionary) -> String? {
        (query as NSDictionary)[kSecAttrAccount] as? String
    }

    private func secret(from query: CFDictionary) -> Data? {
        (query as NSDictionary)[kSecValueData] as? Data
    }
}

private final class ThreadTrackingProviderKeychainSecurityAPI:
    ProviderKeychainSecurityAPI,
    @unchecked Sendable
{
    enum Call: Equatable {
        case add
        case update
        case delete
        case copyMatching
    }

    struct Snapshot {
        let calls: [Call]
        let mainThreadCallCount: Int
    }

    private let lock = NSLock()
    private let underlying: any ProviderKeychainSecurityAPI
    private var storedCalls: [Call] = []
    private var storedMainThreadCallCount = 0

    init(underlying: any ProviderKeychainSecurityAPI) {
        self.underlying = underlying
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                calls: storedCalls,
                mainThreadCallCount: storedMainThreadCallCount
            )
        }
    }

    func add(_ query: CFDictionary) -> OSStatus {
        record(.add)
        return underlying.add(query)
    }

    func update(
        _ query: CFDictionary,
        attributes: CFDictionary
    ) -> OSStatus {
        record(.update)
        return underlying.update(query, attributes: attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        record(.delete)
        return underlying.delete(query)
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        record(.copyMatching)
        return underlying.copyMatching(query, result: result)
    }

    private func record(_ call: Call) {
        lock.withLock {
            storedCalls.append(call)
            if Thread.isMainThread {
                storedMainThreadCallCount += 1
            }
        }
    }
}

private final class BlockingThreadTrackingProviderKeychainSecurityAPI:
    ProviderKeychainSecurityAPI,
    @unchecked Sendable
{
    struct Snapshot {
        let copyMatchingCallCount: Int
        let mainThreadCallCount: Int
        let didTimeOutWaitingForRelease: Bool
    }

    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let storedSecret: String
    private let onCopyMatching: @Sendable () -> Void
    private var storedCopyMatchingCallCount = 0
    private var storedMainThreadCallCount = 0
    private var storedDidTimeOutWaitingForRelease = false

    init(
        storedSecret: String,
        onCopyMatching: @escaping @Sendable () -> Void
    ) {
        self.storedSecret = storedSecret
        self.onCopyMatching = onCopyMatching
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                copyMatchingCallCount: storedCopyMatchingCallCount,
                mainThreadCallCount: storedMainThreadCallCount,
                didTimeOutWaitingForRelease:
                    storedDidTimeOutWaitingForRelease
            )
        }
    }

    func add(_: CFDictionary) -> OSStatus { errSecUnimplemented }

    func update(_: CFDictionary, attributes _: CFDictionary) -> OSStatus {
        errSecUnimplemented
    }

    func delete(_: CFDictionary) -> OSStatus { errSecUnimplemented }

    func copyMatching(
        _: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        lock.withLock {
            storedCopyMatchingCallCount += 1
            if Thread.isMainThread {
                storedMainThreadCallCount += 1
            }
        }
        onCopyMatching()
        guard releaseSignal.wait(timeout: .now() + 2) == .success else {
            lock.withLock { storedDidTimeOutWaitingForRelease = true }
            return errSecInteractionNotAllowed
        }
        result?.pointee = try! JSONEncoder().encode(
            ProviderStoredUserSecretEnvelope(
                credentialRevision: 0,
                secret: storedSecret
            )
        ) as CFData
        return errSecSuccess
    }

    func release() {
        releaseSignal.signal()
    }
}

private final class ProviderCredentialMutationOrderingSecurityAPI:
    ProviderKeychainSecurityAPI,
    @unchecked Sendable
{
    struct Snapshot {
        let didObserveSecurityCall: Bool
        let oldGrantWasAuthorized: Bool
        let credentialRevision: UInt64?
    }

    private let lock = NSLock()
    private let suiteName: String
    private let previouslyGrantedTarget: ProviderExternalTransferTarget
    private let underlying: any ProviderKeychainSecurityAPI
    private var storedSnapshot = Snapshot(
        didObserveSecurityCall: false,
        oldGrantWasAuthorized: true,
        credentialRevision: nil
    )

    init(
        suiteName: String,
        previouslyGrantedTarget: ProviderExternalTransferTarget,
        underlying: any ProviderKeychainSecurityAPI
    ) {
        self.suiteName = suiteName
        self.previouslyGrantedTarget = previouslyGrantedTarget
        self.underlying = underlying
    }

    var snapshot: Snapshot { lock.withLock { storedSnapshot } }

    func add(_ query: CFDictionary) -> OSStatus {
        observeDurableRevocationIfNeeded()
        return underlying.add(query)
    }

    func update(
        _ query: CFDictionary,
        attributes: CFDictionary
    ) -> OSStatus {
        observeDurableRevocationIfNeeded()
        return underlying.update(query, attributes: attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        observeDurableRevocationIfNeeded()
        return underlying.delete(query)
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        observeDurableRevocationIfNeeded()
        return underlying.copyMatching(query, result: result)
    }

    private func observeDurableRevocationIfNeeded() {
        lock.lock()
        guard !storedSnapshot.didObserveSecurityCall else {
            lock.unlock()
            return
        }
        lock.unlock()

        let reopenedDefaults = UserDefaults(suiteName: suiteName)!
        let observed = Snapshot(
            didObserveSecurityCall: true,
            oldGrantWasAuthorized:
                ProviderSettingsPersistence.isExternalTransferAuthorized(
                    target: previouslyGrantedTarget,
                    defaults: reopenedDefaults
                ),
            credentialRevision: ProviderSettingsPersistence
                .credentialRevision(defaults: reopenedDefaults)
        )
        lock.withLock {
            if !storedSnapshot.didObserveSecurityCall {
                storedSnapshot = observed
            }
        }
    }
}

private final class SynchronousStartOpenAIConnectionTransportProbe:
    OpenAIConnectionTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedStartCount = 0

    func perform(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        let operation = makeOperation(request, timeoutSeconds: 0)
        guard operation.start() else {
            throw CancellationError()
        }
        return try await operation.response()
    }

    func makeOperation(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) -> any OpenAIConnectionTransportOperation {
        SynchronousStartOpenAIConnectionTransportOperation(
            owner: self,
            response: OpenAIConnectionTransportResponse(
                httpResponse: HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["x-request-id": "fixture-request"]
                )!,
                data: Data(#"{"choices":[{"message":{"content":"fixture"}}]}"#.utf8)
            )
        )
    }

    func recordSynchronousStart() {
        lock.lock()
        storedStartCount += 1
        lock.unlock()
    }

    func startCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }
}

private final class SynchronousStartOpenAIConnectionTransportOperation:
    OpenAIConnectionTransportOperation,
    @unchecked Sendable
{
    private enum State { case prepared, started, cancelled }

    private let lock = NSLock()
    private weak var owner: SynchronousStartOpenAIConnectionTransportProbe?
    private let storedResponse: OpenAIConnectionTransportResponse
    private var state: State = .prepared

    init(
        owner: SynchronousStartOpenAIConnectionTransportProbe,
        response: OpenAIConnectionTransportResponse
    ) {
        self.owner = owner
        storedResponse = response
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        guard case .prepared = state else {
            lock.unlock()
            return false
        }
        state = .started
        owner?.recordSynchronousStart()
        lock.unlock()
        return true
    }

    func response() async throws -> OpenAIConnectionTransportResponse {
        let isCancelled = lock.withLock {
            if case .cancelled = state {
                true
            } else {
                false
            }
        }
        if isCancelled {
            throw CancellationError()
        }
        return storedResponse
    }

    func cancel() {
        lock.lock()
        state = .cancelled
        lock.unlock()
    }
}

private actor ProviderSaveSessionSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private let onSuspend: @Sendable () -> Void

    init(onSuspend: @escaping @Sendable () -> Void) {
        self.onSuspend = onSuspend
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onSuspend()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CountingOpenAIConnectionTransport: OpenAIConnectionTransport {
    private var calls = 0

    func perform(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        calls += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["x-request-id": "fixture-request"]
        )!
        return OpenAIConnectionTransportResponse(
            httpResponse: response,
            data: Data(#"{"choices":[{"message":{"content":"fixture"}}]}"#.utf8)
        )
    }

    func callCount() -> Int { calls }
}

private struct RedirectOpenAIConnectionTransport: OpenAIConnectionTransport {
    let statusCode: Int

    func perform(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        OpenAIConnectionTransportResponse(
            httpResponse: HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Location": "https://unapproved.example.test/receive",
                ]
            )!,
            data: Data()
        )
    }
}

private final class OpenAIRedirectSessionProbe:
    OpenAIURLSessionLoading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let statusCode: Int
    private var storedRedirectTargetRequestCount = 0
    private var storedRedirectedAuthorizationHeader: String?
    private var storedRedirectedBody: Data?

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    var redirectTargetRequestCount: Int {
        lock.withLock { storedRedirectTargetRequestCount }
    }

    var redirectedAuthorizationHeader: String? {
        lock.withLock { storedRedirectedAuthorizationHeader }
    }

    var redirectedBody: Data? {
        lock.withLock { storedRedirectedBody }
    }

    func data(
        for request: URLRequest,
        delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, URLResponse) {
        let targetURL = URL(string: "https://unapproved.example.test/receive")!
        let redirectedRequest = URLRequest(url: targetURL)
        let redirectResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": targetURL.absoluteString]
        )!
        let task = URLSession.shared.dataTask(with: request)
        let allowedRequest: URLRequest? = await withCheckedContinuation {
            continuation in
            delegate!.urlSession!(
                URLSession.shared,
                task: task,
                willPerformHTTPRedirection: redirectResponse,
                newRequest: redirectedRequest,
                completionHandler: { request in
                    continuation.resume(returning: request)
                }
            )
        }

        if allowedRequest != nil {
            lock.withLock {
                storedRedirectTargetRequestCount += 1
                storedRedirectedAuthorizationHeader = allowedRequest?
                    .value(forHTTPHeaderField: "Authorization")
                storedRedirectedBody = allowedRequest?.httpBody
            }
            return (
                Data("redirect target received private-source-text".utf8),
                HTTPURLResponse(
                    url: targetURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        }
        return (Data(), redirectResponse)
    }
}

private final class OpenAIFoundationRedirectURLProtocolFixture:
    URLProtocol,
    @unchecked Sendable
{
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        let statusCode: Int
        private var storedSourceRequestCount = 0
        private var storedTargetRequestCount = 0
        private var storedTargetAuthorizationHeader: String?
        private var storedTargetBody: Data?
        private var storedRedirectWasProposed = false

        init(statusCode: Int) {
            self.statusCode = statusCode
        }

        var sourceRequestCount: Int {
            lock.withLock { storedSourceRequestCount }
        }

        var targetRequestCount: Int {
            lock.withLock { storedTargetRequestCount }
        }

        var targetAuthorizationHeader: String? {
            lock.withLock { storedTargetAuthorizationHeader }
        }

        var targetBody: Data? {
            lock.withLock { storedTargetBody }
        }

        var redirectWasProposed: Bool {
            lock.withLock { storedRedirectWasProposed }
        }

        func recordSource() {
            lock.withLock { storedSourceRequestCount += 1 }
        }

        func recordTarget(_ request: URLRequest) {
            lock.withLock {
                storedTargetRequestCount += 1
                storedTargetAuthorizationHeader = request.value(
                    forHTTPHeaderField: "Authorization"
                )
                storedTargetBody = request.httpBody
            }
        }

        func recordRedirectProposal() {
            lock.withLock { storedRedirectWasProposed = true }
        }
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var installedState: State?

    static func install(_ state: State) {
        stateLock.withLock { installedState = state }
    }

    static func reset() {
        stateLock.withLock { installedState = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "authorized.example.test"
            || request.url?.host == "unapproved.example.test"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let state = Self.stateLock.withLock({ Self.installedState }) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        guard request.url?.host == "authorized.example.test" else {
            state.recordTarget(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(
                self,
                didLoad: Data("redirect target should remain unreachable".utf8)
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        state.recordSource()
        state.recordRedirectProposal()
        let targetURL = URL(
            string: "https://unapproved.example.test/receive"
        )!
        let redirectResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: state.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": targetURL.absoluteString]
        )!
        client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: targetURL),
            redirectResponse: redirectResponse
        )
        // When the per-task delegate rejects the proposed redirect, Foundation
        // keeps the source task alive until its protocol load completes. Finish
        // the original response on the next queue turn so the async data API
        // returns the denied 3xx instead of waiting indefinitely.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(
                self,
                didReceive: redirectResponse,
                cacheStoragePolicy: .notAllowed
            )
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private actor SuspendedOpenAIConnectionTransport: OpenAIConnectionTransport {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<
        OpenAIConnectionTransportResponse,
        Never
    >?

    func perform(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard responseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        guard let responseContinuation else { return }
        self.responseContinuation = nil
        let response = HTTPURLResponse(
            url: URL(string: "https://a.example.test/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        responseContinuation.resume(
            returning: OpenAIConnectionTransportResponse(
                httpResponse: response,
                data: Data(
                    #"{"choices":[{"message":{"content":"fixture"}}]}"#.utf8
                )
            )
        )
    }
}

private actor QueuedOpenAIConnectionTransport: OpenAIConnectionTransport {
    private var nextRequestID = 0
    private var pendingResponses: [
        Int: CheckedContinuation<OpenAIConnectionTransportResponse, Never>
    ] = [:]
    private var pendingRequestWaiters: [CheckedContinuation<Void, Never>] = []

    func perform(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        let requestID = nextRequestID
        nextRequestID += 1
        return await withCheckedContinuation { continuation in
            pendingResponses[requestID] = continuation
            let waiters = pendingRequestWaiters
            pendingRequestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilPendingRequestCount(_ count: Int) async {
        while pendingResponses.count < count {
            await withCheckedContinuation { continuation in
                pendingRequestWaiters.append(continuation)
            }
        }
    }

    func pendingRequestIDs() -> [Int] {
        pendingResponses.keys.sorted()
    }

    func resume(requestID: Int, statusCode: Int = 200) {
        guard let continuation = pendingResponses.removeValue(forKey: requestID)
        else {
            return
        }
        let response = HTTPURLResponse(
            url: URL(string: "https://a.example.test/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        continuation.resume(
            returning: OpenAIConnectionTransportResponse(
                httpResponse: response,
                data: Data(
                    #"{"choices":[{"message":{"content":"fixture"}}]}"#.utf8
                )
            )
        )
    }
}

private final class TranslationRuntimeAuditTokenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDelivery: (
        result: OpenAITranslationRuntimeResult,
        token: ProviderAuditToken
    )?

    var delivery: (
        result: OpenAITranslationRuntimeResult,
        token: ProviderAuditToken
    )? {
        lock.withLock { storedDelivery }
    }

    func record(
        _ result: OpenAITranslationRuntimeResult,
        token: ProviderAuditToken
    ) {
        lock.withLock {
            storedDelivery = (result, token)
        }
    }
}

private final class TranslationProfileDatabaseFixture {
    let root: URL
    let database: AppDatabase
    let repository: TranslationServiceProfileRepository

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranslationProfileMutationTests.\(UUID().uuidString)",
            isDirectory: true
        )
        database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        repository = TranslationServiceProfileRepository(database: database)
    }

    func cleanUp() {
        database.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TranslationServiceCredentialFailpointError: Error {
    case read
    case save
    case delete
}

private final class TranslationServiceCredentialFailpointStore:
    TranslationServiceCredentialStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String]
    private var saveAttempt = 0
    private var deleteAttempt = 0
    private var readsFail = false
    private let failingSaveAttempts: Set<Int>
    private let failingDeleteAttempts: Set<Int>

    init(
        values: [String: String],
        failingSaveAttempts: Set<Int> = [],
        failingDeleteAttempts: Set<Int> = []
    ) {
        self.values = values
        self.failingSaveAttempts = failingSaveAttempts
        self.failingDeleteAttempts = failingDeleteAttempts
    }

    func read(profileID: String, fieldID: String) throws -> String {
        guard let value = try value(
            profileID: profileID,
            fieldID: fieldID
        ) else {
            throw TranslationServiceCredentialStoreError
                .missingCredential(fieldID)
        }
        return value
    }

    func value(profileID: String, fieldID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !readsFail else {
            throw TranslationServiceCredentialFailpointError.read
        }
        return values["\(profileID)::\(fieldID)"]
    }

    func contains(profileID: String, fieldID: String) throws -> Bool {
        try value(profileID: profileID, fieldID: fieldID) != nil
    }

    func save(
        _ value: String,
        profileID: String,
        fieldID: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        saveAttempt += 1
        guard !failingSaveAttempts.contains(saveAttempt) else {
            throw TranslationServiceCredentialFailpointError.save
        }
        values["\(profileID)::\(fieldID)"] = value
    }

    func delete(profileID: String, fieldID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        deleteAttempt += 1
        guard !failingDeleteAttempts.contains(deleteAttempt) else {
            throw TranslationServiceCredentialFailpointError.delete
        }
        values["\(profileID)::\(fieldID)"] = nil
    }

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func failReads() {
        lock.lock()
        readsFail = true
        lock.unlock()
    }
}

private final class TranslationServiceCredentialSuspendedStore:
    TranslationServiceCredentialStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String]
    private var shouldSuspendNextSave = true
    private let saveStarted = DispatchSemaphore(value: 0)
    private let resumeSaveSemaphore = DispatchSemaphore(value: 0)

    init(values: [String: String]) {
        self.values = values
    }

    func read(profileID: String, fieldID: String) throws -> String {
        guard let value = try value(profileID: profileID, fieldID: fieldID) else {
            throw TranslationServiceCredentialStoreError
                .missingCredential(fieldID)
        }
        return value
    }

    func value(profileID: String, fieldID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values["\(profileID)::\(fieldID)"]
    }

    func contains(profileID: String, fieldID: String) throws -> Bool {
        try value(profileID: profileID, fieldID: fieldID) != nil
    }

    func save(
        _ value: String,
        profileID: String,
        fieldID: String
    ) throws {
        lock.lock()
        let shouldSuspend = shouldSuspendNextSave
        if shouldSuspend {
            shouldSuspendNextSave = false
        }
        lock.unlock()

        if shouldSuspend {
            saveStarted.signal()
            _ = resumeSaveSemaphore.wait(timeout: .now() + 1)
        }

        lock.lock()
        values["\(profileID)::\(fieldID)"] = value
        lock.unlock()
    }

    func delete(profileID: String, fieldID: String) throws {
        lock.lock()
        values["\(profileID)::\(fieldID)"] = nil
        lock.unlock()
    }

    func waitUntilSaveStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning:
                        self.saveStarted.wait(timeout: .now() + 1)
                            == .success
                )
            }
        }
    }

    func resumeSave() {
        resumeSaveSemaphore.signal()
    }

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class TranslationServiceCredentialSuspendedFailureStore:
    TranslationServiceCredentialStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String]
    private var shouldSuspendNextSave = true
    private let saveStarted = DispatchSemaphore(value: 0)
    private let resumeSave = DispatchSemaphore(value: 0)

    init(values: [String: String]) {
        self.values = values
    }

    func read(profileID: String, fieldID: String) throws -> String {
        guard let value = try value(
            profileID: profileID,
            fieldID: fieldID
        ) else {
            throw TranslationServiceCredentialStoreError
                .missingCredential(fieldID)
        }
        return value
    }

    func value(profileID: String, fieldID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values["\(profileID)::\(fieldID)"]
    }

    func contains(profileID: String, fieldID: String) throws -> Bool {
        try value(profileID: profileID, fieldID: fieldID) != nil
    }

    func save(
        _ value: String,
        profileID: String,
        fieldID: String
    ) throws {
        lock.lock()
        let shouldSuspend = shouldSuspendNextSave
        if shouldSuspend {
            shouldSuspendNextSave = false
        }
        lock.unlock()

        if shouldSuspend {
            saveStarted.signal()
            _ = resumeSave.wait(timeout: .now() + 5)
            throw TranslationServiceCredentialFailpointError.save
        }

        lock.lock()
        values["\(profileID)::\(fieldID)"] = value
        lock.unlock()
    }

    func delete(profileID: String, fieldID: String) throws {
        lock.lock()
        values["\(profileID)::\(fieldID)"] = nil
        lock.unlock()
    }

    func waitUntilSaveStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning:
                        self.saveStarted.wait(timeout: .now() + 5)
                            == .success
                )
            }
        }
    }

    func resumeWithFailure() {
        resumeSave.signal()
    }
}

private enum TranslationServiceProfileRefreshFailpointError: Error {
    case unavailable
}

private actor TranslationServiceProfileRefreshFailpoint {
    private let initialBatch: TranslationOfficialServiceProfileBatch
    private let onReloadAttempt: @Sendable () -> Void
    private var loadCount = 0

    init(
        initialBatch: TranslationOfficialServiceProfileBatch,
        onReloadAttempt: @escaping @Sendable () -> Void
    ) {
        self.initialBatch = initialBatch
        self.onReloadAttempt = onReloadAttempt
    }

    func load() throws -> TranslationOfficialServiceProfileBatch {
        loadCount += 1
        guard loadCount == 1 else {
            onReloadAttempt()
            throw TranslationServiceProfileRefreshFailpointError.unavailable
        }
        return initialBatch
    }
}

private enum TranslationServiceProfileRefreshSequenceError: Error {
    case exhausted
}

private actor TranslationServiceProfileRefreshSequenceLoader {
    private var batches: [TranslationOfficialServiceProfileBatch]

    init(batches: [TranslationOfficialServiceProfileBatch]) {
        self.batches = batches
    }

    func load() throws -> TranslationOfficialServiceProfileBatch {
        guard !batches.isEmpty else {
            throw TranslationServiceProfileRefreshSequenceError.exhausted
        }
        return batches.removeFirst()
    }
}

private actor LibreTranslateCapabilityTransport:
    TranslationOfficialHTTPTransport
{
    private var capturedRequests: [URLRequest] = []

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        let body: Data
        switch request.url?.lastPathComponent {
        case "languages":
            // Deliberately omit English and return an unstable order. The
            // connection probe must select the same deterministic supported
            // edge rather than assuming en→zh.
            body = Data(
                """
                [
                  {"code":"fr","name":"French","targets":["de"]},
                  {"code":"de","name":"German","targets":["fr"]}
                ]
                """.utf8
            )
        case "translate":
            body = Data(#"{"translatedText":"Hallo"}"#.utf8)
        default:
            throw TranslationOfficialAdapterError.invalidResponse
        }
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func recordedRequests() -> [URLRequest] {
        capturedRequests
    }
}

private actor TranslationOfficialSuspendedTransport:
    TranslationOfficialHTTPTransport
{
    typealias RequestObserver = @Sendable (Int) -> Void
    typealias RequestFinishedObserver = @Sendable (Int) -> Void
    typealias RequestCancellationObserver = @Sendable (Int) -> Void

    private struct PendingResponse {
        let requestURL: URL
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    }

    private let onRequestReceived: RequestObserver?
    private let onRequestFinished: RequestFinishedObserver?
    private let onRequestCancelled: RequestCancellationObserver?
    private var receivedRequestCount = 0
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var cancelledRequestIDs: Set<Int> = []
    private var storedCancelledRequestCount = 0

    init(
        onRequestReceived: RequestObserver? = nil,
        onRequestFinished: RequestFinishedObserver? = nil,
        onRequestCancelled: RequestCancellationObserver? = nil
    ) {
        self.onRequestReceived = onRequestReceived
        self.onRequestFinished = onRequestFinished
        self.onRequestCancelled = onRequestCancelled
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = request.url else {
            throw TranslationOfficialAdapterError.invalidResponse
        }
        receivedRequestCount += 1
        let requestID = receivedRequestCount
        defer { onRequestFinished?(requestID) }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (
                    continuation: CheckedContinuation<
                        (Data, HTTPURLResponse),
                        Error
                    >
                ) in
                if cancelledRequestIDs.contains(requestID) {
                    storedCancelledRequestCount += 1
                    onRequestCancelled?(requestID)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingResponses[requestID] = PendingResponse(
                    requestURL: requestURL,
                    continuation: continuation
                )
                onRequestReceived?(requestID)
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
        return response
    }

    func succeed(with responseBody: String) {
        guard let requestID = pendingResponses.keys.sorted().first else {
            return
        }
        succeed(requestID: requestID, with: responseBody)
    }

    func succeed(requestID: Int, with responseBody: String) {
        guard let pending = pendingResponses.removeValue(forKey: requestID),
              let response = HTTPURLResponse(
                url: pending.requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
              ) else {
            return
        }
        pending.continuation.resume(
            returning: (Data(responseBody.utf8), response)
        )
    }

    func requestCount() -> Int {
        receivedRequestCount
    }

    func cancelledRequestCount() -> Int {
        storedCancelledRequestCount
    }

    private func cancel(requestID: Int) {
        guard cancelledRequestIDs.insert(requestID).inserted else { return }
        guard let pending = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        storedCancelledRequestCount += 1
        onRequestCancelled?(requestID)
        pending.continuation.resume(throwing: CancellationError())
    }
}

private final class TranslationTestExpectationSignal: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

@MainActor
final class TranslationOfficialServiceAdapterTests: XCTestCase {
    func testLibreCapabilitySnapshotPreservesDirectionalPairsAndChineseCodes()
        throws
    {
        let profile = TranslationServiceProfile(
            id: "libre-direction-fixture",
            templateID: .libreTranslate,
            displayName: "Libre",
            configuration: [
                "base_url": .string("https://libre.example.test"),
            ],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let en = try XCTUnwrap(
            LibreTranslateCapabilitySnapshot.language(rawCode: "en")
        )
        let es = try XCTUnwrap(
            LibreTranslateCapabilitySnapshot.language(rawCode: "es")
        )
        let fr = try XCTUnwrap(
            LibreTranslateCapabilitySnapshot.language(rawCode: "fr")
        )
        let de = try XCTUnwrap(
            LibreTranslateCapabilitySnapshot.language(rawCode: "de")
        )
        let zh = try XCTUnwrap(
            LibreTranslateCapabilitySnapshot.language(rawCode: "zh")
        )
        let zt = try XCTUnwrap(
            LibreTranslateCapabilitySnapshot.language(rawCode: "zt")
        )
        XCTAssertEqual(zh.tag.rawValue, "zh-Hans")
        XCTAssertEqual(zt.tag.rawValue, "zh-Hant")

        let snapshot = try LibreTranslateCapabilitySnapshot(
            schemaVersion:
                LibreTranslateCapabilitySnapshot.currentSchemaVersion,
            profileID: profile.id,
            profileRevision: profile.updatedAt.timeIntervalSince1970,
            fetchedAt: Date(timeIntervalSince1970: 3),
            entries: [
                .init(source: fr, targets: [de]),
                .init(source: en, targets: [es]),
                .init(source: zh, targets: [zt]),
            ]
        ).validated(for: profile)
        let probe = try snapshot.validationProbe()
        XCTAssertEqual(probe.source.rawCode, "en")
        XCTAssertEqual(probe.target.rawCode, "es")
        XCTAssertEqual(probe.text, "Hello.")
        XCTAssertEqual(
            try snapshot.serverCodes(
                for: TranslationLanguageDirection(
                    source: TranslationLanguageTag("en-US"),
                    target: TranslationLanguageTag("es-ES")!
                )
            ).source,
            "en"
        )
        XCTAssertThrowsError(
            try snapshot.serverCodes(
                for: TranslationLanguageDirection(
                    source: TranslationLanguageTag("en"),
                    target: TranslationLanguageTag("de")!
                )
            )
        )
    }

    func testProviderLanguageMappingsAreExplicitAndStable() throws {
        XCTAssertEqual(
            try TranslationOfficialServiceWorker.deepLLanguage(
                try XCTUnwrap(TranslationLanguageTag("en-US")),
                isTarget: false
            ),
            "EN"
        )
        XCTAssertEqual(
            try TranslationOfficialServiceWorker.deepLLanguage(
                try XCTUnwrap(TranslationLanguageTag("zh-Hant")),
                isTarget: true
            ),
            "ZH-HANT"
        )
        XCTAssertEqual(
            try TranslationOfficialServiceWorker.googleLanguage(
                try XCTUnwrap(TranslationLanguageTag("zh-Hans"))
            ),
            "zh-CN"
        )
        XCTAssertEqual(
            try TranslationOfficialServiceWorker.alibabaLanguage(
                try XCTUnwrap(TranslationLanguageTag("en-US"))
            ),
            "en"
        )
        XCTAssertEqual(
            try TranslationOfficialServiceWorker.libreLanguage(
                try XCTUnwrap(TranslationLanguageTag("pt-BR"))
            ),
            "pt"
        )
        XCTAssertThrowsError(
            try TranslationOfficialServiceWorker.deepLLanguage(
                try XCTUnwrap(TranslationLanguageTag("cy")),
                isTarget: true
            )
        )

        let deepLLanguages = TranslationServiceTemplateCatalog
            .supportedLanguages(for: .deepLFree)
        XCTAssertFalse(
            deepLLanguages.contains(
                try XCTUnwrap(TranslationLanguageTag("hi"))
            )
        )
        for language in deepLLanguages {
            XCTAssertNoThrow(
                try TranslationOfficialServiceWorker.deepLLanguage(
                    language,
                    isTarget: true
                ),
                language.rawValue
            )
        }

        let alibabaLanguages = TranslationServiceTemplateCatalog
            .supportedLanguages(for: .alibabaMachineTranslation)
        XCTAssertFalse(
            alibabaLanguages.contains(
                try XCTUnwrap(TranslationLanguageTag("cs"))
            )
        )
        for language in alibabaLanguages {
            XCTAssertNoThrow(
                try TranslationOfficialServiceWorker.alibabaLanguage(
                    language
                ),
                language.rawValue
            )
        }
    }

    func testOfficialAdaptersUseExpectedAuthenticationAndEndpoints()
        async throws
    {
        let deepL = try await execute(
            profile: profile(.deepLFree),
            credentials: ["auth_key": "deep-key"],
            response: #"{"translations":[{"text":"你好"}]}"#
        )
        XCTAssertEqual(deepL.url?.host, "api-free.deepl.com")
        XCTAssertEqual(
            deepL.value(forHTTPHeaderField: "Authorization"),
            "DeepL-Auth-Key deep-key"
        )

        let microsoft = try await execute(
            profile: profile(
                .microsoftTranslator,
                configuration: ["region": .string("eastus")]
            ),
            credentials: ["subscription_key": "azure-key"],
            response:
                #"[{"translations":[{"text":"你好","to":"zh-Hans"}]}]"#
        )
        XCTAssertEqual(
            microsoft.value(
                forHTTPHeaderField: "Ocp-Apim-Subscription-Key"
            ),
            "azure-key"
        )
        XCTAssertEqual(
            microsoft.value(
                forHTTPHeaderField: "Ocp-Apim-Subscription-Region"
            ),
            "eastus"
        )

        let google = try await execute(
            profile: profile(.googleCloudBasic),
            credentials: ["api_key": "google-key"],
            response:
                #"{"data":{"translations":[{"translatedText":"你好"}]}}"#
        )
        XCTAssertEqual(
            google.value(forHTTPHeaderField: "X-Goog-Api-Key"),
            "google-key"
        )
        XCTAssertFalse(
            google.url?.absoluteString.contains("google-key") == true
        )

        let alibaba = try await execute(
            profile: profile(
                .alibabaMachineTranslation,
                configuration: ["region": .string("cn-hangzhou")]
            ),
            credentials: [
                "access_key_id": "ali-id",
                "access_key_secret": "ali-secret",
            ],
            response: #"{"Data":{"Translated":"你好"}}"#
        )
        XCTAssertEqual(
            alibaba.value(forHTTPHeaderField: "x-acs-action"),
            "TranslateGeneral"
        )
        XCTAssertEqual(
            alibaba.url?.host,
            "mt.cn-hangzhou.aliyuncs.com"
        )
        XCTAssertEqual(
            alibaba.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        let alibabaBody = try XCTUnwrap(
            alibaba.httpBody.flatMap {
                String(data: $0, encoding: .utf8)
            }
        )
        XCTAssertEqual(
            alibabaBody,
            "FormatType=text&Scene=general&SourceLanguage=en"
                + "&SourceText=Hello&TargetLanguage=zh"
        )
        XCTAssertTrue(
            alibaba.value(forHTTPHeaderField: "Authorization")?
                .contains("Credential=ali-id") == true
        )
        XCTAssertFalse(
            alibaba.value(forHTTPHeaderField: "Authorization")?
                .contains("ali-secret") == true
        )

        let libre = try await execute(
            profile: profile(
                .libreTranslate,
                configuration: [
                    "base_url": .string(
                        "https://libre.example.test/api/"
                    ),
                ]
            ),
            credentials: ["api_key": "libre-key"],
            response: #"{"translatedText":"你好"}"#
        )
        XCTAssertEqual(
            libre.url?.absoluteString,
            "https://libre.example.test/api/translate"
        )
        let libreBody = try XCTUnwrap(libre.httpBody)
        let libreJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: libreBody)
                as? [String: Any]
        )
        XCTAssertEqual(libreJSON["api_key"] as? String, "libre-key")
    }

    func testMicrosoftRejectsReturnedTargetLanguageMismatch()
        async
    {
        do {
            _ = try await execute(
                profile: profile(.microsoftTranslator),
                credentials: ["subscription_key": "azure-key"],
                response:
                    #"[{"translations":[{"text":"Bonjour","to":"fr"}]}]"#
            )
            XCTFail("Expected returned target language mismatch")
        } catch let error as TranslationServiceAdapterError {
            XCTAssertEqual(
                error.errorCode,
                "translation_response_language_mismatch"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLibreEndpointPolicyAllowsOnlyPublicHTTPSOrLiteralLoopback()
        throws
    {
        XCTAssertEqual(
            try LibreTranslateEndpointPolicy.translateEndpoint(
                "http://127.0.0.1:5000/"
            ).absoluteString,
            "http://127.0.0.1:5000/translate"
        )
        XCTAssertEqual(
            try LibreTranslateEndpointPolicy.translateEndpoint(
                "https://translate.example.com/api"
            ).absoluteString,
            "https://translate.example.com/api/translate"
        )
        XCTAssertEqual(
            try LibreTranslateEndpointPolicy.languagesEndpoint(
                "https://translate.example.com/api"
            ).absoluteString,
            "https://translate.example.com/api/languages"
        )
        XCTAssertThrowsError(
            try LibreTranslateEndpointPolicy.translateEndpoint(
                "http://localhost:5000"
            )
        )
        XCTAssertThrowsError(
            try LibreTranslateEndpointPolicy.translateEndpoint(
                "https://192.168.1.20"
            )
        )
        XCTAssertThrowsError(
            try LibreTranslateEndpointPolicy.translateEndpoint(
                "https://user:password@translate.example.com/api"
            )
        )
        XCTAssertThrowsError(
            try LibreTranslateEndpointPolicy.translateEndpoint(
                "https://translate.example.com/api?api_key=secret"
            )
        )
        XCTAssertThrowsError(
            try LibreTranslateEndpointPolicy.translateEndpoint(
                "https://translate.example.com/api#token=secret"
            )
        )
    }

    func testAlibabaRegionUsesExplicitEndpointAllowlist() throws {
        XCTAssertEqual(
            AlibabaMachineTranslationRegion.chinaBeijing
                .publicEndpointHost,
            "mt.aliyuncs.com"
        )
        XCTAssertEqual(
            AlibabaMachineTranslationRegion.chinaHangzhou
                .publicEndpointHost,
            "mt.cn-hangzhou.aliyuncs.com"
        )
        XCTAssertEqual(
            AlibabaMachineTranslationRegion.singapore
                .publicEndpointHost,
            "mt.ap-southeast-1.aliyuncs.com"
        )
        XCTAssertEqual(
            AlibabaMachineTranslationRegion.dubai
                .publicEndpointHost,
            "alimt.me-east-1.aliyuncs.com"
        )
        XCTAssertNil(
            AlibabaMachineTranslationRegion(
                rawValue: "attacker.example"
            )
        )
    }

    func testAlibabaFormBodyUsesStableRFC3986Encoding() {
        let body = AlibabaCloudACS3Signer.formEncodedBody(
            [
                "SourceText": "你好 &+",
                "FormatType": "text",
            ]
        )
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            "FormatType=text&SourceText="
                + "%E4%BD%A0%E5%A5%BD%20%26%2B"
        )
    }

    func testCredentialPolicyRejectsHeaderControlCharacters() throws {
        XCTAssertEqual(
            try TranslationServiceCredentialPolicy.normalized(
                "  fixture-key  "
            ),
            "fixture-key"
        )
        for invalidValue in [
            "fixture\rkey",
            "fixture\nkey",
            "fixture\u{0}key",
        ] {
            XCTAssertThrowsError(
                try TranslationServiceCredentialPolicy.normalized(
                    invalidValue
                )
            ) { error in
                guard case TranslationServiceCredentialStoreError
                    .invalidValue = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testCredentialPreparationCapturesStoreFailurePerProfile()
        async
    {
        let profile = profile(.deepLFree)
        let credentialKey = "\(profile.id)::auth_key"
        let credentialStore = TranslationOfficialCredentialFixture(
            values: [credentialKey: "fixture-key"],
            failingKeys: [credentialKey]
        )

        let state = await Task.detached(priority: .utility) {
            TranslationOfficialServiceProfilePreparer.credentialState(
                for: profile,
                credentialStore: credentialStore
            )
        }.value

        guard case let .inaccessible(message) = state else {
            return XCTFail("Expected an inaccessible credential state")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(credentialStore.didReadOnMainThread)
        let adapter = TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: state,
            credentialStore: credentialStore
        )
        XCTAssertEqual(
            adapter.descriptor.availability,
            .requiresConfiguration
        )
    }

    func testAlibabaACS3SignatureMatchesFixedCanonicalRequestVector() {
        let body = AlibabaCloudACS3Signer.formEncodedBody(
            ["SourceText": "hello"]
        )
        let request = AlibabaCloudACS3Signer.makeSignedRequest(
            url: URL(
                string: "https://mt.cn-hangzhou.aliyuncs.com/"
            )!,
            action: "TranslateGeneral",
            version: "2018-10-12",
            body: body,
            accessKeyID: "fixture-id",
            accessKeySecret: "fixture-secret",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            nonce: "fixture-nonce"
        )

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-acs-content-sha256"),
            "022d2e1d5cb17e69c0cbe0a22216cfffd94368233d9e41a7cc59039f34235b38"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "ACS3-HMAC-SHA256 Credential=fixture-id,"
                + "SignedHeaders=content-type;host;x-acs-action;"
                + "x-acs-content-sha256;x-acs-date;"
                + "x-acs-signature-nonce;x-acs-version,"
                + "Signature=1b00abf5aecd1c8af5f5785f551a7a2"
                + "080e58f91069fe48af1aae5be7d51406e"
        )
    }

    func testBoundedLoopbackClientCancelsUnderlyingTaskAndRejectsLargeResponse()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TranslationOfficialURLProtocolFixture.self,
        ]
        TranslationOfficialURLProtocolFixture.setMode(.blocking)
        let cancellationClient = TranslationBoundedURLSessionClient(
            maximumResponseBytes: 32,
            sessionConfiguration: configuration
        )
        let request = URLRequest(
            url: URL(string: "http://127.0.0.1:5000/translate")!
        )
        let task = Task {
            try await cancellationClient.data(for: request)
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        for _ in 0..<20
            where TranslationOfficialURLProtocolFixture.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(
            TranslationOfficialURLProtocolFixture.stopCount,
            1
        )

        TranslationOfficialURLProtocolFixture.setMode(
            .oversized(contentLength: 33)
        )
        let sizeClient = TranslationBoundedURLSessionClient(
            maximumResponseBytes: 32,
            sessionConfiguration: configuration
        )
        do {
            _ = try await sizeClient.data(for: request)
            XCTFail("Expected bounded response failure")
        } catch let error as TranslationOfficialAdapterError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testBoundedLoopbackClientRejectsOversizedContentLengthBeforeBody()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TranslationOfficialURLProtocolFixture.self,
        ]
        TranslationOfficialURLProtocolFixture.setMode(
            .oversizedHeaderOnly(contentLength: 33)
        )
        let client = TranslationBoundedURLSessionClient(
            maximumResponseBytes: 32,
            sessionConfiguration: configuration
        )
        let request = URLRequest(
            url: URL(string: "http://127.0.0.1:5000/translate")!
        )

        do {
            _ = try await client.data(for: request)
            XCTFail("Expected content-length response-size rejection")
        } catch let error as TranslationOfficialAdapterError {
            XCTAssertEqual(error, .responseTooLarge)
        }

        XCTAssertEqual(TranslationOfficialURLProtocolFixture.bodySendCount, 0)
    }

    func testBoundedLoopbackClientDeniesFoundationRedirectsBeforeCrossHostTarget()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TranslationOfficialURLProtocolFixture.self,
        ]

        for statusCode in [301, 302, 303, 307, 308] {
            let state = TranslationOfficialURLProtocolFixture.RedirectState(
                statusCode: statusCode
            )
            TranslationOfficialURLProtocolFixture.installRedirect(state)
            defer {
                state.cancel()
                TranslationOfficialURLProtocolFixture.uninstallRedirect(state)
            }
            let client = TranslationBoundedURLSessionClient(
                maximumResponseBytes: 32,
                sessionConfiguration: configuration,
                redirectDeniedObserver: { state.recordRedirectDenied() }
            )
            var request = URLRequest(url: state.sourceURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 0.5
            request.setValue(
                "Bearer loopback-secret-\(statusCode)",
                forHTTPHeaderField: "Authorization"
            )
            request.httpBody = Data("loopback-private-source-\(statusCode)".utf8)

            let (data, response) = try await client.data(for: request)

            XCTAssertTrue(data.isEmpty)
            XCTAssertEqual(response.statusCode, statusCode)
            XCTAssertEqual(response.url, request.url)
            XCTAssertEqual(state.sourceRequestCount, 1)
            XCTAssertTrue(state.redirectWasProposed)
            XCTAssertEqual(state.redirectDeniedCallbackCount, 1)
            XCTAssertEqual(state.targetRequestCount, 0)
            XCTAssertNil(state.targetAuthorizationHeader)
            XCTAssertNil(state.targetBody)
        }
    }

    func testFoundationURLSessionFollowsFixtureRedirectToLocalTarget()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TranslationOfficialURLProtocolFixture.self,
        ]
        let state = TranslationOfficialURLProtocolFixture.RedirectState(
            statusCode: 307
        )
        TranslationOfficialURLProtocolFixture.installRedirect(state)
        defer {
            state.cancel()
            TranslationOfficialURLProtocolFixture.uninstallRedirect(state)
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: state.sourceURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 0.5
        request.httpBody = Data("fixture-control-source".utf8)

        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.url, state.targetURL)
        XCTAssertEqual(data, state.targetResponseBody)
        XCTAssertEqual(state.sourceRequestCount, 1)
        XCTAssertTrue(state.redirectWasProposed)
        XCTAssertEqual(state.redirectDeniedCallbackCount, 0)
        XCTAssertEqual(state.targetRequestCount, 1)
    }

    func testBoundedLoopbackClientAppliesAbsoluteDeadlineToBlockingResponse()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TranslationOfficialURLProtocolFixture.self,
        ]
        TranslationOfficialURLProtocolFixture.setMode(.blocking)
        let client = TranslationBoundedURLSessionClient(
            maximumResponseBytes: 32,
            sessionConfiguration: configuration
        )
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:5000/translate")!
        )
        request.timeoutInterval = 0.05
        let start = ContinuousClock.now

        do {
            _ = try await client.data(for: request)
            XCTFail("Expected the overall request deadline")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case .transport = error else {
                return XCTFail("Expected a transport timeout")
            }
        }

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        for _ in 0..<20
            where TranslationOfficialURLProtocolFixture.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(
            TranslationOfficialURLProtocolFixture.stopCount,
            1
        )
    }

    func testBoundedLoopbackClientRejectsSuccessCompletedAfterDeadline()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TranslationOfficialURLProtocolFixture.self,
        ]
        TranslationOfficialURLProtocolFixture.setMode(
            .delayedSuccess(delay: .milliseconds(50))
        )
        let client = TranslationBoundedURLSessionClient(
            maximumResponseBytes: 32,
            sessionConfiguration: configuration,
            watchdogSleeper: { _ in
                try await Task.sleep(for: .seconds(1))
            },
            deadlineHasElapsed: { _ in true }
        )
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:5000/translate")!
        )
        request.timeoutInterval = 1
        let start = ContinuousClock.now

        do {
            _ = try await client.data(for: request)
            XCTFail("A response after the deadline must not succeed")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            guard case let .transport(message) = error else {
                return XCTFail("Expected a transport timeout")
            }
            XCTAssertEqual(message, "The request timed out.")
        } catch {
            XCTFail("Unexpected deadline error type")
        }

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(0.5))
        XCTAssertEqual(TranslationOfficialURLProtocolFixture.startCount, 1)
        for _ in 0..<20
            where TranslationOfficialURLProtocolFixture.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(
            TranslationOfficialURLProtocolFixture.stopCount,
            1
        )
    }

    func testBoundedLoopbackClientRejectsInvalidTimeoutBeforeStartingRequest()
        async
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            TranslationOfficialURLProtocolFixture.self,
        ]

        for timeoutInterval in [0, -1, Double.nan] {
            TranslationOfficialURLProtocolFixture.setMode(.blocking)
            let client = TranslationBoundedURLSessionClient(
                maximumResponseBytes: 32,
                sessionConfiguration: configuration
            )
            var request = URLRequest(
                url: URL(string: "http://127.0.0.1:5000/translate")!
            )
            request.timeoutInterval = timeoutInterval

            do {
                _ = try await client.data(for: request)
                XCTFail("Expected invalid timeout configuration to fail")
            } catch let error as BlocksNativePluginNetworkBrokerError {
                guard case let .transport(message) = error else {
                    return XCTFail("Expected a transport configuration error")
                }
                XCTAssertEqual(
                    message,
                    "The request timeout configuration is invalid."
                )
            } catch {
                XCTFail("Unexpected invalid timeout error: \(error)")
            }

            XCTAssertEqual(TranslationOfficialURLProtocolFixture.startCount, 0)
            XCTAssertEqual(TranslationOfficialURLProtocolFixture.stopCount, 0)
        }
    }

    func testOfficialHTTPSDeadlineBoundsNonCooperativeResolver()
        async throws
    {
        let resolver = TranslationOfficialSuspendedResolver()
        let transport = TranslationOfficialPinnedTransportProbe()
        let client = URLSessionTranslationOfficialHTTPTransport(
            addressResolver: { _ in try await resolver.resolve() },
            pinnedTransport: { request in await transport.perform(request) }
        )
        var request = URLRequest(
            url: URL(string: "https://translate.example.test/v2")!
        )
        request.timeoutInterval = 0.05
        let start = ContinuousClock.now
        let task = Task { try await client.data(for: request) }
        let resolverStarted = await resolver.waitUntilStarted()
        XCTAssertTrue(resolverStarted)
        do {
            _ = try await task.value
            XCTFail("Expected the overall request deadline")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            if case .transport = error {
                // Expected.
            } else {
                XCTFail("Unexpected deadline error: \(error)")
            }
        } catch {
            XCTFail("Unexpected deadline error: \(error)")
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1))
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
        await resolver.release()
    }

    func testLibreTranslateBaseURLPolicyRejectsInvalidExplicitPorts() throws {
        for rawValue in [
            "https://translate.example.test:0/v2",
            "https://translate.example.test:65536/v2",
            "https://translate.example.test:/v2",
            "https://translate.example.test:999999999999999999999/v2",
            "http://[::1]:/v2",
        ] {
            XCTAssertThrowsError(
                try LibreTranslateBaseURLPolicy.normalizedURLString(rawValue)
            ) { error in
                XCTAssertEqual(
                    error as? LibreTranslateBaseURLValidationError,
                    .invalidURL
                )
            }
        }
        XCTAssertEqual(
            try LibreTranslateBaseURLPolicy.normalizedURLString(
                "https://translate.example.test:65535/v2"
            ),
            "https://translate.example.test:65535/v2"
        )
        XCTAssertEqual(
            try LibreTranslateBaseURLPolicy.normalizedURLString(
                "http://127.0.0.1:80/v2"
            ),
            "http://127.0.0.1:80/v2"
        )
        XCTAssertEqual(
            try LibreTranslateBaseURLPolicy.normalizedURLString(
                "http://[::1]:80/v2"
            ),
            "http://[::1]:80/v2"
        )
    }

    func testOfficialHTTPSRejectsInvalidExplicitPortsBeforeResolution()
        async throws
    {
        let resolver = TranslationOfficialResolverProbe()
        let transport = TranslationOfficialPinnedTransportProbe()
        let client = URLSessionTranslationOfficialHTTPTransport(
            addressResolver: { host in await resolver.resolve(host: host) },
            pinnedTransport: { request in await transport.perform(request) }
        )
        let invalidURLs: [(rawValue: String, parsedPort: Int?)] = [
            ("https://translate.example.test:0/v2", 0),
            ("https://translate.example.test:65536/v2", 65_536),
            ("https://translate.example.test:/v2", nil),
            (
                "https://translate.example.test:999999999999999999999/v2",
                nil
            ),
        ]

        for invalidURL in invalidURLs {
            let url = try XCTUnwrap(URL(string: invalidURL.rawValue))
            XCTAssertEqual(url.port, invalidURL.parsedPort)
            do {
                _ = try await client.data(for: URLRequest(url: url))
                XCTFail("Expected an invalid explicit port")
            } catch let error as TranslationOfficialAdapterError {
                XCTAssertEqual(error, .invalidBaseURL)
            } catch {
                XCTFail("Unexpected invalid port error: \(error)")
            }
        }

        let resolverCallCount = await resolver.callCount()
        let transportCallCount = await transport.callCount()
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(transportCallCount, 0)
    }

    func testOfficialHTTPSPassesRemainingDeadlineToPinnedTransport()
        async throws
    {
        let resolver = TranslationOfficialDelayedResolver(delay: .milliseconds(50))
        let transport = TranslationOfficialPinnedTransportProbe()
        let client = URLSessionTranslationOfficialHTTPTransport(
            addressResolver: { _ in try await resolver.resolve() },
            pinnedTransport: { request in await transport.perform(request) }
        )
        var request = URLRequest(
            url: URL(string: "https://translate.example.test/v2")!
        )
        request.timeoutInterval = 0.2

        _ = try await client.data(for: request)

        let recordedTimeout = await transport.timeoutSeconds()
        let timeout = try XCTUnwrap(recordedTimeout)
        XCTAssertGreaterThan(timeout, 0)
        XCTAssertLessThan(timeout, request.timeoutInterval)
        let deadlineProvided = await transport.deadlineProvided()
        XCTAssertTrue(deadlineProvided)
    }

    func testOfficialHTTPSCallerCancellationReleasesBeforeResolver()
        async throws
    {
        let resolver = TranslationOfficialSuspendedResolver()
        let transport = TranslationOfficialPinnedTransportProbe()
        let client = URLSessionTranslationOfficialHTTPTransport(
            addressResolver: { _ in try await resolver.resolve() },
            pinnedTransport: { request in await transport.perform(request) }
        )
        let request = URLRequest(
            url: URL(string: "https://translate.example.test/v2")!
        )
        let task = Task { try await client.data(for: request) }
        let resolverStarted = await resolver.waitUntilStarted()
        XCTAssertTrue(resolverStarted)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected caller cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
        await resolver.release()
    }

    func testOfficialHTTPSDeadlineBoundsNonCooperativePinnedTransport()
        async throws
    {
        let transport = TranslationOfficialSuspendedPinnedTransport()
        let client = URLSessionTranslationOfficialHTTPTransport(
            addressResolver: { _ in [.ipv4("8.8.8.8")] },
            pinnedTransport: { request in try await transport.perform(request) }
        )
        var request = URLRequest(
            url: URL(string: "https://translate.example.test/v2")!
        )
        request.timeoutInterval = 0.05
        let start = ContinuousClock.now
        let task = Task { try await client.data(for: request) }
        let transportStarted = await transport.waitUntilStarted()
        XCTAssertTrue(transportStarted)
        do {
            _ = try await task.value
            XCTFail("Expected the overall request deadline")
        } catch let error as BlocksNativePluginNetworkBrokerError {
            if case .transport = error {
                // Expected.
            } else {
                XCTFail("Unexpected deadline error: \(error)")
            }
        } catch {
            XCTFail("Unexpected deadline error: \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        await transport.release()
        let finished = await transport.waitUntilFinished()
        XCTAssertTrue(finished)
    }

    func testOfficialHTTPSCallerCancellationReleasesBeforePinnedTransport()
        async throws
    {
        let transport = TranslationOfficialSuspendedPinnedTransport()
        let client = URLSessionTranslationOfficialHTTPTransport(
            addressResolver: { _ in [.ipv4("8.8.8.8")] },
            pinnedTransport: { request in try await transport.perform(request) }
        )
        let request = URLRequest(
            url: URL(string: "https://translate.example.test/v2")!
        )
        let task = Task { try await client.data(for: request) }
        let transportStarted = await transport.waitUntilStarted()
        XCTAssertTrue(transportStarted)
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected caller cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        await transport.release()
        let finished = await transport.waitUntilFinished()
        XCTAssertTrue(finished)
    }

    private func execute(
        profile: TranslationServiceProfile,
        credentials: [String: String],
        response: String
    ) async throws -> URLRequest {
        let transport = TranslationOfficialTransportProbe(
            responseData: Data(response.utf8)
        )
        let credentialStore = TranslationOfficialCredentialFixture(
            values: Dictionary(
                uniqueKeysWithValues: credentials.map {
                    ("\(profile.id)::\($0.key)", $0.value)
                }
            )
        )
        let libreCapabilities: LibreTranslateCapabilitySnapshot? =
            profile.templateID == .libreTranslate
            ? LibreTranslateCapabilitySnapshot(
                schemaVersion:
                    LibreTranslateCapabilitySnapshot.currentSchemaVersion,
                profileID: profile.id,
                profileRevision:
                    profile.updatedAt.timeIntervalSince1970,
                fetchedAt: Date(timeIntervalSince1970: 1),
                entries: [
                    LibreTranslateCapabilitySnapshot.Entry(
                        source: LibreTranslateCapabilitySnapshot.Language(
                            rawCode: "en",
                            tag: TranslationLanguageTag("en")!
                        ),
                        targets: [
                            LibreTranslateCapabilitySnapshot.Language(
                                rawCode: "zh",
                                tag: TranslationLanguageTag("zh-Hans")!
                            ),
                        ]
                    ),
                ]
            )
            : nil
        let adapter = TranslationOfficialServiceAdapter(
            profile: profile,
            credentialState: .configured,
            credentialStore: credentialStore,
            transport: transport,
            libreCapabilities: libreCapabilities,
            now: {
                Date(timeIntervalSince1970: 1_700_000_000)
            },
            nonce: { "fixture-nonce" }
        )
        let request = TranslationServiceRequest(
            sessionID: "official-fixture",
            input: TranslationInput(source: .manual, text: "Hello"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en-US"),
                target: TranslationLanguageTag("zh-Hans")!
            )
        )
        var output: String?
        for try await event in adapter.translate(request) {
            if case let .completed(text, _, _) = event {
                output = text
            }
        }
        XCTAssertEqual(output, "你好")
        let capturedRequest = await transport.lastRequest()
        return try XCTUnwrap(capturedRequest)
    }

    private func profile(
        _ templateID: TranslationServiceTemplateID,
        configuration: [String: JSONValue] = [:]
    ) -> TranslationServiceProfile {
        TranslationServiceProfile(
            id: "\(templateID.rawValue)-fixture",
            templateID: templateID,
            displayName: templateID.rawValue,
            configuration: configuration
        )
    }
}

final class TranslationPluginSecretWorkerTests: XCTestCase {
    @MainActor
    func testWorkerReadsConfiguredSecretStatusSeriallyOffMainActor()
        async throws
    {
        let store = TranslationPluginSecretFakeStore(
            configuredAccounts: ["plugin-a::TOKEN"]
        )
        let worker = TranslationPluginSecretWorker(store: store)
        let descriptors = [
            TranslationPluginSecretDescriptor(
                pluginID: "plugin-a",
                secretID: "TOKEN"
            ),
            TranslationPluginSecretDescriptor(
                pluginID: "plugin-a",
                secretID: "OTHER"
            ),
        ]

        let configured = try await worker.configuredKeys(for: descriptors)
        XCTAssertEqual(configured, ["plugin-a::TOKEN"])

        let snapshot = store.snapshot()
        XCTAssertFalse(snapshot.observedMainThread)
        XCTAssertEqual(snapshot.maximumConcurrentCalls, 1)
        XCTAssertTrue(snapshot.savedAccounts.isEmpty)
        XCTAssertTrue(snapshot.deletedAccounts.isEmpty)
    }
}

private final class TranslationPluginSecretFakeStore:
    BlocksNativePluginSecretStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var configuredAccounts: Set<String>
    private var activeCalls = 0
    private var maximumConcurrentCalls = 0
    private var observedMainThread = false
    private var savedAccounts: [String] = []
    private var deletedAccounts: [String] = []

    init(configuredAccounts: Set<String>) {
        self.configuredAccounts = configuredAccounts
    }

    func value(pluginID: String, secretID: String) throws -> String? {
        try contains(pluginID: pluginID, secretID: secretID)
            ? "configured"
            : nil
    }

    func contains(pluginID: String, secretID: String) throws -> Bool {
        withTrackedCall {
            configuredAccounts.contains(
                "\(pluginID)::\(secretID)"
            )
        }
    }

    func save(
        _ value: String,
        pluginID: String,
        secretID: String
    ) throws {
        withTrackedCall {
            let account = "\(pluginID)::\(secretID)"
            configuredAccounts.insert(account)
            savedAccounts.append(account)
        }
    }

    func delete(pluginID: String, secretID: String) throws {
        withTrackedCall {
            let account = "\(pluginID)::\(secretID)"
            configuredAccounts.remove(account)
            deletedAccounts.append(account)
        }
    }

    func snapshot() -> (
        observedMainThread: Bool,
        maximumConcurrentCalls: Int,
        savedAccounts: [String],
        deletedAccounts: [String]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            observedMainThread,
            maximumConcurrentCalls,
            savedAccounts,
            deletedAccounts
        )
    }

    private func withTrackedCall<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        activeCalls += 1
        maximumConcurrentCalls = max(
            maximumConcurrentCalls,
            activeCalls
        )
        observedMainThread = observedMainThread || Thread.isMainThread
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.01)

        lock.lock()
        defer {
            activeCalls -= 1
            lock.unlock()
        }
        return body()
    }
}

@MainActor
private final class ControlledRetryTranslationAdapter:
    TranslationServiceAdapter
{
    let descriptor = TranslationServiceDescriptor(
        id: "plugin:retry-controlled",
        displayName: "Retry Controlled",
        kind: .plugin
    )
    private var continuations: [
        AsyncThrowingStream<TranslationServiceEvent, Error>.Continuation
    ] = []

    var attemptCount: Int {
        continuations.count
    }

    func translate(
        _: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuations.append(continuation)
        }
    }

    func succeed(attempt: Int, text: String) {
        guard continuations.indices.contains(attempt) else { return }
        continuations[attempt].yield(.completed(text))
        continuations[attempt].finish()
    }

    func fail(attempt: Int, error: Error) {
        guard continuations.indices.contains(attempt) else { return }
        continuations[attempt].finish(throwing: error)
    }
}

@MainActor
private final class ControlledStreamingTranslationAdapter:
    TranslationServiceAdapter
{
    let descriptor: TranslationServiceDescriptor
    private var continuation:
        AsyncThrowingStream<
            TranslationServiceEvent,
            Error
        >.Continuation?

    private(set) var attemptCount = 0

    init(id: String) {
        descriptor = TranslationServiceDescriptor(
            id: id,
            displayName: id,
            kind: .plugin,
            availability: .available,
            supportsStreaming: true
        )
    }

    func translate(
        _: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        attemptCount += 1
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func yieldPartial(_ text: String) {
        continuation?.yield(.partial(text))
    }

    func complete(_ text: String) {
        continuation?.yield(.completed(text))
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class TestTranslationAdapter: TranslationServiceAdapter {
    let descriptor: TranslationServiceDescriptor
    let requiresExplicitSourceLanguage: Bool
    let acceptedInputs: Set<TranslationSourceAcceptedInput>
    private(set) var translateCallCount = 0
    private(set) var requestedTexts: [String] = []
    private(set) var requestedAttachmentCounts: [Int] = []
    private let delay: Duration
    private let result: Result<String, Error>

    init(
        id: String,
        delay: Duration = .zero,
        result: Result<String, Error>? = nil,
        supportedTargetLanguages: [TranslationLanguageTag] = [],
        requiresExplicitSourceLanguage: Bool = false,
        acceptedInputs: Set<TranslationSourceAcceptedInput> = [.text]
    ) {
        descriptor = TranslationServiceDescriptor(
            id: id,
            displayName: id,
            kind: .plugin,
            availability: .available,
            supportsStreaming: false,
            supportedTargetLanguages: supportedTargetLanguages
        )
        self.delay = delay
        self.result = result ?? .success(id)
        self.requiresExplicitSourceLanguage =
            requiresExplicitSourceLanguage
        self.acceptedInputs = acceptedInputs
    }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        translateCallCount += 1
        requestedTexts.append(request.input.text)
        requestedAttachmentCounts.append(
            request.attachments.count
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: delay)
                    try Task.checkCancellation()
                    switch result {
                    case let .success(text):
                        continuation.yield(
                            TranslationServiceEvent.completed(
                                text,
                                warnings: []
                            )
                        )
                        continuation.finish()
                    case let .failure(error):
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private final class DiagnosticTranslationAdapter:
    TranslationServiceAdapter
{
    let descriptor = TranslationServiceDescriptor(
        id: "diagnostic-fixture",
        displayName: "Diagnostic Fixture",
        kind: .openAICompatible
    )
    private let diagnostics: TranslationResultDiagnostics

    init(diagnostics: TranslationResultDiagnostics) {
        self.diagnostics = diagnostics
    }

    func translate(
        _: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .completed(
                    "translated",
                    diagnostics: diagnostics
                )
            )
            continuation.finish()
        }
    }
}

@MainActor
private final class SourceOutputTranslationAdapter:
    TranslationServiceAdapter
{
    let descriptor = TranslationServiceDescriptor(
        id: "source-output-fixture",
        displayName: "Source Output Fixture",
        kind: .plugin
    )

    func translate(
        _: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .source(
                    .completed(
                        TranslationSourceOutput(
                            text: "积木",
                            detectedSourceLanguage:
                                TranslationLanguageTag("en"),
                            metadata: [
                                "provider": .string("fixture"),
                            ]
                        )
                    )
                )
            )
            continuation.finish()
        }
    }
}

private struct HTTPStatusOpenAIConnectionTransport:
    OpenAIConnectionTransport
{
    let statusCode: Int

    func perform(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        OpenAIConnectionTransportResponse(
            httpResponse: HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["x-request-id": "fixture-request"]
            )!,
            data: Data()
        )
    }
}

private struct ThrowingOpenAIConnectionTransport:
    OpenAIConnectionTransport
{
    func perform(
        _: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private struct SuccessfulTranslationTransport:
    OpenAIConnectionTransport
{
    func perform(
        _ request: URLRequest,
        timeoutSeconds _: Int
    ) async throws -> OpenAIConnectionTransportResponse {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["x-request-id": "fixture-request"]
        )!
        return OpenAIConnectionTransportResponse(
            httpResponse: response,
            data: Data(
                #"{"choices":[{"message":{"content":"积木"}}]}"#.utf8
            )
        )
    }
}

private actor TranslationOfficialTransportProbe:
    TranslationOfficialHTTPTransport
{
    private let responseData: Data
    private var recordedRequest: URLRequest?

    init(responseData: Data) {
        self.responseData = responseData
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        recordedRequest = request
        return (
            responseData,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func lastRequest() -> URLRequest? {
        recordedRequest
    }
}

private actor AppleSupportedLanguagesProviderProbe {
    private let responses: [[TranslationLanguageTag]]
    private let suspendsFirstResponse: Bool
    private var storedCallCount = 0
    private var firstCallStarted = false
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstResponseContinuation:
        CheckedContinuation<[TranslationLanguageTag], Never>?

    init(
        responses: [[TranslationLanguageTag]] = [[]],
        suspendsFirstResponse: Bool = false
    ) {
        self.responses = responses
        self.suspendsFirstResponse = suspendsFirstResponse
    }

    func languages() async -> [TranslationLanguageTag] {
        let callIndex = storedCallCount
        storedCallCount += 1
        if callIndex == 0 {
            firstCallStarted = true
            let waiters = firstCallWaiters
            firstCallWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if suspendsFirstResponse {
                return await withCheckedContinuation { continuation in
                    firstResponseContinuation = continuation
                }
            }
        }
        return responses[min(callIndex, responses.count - 1)]
    }

    func callCount() -> Int {
        storedCallCount
    }

    func waitUntilFirstCallStarts() async {
        guard !firstCallStarted else { return }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }

    func releaseFirstResponse(with languages: [TranslationLanguageTag]) {
        firstResponseContinuation?.resume(returning: languages)
        firstResponseContinuation = nil
    }
}

private actor TranslationCommunityTransportProbe:
    TranslationCommunityWebHTTPTransport
{
    private let responsesByHost: [String: Data]
    private var capturedRequests: [URLRequest] = []

    init(responsesByHost: [String: Data]) {
        self.responsesByHost = responsesByHost
    }

    func data(
        for request: URLRequest,
        allowedHosts: Set<String>
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let host = try XCTUnwrap(url.host?.lowercased())
        XCTAssertTrue(allowedHosts.contains(host))
        capturedRequests.append(request)
        let responseData = try XCTUnwrap(responsesByHost[host])
        return (
            responseData,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}

private actor TranslationOfficialSuspendedResolver {
    private var started = false
    private var startWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var continuation: CheckedContinuation<
        [BlocksNativePluginResolvedAddress], Error
    >?

    func resolve() async throws -> [BlocksNativePluginResolvedAddress] {
        started = true
        let waiters = startWaiters
        startWaiters = [:]
        waiters.values.forEach { $0.resume(returning: true) }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async -> Bool {
        guard !started else { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            startWaiters[waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.timeoutStartWaiter(waiterID)
            }
        }
    }

    func release() {
        continuation?.resume(returning: [.ipv4("8.8.8.8")])
        continuation = nil
    }

    private func timeoutStartWaiter(_ waiterID: UUID) {
        startWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}

private actor TranslationOfficialResolverProbe {
    private var storedCallCount = 0

    func resolve(
        host _: String
    ) -> [BlocksNativePluginResolvedAddress] {
        storedCallCount += 1
        return [.ipv4("8.8.8.8")]
    }

    func callCount() -> Int {
        storedCallCount
    }
}

private actor TranslationOfficialDelayedResolver {
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func resolve() async throws -> [BlocksNativePluginResolvedAddress] {
        try await Task.sleep(for: delay)
        return [.ipv4("8.8.8.8")]
    }
}

private actor TranslationOfficialSuspendedPinnedTransport {
    private var started = false
    private var startWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var finishWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var continuation: CheckedContinuation<
        BlocksNativePluginPinnedHTTPResponse, Error
    >?
    private var pendingInvocationCount = 0

    func perform(
        _: BlocksNativePluginPinnedHTTPRequest
    ) async throws -> BlocksNativePluginPinnedHTTPResponse {
        pendingInvocationCount += 1
        defer {
            pendingInvocationCount -= 1
            if pendingInvocationCount == 0 {
                let waiters = finishWaiters
                finishWaiters = [:]
                waiters.values.forEach { $0.resume(returning: true) }
            }
        }
        started = true
        let waiters = startWaiters
        startWaiters = [:]
        waiters.values.forEach { $0.resume(returning: true) }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async -> Bool {
        guard !started else { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            startWaiters[waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.timeoutStartWaiter(waiterID)
            }
        }
    }

    func release() {
        continuation?.resume(
            returning: BlocksNativePluginPinnedHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data("{}".utf8)
            )
        )
        continuation = nil
    }

    func waitUntilFinished() async -> Bool {
        guard pendingInvocationCount == 0 else {
            let waiterID = UUID()
            return await withCheckedContinuation { continuation in
                finishWaiters[waiterID] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    await self?.timeoutFinishWaiter(waiterID)
                }
            }
        }
        return true
    }

    private func timeoutStartWaiter(_ waiterID: UUID) {
        startWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }

    private func timeoutFinishWaiter(_ waiterID: UUID) {
        finishWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}

private actor TranslationOfficialPinnedTransportProbe {
    private var recordedTimeoutSeconds: Double?
    private var recordedDeadlineWasProvided = false
    private var storedCallCount = 0

    func perform(
        _ request: BlocksNativePluginPinnedHTTPRequest
    ) -> BlocksNativePluginPinnedHTTPResponse {
        storedCallCount += 1
        recordedTimeoutSeconds = request.request.timeoutSeconds
        recordedDeadlineWasProvided = request.deadline != nil
        return BlocksNativePluginPinnedHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("{}".utf8)
        )
    }

    func callCount() -> Int {
        storedCallCount
    }

    func timeoutSeconds() -> Double? {
        recordedTimeoutSeconds
    }

    func deadlineProvided() -> Bool {
        recordedDeadlineWasProvided
    }
}

private final class TranslationOfficialCredentialFixture:
    TranslationServiceCredentialStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values: [String: String]
    private let failingKeys: Set<String>
    private var observedMainThreadRead = false

    init(
        values: [String: String],
        failingKeys: Set<String> = []
    ) {
        self.values = values
        self.failingKeys = failingKeys
    }

    func read(profileID: String, fieldID: String) throws -> String {
        guard let value = try value(
            profileID: profileID,
            fieldID: fieldID
        ) else {
            throw TranslationServiceCredentialStoreError
                .missingCredential(fieldID)
        }
        return value
    }

    func value(profileID: String, fieldID: String) throws -> String? {
        let key = "\(profileID)::\(fieldID)"
        lock.lock()
        observedMainThreadRead = observedMainThreadRead
            || Thread.isMainThread
        let shouldFail = failingKeys.contains(key)
        let value = values[key]
        lock.unlock()
        if shouldFail {
            throw TranslationServiceCredentialStoreError
                .keychain(errSecInteractionNotAllowed)
        }
        return value
    }

    func contains(profileID: String, fieldID: String) throws -> Bool {
        try value(profileID: profileID, fieldID: fieldID) != nil
    }

    func save(
        _ value: String,
        profileID: String,
        fieldID: String
    ) throws {
        XCTFail("Credential fixture is read-only")
    }

    func delete(profileID: String, fieldID: String) throws {
        XCTFail("Credential fixture is read-only")
    }

    var didReadOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedMainThreadRead
    }
}

private final class TranslationOfficialURLProtocolFixture:
    URLProtocol,
    @unchecked Sendable
{
    enum Mode {
        case blocking
        case success
        case delayedSuccess(delay: Duration)
        case oversized(contentLength: Int)
        case oversizedHeaderOnly(contentLength: Int)
        case redirect
    }

    final class RedirectState: @unchecked Sendable {
        enum Outcome {
            case denied
            case targetReached
            case timedOut
            case cancelled
        }

        private let lock = NSLock()
        private let outcomeSignal = DispatchSemaphore(value: 0)
        let statusCode: Int
        let identifier = UUID().uuidString
        let targetResponseBody = Data("redirect target reached".utf8)
        private var isCancelled = false
        private var storedSourceRequestCount = 0
        private var storedTargetRequestCount = 0
        private var storedTargetAuthorizationHeader: String?
        private var storedTargetBody: Data?
        private var storedRedirectWasProposed = false
        private var storedRedirectDeniedCallbackCount = 0

        init(statusCode: Int) {
            self.statusCode = statusCode
        }

        var sourceURL: URL {
            URL(
                string: "http://127.0.0.1:5000/translate?redirect-fixture-id=\(identifier)"
            )!
        }

        var targetURL: URL {
            URL(
                string: "https://unapproved.example.test/receive?redirect-fixture-id=\(identifier)"
            )!
        }

        var sourceRequestCount: Int {
            lock.withLock { storedSourceRequestCount }
        }

        var targetRequestCount: Int {
            lock.withLock { storedTargetRequestCount }
        }

        var targetAuthorizationHeader: String? {
            lock.withLock { storedTargetAuthorizationHeader }
        }

        var targetBody: Data? {
            lock.withLock { storedTargetBody }
        }

        var redirectWasProposed: Bool {
            lock.withLock { storedRedirectWasProposed }
        }

        var redirectDeniedCallbackCount: Int {
            lock.withLock { storedRedirectDeniedCallbackCount }
        }

        func isSourceURL(_ url: URL?) -> Bool {
            url == sourceURL
        }

        func isTargetURL(_ url: URL?) -> Bool {
            url == targetURL
        }

        func recordSourceRedirectProposal() {
            lock.withLock {
                storedSourceRequestCount += 1
                storedRedirectWasProposed = true
            }
        }

        func recordRedirectDenied() {
            lock.withLock { storedRedirectDeniedCallbackCount += 1 }
            outcomeSignal.signal()
        }

        func recordTarget(_ request: URLRequest) {
            lock.withLock {
                storedTargetRequestCount += 1
                storedTargetAuthorizationHeader = request.value(
                    forHTTPHeaderField: "Authorization"
                )
                storedTargetBody = request.httpBody
            }
            outcomeSignal.signal()
        }

        func waitForRedirectOutcome() -> Outcome {
            guard outcomeSignal.wait(timeout: .now() + .milliseconds(500))
                == .success
            else {
                return lock.withLock {
                    isCancelled ? .cancelled : .timedOut
                }
            }
            return lock.withLock {
                if isCancelled { return .cancelled }
                if storedRedirectDeniedCallbackCount > 0 { return .denied }
                if storedTargetRequestCount > 0 { return .targetReached }
                return .timedOut
            }
        }

        func cancel() {
            lock.withLock { isCancelled = true }
            outcomeSignal.signal()
        }
    }

    private static let stateLock = NSLock()
    private static let redirectQueue = DispatchQueue(
        label: "TranslationOfficialURLProtocolFixture.redirect"
    )
    nonisolated(unsafe) private static var mode: Mode = .blocking
    nonisolated(unsafe) private static var redirectStates: [String: RedirectState] = [:]
    nonisolated(unsafe) private static var storedStartCount = 0
    nonisolated(unsafe) private static var storedStopCount = 0
    nonisolated(unsafe) private static var storedBodySendCount = 0
    nonisolated(unsafe) private static var storedSourceRequestCount = 0
    nonisolated(unsafe) private static var storedTargetRequestCount = 0
    nonisolated(unsafe) private static var storedTargetAuthorizationHeader: String?
    nonisolated(unsafe) private static var storedTargetBody: Data?
    nonisolated(unsafe) private static var storedRedirectWasProposed = false
    private var delayedResponseTask: Task<Void, Never>?
    private var redirectWorkItem: DispatchWorkItem?
    private var redirectState: RedirectState?

    static var startCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedStartCount
    }

    static var stopCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedStopCount
    }

    static var bodySendCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedBodySendCount
    }

    static var sourceRequestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedSourceRequestCount
    }

    static var targetRequestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedTargetRequestCount
    }

    static var targetAuthorizationHeader: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedTargetAuthorizationHeader
    }

    static var targetBody: Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedTargetBody
    }

    static var redirectWasProposed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedRedirectWasProposed
    }

    static func setMode(_ mode: Mode) {
        stateLock.lock()
        self.mode = mode
        storedStartCount = 0
        storedStopCount = 0
        storedBodySendCount = 0
        storedSourceRequestCount = 0
        storedTargetRequestCount = 0
        storedTargetAuthorizationHeader = nil
        storedTargetBody = nil
        storedRedirectWasProposed = false
        stateLock.unlock()
    }

    static func installRedirect(_ state: RedirectState) {
        stateLock.withLock {
            mode = .redirect
            redirectStates[state.identifier] = state
        }
    }

    static func uninstallRedirect(_ state: RedirectState) {
        stateLock.withLock {
            redirectStates[state.identifier] = nil
            if redirectStates.isEmpty, case .redirect = mode {
                mode = .blocking
            }
        }
    }

    private static func redirectState(for url: URL?) -> RedirectState? {
        guard let url,
              let identifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?
              .first(where: { $0.name == "redirect-fixture-id" })?
              .value
        else {
            return nil
        }
        return stateLock.withLock { redirectStates[identifier] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.stateLock.lock()
        let mode = Self.mode
        Self.storedStartCount += 1
        Self.stateLock.unlock()
        if let state = Self.redirectState(for: request.url) {
            if state.isSourceURL(request.url) {
                startRedirectSource(state)
            } else if state.isTargetURL(request.url) {
                loadRedirectTarget(state)
            } else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.badURL)
                )
            }
            return
        }
        switch mode {
        case .blocking:
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                cacheStoragePolicy: .notAllowed
            )
        case .success:
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data("success".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .delayedSuccess(delay):
            delayedResponseTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.client?.urlProtocol(
                    self,
                    didReceive: HTTPURLResponse(
                        url: self.request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!,
                    cacheStoragePolicy: .notAllowed
                )
                self.client?.urlProtocol(
                    self,
                    didLoad: Data("late".utf8)
                )
                self.client?.urlProtocolDidFinishLoading(self)
            }
        case let .oversized(contentLength):
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                cacheStoragePolicy: .notAllowed
            )
            Self.stateLock.lock()
            Self.storedBodySendCount += 1
            Self.stateLock.unlock()
            client?.urlProtocol(
                self,
                didLoad: Data(repeating: 0, count: contentLength)
            )
            client?.urlProtocolDidFinishLoading(self)
        case let .oversizedHeaderOnly(contentLength):
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": "\(contentLength)",
                    ]
                )!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
        }
    }

    private func startRedirectSource(_ state: RedirectState) {
        redirectState = state
        let redirectResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: state.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": state.targetURL.absoluteString]
        )!
        let workItem = DispatchWorkItem { [weak self, state] in
            guard let self else { return }
            state.recordSourceRedirectProposal()
            self.client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: state.targetURL),
                redirectResponse: redirectResponse
            )
            switch state.waitForRedirectOutcome() {
            case .denied:
                self.client?.urlProtocol(
                    self,
                    didReceive: redirectResponse,
                    cacheStoragePolicy: .notAllowed
                )
                self.client?.urlProtocolDidFinishLoading(self)
            case .targetReached, .cancelled:
                break
            case .timedOut:
                self.client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.timedOut)
                )
            }
        }
        redirectWorkItem = workItem
        Self.redirectQueue.async(execute: workItem)
    }

    private func loadRedirectTarget(_ state: RedirectState) {
        state.recordTarget(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: state.targetResponseBody
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        delayedResponseTask?.cancel()
        delayedResponseTask = nil
        redirectWorkItem?.cancel()
        redirectWorkItem = nil
        redirectState?.cancel()
        redirectState = nil
        Self.stateLock.lock()
        Self.storedStopCount += 1
        Self.stateLock.unlock()
    }
}

private final class TranslationSecretReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func recordRead() {
        lock.withLock { storedCallCount += 1 }
    }
}

private final class BlockingTranslationSecretReader: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let material: ProviderUserSecretMaterial
    private var storedCallCount = 0

    init(material: ProviderUserSecretMaterial) {
        self.material = material
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func read() -> ProviderUserSecretMaterial {
        lock.withLock { storedCallCount += 1 }
        entered.signal()
        releaseSignal.wait()
        return material
    }

    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [entered] in
                continuation.resume(
                    returning: entered.wait(timeout: .now() + 1) == .success
                )
            }
        }
    }

    func release() {
        releaseSignal.signal()
    }
}

private final class TranslationRuntimeAuditProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: OpenAITranslationRuntimeResult?
    private var storedCallCount = 0

    var result: OpenAITranslationRuntimeResult? {
        lock.withLock { storedResult }
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func record(_ result: OpenAITranslationRuntimeResult) {
        lock.withLock {
            storedCallCount += 1
            storedResult = result
        }
    }
}

private final class TranslationAuditTokenSourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let source: ProviderAuditTokenSource
    private var storedCallCount = 0

    init(source: @escaping ProviderAuditTokenSource) {
        self.source = source
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func capture() -> ProviderAuditToken {
        lock.withLock { storedCallCount += 1 }
        return source()
    }
}

private final class TranslationPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func recordCall() {
        lock.withLock { storedCallCount += 1 }
    }
}

private final class AuthorizationCheckSequenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Bool]
    private var index = 0

    init(values: [Bool]) {
        self.values = values
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func nextValue() -> Bool {
        lock.withLock {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }
}

private actor SuspendedTranslationCopyProbe {
    private(set) var copiedTexts: [String] = []
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func copy(_ text: String) async {
        copiedTexts.append(text)
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor SuspendedPluginRuntimeEnableProbe {
    private var firstEnableStarted = false
    private var firstEnableContinuation: CheckedContinuation<Void, Never>?
    private var firstEnableStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var enabledPluginIDs: Set<String> = []
    private var enablementCallCount = 0

    func setEnabled(_ enabled: Bool, pluginID: String) async {
        enablementCallCount += 1
        if enabled, !firstEnableStarted {
            firstEnableStarted = true
            let waiters = firstEnableStartWaiters
            firstEnableStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstEnableContinuation = continuation
            }
        }
        if enabled {
            enabledPluginIDs.insert(pluginID)
        } else {
            enabledPluginIDs.remove(pluginID)
        }
    }

    func waitUntilFirstEnableStarts() async {
        guard !firstEnableStarted else { return }
        await withCheckedContinuation { continuation in
            firstEnableStartWaiters.append(continuation)
        }
    }

    func releaseFirstEnable() {
        firstEnableContinuation?.resume()
        firstEnableContinuation = nil
    }

    func isEnabled(pluginID: String) -> Bool {
        enabledPluginIDs.contains(pluginID)
    }

    var callCount: Int {
        enablementCallCount
    }
}

private actor SuspendedPluginRuntimeDisableProbe {
    private var firstDisableStarted = false
    private var firstDisableContinuation: CheckedContinuation<Void, Never>?
    private var firstDisableStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var enabledPluginIDs: Set<String>

    init(initiallyEnabledPluginIDs: Set<String>) {
        enabledPluginIDs = initiallyEnabledPluginIDs
    }

    func setEnabled(_ enabled: Bool, pluginID: String) async throws {
        if !enabled, !firstDisableStarted {
            firstDisableStarted = true
            let waiters = firstDisableStartWaiters
            firstDisableStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            try await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    firstDisableContinuation = continuation
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancelFirstDisable() }
            }
        }
        if enabled {
            enabledPluginIDs.insert(pluginID)
        } else {
            enabledPluginIDs.remove(pluginID)
        }
    }

    func waitUntilFirstDisableStarts() async {
        guard !firstDisableStarted else { return }
        await withCheckedContinuation { continuation in
            firstDisableStartWaiters.append(continuation)
        }
    }

    func isEnabled(pluginID: String) -> Bool {
        enabledPluginIDs.contains(pluginID)
    }

    private func cancelFirstDisable() {
        firstDisableContinuation?.resume()
        firstDisableContinuation = nil
    }
}

private actor OpenAIPinnedTransportProbe {
    private var requests: [BlocksNativePluginPinnedHTTPRequest] = []

    func perform(
        _ request: BlocksNativePluginPinnedHTTPRequest
    ) async throws -> BlocksNativePluginPinnedHTTPResponse {
        requests.append(request)
        return BlocksNativePluginPinnedHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"choices":[{"message":{"content":"fixture"}}]}"#.utf8)
        )
    }

    func invocationCount() -> Int { requests.count }

    func timeoutSeconds() -> Double? { requests.first?.request.timeoutSeconds }
}

private actor OpenAISuspendedResolver {
    private let onStarted: @Sendable () -> Void
    private let onFinished: @Sendable () -> Void
    private var continuation: CheckedContinuation<
        [BlocksNativePluginResolvedAddress], Error
    >?

    init(
        onStarted: @escaping @Sendable () -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.onStarted = onStarted
        self.onFinished = onFinished
    }

    func resolve() async throws -> [BlocksNativePluginResolvedAddress] {
        onStarted()
        defer { onFinished() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume(returning: [.ipv4("8.8.8.8")])
        continuation = nil
    }
}

private actor OpenAISuspendedPinnedTransport {
    private let onStarted: @Sendable () -> Void
    private let onFinished: @Sendable () -> Void
    private var continuation: CheckedContinuation<
        BlocksNativePluginPinnedHTTPResponse, Error
    >?

    init(
        onStarted: @escaping @Sendable () -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.onStarted = onStarted
        self.onFinished = onFinished
    }

    func perform(
        _: BlocksNativePluginPinnedHTTPRequest
    ) async throws -> BlocksNativePluginPinnedHTTPResponse {
        onStarted()
        defer { onFinished() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume(
            returning: BlocksNativePluginPinnedHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data()
            )
        )
        continuation = nil
    }
}

private final class OpenAIHeaderSessionProbe:
    OpenAIURLSessionLoading,
    @unchecked Sendable
{
    func data(
        for request: URLRequest,
        delegate _: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "x-request-id": String(repeating: "x", count: 8_192),
                "Set-Cookie": "secret=must-not-propagate",
            ]
        )!
        return (Data(), response)
    }
}
