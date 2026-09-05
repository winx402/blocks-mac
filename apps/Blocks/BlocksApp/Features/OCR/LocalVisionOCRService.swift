import CoreGraphics
import Foundation
import ImageIO
import OSLog
@preconcurrency import Vision

enum LocalVisionOCRTimingTerminal: String, Codable, Sendable { case success, failure, cancelled }

struct LocalVisionOCRPassTimingSnapshot: Codable, Sendable {
    let ordinal: Int
    let passKind: String
    let pixelBucket: String
    let terminal: LocalVisionOCRTimingTerminal
    let requestConstructionMilliseconds: Double
    let queueWaitMilliseconds: Double
    let handlerConstructionMilliseconds: Double
    let performMilliseconds: Double
    let mappingMilliseconds: Double
    let adapterTotalMilliseconds: Double
    let unattributedMilliseconds: Double
}

struct LocalVisionOCRTimingSnapshot: Codable, Sendable {
    let recognitionID: UUID
    let terminal: LocalVisionOCRTimingTerminal
    let totalMilliseconds: Double
    let supportedLanguagesCacheHit: Bool
    let supportedLanguagesMilliseconds: Double
    /// This includes supported-language resolution; consumers must not add it again.
    let requestConfigurationMilliseconds: Double
    let layoutMilliseconds: Double
    let requestCount: Int
    let passes: [LocalVisionOCRPassTimingSnapshot]
    let serviceUnattributedMilliseconds: Double
}

protocol LocalVisionOCRTimingClock: Sendable { func nowNanoseconds() -> UInt64 }
struct LocalVisionOCRSystemTimingClock: LocalVisionOCRTimingClock {
    func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

private func ocrTimingMilliseconds(_ start: UInt64, _ end: UInt64) -> Double {
    Double(end >= start ? end - start : 0) / 1_000_000
}

final class LocalVisionOCRPassTimingContext: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: any LocalVisionOCRTimingClock
    private let startedAt: UInt64
    private let ordinal: Int
    private let passKind: String
    private let pixelBucket: String
    private var constructionMilliseconds = 0.0
    private var queueMilliseconds = 0.0
    private var handlerMilliseconds = 0.0
    private var performMilliseconds = 0.0
    private var mappingMilliseconds = 0.0
    private var terminal: LocalVisionOCRTimingTerminal = .failure
    private var endedAt: UInt64?

    init(ordinal: Int, passKind: String, pixelBucket: String, clock: any LocalVisionOCRTimingClock) {
        self.ordinal = ordinal; self.passKind = passKind; self.pixelBucket = pixelBucket
        self.clock = clock; startedAt = clock.nowNanoseconds()
    }
    func nowNanoseconds() -> UInt64 { clock.nowNanoseconds() }
    func measureRequestConstruction(from start: UInt64) { lock.withCriticalSection { constructionMilliseconds = ocrTimingMilliseconds(start, clock.nowNanoseconds()) } }
    func measureQueue(from start: UInt64) { lock.withCriticalSection { queueMilliseconds = ocrTimingMilliseconds(start, clock.nowNanoseconds()) } }
    func measureHandler(from start: UInt64) { lock.withCriticalSection { handlerMilliseconds = ocrTimingMilliseconds(start, clock.nowNanoseconds()) } }
    func measurePerform(from start: UInt64) { lock.withCriticalSection { performMilliseconds = ocrTimingMilliseconds(start, clock.nowNanoseconds()) } }
    func measureMapping(from start: UInt64) { lock.withCriticalSection { mappingMilliseconds = ocrTimingMilliseconds(start, clock.nowNanoseconds()) } }
    func finish(_ terminal: LocalVisionOCRTimingTerminal) { lock.withCriticalSection { self.terminal = terminal; endedAt = clock.nowNanoseconds() } }
    func snapshot() -> LocalVisionOCRPassTimingSnapshot { lock.withCriticalSection {
        let total = ocrTimingMilliseconds(startedAt, endedAt ?? clock.nowNanoseconds())
        let known = constructionMilliseconds + queueMilliseconds + handlerMilliseconds + performMilliseconds + mappingMilliseconds
        return LocalVisionOCRPassTimingSnapshot(ordinal: ordinal, passKind: passKind, pixelBucket: pixelBucket, terminal: terminal, requestConstructionMilliseconds: constructionMilliseconds, queueWaitMilliseconds: queueMilliseconds, handlerConstructionMilliseconds: handlerMilliseconds, performMilliseconds: performMilliseconds, mappingMilliseconds: mappingMilliseconds, adapterTotalMilliseconds: total, unattributedMilliseconds: max(0, total - known))
    } }
}

private final class LocalVisionOCRTimingSession: @unchecked Sendable {
    private let lock = NSLock(); private let clock: any LocalVisionOCRTimingClock; private let startedAt: UInt64
    private let observer: (@Sendable (LocalVisionOCRTimingSnapshot) -> Void)?
    private let recognitionID = UUID()
    private var cacheHit = false, supportedMilliseconds = 0.0, configurationMilliseconds = 0.0, layoutMilliseconds = 0.0
    private var passes: [LocalVisionOCRPassTimingContext] = []; private var finished = false
    init(clock: any LocalVisionOCRTimingClock, observer: (@Sendable (LocalVisionOCRTimingSnapshot) -> Void)?) { self.clock = clock; self.observer = observer; startedAt = clock.nowNanoseconds() }
    func nowNanoseconds() -> UInt64 { clock.nowNanoseconds() }
    func recordSupported(cacheHit: Bool, milliseconds: Double) { lock.withCriticalSection { self.cacheHit = cacheHit; supportedMilliseconds += milliseconds } }
    func recordConfiguration(_ milliseconds: Double) { lock.withCriticalSection { configurationMilliseconds += milliseconds } }
    func recordLayout(_ milliseconds: Double) { lock.withCriticalSection { layoutMilliseconds += milliseconds } }
    func makePass(kind: String, pixelBucket: String) -> LocalVisionOCRPassTimingContext { lock.withCriticalSection { let context = LocalVisionOCRPassTimingContext(ordinal: passes.count + 1, passKind: kind, pixelBucket: pixelBucket, clock: clock); passes.append(context); return context } }
    func finish(_ terminal: LocalVisionOCRTimingTerminal) { let snapshot: LocalVisionOCRTimingSnapshot? = lock.withCriticalSection {
        guard !finished else { return nil }; finished = true
        let passSnapshots = passes.map { $0.snapshot() }; let total = ocrTimingMilliseconds(startedAt, clock.nowNanoseconds())
        let known = configurationMilliseconds + layoutMilliseconds + passSnapshots.reduce(0) { $0 + $1.adapterTotalMilliseconds }
        return LocalVisionOCRTimingSnapshot(recognitionID: recognitionID, terminal: terminal, totalMilliseconds: total, supportedLanguagesCacheHit: cacheHit, supportedLanguagesMilliseconds: supportedMilliseconds, requestConfigurationMilliseconds: configurationMilliseconds, layoutMilliseconds: layoutMilliseconds, requestCount: passSnapshots.count, passes: passSnapshots, serviceUnattributedMilliseconds: max(0, total - known))
    }; if let snapshot { observer?(snapshot) } }
}

