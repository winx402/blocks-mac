import AppKit
import CryptoKit
import CoreGraphics
import Foundation

private struct OCRTimingEvidence: Codable {
    let recognitionID: String; let terminal: LocalVisionOCRTimingTerminal; let totalMilliseconds: Double; let supportedLanguagesCacheHit: Bool; let supportedLanguagesMilliseconds: Double; let requestConfigurationMilliseconds: Double; let layoutMilliseconds: Double; let requestCount: Int; let passes: [LocalVisionOCRPassTimingSnapshot]; let serviceUnattributedMilliseconds: Double
    init(_ snapshot: LocalVisionOCRTimingSnapshot) { recognitionID = snapshot.recognitionID.uuidString.lowercased(); terminal = snapshot.terminal; totalMilliseconds = snapshot.totalMilliseconds; supportedLanguagesCacheHit = snapshot.supportedLanguagesCacheHit; supportedLanguagesMilliseconds = snapshot.supportedLanguagesMilliseconds; requestConfigurationMilliseconds = snapshot.requestConfigurationMilliseconds; layoutMilliseconds = snapshot.layoutMilliseconds; requestCount = snapshot.requestCount; passes = snapshot.passes; serviceUnattributedMilliseconds = snapshot.serviceUnattributedMilliseconds }
}

private struct OCRFixtureResult: Codable {
    let name: String
    let characterErrorRate: Double
    let expectedLineCount: Int
    let actualLineCount: Int
    let coldDurationMilliseconds: Double
    /// The first recognition is retained for backward-compatible single-run timing consumers.
    let durationMilliseconds: Double
    /// Only the four recognitions after the first run; excludes process cold start.
    let warmP95DurationMilliseconds: Double
    /// Legacy compatibility field. It retains the historical all-five-run p95.
    let p95DurationMilliseconds: Double
    /// Exactly one fixture may be eligible: the first recognition in this process.
    let isColdEligible: Bool
    let maximumCharacterErrorRate: Double
    let runsAllLineCountsValid: Bool
    let fixtureSHA256: String
    let firstRecognitionVisionRequests: [OCRVisionRequestEvidence]
    let firstRecognitionTiming: OCRTimingEvidence
}

private struct OCRQualityReport: Codable {
    /// The 8s measurement is the first service call in this corpus process, not a system-cold claim.
    let measurementScope: String
    let fixtures: [OCRFixtureResult]
    let tallExpectedLineCount: Int
    let tallActualLineCount: Int
    let tallUniqueLineCount: Int
    let tallDurationMilliseconds: Double
    let tallP95DurationMilliseconds: Double
    let tallRunsAllValid: Bool
    let tallFixtureSHA256: String
    let tallFirstRecognitionVisionRequests: [OCRVisionRequestEvidence]
    let tallFirstRecognitionTiming: OCRTimingEvidence
    let fourKExpectedLineCount: Int
    let fourKActualLineCount: Int
    let fourKDurationMilliseconds: Double
    let fourKP95DurationMilliseconds: Double
    let fourKRunsAllValid: Bool
    let fourKFixtureSHA256: String
    let fourKFirstRecognitionVisionRequests: [OCRVisionRequestEvidence]
    let fourKFirstRecognitionTiming: OCRTimingEvidence
}

private struct OCRProcessFirstReport: Codable {
    let measurementKind: String
    let recognitionOrdinal: Int
    let fixtureName: String
    let processIdentifier: Int32
    let characterErrorRate: Double
    let expectedLineCount: Int
    let actualLineCount: Int
    let coldDurationMilliseconds: Double
    let fixtureSHA256: String
    let firstRecognitionVisionRequests: [OCRVisionRequestEvidence]
    let firstRecognitionTiming: OCRTimingEvidence
}

private struct OCRVisionRequestEvidence: Codable {
    let recognitionLanguages: [String]
    let automaticallyDetectsLanguage: Bool
    let usesLanguageCorrection: Bool

    init(_ configuration: LocalVisionOCRRequestConfiguration) {
        recognitionLanguages = configuration.recognitionLanguages
        automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
        usesLanguageCorrection = configuration.usesLanguageCorrection
    }
}

private final class RecordingAppleVisionOCRAdapter: LocalVisionOCRAdapter {
    private let adapter = AppleVisionOCRAdapter()
    private let lock = NSLock()
    private var recordedConfigurations: [LocalVisionOCRRequestConfiguration] = []

