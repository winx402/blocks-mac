@testable import Blocks
@testable import BlocksCore
import Foundation
import XCTest

@MainActor
final class TranslationCommunityWebNetworkFeedbackTests: XCTestCase {
    /// Explicit local probe only: sends the fixed non-personal text "Hello".
    /// Normal CI and offline tests must never depend on a community endpoint.
    func testLiveCommunityConnectionTestsWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BLOCKS_LIVE_COMMUNITY_PROBE"] == "1" else {
            throw XCTSkip("Live community requests require explicit opt-in.")
        }
        let suite = "LiveCommunityProbe.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let disclosures = TranslationCommunityWebDisclosureStore(defaults: defaults)
        let store = TranslationStore(defaults: defaults)
        let service = TranslationSourceManagementService(
            pluginManager: BlocksNativePluginManager(storageUnavailableBecause: NSError(domain: "fixture", code: 1)),
            translationStore: store,
            communityDisclosureStore: disclosures
        )
        for source in TranslationCommunityWebSource.productionAvailable {
            disclosures.acknowledge(source: source)
            try await service.setSourceEnabled(true, sourceID: source.rawValue)
            let result = await service.testSource(sourceID: source.rawValue, testText: "Hello")
            print("LIVE_COMMUNITY \(source.rawValue) succeeded=\(result.succeeded) code=\(result.errorCode ?? "none")")
            XCTAssertTrue(result.succeeded, "\(source.rawValue): \(result.errorCode ?? "unknown")")
        }
    }

    func testManagementConnectionTestPreservesNetworkCategoriesAndPresentation() async {
        let cases: [(NetworkFeedbackTransport, String, String)] = [
            (.init(urlErrorCode: URLError.Code.networkConnectionLost.rawValue), "network_connection_lost", "-1005"),
            (.init(urlErrorCode: URLError.Code.timedOut.rawValue), "network_timed_out", "-1001"),
            (.init(statusCode: 429), "network_rate_limited", "429")
        ]
        for (transport, code, marker) in cases {
            let suite = "CommunityManagementFeedback.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let disclosures = TranslationCommunityWebDisclosureStore(defaults: defaults)
            disclosures.acknowledge(source: .googleWeb)
            let store = TranslationStore(communityWebTransport: transport, defaults: defaults)
            let service = TranslationSourceManagementService(
                pluginManager: BlocksNativePluginManager(storageUnavailableBecause: NSError(domain: "fixture", code: 1)),
                translationStore: store,
                communityDisclosureStore: disclosures
            )
            let result = await service.testSource(sourceID: "community:google-web")
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.errorCode, code)
            XCTAssertEqual(result.errorMessage, TranslationErrorPresentation.message(code: code, fallback: nil))
            XCTAssertTrue(result.errorMessage?.contains(marker) == true)
            do {
                _ = try await service.execute(.init(operation: .test, sourceID: "community:google-web"))
                XCTFail("A failed test must not become a successful CLI action.")
            } catch let error as TranslationSourceManagementServiceError {
                XCTAssertEqual(error.code, code)
                XCTAssertTrue(error.localizedDescription.contains(marker))
            } catch {
                XCTFail("Unexpected error category: \(error)")
            }
        }
    }

    func testNetworkConnectionLostHasStableCodeAndRecoveryMessage()
        async
    {
        let outcome = await runCommunityTranslation(
            transport: NetworkFeedbackTransport(
                urlErrorCode: URLError.Code.networkConnectionLost.rawValue
            )
        )

        XCTAssertEqual(outcome.errorCode, "network_connection_lost")
        XCTAssertEqual(outcome.diagnosticCodes, ["network_connection_lost"])
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(
            outcome.message,
            L10n.string(
                "translation.community.error.networkConnectionLost"
            )
        )
        XCTAssertTrue(outcome.message?.contains("-1005") == true)
    }

    func testTimeoutAndHTTP429RemainDistinctRecoveryCategories() async {
        let timedOut = await runCommunityTranslation(
            transport: NetworkFeedbackTransport(
                urlErrorCode: URLError.Code.timedOut.rawValue
            )
        )
        let rateLimited = await runCommunityTranslation(
            transport: NetworkFeedbackTransport(statusCode: 429)
        )

        XCTAssertEqual(timedOut.errorCode, "network_timed_out")
        XCTAssertEqual(timedOut.diagnosticCodes, ["network_timed_out"])
        XCTAssertEqual(
            timedOut.message,
            L10n.string("translation.community.error.networkTimedOut")
        )
        XCTAssertTrue(timedOut.message?.contains("-1001") == true)

        XCTAssertEqual(rateLimited.errorCode, "network_rate_limited")
        XCTAssertEqual(rateLimited.diagnosticCodes, ["network_rate_limited"])
        XCTAssertEqual(
            rateLimited.message,
            L10n.string(
                "translation.community.error.networkRateLimited"
            )
        )
        XCTAssertTrue(rateLimited.message?.contains("429") == true)
    }

    func testCancelledTransportRemainsCancellationWithoutDiagnostics()
        async
    {
        let outcome = await runCommunityTranslation(
            transport: NetworkFeedbackTransport(
                urlErrorCode: URLError.Code.cancelled.rawValue
            )
        )

        XCTAssertTrue(outcome.cancelled)
        XCTAssertNil(outcome.errorCode)
        XCTAssertTrue(outcome.diagnosticCodes.isEmpty)
    }

    private func runCommunityTranslation(
        transport: any TranslationCommunityWebHTTPTransport
    ) async -> CommunityTranslationOutcome {
        let suiteName = "TranslationCommunityWebNetworkFeedbackTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let disclosures = TranslationCommunityWebDisclosureStore(
            defaults: defaults
        )
        disclosures.acknowledge(source: .googleWeb)
        let adapter = TranslationCommunityWebServiceAdapter(
            source: .googleWeb,
            transport: transport,
            disclosureStore: disclosures
        )
        let request = TranslationServiceRequest(
            sessionID: "network-feedback-fixture",
            input: TranslationInput(source: .manual, text: "Hello"),
            direction: TranslationLanguageDirection(
                source: TranslationLanguageTag("en"),
                target: TranslationLanguageTag("zh-Hans")!
            )
        )

        var diagnosticCodes: [String] = []
        do {
            for try await event in adapter.translate(request) {
                if case let .diagnostics(diagnostics, _) = event {
                    diagnosticCodes.append(diagnostics.status)
                }
            }
            return CommunityTranslationOutcome(
                diagnosticCodes: diagnosticCodes
            )
        } catch is CancellationError {
            return CommunityTranslationOutcome(
                diagnosticCodes: diagnosticCodes,
                cancelled: true
            )
        } catch let error as TranslationServiceAdapterError {
            return CommunityTranslationOutcome(
                errorCode: error.errorCode,
                message: TranslationErrorPresentation.message(for: error),
                diagnosticCodes: diagnosticCodes
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
            return CommunityTranslationOutcome(
                diagnosticCodes: diagnosticCodes
            )
        }
    }
}

private struct CommunityTranslationOutcome {
    let errorCode: String?
    let message: String?
    let diagnosticCodes: [String]
    let cancelled: Bool

    init(
        errorCode: String? = nil,
        message: String? = nil,
        diagnosticCodes: [String],
        cancelled: Bool = false
    ) {
        self.errorCode = errorCode
        self.message = message
        self.diagnosticCodes = diagnosticCodes
        self.cancelled = cancelled
    }
}

private actor NetworkFeedbackTransport: TranslationCommunityWebHTTPTransport {
    private let urlErrorCode: Int?
    private let statusCode: Int

    init(urlErrorCode: Int? = nil, statusCode: Int = 200) {
        self.urlErrorCode = urlErrorCode
        self.statusCode = statusCode
    }

    func data(
        for request: URLRequest,
        allowedHosts: Set<String>
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let host = try XCTUnwrap(url.host?.lowercased())
        XCTAssertTrue(allowedHosts.contains(host))
        if let urlErrorCode {
            throw URLError(URLError.Code(rawValue: urlErrorCode))
        }
        return (
            Data(#"[[[\"你好\",\"Hello\",null,null,10]],null,\"en\"]"#.utf8),
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}