struct LocalVisionOCRResult: Equatable, Sendable {
    let text: String
    let lineCount: Int
    let meanConfidence: Float

    init(text: String, lineCount: Int, meanConfidence: Float = 1) {
        self.text = text
        self.lineCount = lineCount
        self.meanConfidence = meanConfidence
    }
}

enum LocalVisionOCRError: Error, Equatable {
    case imageDataUnavailable
    case imageDecodingFailed
    case noTextRecognized
    case visionFailed
    case fixtureFailed(String)

    var lowSensitivityCode: String {
        switch self {
        case .imageDataUnavailable:
            "image_data_unavailable"
        case .imageDecodingFailed:
            "image_decoding_failed"
        case .noTextRecognized:
            "no_text_recognized"
        case .visionFailed:
            "vision_failed"
        case .fixtureFailed(let code):
            code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "fixture_failed" : code
        }
    }
}

struct LocalVisionOCRConfiguration: Equatable, Sendable {
    static let systemPreferredLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]

    var preferredLanguages = systemPreferredLanguages
    var automaticallyDetectsLanguage = true
    var usesLanguageCorrection = false
    var fallbackConfidenceThreshold: Float = 0.65
    var eastAsianFallbackConfidenceThreshold: Float = 0.35
    var fallbackMinimumImprovement: Float = 0.05
    var japaneseRefinementConfidenceThreshold: Float = 0.80
    var adaptiveGridConfidenceThreshold: Float = 0.58
    var eastAsianAdaptiveGridConfidenceThreshold: Float = 0.35
    var adaptiveGridMinimumWidth = 1_000
    var adaptiveGridMinimumHeight = 600
    var adaptiveGridOverlap = 64
    var maximumTileHeight = 4_096
    var tileOverlap = 192

    func requestConfiguration(
        supportedLanguages: [String]
    ) -> LocalVisionOCRRequestConfiguration {
        let supported = Set(supportedLanguages)
        return LocalVisionOCRRequestConfiguration(
            recognitionLanguages: preferredLanguages.filter(supported.contains),
            automaticallyDetectsLanguage: automaticallyDetectsLanguage,
            usesLanguageCorrection: usesLanguageCorrection
        )
    }
}

struct LocalVisionOCRRequestConfiguration: Equatable, Sendable {
    let recognitionLanguages: [String]
    let automaticallyDetectsLanguage: Bool
    let usesLanguageCorrection: Bool
}

struct LocalVisionOCRObservation: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(text: String, boundingBox: CGRect, confidence: Float = 1) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

final class LocalVisionOCRRequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
        lock.withCriticalSection { cancelled }
    }

    func cancel() {
        let handlers = lock.withCriticalSection { () -> [() -> Void] in
            guard !cancelled else { return [] }
            cancelled = true
            let handlers = Array(cancellationHandlers.values)
            cancellationHandlers.removeAll()
            return handlers
        }
        handlers.forEach { $0() }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    @discardableResult
    func addCancellationHandler(_ handler: @escaping () -> Void) -> UUID? {
        let id = UUID()
        let shouldCancelImmediately = lock.withCriticalSection { () -> Bool in
            guard !cancelled else { return true }
            cancellationHandlers[id] = handler
            return false
        }
        if shouldCancelImmediately {
            handler()
            return nil
        }
        return id
    }

    func removeCancellationHandler(_ id: UUID?) {
        guard let id else { return }
        _ = lock.withCriticalSection {
            cancellationHandlers.removeValue(forKey: id)
        }
    }
}

protocol LocalVisionOCRAdapter: AnyObject {
    func supportedRecognitionLanguages() throws -> [String]

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation]

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService
    ) async throws -> [LocalVisionOCRObservation]

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingContext: LocalVisionOCRPassTimingContext?
    ) async throws -> [LocalVisionOCRObservation]
}

extension LocalVisionOCRAdapter {
    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService _: QualityOfService
    ) async throws -> [LocalVisionOCRObservation] {
        try await recognizeText(
            in: image,
            orientation: orientation,
            configuration: configuration,
            requestToken: requestToken
        )
    }
    func recognizeText(
        in image: CGImage, orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration, requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService, timingContext _: LocalVisionOCRPassTimingContext?
    ) async throws -> [LocalVisionOCRObservation] {
        try await recognizeText(in: image, orientation: orientation, configuration: configuration, requestToken: requestToken, qualityOfService: qualityOfService)
    }
}