    func supportedRecognitionLanguages() throws -> [String] {
        try adapter.supportedRecognitionLanguages()
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> [LocalVisionOCRObservation] {
        record(configuration)
        return try await adapter.recognizeText(
            in: image,
            orientation: orientation,
            configuration: configuration,
            requestToken: requestToken
        )
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService,
        timingContext: LocalVisionOCRPassTimingContext?
    ) async throws -> [LocalVisionOCRObservation] {
        record(configuration)
        return try await adapter.recognizeText(in: image, orientation: orientation, configuration: configuration, requestToken: requestToken, qualityOfService: qualityOfService, timingContext: timingContext)
    }

    func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        configuration: LocalVisionOCRRequestConfiguration,
        requestToken: LocalVisionOCRRequestToken,
        qualityOfService: QualityOfService
    ) async throws -> [LocalVisionOCRObservation] {
        record(configuration)
        return try await adapter.recognizeText(
            in: image,
            orientation: orientation,
            configuration: configuration,
            requestToken: requestToken,
            qualityOfService: qualityOfService
        )
    }

    func checkpoint() -> Int {
        withLock { recordedConfigurations.count }
    }

    func configurations(since checkpoint: Int) -> [OCRVisionRequestEvidence] {
        withLock {
            recordedConfigurations.dropFirst(checkpoint).map(OCRVisionRequestEvidence.init)
        }
    }