final class LocalVisionOCRService: @unchecked Sendable {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "local-ocr-engine"
    )
    private let adapter: LocalVisionOCRAdapter
    private let configuration: LocalVisionOCRConfiguration
    private let supportedLanguagesLock = NSLock()
    private var cachedSupportedLanguages: Result<[String], Error>?
    private let timingClock: any LocalVisionOCRTimingClock
    private let timingObserver: (@Sendable (LocalVisionOCRTimingSnapshot) -> Void)?

    init(
        adapter: LocalVisionOCRAdapter = AppleVisionOCRAdapter(),
        configuration: LocalVisionOCRConfiguration = LocalVisionOCRConfiguration(),
        timingClock: any LocalVisionOCRTimingClock = LocalVisionOCRSystemTimingClock(),
        timingObserver: (@Sendable (LocalVisionOCRTimingSnapshot) -> Void)? = nil
    ) {
        self.adapter = adapter
        self.configuration = configuration
        self.timingClock = timingClock
        self.timingObserver = timingObserver
    }

    func recognizeText(
        from imageData: Data,
        requestToken: LocalVisionOCRRequestToken = LocalVisionOCRRequestToken(),
        qualityOfService: QualityOfService = .userInitiated
    ) async throws -> LocalVisionOCRResult {
        let session = timingObserver.map { LocalVisionOCRTimingSession(clock: timingClock, observer: $0) }
        do { let result = try await withCooperativeCancellation(requestToken: requestToken) {
            let decodeState = Self.signposter.beginInterval("OCRDecode")
            guard !imageData.isEmpty else {
                Self.signposter.endInterval("OCRDecode", decodeState, "terminal=empty")
                throw LocalVisionOCRError.imageDataUnavailable
            }
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                Self.signposter.endInterval("OCRDecode", decodeState, "terminal=failed")
                throw LocalVisionOCRError.imageDecodingFailed
            }
            Self.signposter.endInterval("OCRDecode", decodeState, "terminal=success")
            return try await recognizeDecodedImage(
                image,
                orientation: Self.imageOrientation(from: source),
                requestToken: requestToken,
                qualityOfService: qualityOfService, timingSession: session
            )
        }; session?.finish(.success); return result
        } catch is CancellationError { session?.finish(.cancelled); throw CancellationError()
        } catch { session?.finish(requestToken.isCancelled || Task.isCancelled ? .cancelled : .failure); throw error }
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        requestToken: LocalVisionOCRRequestToken = LocalVisionOCRRequestToken(),
        qualityOfService: QualityOfService = .userInitiated
    ) async throws -> LocalVisionOCRResult {
        let session = timingObserver.map { LocalVisionOCRTimingSession(clock: timingClock, observer: $0) }
        do { let result = try await withCooperativeCancellation(requestToken: requestToken) {
            try await recognizeDecodedImage(
                image,
                orientation: orientation,
                requestToken: requestToken,
                qualityOfService: qualityOfService, timingSession: session
            )
        }; session?.finish(.success); return result
        } catch is CancellationError { session?.finish(.cancelled); throw CancellationError()
        } catch { session?.finish(requestToken.isCancelled || Task.isCancelled ? .cancelled : .failure); throw error }
    }

    private func recognizeDecodedImage(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingSession: LocalVisionOCRTimingSession?
    ) async throws -> LocalVisionOCRResult {
        do {
            try requestToken.checkCancellation()
            let configurationStart = timingSession?.nowNanoseconds()
            let requestConfiguration: LocalVisionOCRRequestConfiguration
            do {
                requestConfiguration = try makeRequestConfiguration(
                    qualityOfService: qualityOfService,
                    timingSession: timingSession
                )
            } catch {
                if let timingSession, let configurationStart {
                    timingSession.recordConfiguration(
                        ocrTimingMilliseconds(configurationStart, timingSession.nowNanoseconds())
                    )
                }
                throw error
            }
            if let timingSession, let configurationStart {
                timingSession.recordConfiguration(ocrTimingMilliseconds(configurationStart, timingSession.nowNanoseconds()))
            }
            if orientation == .up,
               image.height > configuration.maximumTileHeight {
                return try await recognizeTiledImage(
                    image,
                    configuration: requestConfiguration,
                    requestToken: requestToken,
                    qualityOfService: qualityOfService, timingSession: timingSession
                )
            }
            let observations = try await recognizeObservations(
                in: image,
                orientation: orientation,
                configuration: requestConfiguration,
                requestToken: requestToken,
                qualityOfService: qualityOfService, timingSession: timingSession
            )
            try requestToken.checkCancellation()
            let layoutStart = timingSession?.nowNanoseconds(); let layoutState = Self.signposter.beginInterval("OCRLayout")
            let orderedText = normalizedText(observations)
            Self.signposter.endInterval(
                "OCRLayout",
                layoutState,
                "observations=\(observations.count, privacy: .public)"
            )
            if let timingSession, let layoutStart {
                timingSession.recordLayout(ocrTimingMilliseconds(layoutStart, timingSession.nowNanoseconds()))
            }
            guard !orderedText.isEmpty else {
                throw LocalVisionOCRError.noTextRecognized
            }
            return LocalVisionOCRResult(
                text: orderedText.joined(separator: "\n"),
                lineCount: orderedText.count,
                meanConfidence: Self.meanConfidence(observations)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalVisionOCRError {
            throw error
        } catch {
            if requestToken.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw LocalVisionOCRError.visionFailed
        }
    }

    private func recognizeTiledImage(
        _ image: CGImage,
        configuration requestConfiguration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingSession: LocalVisionOCRTimingSession?
    ) async throws -> LocalVisionOCRResult {
        let tileHeight = max(1, configuration.maximumTileHeight)
        let overlap = min(max(0, configuration.tileOverlap), tileHeight / 3)
        let step = max(1, tileHeight - overlap)
        var y = 0
        var tileCount = 0
        var observations: [LocalVisionOCRObservation] = []

        while y < image.height {
            try requestToken.checkCancellation()
            let height = min(tileHeight, image.height - y)
            guard let tile = image.cropping(to: CGRect(
                x: 0,
                y: y,
                width: image.width,
                height: height
            )) else {
                throw LocalVisionOCRError.imageDecodingFailed
            }
            let tileObservations = try await recognizeObservations(
                in: tile,
                orientation: .up,
                configuration: requestConfiguration,
                requestToken: requestToken,
                qualityOfService: qualityOfService,
                primaryPass: .tallTile,
                timingSession: timingSession
            )
            observations.append(contentsOf: tileObservations.map {
                Self.mapToFullImage(
                    $0,
                    tileY: y,
                    tileHeight: height,
                    imageHeight: image.height
                )
            })
            tileCount += 1
            guard y + height < image.height else { break }
            y += step
        }

        let deduplicated = Self.deduplicatedObservations(observations)
        let layoutStart = timingSession?.nowNanoseconds(); let layoutState = Self.signposter.beginInterval("OCRLayout")
        let lines = normalizedText(deduplicated)
        Self.signposter.endInterval(
            "OCRLayout",
            layoutState,
            "tiles=\(tileCount, privacy: .public) observations=\(deduplicated.count, privacy: .public)"
        )
        if let timingSession, let layoutStart {
            timingSession.recordLayout(ocrTimingMilliseconds(layoutStart, timingSession.nowNanoseconds()))
        }
        guard !lines.isEmpty else {
            throw LocalVisionOCRError.noTextRecognized
        }
        return LocalVisionOCRResult(
            text: lines.joined(separator: "\n"),
            lineCount: lines.count,
            meanConfidence: Self.meanConfidence(deduplicated)
        )
    }

    private func supportedRecognitionLanguages(timingSession: LocalVisionOCRTimingSession?) throws -> [String] {
        if let cached = supportedLanguagesLock.withCriticalSection({ cachedSupportedLanguages }) {
            timingSession?.recordSupported(cacheHit: true, milliseconds: 0)
            return try cached.get()
        }

        let timingStart = timingSession?.nowNanoseconds()
        let signpostState = Self.signposter.beginInterval("OCRSupportedLanguages")
        let resolved: Result<[String], Error>
        do { resolved = .success(try adapter.supportedRecognitionLanguages()) }
        catch { resolved = .failure(error) }
        _ = supportedLanguagesLock.withCriticalSection { () -> Bool in
            guard cachedSupportedLanguages == nil else { return false }
            cachedSupportedLanguages = resolved
            return true
        }
        if case .success(let languages) = resolved {
            Self.signposter.endInterval(
                "OCRSupportedLanguages",
                signpostState,
                "terminal=success languages=\(Self.countBucket(languages.count), privacy: .public)"
            )
        } else {
            Self.signposter.endInterval("OCRSupportedLanguages", signpostState, "terminal=failure")
        }
        if let timingSession, let timingStart {
            timingSession.recordSupported(cacheHit: false, milliseconds: ocrTimingMilliseconds(timingStart, timingSession.nowNanoseconds()))
        }
        return try resolved.get()
    }

    private func makeRequestConfiguration(
        qualityOfService: QualityOfService,
        timingSession: LocalVisionOCRTimingSession?
    ) throws -> LocalVisionOCRRequestConfiguration {
        let signpostState = Self.signposter.beginInterval("OCRRequestConfiguration")
        do {
            let requestConfiguration = configuration.requestConfiguration(
                supportedLanguages: try supportedRecognitionLanguages(timingSession: timingSession)
            )
            Self.signposter.endInterval(
                "OCRRequestConfiguration",
                signpostState,
                "qos=\(Self.qualityOfServiceBucket(qualityOfService), privacy: .public) terminal=success languages=\(Self.countBucket(requestConfiguration.recognitionLanguages.count), privacy: .public)"
            )
            return requestConfiguration
        } catch {
            Self.signposter.endInterval(
                "OCRRequestConfiguration",
                signpostState,
                "qos=\(Self.qualityOfServiceBucket(qualityOfService), privacy: .public) terminal=failure"
            )
            throw error
        }
    }

    private func recognizeObservations(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration requestConfiguration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        primaryPass: OCRVisionPass = .primary,
        timingSession: LocalVisionOCRTimingSession?
    ) async throws -> [LocalVisionOCRObservation] {
        let fullImageObservations = try await recognizeCandidateObservations(
            in: image,
            orientation: orientation,
            configuration: requestConfiguration,
            requestToken: requestToken,
            qualityOfService: qualityOfService,
            primaryPass: primaryPass, timingSession: timingSession
        )
        guard orientation == .up,
              image.width >= configuration.adaptiveGridMinimumWidth,
              image.height >= configuration.adaptiveGridMinimumHeight,
              Self.meanConfidence(fullImageObservations)
                < adaptiveGridConfidenceThreshold(for: fullImageObservations) else {
            return fullImageObservations
        }

        let tiledObservations = try await recognizeAdaptiveGrid(
            image,
            configuration: requestConfiguration,
            requestToken: requestToken,
            qualityOfService: qualityOfService, timingSession: timingSession
        )
        return Self.prefersAdaptiveGrid(
            tiledObservations,
            over: fullImageObservations
        ) ? tiledObservations : fullImageObservations
    }

    private func recognizeCandidateObservations(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration requestConfiguration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        primaryPass: OCRVisionPass,
        timingSession: LocalVisionOCRTimingSession?
    ) async throws -> [LocalVisionOCRObservation] {
        let primary = try await recognizeAdapterPass(
            primaryPass,
            in: image,
            orientation: orientation,
            configuration: requestConfiguration,
            requestToken: requestToken,
            qualityOfService: qualityOfService, timingSession: timingSession
        )
        let primaryConfidence = Self.meanConfidence(primary)
        let shouldTryCorrectionFallback = primary.isEmpty
            || primaryConfidence < fallbackConfidenceThreshold(for: primary)
        guard shouldTryCorrectionFallback else {
            return try await refineJapaneseObservationsIfNeeded(
                primary,
                in: image,
                orientation: orientation,
                configuration: requestConfiguration,
                requestToken: requestToken,
                qualityOfService: qualityOfService, timingSession: timingSession
            )
        }
        var fallbackConfiguration = requestConfiguration
        fallbackConfiguration = LocalVisionOCRRequestConfiguration(
            recognitionLanguages: fallbackConfiguration.recognitionLanguages,
            automaticallyDetectsLanguage: fallbackConfiguration.automaticallyDetectsLanguage,
            usesLanguageCorrection: true
        )
        let fallback = try await recognizeAdapterPass(
            .correctionFallback,
            in: image,
            orientation: orientation,
            configuration: fallbackConfiguration,
            requestToken: requestToken,
            qualityOfService: qualityOfService, timingSession: timingSession
        )
        let fallbackConfidence = Self.meanConfidence(fallback)
        let primaryCoverage = Self.coverage(primary)
        let fallbackCoverage = Self.coverage(fallback)
        guard fallbackCoverage > primaryCoverage,
              primary.isEmpty || fallbackConfidence >= primaryConfidence + configuration.fallbackMinimumImprovement else {
            return try await refineJapaneseObservationsIfNeeded(
                primary,
                in: image,
                orientation: orientation,
                configuration: requestConfiguration,
                requestToken: requestToken,
                qualityOfService: qualityOfService, timingSession: timingSession
            )
        }
        return try await refineJapaneseObservationsIfNeeded(
            fallback,
            in: image,
            orientation: orientation,
            configuration: requestConfiguration,
            requestToken: requestToken,
            qualityOfService: qualityOfService, timingSession: timingSession
        )
    }

    private func fallbackConfidenceThreshold(
        for observations: [LocalVisionOCRObservation]
    ) -> Float {
        Self.containsEastAsianScript(observations)
            ? min(
                configuration.fallbackConfidenceThreshold,
                configuration.eastAsianFallbackConfidenceThreshold
            )
            : configuration.fallbackConfidenceThreshold
    }

    private func adaptiveGridConfidenceThreshold(
        for observations: [LocalVisionOCRObservation]
    ) -> Float {
        Self.containsEastAsianScript(observations)
            ? min(
                configuration.adaptiveGridConfidenceThreshold,
                configuration.eastAsianAdaptiveGridConfidenceThreshold
            )
            : configuration.adaptiveGridConfidenceThreshold
    }

    private func recognizeAdaptiveGrid(
        _ image: CGImage,
        configuration requestConfiguration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingSession: LocalVisionOCRTimingSession?
    ) async throws -> [LocalVisionOCRObservation] {
        let columnCount = image.width >= configuration.adaptiveGridMinimumWidth ? 2 : 1
        let rowCount = image.height >= configuration.adaptiveGridMinimumHeight ? 2 : 1
        let overlap = max(0, configuration.adaptiveGridOverlap)
        var observations: [LocalVisionOCRObservation] = []

        for row in 0..<rowCount {
            for column in 0..<columnCount {
                try requestToken.checkCancellation()
                let tileRect = Self.adaptiveTileRect(
                    imageWidth: image.width,
                    imageHeight: image.height,
                    column: column,
                    row: row,
                    columnCount: columnCount,
                    rowCount: rowCount,
                    overlap: overlap
                )
                guard let tile = image.cropping(to: tileRect) else {
                    continue
                }
                // Adaptive grid is the recovery pass. Each grid tile therefore
                // gets exactly one Vision request; running correction or
                // language refinement again here multiplies work and can turn
                // one low-confidence image into an unbounded-looking request
                // cascade.
                let tileObservations = try await recognizeAdapterPass(
                    .adaptiveGrid,
                    in: tile,
                    orientation: .up,
                    configuration: requestConfiguration,
                    requestToken: requestToken,
                    qualityOfService: qualityOfService, timingSession: timingSession
                )
                observations.append(contentsOf: tileObservations.map {
                    Self.mapToFullImage($0, tileRect: tileRect, image: image)
                })
            }
        }
        return Self.deduplicatedObservations(observations)
    }

    private static func adaptiveTileRect(
        imageWidth: Int,
        imageHeight: Int,
        column: Int,
        row: Int,
        columnCount: Int,
        rowCount: Int,
        overlap: Int
    ) -> CGRect {
        let baseMinX = column * imageWidth / columnCount
        let baseMaxX = (column + 1) * imageWidth / columnCount
        let baseMinY = row * imageHeight / rowCount
        let baseMaxY = (row + 1) * imageHeight / rowCount
        let halfOverlap = overlap / 2
        let minX = max(0, baseMinX - (column == 0 ? 0 : halfOverlap))
        let maxX = min(
            imageWidth,
            baseMaxX + (column == columnCount - 1 ? 0 : halfOverlap)
        )
        let minY = max(0, baseMinY - (row == 0 ? 0 : halfOverlap))
        let maxY = min(
            imageHeight,
            baseMaxY + (row == rowCount - 1 ? 0 : halfOverlap)
        )
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func mapToFullImage(
        _ observation: LocalVisionOCRObservation,
        tileRect: CGRect,
        image: CGImage
    ) -> LocalVisionOCRObservation {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let box = observation.boundingBox
        return LocalVisionOCRObservation(
            text: observation.text,
            boundingBox: CGRect(
                x: tileRect.minX / width + box.minX * tileRect.width / width,
                y: 1 - tileRect.maxY / height + box.minY * tileRect.height / height,
                width: box.width * tileRect.width / width,
                height: box.height * tileRect.height / height
            ),
            confidence: observation.confidence
        )
    }

    private static func prefersAdaptiveGrid(
        _ candidate: [LocalVisionOCRObservation],
        over baseline: [LocalVisionOCRObservation]
    ) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard !baseline.isEmpty else { return true }
        let candidateCoverage = coverage(candidate)
        let baselineCoverage = coverage(baseline)
        guard candidateCoverage * 5 >= baselineCoverage * 4 else {
            return false
        }
        return meanConfidence(candidate) >= meanConfidence(baseline) + 0.02
    }

    private func refineJapaneseObservationsIfNeeded(
        _ observations: [LocalVisionOCRObservation],
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration requestConfiguration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingSession: LocalVisionOCRTimingSession?
    ) async throws -> [LocalVisionOCRObservation] {
        guard observations.contains(where: {
            Self.containsJapaneseSignal($0.text)
                && Self.coverage([$0]) <= 10
                && $0.confidence < configuration.japaneseRefinementConfidenceThreshold
        }),
              requestConfiguration.recognitionLanguages.first != "ja-JP",
              requestConfiguration.recognitionLanguages.contains("ja-JP") else {
            return observations
        }
        let japaneseConfiguration = LocalVisionOCRRequestConfiguration(
            recognitionLanguages: ["ja-JP"]
                + requestConfiguration.recognitionLanguages.filter { $0 != "ja-JP" },
            automaticallyDetectsLanguage: requestConfiguration.automaticallyDetectsLanguage,
            usesLanguageCorrection: false
        )
        let japaneseObservations = try await recognizeAdapterPass(
            .japaneseRefinement,
            in: image,
            orientation: orientation,
            configuration: japaneseConfiguration,
            requestToken: requestToken,
            qualityOfService: qualityOfService, timingSession: timingSession
        )
        return observations.map { primary in
            guard Self.containsEastAsianScript(primary.text),
                  Self.coverage([primary]) <= 10,
                  let candidate = japaneseObservations
                    .filter({
                        Self.containsKana($0.text)
                            && Self.geometryMatches(primary, $0)
                            && $0.confidence >= primary.confidence
                    })
                    .max(by: { Self.coverage([$0]) < Self.coverage([$1]) }),
                  Self.coverage([candidate]) > Self.coverage([primary]) else {
                return primary
            }
            return candidate
        }
    }

    private func recognizeAdapterPass(
        _ pass: OCRVisionPass,
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration requestConfiguration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingSession: LocalVisionOCRTimingSession?
    ) async throws -> [LocalVisionOCRObservation] {
        let timingContext = timingSession?.makePass(kind: pass.rawValue, pixelBucket: Self.pixelBucket(for: image))
        let signpostState = Self.signposter.beginInterval("OCRVisionPass")
        do {
            let observations = try await adapter.recognizeText(
                in: image,
                orientation: orientation,
                configuration: requestConfiguration,
                requestToken: requestToken,
                qualityOfService: qualityOfService,
                timingContext: timingContext
            )
            timingContext?.finish(.success)
            Self.signposter.endInterval(
                "OCRVisionPass",
                signpostState,
                "pass=\(pass.rawValue, privacy: .public) pixels=\(Self.pixelBucket(for: image), privacy: .public) qos=\(Self.qualityOfServiceBucket(qualityOfService), privacy: .public) terminal=success observations=\(Self.countBucket(observations.count), privacy: .public)"
            )
            return observations
        } catch {
            timingContext?.finish(requestToken.isCancelled || Task.isCancelled ? .cancelled : .failure)
            let terminal = requestToken.isCancelled || Task.isCancelled ? "cancelled" : "failure"
            Self.signposter.endInterval(
                "OCRVisionPass",
                signpostState,
                "pass=\(pass.rawValue, privacy: .public) pixels=\(Self.pixelBucket(for: image), privacy: .public) qos=\(Self.qualityOfServiceBucket(qualityOfService), privacy: .public) terminal=\(terminal, privacy: .public)"
            )
            throw error
        }
    }

    private enum OCRVisionPass: String {
        case primary
        case correctionFallback = "correction_fallback"
        case japaneseRefinement = "japanese_refinement"
        case adaptiveGrid = "adaptive_grid"
        case tallTile = "tall_tile"
    }

    private static func pixelBucket(for image: CGImage) -> String {
        switch image.width * image.height {
        case ..<1_000_000:
            "under_1mp"
        case ..<4_000_000:
            "1_to_4mp"
        case ..<12_000_000:
            "4_to_12mp"
        default:
            "12mp_plus"
        }
    }

    private static func countBucket(_ count: Int) -> String {
        switch count {
        case 0:
            "zero"
        case 1:
            "one"
        case 2...4:
            "two_to_four"
        case 5...16:
            "five_to_sixteen"
        default:
            "seventeen_plus"
        }
    }

    private static func qualityOfServiceBucket(_ qualityOfService: QualityOfService) -> String {
        switch qualityOfService {
        case .userInteractive:
            "user_interactive"
        case .userInitiated:
            "user_initiated"
        case .utility:
            "utility"
        case .background:
            "background"
        case .default:
            "default"
        @unknown default:
            "other"
        }
    }

    private static func geometryMatches(
        _ lhs: LocalVisionOCRObservation,
        _ rhs: LocalVisionOCRObservation
    ) -> Bool {
        let intersection = lhs.boundingBox.intersection(rhs.boundingBox)
        let minimumArea = max(
            min(lhs.boundingBox.width * lhs.boundingBox.height, rhs.boundingBox.width * rhs.boundingBox.height),
            .ulpOfOne
        )
        return !intersection.isNull
            && intersection.width * intersection.height / minimumArea >= 0.55
    }

    private static func containsEastAsianScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }

    private static func containsEastAsianScript(
        _ observations: [LocalVisionOCRObservation]
    ) -> Bool {
        observations.contains { containsEastAsianScript($0.text) }
    }

    private static func containsJapaneseSignal(_ text: String) -> Bool {
        containsKana(text) || text.contains("日本語")
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF:
                true
            default:
                false
            }
        }
    }

    private static func meanConfidence(_ observations: [LocalVisionOCRObservation]) -> Float {
        guard !observations.isEmpty else { return 0 }
        return observations.reduce(Float.zero) { $0 + $1.confidence }
            / Float(observations.count)
    }

    private static func coverage(_ observations: [LocalVisionOCRObservation]) -> Int {
        observations.reduce(0) {
            $0 + $1.text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        }
    }

    private static func mapToFullImage(
        _ observation: LocalVisionOCRObservation,
        tileY: Int,
        tileHeight: Int,
        imageHeight: Int
    ) -> LocalVisionOCRObservation {
        let box = observation.boundingBox
        let normalizedTileHeight = CGFloat(tileHeight) / CGFloat(imageHeight)
        let tileBottomInVisionCoordinates = 1 - CGFloat(tileY + tileHeight) / CGFloat(imageHeight)
        return LocalVisionOCRObservation(
            text: observation.text,
            boundingBox: CGRect(
                x: box.minX,
                y: tileBottomInVisionCoordinates + box.minY * normalizedTileHeight,
                width: box.width,
                height: box.height * normalizedTileHeight
            ),
            confidence: observation.confidence
        )
    }

    static func deduplicatedObservations(
        _ observations: [LocalVisionOCRObservation]
    ) -> [LocalVisionOCRObservation] {
        let ordered = observations.sorted { lhs, rhs in
            if lhs.boundingBox.midY != rhs.boundingBox.midY {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var result: [LocalVisionOCRObservation] = []
        for candidate in ordered {
            guard let duplicateIndex = result.firstIndex(where: {
                Self.isDuplicate(candidate, $0)
            }) else {
                result.append(candidate)
                continue
            }
            if candidate.confidence > result[duplicateIndex].confidence {
                result[duplicateIndex] = candidate
            }
        }
        return result
    }

    private static func isDuplicate(
        _ lhs: LocalVisionOCRObservation,
        _ rhs: LocalVisionOCRObservation
    ) -> Bool {
        let relativeHeight = max(lhs.boundingBox.height, rhs.boundingBox.height, .ulpOfOne)
        guard abs(lhs.boundingBox.midY - rhs.boundingBox.midY) <= relativeHeight * 0.9 else {
            return false
        }
        let horizontalIntersection = max(
            0,
            min(lhs.boundingBox.maxX, rhs.boundingBox.maxX)
                - max(lhs.boundingBox.minX, rhs.boundingBox.minX)
        )
        let minimumWidth = max(min(lhs.boundingBox.width, rhs.boundingBox.width), .ulpOfOne)
        guard horizontalIntersection / minimumWidth >= 0.55 else {
            return false
        }
        return normalizedSimilarity(lhs.text, rhs.text) >= 0.82
    }

    private static func normalizedSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil))
        let right = Array(rhs.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil))
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        let maximumLength = max(left.count, right.count)
        return 1 - Double(previous[right.count]) / Double(maximumLength)
    }

    private func normalizedText(
        _ observations: [LocalVisionOCRObservation]
    ) -> [String] {
        let boxes = observations.enumerated().map { index, observation in
            LocalVisionOCRLayoutBox(
                index: index,
                boundingBox: observation.boundingBox,
                text: observation.text
            )
        }
        return LocalVisionOCRReadingOrder.orderedIndices(boxes)
            .map { observations[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func withCooperativeCancellation<T>(
        requestToken: LocalVisionOCRRequestToken,
        operation: () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try requestToken.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            try requestToken.checkCancellation()
            return result
        } onCancel: {
            requestToken.cancel()
        }
    }

    private static func imageOrientation(
        from source: CGImageSource
    ) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let rawValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
            let orientation = CGImagePropertyOrientation(rawValue: rawValue) else {
            return .up
        }
        return orientation
    }
}

final class AppleVisionOCRAdapter: LocalVisionOCRAdapter {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "local-ocr-vision"
    )
    private let operationQueue: OperationQueue

    init(maxConcurrentRequestCount: Int = 1) {
        operationQueue = OperationQueue()
        operationQueue.name = "com.blocks.local-vision-ocr"
        operationQueue.qualityOfService = .utility
        operationQueue.maxConcurrentOperationCount = max(1, maxConcurrentRequestCount)
    }

    func supportedRecognitionLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        try await recognizeText(
            in: image,
            orientation: orientation,
            configuration: configuration,
            requestToken: requestToken,
            qualityOfService: .userInitiated
        )
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService
    ) async throws -> [LocalVisionOCRObservation] {
        try await recognizeText(in: image, orientation: orientation, configuration: configuration, requestToken: requestToken, qualityOfService: qualityOfService, timingContext: nil)
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingContext: LocalVisionOCRPassTimingContext?
    ) async throws -> [LocalVisionOCRObservation] {
        let constructionStart = timingContext?.nowNanoseconds()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
        request.recognitionLanguages = configuration.recognitionLanguages
        if let constructionStart { timingContext?.measureRequestConstruction(from: constructionStart) }

        let cancellationHandlerID = requestToken.addCancellationHandler {
            request.cancel()
        }
        defer { requestToken.removeCancellationHandler(cancellationHandlerID) }

        return try await withCheckedThrowingContinuation { continuation in
            let enqueueState = Self.signposter.beginInterval(
                "VisionAdapterQueue"
            )
            let queueStart = timingContext?.nowNanoseconds()
            let operation = BlockOperation {
                if let queueStart { timingContext?.measureQueue(from: queueStart) }
                Self.signposter.endInterval(
                    "VisionAdapterQueue",
                    enqueueState,
                    "terminal=started"
                )
                let operationState = Self.signposter.beginInterval(
                    "VisionAdapterOperation"
                )
                do {
                    try requestToken.checkCancellation()
                    let handlerState = Self.signposter.beginInterval(
                        "VisionHandlerConstruction"
                    )
                    let handlerStart = timingContext?.nowNanoseconds()
                    let handler = VNImageRequestHandler(
                        cgImage: image,
                        orientation: orientation,
                        options: [:]
                    )
                    Self.signposter.endInterval(
                        "VisionHandlerConstruction",
                        handlerState,
                        "terminal=success"
                    )
                    if let handlerStart { timingContext?.measureHandler(from: handlerStart) }
                    let performState = Self.signposter.beginInterval(
                        "VisionPerform"
                    )
                    let performStart = timingContext?.nowNanoseconds()
                    do {
                        try handler.perform([request])
                        Self.signposter.endInterval(
                            "VisionPerform",
                            performState,
                            "terminal=success"
                        )
                        if let performStart { timingContext?.measurePerform(from: performStart) }
                    } catch {
                        Self.signposter.endInterval(
                            "VisionPerform",
                            performState,
                            "terminal=error"
                        )
                        if let performStart { timingContext?.measurePerform(from: performStart) }
                        throw error
                    }
                    try requestToken.checkCancellation()
                    let mappingState = Self.signposter.beginInterval(
                        "VisionResultMapping"
                    )
                    let mappingStart = timingContext?.nowNanoseconds()
                    let observations: [LocalVisionOCRObservation] = (request.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }
                        return LocalVisionOCRObservation(
                            text: candidate.string,
                            boundingBox: observation.boundingBox,
                            confidence: candidate.confidence
                        )
                    }
                    Self.signposter.endInterval(
                        "VisionResultMapping",
                        mappingState,
                        "terminal=success observations=\(observations.count, privacy: .public)"
                    )
                    if let mappingStart { timingContext?.measureMapping(from: mappingStart) }
                    Self.signposter.endInterval(
                        "VisionAdapterOperation",
                        operationState,
                        "terminal=success observations=\(observations.count, privacy: .public)"
                    )
                    continuation.resume(returning: observations)
                } catch {
                    Self.signposter.endInterval(
                        "VisionAdapterOperation",
                        operationState,
                        "terminal=error"
                    )
                    if requestToken.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            operation.qualityOfService = qualityOfService
            operationQueue.addOperation(operation)
        }
    }
}