    private func record(_ configuration: LocalVisionOCRRequestConfiguration) {
        withLock {
            recordedConfigurations.append(configuration)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class OCRTimingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [LocalVisionOCRTimingSnapshot] = []
    func record(_ snapshot: LocalVisionOCRTimingSnapshot) {
        withLock { snapshots.append(snapshot) }
    }
    func checkpoint() -> Int { withLock { snapshots.count } }
    func snapshot(from start: Int, through end: Int) throws -> LocalVisionOCRTimingSnapshot {
        let selected = withLock { () -> [LocalVisionOCRTimingSnapshot] in
            guard start >= 0, end >= start, end <= snapshots.count else { return [] }
            return Array(snapshots[start..<end])
        }
        guard selected.count == 1, let snapshot = selected.first else {
            throw NSError(domain: "blocks.ocr.timing", code: 1)
        }
        return snapshot
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private struct OCRFixtureColor {
    let color: NSColor
    let canonicalRed: String
    let canonicalGreen: String
    let canonicalBlue: String
    let canonicalAlpha: String

    static let white = OCRFixtureColor(
        color: .white, canonicalRed: "1", canonicalGreen: "1",
        canonicalBlue: "1", canonicalAlpha: "1"
    )
    static let black = OCRFixtureColor(
        color: .black, canonicalRed: "0", canonicalGreen: "0",
        canonicalBlue: "0", canonicalAlpha: "1"
    )
    static let darkUI = OCRFixtureColor(
        color: NSColor(calibratedWhite: 0.08, alpha: 1),
        canonicalRed: "0.08", canonicalGreen: "0.08",
        canonicalBlue: "0.08", canonicalAlpha: "1"
    )
    static let clear = OCRFixtureColor(
        color: .clear, canonicalRed: "0", canonicalGreen: "0",
        canonicalBlue: "0", canonicalAlpha: "0"
    )
}

private struct OCRFixture {
    private static let digestSchemaVersion = "blocks-ocr-quality-fixture-v1"
    private static let digestRendererFields = [
        ("colorSpace", "sRGB"),
        ("bitsPerComponent", "8"),
        ("bytesPerRow", "0"),
        ("bitmapAlphaInfo", "premultipliedLast"),
        ("graphicsContextFlipped", "false"),
        ("textRenderer", "NSString.draw"),
        ("textOriginX", "72"),
        ("textTopInset", "100"),
    ]

    let name: String
    let lines: [String]
    let fontName: String
    let fontSize: Int
    let background: OCRFixtureColor
    let foreground: OCRFixtureColor
    let lineStep: Int
    let width: Int
    let height: Int

    var fixtureSHA256: String {
        var fields = [
            ("schemaVersion", Self.digestSchemaVersion),
            ("name", name),
            ("lineCount", String(lines.count)),
        ]
        fields += lines.enumerated().map { ("line[\($0.offset)]", $0.element) }
        fields += [
            ("fontName", fontName),
            ("fontSize", String(fontSize)),
            ("canvasWidth", String(width)),
            ("canvasHeight", String(height)),
            ("lineStep", String(lineStep)),
            ("foregroundRed", foreground.canonicalRed),
            ("foregroundGreen", foreground.canonicalGreen),
            ("foregroundBlue", foreground.canonicalBlue),
            ("foregroundAlpha", foreground.canonicalAlpha),
            ("backgroundRed", background.canonicalRed),
            ("backgroundGreen", background.canonicalGreen),
            ("backgroundBlue", background.canonicalBlue),
            ("backgroundAlpha", background.canonicalAlpha),
        ]
        fields += Self.digestRendererFields

        var data = Data()
        for (key, value) in fields {
            Self.appendLengthPrefixedUTF8(key, to: &data)
            Self.appendLengthPrefixedUTF8(value, to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLengthPrefixedUTF8(_ value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
    }
}

@main
private enum OCRQualityCorpus {
    static func main() async throws {
        let recordingAdapter = RecordingAppleVisionOCRAdapter()
        let timingRecorder = OCRTimingRecorder()
        let service = LocalVisionOCRService(adapter: recordingAdapter, timingObserver: { timingRecorder.record($0) })
        let fixtures = [
            OCRFixture(
                name: "light-2x-mixed",
                lines: ["Blocks 截图文字识别", "The quick brown fox 1234567890", "スクリーンショット文字認識"],
                fontName: "system",
                fontSize: 36,
                background: .white,
                foreground: .black,
                lineStep: 150,
                width: 1_600,
                height: 720
            ),
            OCRFixture(
                name: "dark-ui",
                lines: ["设置 Settings 12345", "比例 16:9  延迟 3s  水印 35%", "https://blocks.example/path?a=1"],
                fontName: "system",
                fontSize: 30,
                background: .darkUI,
                foreground: .white,
                lineStep: 115,
                width: 1_600,
                height: 720
            ),
            OCRFixture(
                name: "compact-ui",
                lines: ["Settings ratio delay 12345", "版本 v19.2  100%  @MainActor"],
                fontName: "system",
                fontSize: 20,
                background: .white,
                foreground: .black,
                lineStep: 90,
                width: 1_600,
                height: 720
            ),
            OCRFixture(
                name: "traditional-japanese",
                lines: ["螢幕截圖文字辨識", "日本語テスト 123"],
                fontName: "system",
                fontSize: 32,
                background: .white,
                foreground: .black,
                lineStep: 120,
                width: 1_600,
                height: 720
            ),
            OCRFixture(
                name: "transparent-alpha",
                lines: ["Alpha OCR 透明背景 12345"],
                fontName: "system",
                fontSize: 30,
                background: .clear,
                foreground: .white,
                lineStep: 110,
                width: 1_600,
                height: 720
            ),
        ]
        let tallLines = (1...72).map { String(format: "LINE-%03d Blocks 长截图 OCR 12345", $0) }
        let tallFixture = OCRFixture(
            name: "tall-72-lines",
            lines: tallLines,
            fontName: "system",
            fontSize: 22,
            background: .white,
            foreground: .black,
            lineStep: 120,
            width: 1_400,
            height: tallLines.count * 120 + 160
        )
        let fourKLines = (1...24).map { "设置项目 \($0)  Settings Item \($0)  100%  ⌘K" }
        let fourKFixture = OCRFixture(
            name: "four-k-3840x2160",
            lines: fourKLines,
            fontName: "system",
            fontSize: 30,
            background: .white,
            foreground: .black,
            lineStep: 80,
            width: 3_840,
            height: 2_160
        )
        let processFirstFixtures = Dictionary(
            uniqueKeysWithValues: fixtures.map { ($0.name, $0) } + [
                ("tall-scroll", tallFixture),
                ("4k-screen", fourKFixture),
            ]
        )

        if let fixtureName = try processFirstFixtureName() {
            guard let fixture = processFirstFixtures[fixtureName] else {
                throw NSError(
                    domain: "blocks.ocr.fixture",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown fixture: \(fixtureName)"]
                )
            }
            let image = try render(fixture: fixture)
            let firstRecognitionCheckpoint = recordingAdapter.checkpoint()
            let firstTimingCheckpoint = timingRecorder.checkpoint()
            let start = ContinuousClock.now
            let result = try await service.recognizeText(in: image)
            let firstTimingEnd = timingRecorder.checkpoint()
            let report = OCRProcessFirstReport(
                measurementKind: "process-first-service-call",
                recognitionOrdinal: 1,
                fixtureName: fixtureName,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                characterErrorRate: characterErrorRate(
                    expected: fixture.lines.joined(separator: "\n"),
                    actual: result.text
                ),
                expectedLineCount: fixture.lines.count,
                actualLineCount: result.lineCount,
                coldDurationMilliseconds: milliseconds(start.duration(to: .now)),
                fixtureSHA256: fixture.fixtureSHA256,
                firstRecognitionVisionRequests: recordingAdapter.configurations(
                    since: firstRecognitionCheckpoint
                ),
                firstRecognitionTiming: OCRTimingEvidence(
                    try timingRecorder.snapshot(
                        from: firstTimingCheckpoint,
                        through: firstTimingEnd
                    )
                )
            )
            try writeJSON(report)
            return
        }

        var fixtureResults: [OCRFixtureResult] = []
        for fixture in fixtures {
            let image = try render(fixture: fixture)
            let firstRecognitionCheckpoint = recordingAdapter.checkpoint()
            let firstTimingCheckpoint = timingRecorder.checkpoint()
            let start = ContinuousClock.now
            let result = try await service.recognizeText(in: image)
            let firstTimingEnd = timingRecorder.checkpoint()
            let firstRecognitionVisionRequests = recordingAdapter.configurations(
                since: firstRecognitionCheckpoint
            )
            let firstRecognitionTiming = OCRTimingEvidence(
                try timingRecorder.snapshot(
                    from: firstTimingCheckpoint,
                    through: firstTimingEnd
                )
            )
            let coldDuration = milliseconds(start.duration(to: .now))
            var warmDurations: [Double] = []
            let firstErrorRate = characterErrorRate(
                expected: fixture.lines.joined(separator: "\n"),
                actual: result.text
            )
            var maximumErrorRate = firstErrorRate
            var runsAllLineCountsValid = result.lineCount >= fixture.lines.count
            for _ in 0..<4 {
                let repeatedStart = ContinuousClock.now
                let repeated = try await service.recognizeText(in: image)
                warmDurations.append(milliseconds(repeatedStart.duration(to: .now)))
                maximumErrorRate = max(
                    maximumErrorRate,
                    characterErrorRate(
                        expected: fixture.lines.joined(separator: "\n"),
                        actual: repeated.text
                    )
                )
                runsAllLineCountsValid = runsAllLineCountsValid
                    && repeated.lineCount >= fixture.lines.count
            }
            fixtureResults.append(OCRFixtureResult(
                name: fixture.name,
                characterErrorRate: firstErrorRate,
                expectedLineCount: fixture.lines.count,
                actualLineCount: result.lineCount,
                coldDurationMilliseconds: coldDuration,
                durationMilliseconds: coldDuration,
                warmP95DurationMilliseconds: percentile95(warmDurations),
                p95DurationMilliseconds: percentile95([coldDuration] + warmDurations),
                isColdEligible: fixtureResults.isEmpty,
                maximumCharacterErrorRate: maximumErrorRate,
                runsAllLineCountsValid: runsAllLineCountsValid,
                fixtureSHA256: fixture.fixtureSHA256,
                firstRecognitionVisionRequests: firstRecognitionVisionRequests,
                firstRecognitionTiming: firstRecognitionTiming
            ))
        }

        let tallImage = try render(fixture: tallFixture)
        let tallFirstRecognitionCheckpoint = recordingAdapter.checkpoint()
        let tallTimingCheckpoint = timingRecorder.checkpoint()
        let tallStart = ContinuousClock.now
        let tallResult = try await service.recognizeText(in: tallImage)
        let tallTimingEnd = timingRecorder.checkpoint()
        let tallFirstRecognitionVisionRequests = recordingAdapter.configurations(
            since: tallFirstRecognitionCheckpoint
        )
        let tallFirstRecognitionTiming = OCRTimingEvidence(
            try timingRecorder.snapshot(from: tallTimingCheckpoint, through: tallTimingEnd)
        )
        var tallDurations = [milliseconds(tallStart.duration(to: .now))]
        let tallRecognized = tallResult.text.split(whereSeparator: \.isNewline).map(String.init)
        let tallUniquePrefixes = Set(tallRecognized.compactMap { line -> String? in
            guard let range = line.range(of: #"LINE-\d{3}"#, options: .regularExpression) else { return nil }
            return String(line[range])
        })
        var tallRunsAllValid = tallResult.lineCount == tallLines.count
            && tallUniquePrefixes.count == tallLines.count
        for _ in 0..<4 {
            let start = ContinuousClock.now
            let result = try await service.recognizeText(in: tallImage)
            tallDurations.append(milliseconds(start.duration(to: .now)))
            let prefixes = Set(result.text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                guard let range = line.range(of: #"LINE-\d{3}"#, options: .regularExpression) else { return nil }
                return String(line[range])
            })
            tallRunsAllValid = tallRunsAllValid
                && result.lineCount == tallLines.count
                && prefixes.count == tallLines.count
        }

        let fourKImage = try render(fixture: fourKFixture)
        let fourKFirstRecognitionCheckpoint = recordingAdapter.checkpoint()
        let fourKTimingCheckpoint = timingRecorder.checkpoint()
        let fourKStart = ContinuousClock.now
        let fourKResult = try await service.recognizeText(in: fourKImage)
        let fourKTimingEnd = timingRecorder.checkpoint()
        let fourKFirstRecognitionVisionRequests = recordingAdapter.configurations(
            since: fourKFirstRecognitionCheckpoint
        )
        let fourKFirstRecognitionTiming = OCRTimingEvidence(
            try timingRecorder.snapshot(from: fourKTimingCheckpoint, through: fourKTimingEnd)
        )
        var fourKDurations = [milliseconds(fourKStart.duration(to: .now))]
        var fourKRunsAllValid = fourKResult.lineCount == fourKLines.count
        for _ in 0..<4 {
            let start = ContinuousClock.now
            let result = try await service.recognizeText(in: fourKImage)
            fourKDurations.append(milliseconds(start.duration(to: .now)))
            fourKRunsAllValid = fourKRunsAllValid && result.lineCount == fourKLines.count
        }

        let report = OCRQualityReport(
            measurementScope: "current-corpus-process-first-service-call",
            fixtures: fixtureResults,
            tallExpectedLineCount: tallLines.count,
            tallActualLineCount: tallResult.lineCount,
            tallUniqueLineCount: tallUniquePrefixes.count,
            tallDurationMilliseconds: tallDurations[0],
            tallP95DurationMilliseconds: percentile95(tallDurations),
            tallRunsAllValid: tallRunsAllValid,
            tallFixtureSHA256: tallFixture.fixtureSHA256,
            tallFirstRecognitionVisionRequests: tallFirstRecognitionVisionRequests,
            tallFirstRecognitionTiming: tallFirstRecognitionTiming,
            fourKExpectedLineCount: fourKLines.count,
            fourKActualLineCount: fourKResult.lineCount,
            fourKDurationMilliseconds: fourKDurations[0],
            fourKP95DurationMilliseconds: percentile95(fourKDurations),
            fourKRunsAllValid: fourKRunsAllValid,
            fourKFixtureSHA256: fourKFixture.fixtureSHA256,
            fourKFirstRecognitionVisionRequests: fourKFirstRecognitionVisionRequests,
            fourKFirstRecognitionTiming: fourKFirstRecognitionTiming
        )
        try writeJSON(report)
    }

    private static func processFirstFixtureName() throws -> String? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { return nil }
        guard arguments.count == 4,
              arguments[0] == "--fixture",
              arguments[2] == "--recognitions",
              arguments[3] == "1",
              !arguments[1].isEmpty else {
            throw NSError(
                domain: "blocks.ocr.fixture",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Expected --fixture <name> --recognitions 1"
                ]
            )
        }
        return arguments[1]
    }

    private static func render(fixture: OCRFixture) throws -> CGImage {
        try render(
            lines: fixture.lines,
            fontSize: CGFloat(fixture.fontSize),
            background: fixture.background.color,
            foreground: fixture.foreground.color,
            lineStep: fixture.lineStep,
            width: fixture.width,
            height: fixture.height
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func render(
        lines: [String],
        fontSize: CGFloat,
        background: NSColor,
        foreground: NSColor,
        lineStep: Int,
        width: Int,
        height: Int
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "blocks.ocr.fixture", code: 1)
        }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: foreground,
        ]
        for (index, line) in lines.enumerated() {
            NSString(string: line).draw(
                at: NSPoint(x: 72, y: CGFloat(height - 100 - index * lineStep)),
                withAttributes: attributes
            )
        }
        guard let image = context.makeImage() else {
            throw NSError(domain: "blocks.ocr.fixture", code: 2)
        }
        return image
    }

    private static func characterErrorRate(expected: String, actual: String) -> Double {
        let expectedCharacters = Array(normalized(expected))
        let actualCharacters = Array(normalized(actual))
        guard !expectedCharacters.isEmpty else { return actualCharacters.isEmpty ? 0 : 1 }
        var previous = Array(0...actualCharacters.count)
        for (expectedIndex, expectedCharacter) in expectedCharacters.enumerated() {
            var current = [expectedIndex + 1] + Array(repeating: 0, count: actualCharacters.count)
            for (actualIndex, actualCharacter) in actualCharacters.enumerated() {
                current[actualIndex + 1] = min(
                    current[actualIndex] + 1,
                    previous[actualIndex + 1] + 1,
                    previous[actualIndex] + (expectedCharacter == actualCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return Double(previous[actualCharacters.count]) / Double(expectedCharacters.count)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }
}