struct LocalVisionOCRLayoutBox: Equatable, Sendable {
    let index: Int
    let boundingBox: CGRect
    let text: String
}

enum LocalVisionOCRReadingOrder {
    static func orderedIndices(_ boxes: [LocalVisionOCRLayoutBox]) -> [Int] {
        guard boxes.count > 1 else {
            return boxes.map(\.index)
        }
        if isVerticalScriptLayout(boxes) {
            return verticalColumnOrder(boxes).map(\.index)
        }
        if let columns = horizontalColumns(boxes) {
            return columns.flatMap(horizontalLineOrder).map(\.index)
        }
        return horizontalLineOrder(boxes).map(\.index)
    }

    private static func isVerticalScriptLayout(_ boxes: [LocalVisionOCRLayoutBox]) -> Bool {
        let tallBoxes = boxes.filter { box in
            box.boundingBox.height >= max(box.boundingBox.width * 1.35, 0.10)
        }
        let cjkTallBoxes = tallBoxes.filter { containsCJKOrKana($0.text) }
        guard cjkTallBoxes.count * 5 >= boxes.count * 3 else {
            return false
        }
        let columns = groupedVerticalColumns(boxes)
        let hasRepeatedColumn = columns.contains { $0.count > 1 }
        let horizontalSpan = (boxes.map(\.boundingBox.maxX).max() ?? 0)
            - (boxes.map(\.boundingBox.minX).min() ?? 0)
        return hasRepeatedColumn || (boxes.count <= 4 && horizontalSpan >= 0.12)
    }

    private static func containsCJKOrKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }

    private static func verticalColumnOrder(
        _ boxes: [LocalVisionOCRLayoutBox]
    ) -> [LocalVisionOCRLayoutBox] {
        groupedVerticalColumns(boxes)
            .sorted { lhs, rhs in
                averageX(lhs) > averageX(rhs)
            }
            .flatMap { column in
                column.sorted { lhs, rhs in
                    if lhs.boundingBox.midY != rhs.boundingBox.midY {
                        return lhs.boundingBox.midY > rhs.boundingBox.midY
                    }
                    return lhs.index < rhs.index
                }
            }
    }

    private static func groupedVerticalColumns(
        _ boxes: [LocalVisionOCRLayoutBox]
    ) -> [[LocalVisionOCRLayoutBox]] {
        var columns: [[LocalVisionOCRLayoutBox]] = []
        for box in boxes.sorted(by: { $0.boundingBox.midX > $1.boundingBox.midX }) {
            let tolerance = max(box.boundingBox.width * 0.85, 0.035)
            if let columnIndex = columns.indices.min(by: {
                abs(averageX(columns[$0]) - box.boundingBox.midX)
                    < abs(averageX(columns[$1]) - box.boundingBox.midX)
            }), abs(averageX(columns[columnIndex]) - box.boundingBox.midX) <= tolerance {
                columns[columnIndex].append(box)
            } else {
                columns.append([box])
            }
        }
        return columns
    }

    private static func averageX(_ boxes: [LocalVisionOCRLayoutBox]) -> CGFloat {
        boxes.reduce(CGFloat.zero) { $0 + $1.boundingBox.midX }
            / CGFloat(max(1, boxes.count))
    }

    private static func horizontalColumns(
        _ boxes: [LocalVisionOCRLayoutBox]
    ) -> [[LocalVisionOCRLayoutBox]]? {
        guard boxes.count >= 4 else { return nil }
        let sorted = boxes.sorted { lhs, rhs in
            if lhs.boundingBox.midX != rhs.boundingBox.midX {
                return lhs.boundingBox.midX < rhs.boundingBox.midX
            }
            return lhs.index < rhs.index
        }
        let gaps = zip(sorted, sorted.dropFirst()).enumerated().map { offset, pair in
            (splitIndex: offset + 1, gap: pair.1.boundingBox.midX - pair.0.boundingBox.midX)
        }
        guard let largestGap = gaps.max(by: { $0.gap < $1.gap }) else { return nil }
        let widths = boxes.map(\.boundingBox.width).sorted()
        let medianWidth = widths[widths.count / 2]
        guard largestGap.gap >= max(0.12, medianWidth * 0.55) else { return nil }

        let left = Array(sorted[..<largestGap.splitIndex])
        let right = Array(sorted[largestGap.splitIndex...])
        guard left.count >= 2, right.count >= 2 else { return nil }
        let leftMaxX = left.map(\.boundingBox.maxX).max() ?? 0
        let rightMinX = right.map(\.boundingBox.minX).min() ?? 1
        guard leftMaxX <= rightMinX + 0.04,
              hasMultipleRows(left),
              hasMultipleRows(right) else {
            return nil
        }
        return [left, right]
    }

    private static func hasMultipleRows(_ boxes: [LocalVisionOCRLayoutBox]) -> Bool {
        guard boxes.count >= 2 else { return false }
        let ySpan = (boxes.map(\.boundingBox.midY).max() ?? 0)
            - (boxes.map(\.boundingBox.midY).min() ?? 0)
        let heights = boxes.map(\.boundingBox.height).sorted()
        return ySpan >= max(heights[heights.count / 2] * 0.75, 0.04)
    }

    private static func horizontalLineOrder(
        _ boxes: [LocalVisionOCRLayoutBox]
    ) -> [LocalVisionOCRLayoutBox] {
        let verticallyOrdered = boxes.sorted { lhs, rhs in
            if lhs.boundingBox.midY != rhs.boundingBox.midY {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            if lhs.boundingBox.minX != rhs.boundingBox.minX {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.index < rhs.index
        }

        var lines: [[LocalVisionOCRLayoutBox]] = []
        for item in verticallyOrdered {
            var bestLineIndex: Int?
            var bestNormalizedDistance = CGFloat.greatestFiniteMagnitude
            for lineIndex in lines.indices {
                let line = lines[lineIndex]
                let centerY = line.reduce(CGFloat.zero) { $0 + $1.boundingBox.midY }
                    / CGFloat(line.count)
                let lineHeight = line.reduce(CGFloat.zero) { $0 + $1.boundingBox.height }
                    / CGFloat(line.count)
                let relativeHeight = max(item.boundingBox.height, lineHeight, CGFloat.ulpOfOne)
                let normalizedDistance = abs(item.boundingBox.midY - centerY) / relativeHeight
                if normalizedDistance <= 0.5, normalizedDistance < bestNormalizedDistance {
                    bestLineIndex = lineIndex
                    bestNormalizedDistance = normalizedDistance
                }
            }
            if let bestLineIndex {
                lines[bestLineIndex].append(item)
            } else {
                lines.append([item])
            }
        }

        return lines
            .sorted { lhs, rhs in
                let lhsY = lhs.reduce(CGFloat.zero) { $0 + $1.boundingBox.midY }
                    / CGFloat(lhs.count)
                let rhsY = rhs.reduce(CGFloat.zero) { $0 + $1.boundingBox.midY }
                    / CGFloat(rhs.count)
                if lhsY != rhsY { return lhsY > rhsY }
                return (lhs.map(\.boundingBox.minX).min() ?? 0)
                    < (rhs.map(\.boundingBox.minX).min() ?? 0)
            }
            .flatMap { line in
                line.sorted { lhs, rhs in
                    if lhs.boundingBox.minX != rhs.boundingBox.minX {
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                    return lhs.index < rhs.index
                }
            }
    }
}

enum LocalOCRRequestContext: String, Sendable {
    case editorRegion = "editor"
    case pinnedImage = "pin"
    case translationScreenshot = "translation-screenshot"
    case retry = "retry"
    case clipboardImage = "clipboard"
    case screenshotHistory = "screenshot-history"
    case startupRecovery = "startup-recovery"
    case pluginScreenshot = "plugin-screenshot"

    fileprivate var priority: LocalOCRRequestPriority {
        switch self {
        case .editorRegion, .pinnedImage, .translationScreenshot:
            .interactive
        case .retry:
            .userInitiated
        case .clipboardImage, .screenshotHistory, .startupRecovery, .pluginScreenshot:
            .background
        }
    }

    fileprivate var qualityOfService: QualityOfService {
        switch priority {
        case .background:
            .utility
        case .userInitiated:
            .userInitiated
        case .interactive:
            .userInteractive
        }
    }
}

private enum LocalOCRRequestPriority: Int, Sendable {
    case background = 0
    case userInitiated = 1
    case interactive = 2
}

private actor LocalOCRExecutionGate {
    private struct Pending {
        let id: UUID
        let priority: LocalOCRRequestPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var active = false
    private var nextSequence: UInt64 = 0
    private var pending: [Pending] = []

    #if DEBUG
    func pendingRequestCountForTesting() -> Int { pending.count }
    #endif

    func acquire(
        priority: LocalOCRRequestPriority,
        requestToken: LocalVisionOCRRequestToken
    ) async throws {
        try requestToken.checkCancellation()
        guard active else {
            active = true
            return
        }
        let id = UUID()
        let sequence = nextSequence
        nextSequence &+= 1
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(
                id: id,
                priority: priority,
                sequence: sequence,
                continuation: continuation
            ))
            _ = requestToken.addCancellationHandler { [weak self] in
                Task { await self?.cancel(id: id) }
            }
        }
        try requestToken.checkCancellation()
    }

    func release() {
        guard !pending.isEmpty else {
            active = false
            return
        }
        pending.sort {
            if $0.priority.rawValue != $1.priority.rawValue {
                return $0.priority.rawValue > $1.priority.rawValue
            }
            return $0.sequence < $1.sequence
        }
        pending.removeFirst().continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

final class LocalOCRCoordinator: @unchecked Sendable {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "local-ocr"
    )

    private let service: LocalVisionOCRService
    private let gate = LocalOCRExecutionGate()

    init(service: LocalVisionOCRService = LocalVisionOCRService()) {
        self.service = service
    }

    #if DEBUG
    func pendingRequestCountForTesting() async -> Int {
        await gate.pendingRequestCountForTesting()
    }
    #endif

    func recognizeText(
        from imageData: Data,
        context: LocalOCRRequestContext,
        requestToken: LocalVisionOCRRequestToken = LocalVisionOCRRequestToken()
    ) async throws -> LocalVisionOCRResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await waitForBackgroundCapacityIfNeeded(context: context, requestToken: requestToken)
            let queuedAt = ContinuousClock.now
            try await gate.acquire(priority: context.priority, requestToken: requestToken)
            Self.signposter.emitEvent(
                "OCRQueueWait",
                "context=\(context.rawValue, privacy: .public) wait=\(Self.durationBucket(queuedAt.duration(to: .now)), privacy: .public)"
            )
            let state = Self.signposter.beginInterval(
                "OCRRequest",
                id: Self.signposter.makeSignpostID(),
                "context=\(context.rawValue, privacy: .public) priority=\(context.priority.rawValue, privacy: .public) input=data"
            )
            do {
                let result = try await service.recognizeText(
                    from: imageData,
                    requestToken: requestToken,
                    qualityOfService: context.qualityOfService
                )
                Self.signposter.endInterval(
                    "OCRRequest",
                    state,
                    "terminal=success lines=\(result.lineCount, privacy: .public)"
                )
                await gate.release()
                return result
            } catch {
                Self.signposter.endInterval("OCRRequest", state, "terminal=error")
                await gate.release()
                throw error
            }
        } onCancel: {
            requestToken.cancel()
        }
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        context: LocalOCRRequestContext,
        requestToken: LocalVisionOCRRequestToken = LocalVisionOCRRequestToken()
    ) async throws -> LocalVisionOCRResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await waitForBackgroundCapacityIfNeeded(context: context, requestToken: requestToken)
            let queuedAt = ContinuousClock.now
            try await gate.acquire(priority: context.priority, requestToken: requestToken)
            Self.signposter.emitEvent(
                "OCRQueueWait",
                "context=\(context.rawValue, privacy: .public) wait=\(Self.durationBucket(queuedAt.duration(to: .now)), privacy: .public)"
            )
            let pixelBucket = Self.pixelBucket(width: image.width, height: image.height)
            let state = Self.signposter.beginInterval(
                "OCRRequest",
                id: Self.signposter.makeSignpostID(),
                "context=\(context.rawValue, privacy: .public) priority=\(context.priority.rawValue, privacy: .public) pixels=\(pixelBucket, privacy: .public)"
            )
            do {
                let result = try await service.recognizeText(
                    in: image,
                    orientation: orientation,
                    requestToken: requestToken,
                    qualityOfService: context.qualityOfService
                )
                Self.signposter.endInterval(
                    "OCRRequest",
                    state,
                    "terminal=success lines=\(result.lineCount, privacy: .public)"
                )
                await gate.release()
                return result
            } catch {
                Self.signposter.endInterval("OCRRequest", state, "terminal=error")
                await gate.release()
                throw error
            }
        } onCancel: {
            requestToken.cancel()
        }
    }

    private func waitForBackgroundCapacityIfNeeded(
        context: LocalOCRRequestContext,
        requestToken: LocalVisionOCRRequestToken
    ) async throws {
        guard context.priority == .background else { return }
        while ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState == .serious
            || ProcessInfo.processInfo.thermalState == .critical {
            try requestToken.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
    }

    private static func pixelBucket(width: Int, height: Int) -> String {
        let megapixels = Double(width * height) / 1_000_000
        switch megapixels {
        case ..<1: return "lt1mp"
        case ..<4: return "1to4mp"
        case ..<12: return "4to12mp"
        default: return "gte12mp"
        }
    }

    private static func durationBucket(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        switch milliseconds {
        case ..<10: return "lt10ms"
        case ..<50: return "10to50ms"
        case ..<250: return "50to250ms"
        case ..<1_000: return "250to1000ms"
        default: return "gte1000ms"
        }
    }
}

private extension NSLock {
    func withCriticalSection<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
