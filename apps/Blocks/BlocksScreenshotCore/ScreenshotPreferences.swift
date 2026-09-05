import Foundation

public enum ScreenshotOutputFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
}
public enum ScreenshotToolbarItemID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case select
    case aspectRatio
    case arrow
    case line
    case rectangle
    case ellipse
    case freehand
    case text
    case highlight
    case blur
    case pixelate
    case counter
    case step
    case callout
    case spotlight
    case redact
    case magnifier
    case watermark
    case ocr

    public static let allCases: [ScreenshotToolbarItemID] = [
        .select, .arrow, .rectangle, .ellipse, .freehand, .text,
        .highlight, .blur, .pixelate, .counter, .step, .callout, .spotlight,
        .redact, .magnifier, .watermark, .ocr,
    ]

    public init(editorTool: ScreenshotEditorTool) {
        switch editorTool {
        case .select: self = .select
        case .arrow: self = .arrow
        case .line: self = .arrow
        case .rectangle: self = .rectangle
        case .ellipse: self = .ellipse
        case .freehand: self = .freehand
        case .text: self = .text
        case .highlight: self = .highlight
        case .blur: self = .blur
        case .pixelate: self = .pixelate
        case .counter: self = .counter
        case .step: self = .step
        case .callout: self = .callout
        case .spotlight: self = .spotlight
        case .redact: self = .redact
        case .magnifier: self = .magnifier
        case .watermark: self = .watermark
        }
    }

    public var id: String { rawValue }

    public var editorTool: ScreenshotEditorTool? {
        switch self {
        case .select: .select
        case .aspectRatio: nil
        case .arrow: .arrow
        case .line: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .freehand: .freehand
        case .text: .text
        case .highlight: .highlight
        case .blur: .blur
        case .pixelate: .pixelate
        case .counter: .counter
        case .step: .step
        case .callout: .callout
        case .spotlight: .spotlight
        case .redact: .redact
        case .magnifier: .magnifier
        case .watermark: .watermark
        case .ocr: nil
        }
    }
}

public struct ScreenshotCaptureDefaults: Codable, Equatable, Sendable {
    public var delaySeconds: Double
    public var showsCursor: Bool
    public var freezesFrame: Bool
    public var regionConstraint: ScreenshotRegionConstraint
    public var watermarkPresetID: UUID?

    public init(
        delaySeconds: Double = 0,
        showsCursor: Bool = false,
        freezesFrame: Bool = false,
        regionConstraint: ScreenshotRegionConstraint = .free,
        watermarkPresetID: UUID? = nil
    ) {
        self.delaySeconds = delaySeconds
        self.showsCursor = showsCursor
        self.freezesFrame = freezesFrame
        self.regionConstraint = regionConstraint
        self.watermarkPresetID = watermarkPresetID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delaySeconds = try container.decodeIfPresent(Double.self, forKey: .delaySeconds) ?? 0
        showsCursor = try container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? false
        freezesFrame = try container.decodeIfPresent(Bool.self, forKey: .freezesFrame) ?? false
        regionConstraint = try container.decodeIfPresent(
            ScreenshotRegionConstraint.self,
            forKey: .regionConstraint
        ) ?? .free
        watermarkPresetID = try container.decodeIfPresent(UUID.self, forKey: .watermarkPresetID)
    }

    private enum CodingKeys: String, CodingKey {
        case delaySeconds
        case showsCursor
        case freezesFrame
        case regionConstraint
        case watermarkPresetID
    }
}

public struct ScreenshotCustomConstraintPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var constraint: ScreenshotRegionConstraint

    public init(id: UUID = UUID(), constraint: ScreenshotRegionConstraint) {
        self.id = id
        self.constraint = constraint
    }
}

public struct ScreenshotPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 19
    public static let recentColorLimit = 8
    public static let customConstraintLimit = 8
    public static let maximumCustomConstraintDimension = ScreenshotCapturePlanner.maximumDimension
    public static let maximumCustomConstraintPixelCount = ScreenshotCapturePlanner.maximumPixelCount
    public static let commandToolIDs: [ScreenshotToolbarItemID] = [.select]
    public static let defaultQuickTools: [ScreenshotToolbarItemID] = [
        .arrow,
        .rectangle,
        .text,
        .highlight,
        .pixelate,
    ]
    public static let defaultToolPresets: [ScreenshotEditorTool: ScreenshotToolPreset] = Dictionary(
        uniqueKeysWithValues: ScreenshotEditorTool.allCases.map {
            ($0, ScreenshotToolPreset(tool: $0))
        }
    )

    public var version: Int
    public var toolOrder: [ScreenshotToolbarItemID]
    public var quickToolIDs: [ScreenshotToolbarItemID]
    public var hiddenToolIDs: [ScreenshotToolbarItemID]
    public var toolPresets: [ScreenshotEditorTool: ScreenshotToolPreset]
    public private(set) var recentColors: [ScreenshotColor]
    public private(set) var customConstraints: [ScreenshotCustomConstraintPreset]
    public private(set) var watermarkPresets: [ScreenshotWatermarkPreset]
    public var captureDefaults: ScreenshotCaptureDefaults
    public var retainsCaptureDefaults: Bool
    public var confirmsDiscardBeforeClosing: Bool
    public var automaticallyRecognizesHistory: Bool
    public var outputFormat: ScreenshotOutputFormat
    public var jpegQuality: Double

    public init(
        toolOrder: [ScreenshotToolbarItemID] = ScreenshotToolbarItemID.allCases,
        quickToolIDs: [ScreenshotToolbarItemID] = ScreenshotPreferences.defaultQuickTools,
        hiddenToolIDs: [ScreenshotToolbarItemID] = [],
        toolPresets: [ScreenshotEditorTool: ScreenshotToolPreset] = ScreenshotPreferences.defaultToolPresets,
        recentColors: [ScreenshotColor] = [],
        customConstraints: [ScreenshotCustomConstraintPreset] = [],
        watermarkPresets: [ScreenshotWatermarkPreset] = [],
        captureDefaults: ScreenshotCaptureDefaults = ScreenshotCaptureDefaults(),
        retainsCaptureDefaults: Bool = true,
        confirmsDiscardBeforeClosing: Bool = true,
        automaticallyRecognizesHistory: Bool = false,
        outputFormat: ScreenshotOutputFormat = .png,
        jpegQuality: Double = 0.9
    ) {
        version = Self.currentVersion
        self.toolOrder = Self.normalizedToolOrder(toolOrder)
        self.hiddenToolIDs = Self.normalizedHiddenToolIDs(hiddenToolIDs, toolOrder: self.toolOrder)
        self.quickToolIDs = Self.normalizedQuickToolIDs(
            quickToolIDs,
            hiddenToolIDs: self.hiddenToolIDs,
            toolOrder: self.toolOrder
        )
        var normalizedPresets = Self.defaultToolPresets
        for (tool, preset) in toolPresets where tool != .line && preset.tool == tool {
            normalizedPresets[tool] = preset
        }
        self.toolPresets = normalizedPresets
        self.recentColors = Self.normalizedRecentColors(recentColors)
        self.customConstraints = Self.normalizedCustomConstraints(customConstraints)
        self.watermarkPresets = Self.normalizedWatermarkPresets(watermarkPresets)
        var normalizedCaptureDefaults = captureDefaults
        if let presetID = normalizedCaptureDefaults.watermarkPresetID,
           !self.watermarkPresets.contains(where: { $0.id == presetID }) {
            normalizedCaptureDefaults.watermarkPresetID = nil
        }
        self.captureDefaults = normalizedCaptureDefaults
        self.retainsCaptureDefaults = retainsCaptureDefaults
        self.confirmsDiscardBeforeClosing = confirmsDiscardBeforeClosing
        self.automaticallyRecognizesHistory = automaticallyRecognizesHistory
        self.outputFormat = outputFormat
        self.jpegQuality = min(1, max(0.1, jpegQuality))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        if decodedVersion == 18 {
            let legacy = try LegacyScreenshotPreferencesV18(from: decoder)
            let migratedPresets = legacy.watermarkPresets.compactMap(Self.migratedWatermarkPreset)
            self.init(
                toolOrder: legacy.toolOrder,
                quickToolIDs: legacy.quickToolIDs,
                hiddenToolIDs: legacy.hiddenToolIDs,
                toolPresets: legacy.toolPresets,
                recentColors: legacy.recentColors,
                customConstraints: legacy.customConstraints,
                watermarkPresets: migratedPresets,
                captureDefaults: legacy.captureDefaults,
                retainsCaptureDefaults: legacy.retainsCaptureDefaults,
                confirmsDiscardBeforeClosing: legacy.confirmsDiscardBeforeClosing,
                automaticallyRecognizesHistory: legacy.automaticallyRecognizesHistory,
                outputFormat: legacy.outputFormat,
                jpegQuality: legacy.jpegQuality
            )
            return
        }
        if decodedVersion == 17 {
            let legacy = try LegacyScreenshotPreferencesV17(from: decoder)
            self.init(
                toolOrder: legacy.toolOrder,
                quickToolIDs: legacy.quickToolIDs,
                hiddenToolIDs: legacy.hiddenToolIDs,
                toolPresets: legacy.toolPresets,
                recentColors: legacy.recentColors,
                customConstraints: legacy.customConstraints,
                watermarkPresets: [],
                captureDefaults: legacy.captureDefaults,
                retainsCaptureDefaults: legacy.retainsCaptureDefaults,
                confirmsDiscardBeforeClosing: legacy.confirmsDiscardBeforeClosing,
                automaticallyRecognizesHistory: legacy.automaticallyRecognizesHistory,
                outputFormat: legacy.outputFormat,
                jpegQuality: legacy.jpegQuality
            )
            return
        }
        if decodedVersion == 16 {
            let legacy = try LegacyScreenshotPreferencesV16(from: decoder)
            self.init(
                toolOrder: legacy.toolOrder,
                quickToolIDs: legacy.quickToolIDs,
                hiddenToolIDs: legacy.hiddenToolIDs,
                toolPresets: Self.migratedLegacyToolPresets(legacy.toolPresets),
                recentColors: legacy.recentColors,
                customConstraints: legacy.customConstraints,
                captureDefaults: legacy.captureDefaults,
                retainsCaptureDefaults: legacy.retainsCaptureDefaults,
                confirmsDiscardBeforeClosing: legacy.confirmsDiscardBeforeClosing,
                automaticallyRecognizesHistory: legacy.automaticallyRecognizesHistory,
                outputFormat: legacy.outputFormat,
                jpegQuality: legacy.jpegQuality
            )
            return
        }
        if decodedVersion == 15 {
            let legacy = try LegacyScreenshotPreferencesV15(from: decoder)
            self.init(
                toolOrder: Self.migratedLegacyToolOrder(legacy.toolOrder),
                quickToolIDs: Self.migratedLegacyQuickTools(legacy.quickToolIDs),
                hiddenToolIDs: Self.migratedLegacyHiddenTools(legacy.hiddenToolIDs),
                toolPresets: Self.migratedLegacyToolPresets(legacy.toolPresets),
                recentColors: legacy.recentColors,
                customConstraints: legacy.customConstraints,
                captureDefaults: legacy.captureDefaults,
                retainsCaptureDefaults: legacy.retainsCaptureDefaults,
                confirmsDiscardBeforeClosing: legacy.confirmsDiscardBeforeClosing,
                automaticallyRecognizesHistory: legacy.automaticallyRecognizesHistory,
                outputFormat: legacy.outputFormat,
                jpegQuality: legacy.jpegQuality
            )
            return
        }
        if decodedVersion == 14 {
            let legacy = try LegacyScreenshotPreferencesV14(from: decoder)
            self.init(
                toolOrder: Self.migratedLegacyToolOrder(legacy.toolOrder),
                quickToolIDs: Self.migratedLegacyQuickTools(legacy.quickToolIDs),
                hiddenToolIDs: Self.migratedLegacyHiddenTools(legacy.hiddenToolIDs),
                toolPresets: Self.migratedLegacyToolPresets(legacy.toolPresets),
                recentColors: legacy.recentColors,
                customConstraints: [],
                captureDefaults: legacy.captureDefaults,
                retainsCaptureDefaults: legacy.retainsCaptureDefaults,
                confirmsDiscardBeforeClosing: legacy.confirmsDiscardBeforeClosing,
                automaticallyRecognizesHistory: legacy.automaticallyRecognizesHistory,
                outputFormat: legacy.outputFormat,
                jpegQuality: legacy.jpegQuality
            )
            return
        }
        if decodedVersion == 13 {
            let legacy = try LegacyScreenshotPreferencesV13(from: decoder)
            var migratedPresets: [ScreenshotEditorTool: ScreenshotToolPreset] = [:]
            for (tool, preset) in legacy.toolPresets {
                guard let currentTool = tool.currentTool else { continue }
                migratedPresets[currentTool] = ScreenshotToolPreset(
                    tool: currentTool,
                    appearance: preset.appearance
                )
            }
            self.init(
                toolOrder: Self.migratedLegacyToolOrder(legacy.toolOrder.compactMap(\.currentItem)),
                quickToolIDs: Self.migratedLegacyQuickTools(legacy.quickToolIDs.compactMap(\.currentItem)),
                hiddenToolIDs: Self.migratedLegacyHiddenTools(legacy.hiddenToolIDs.compactMap(\.currentItem)),
                toolPresets: migratedPresets,
                recentColors: [],
                customConstraints: [],
                captureDefaults: legacy.captureDefaults,
                retainsCaptureDefaults: legacy.retainsCaptureDefaults,
                confirmsDiscardBeforeClosing: legacy.confirmsDiscardBeforeClosing,
                automaticallyRecognizesHistory: legacy.automaticallyRecognizesHistory,
                outputFormat: legacy.outputFormat,
                jpegQuality: legacy.jpegQuality
            )
            return
        }
        guard decodedVersion == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported screenshot preferences version \(decodedVersion)"
            )
        }
        self.init(
            toolOrder: try container.decode([ScreenshotToolbarItemID].self, forKey: .toolOrder),
            quickToolIDs: try container.decode([ScreenshotToolbarItemID].self, forKey: .quickToolIDs),
            hiddenToolIDs: try container.decode([ScreenshotToolbarItemID].self, forKey: .hiddenToolIDs),
            toolPresets: try container.decode([ScreenshotEditorTool: ScreenshotToolPreset].self, forKey: .toolPresets),
            recentColors: try container.decodeIfPresent([ScreenshotColor].self, forKey: .recentColors) ?? [],
            customConstraints: try container.decodeIfPresent(
                [ScreenshotCustomConstraintPreset].self,
                forKey: .customConstraints
            ) ?? [],
            watermarkPresets: try container.decodeIfPresent(
                [ScreenshotWatermarkPreset].self,
                forKey: .watermarkPresets
            ) ?? [],
            captureDefaults: try container.decode(ScreenshotCaptureDefaults.self, forKey: .captureDefaults),
            retainsCaptureDefaults: try container.decode(Bool.self, forKey: .retainsCaptureDefaults),
            confirmsDiscardBeforeClosing: try container.decode(Bool.self, forKey: .confirmsDiscardBeforeClosing),
            automaticallyRecognizesHistory: try container.decode(Bool.self, forKey: .automaticallyRecognizesHistory),
            outputFormat: try container.decode(ScreenshotOutputFormat.self, forKey: .outputFormat),
            jpegQuality: try container.decode(Double.self, forKey: .jpegQuality)
        )
    }

    public var extendedToolIDs: [ScreenshotToolbarItemID] {
        let excluded = Set(Self.commandToolIDs + quickToolIDs + hiddenToolIDs)
        return toolOrder.filter { !excluded.contains($0) }
    }

    public var visibleQuickToolbarItemIDs: [ScreenshotToolbarItemID] {
        quickToolIDs
    }

    public var visibleExtendedToolbarItemIDs: [ScreenshotToolbarItemID] {
        extendedToolIDs
    }

    public mutating func recordRecentColor(_ color: ScreenshotColor) {
        recentColors = Self.normalizedRecentColors([color] + recentColors)
    }

    public mutating func replaceRecentColors(_ colors: [ScreenshotColor]) {
        recentColors = Self.normalizedRecentColors(colors)
    }

    public mutating func saveCustomConstraint(_ constraint: ScreenshotRegionConstraint) {
        saveCustomConstraint(ScreenshotCustomConstraintPreset(constraint: constraint))
    }

    public mutating func saveCustomConstraint(_ preset: ScreenshotCustomConstraintPreset) {
        let constraint = preset.constraint
        guard let normalized = Self.normalizedCustomConstraint(constraint) else { return }
        let key = CustomConstraintKey(normalized)
        let retained = customConstraints.filter { preset in
            guard let existing = Self.normalizedCustomConstraint(preset.constraint) else { return false }
            return CustomConstraintKey(existing) != key
        }
        customConstraints = Self.normalizedCustomConstraints([
            ScreenshotCustomConstraintPreset(id: preset.id, constraint: normalized),
        ] + retained)
    }

    public mutating func removeCustomConstraint(id: UUID) {
        customConstraints.removeAll { $0.id == id }
    }

    public mutating func saveWatermarkPreset(_ preset: ScreenshotWatermarkPreset) {
        watermarkPresets = Self.normalizedWatermarkPresets(
            [preset] + watermarkPresets.filter { $0.id != preset.id }
        )
    }

    public mutating func removeWatermarkPreset(id: UUID) {
        watermarkPresets.removeAll { $0.id == id }
        if captureDefaults.watermarkPresetID == id {
            captureDefaults.watermarkPresetID = nil
        }
    }

    public static func normalizedToolOrder(_ tools: [ScreenshotToolbarItemID]) -> [ScreenshotToolbarItemID] {
        var result = unique(tools).filter {
            !commandToolIDs.contains($0) && $0 != .line && $0 != .aspectRatio
        }
        for tool in ScreenshotToolbarItemID.allCases where !commandToolIDs.contains(tool) && !result.contains(tool) {
            result.append(tool)
        }
        return commandToolIDs + result
    }

    public static func normalizedRecentColors(_ colors: [ScreenshotColor]) -> [ScreenshotColor] {
        var seen = Set<NormalizedScreenshotColorKey>()
        var result: [ScreenshotColor] = []
        for color in colors {
            let normalized = ScreenshotColor(
                red: normalizedColorChannel(color.red),
                green: normalizedColorChannel(color.green),
                blue: normalizedColorChannel(color.blue),
                alpha: 1
            )
            let key = NormalizedScreenshotColorKey(normalized)
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
            if result.count == recentColorLimit { break }
        }
        return result
    }

    public static func normalizedCustomConstraints(
        _ presets: [ScreenshotCustomConstraintPreset]
    ) -> [ScreenshotCustomConstraintPreset] {
        var seen = Set<CustomConstraintKey>()
        var result: [ScreenshotCustomConstraintPreset] = []
        for preset in presets {
            guard let constraint = normalizedCustomConstraint(preset.constraint) else { continue }
            let key = CustomConstraintKey(constraint)
            guard seen.insert(key).inserted else { continue }
            result.append(ScreenshotCustomConstraintPreset(id: preset.id, constraint: constraint))
            if result.count == customConstraintLimit { break }
        }
        return result
    }

    public static func normalizedWatermarkPresets(
        _ presets: [ScreenshotWatermarkPreset]
    ) -> [ScreenshotWatermarkPreset] {
        var seen = Set<UUID>()
        return presets.compactMap { preset in
            guard seen.insert(preset.id).inserted else { return nil }
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = preset.style.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !text.isEmpty else { return nil }
            var normalized = preset
            normalized.name = name
            normalized.style.text = text
            return normalized
        }
    }

    public static func normalizedCustomConstraint(
        _ constraint: ScreenshotRegionConstraint
    ) -> ScreenshotRegionConstraint? {
        switch constraint {
        case .free:
            return nil
        case let .ratio(width, height):
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            let landscapeWidth = max(width, height)
            let landscapeHeight = min(width, height)
            let ratio = landscapeWidth / landscapeHeight
            guard ratio.isFinite, ratio <= Double(maximumCustomConstraintDimension) else { return nil }
            if landscapeWidth.rounded() == landscapeWidth,
               landscapeHeight.rounded() == landscapeHeight,
               landscapeWidth <= Double(maximumCustomConstraintDimension),
               landscapeHeight <= Double(maximumCustomConstraintDimension) {
                return .ratio(width: landscapeWidth, height: landscapeHeight)
            }
            return .ratio(width: ratio, height: 1)
        case let .fixedPixels(width, height):
            guard width > 0, height > 0,
                  width <= maximumCustomConstraintDimension,
                  height <= maximumCustomConstraintDimension else { return nil }
            let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixelCount <= maximumCustomConstraintPixelCount else { return nil }
            return .fixedPixels(width: max(width, height), height: min(width, height))
        }
    }

    private static func normalizedQuickToolIDs(
        _ tools: [ScreenshotToolbarItemID],
        hiddenToolIDs: [ScreenshotToolbarItemID],
        toolOrder: [ScreenshotToolbarItemID]
    ) -> [ScreenshotToolbarItemID] {
        let requested = Set(unique(tools))
        let hidden = Set(hiddenToolIDs)
        return toolOrder.filter {
            !commandToolIDs.contains($0) && !hidden.contains($0) && requested.contains($0)
        }
    }

    private static func normalizedHiddenToolIDs(
        _ tools: [ScreenshotToolbarItemID],
        toolOrder: [ScreenshotToolbarItemID]
    ) -> [ScreenshotToolbarItemID] {
        let requested = Set(unique(tools))
        return toolOrder.filter { !commandToolIDs.contains($0) && requested.contains($0) }
    }

    private static func migratedLegacyQuickTools(
        _ tools: [ScreenshotToolbarItemID]
    ) -> [ScreenshotToolbarItemID] {
        tools.filter { $0 != .aspectRatio && $0 != .select }
    }

    private static func migratedLegacyToolOrder(
        _ tools: [ScreenshotToolbarItemID]
    ) -> [ScreenshotToolbarItemID] {
        commandToolIDs + tools.filter {
            !commandToolIDs.contains($0) && $0 != .aspectRatio
        }
    }

    private static func migratedLegacyHiddenTools(
        _ tools: [ScreenshotToolbarItemID]
    ) -> [ScreenshotToolbarItemID] {
        tools.filter { !commandToolIDs.contains($0) && $0 != .aspectRatio }
    }

    private static func migratedLegacyToolPresets(
        _ presets: [ScreenshotEditorTool: ScreenshotToolPreset]
    ) -> [ScreenshotEditorTool: ScreenshotToolPreset] {
        var result = presets.filter { $0.key != .line }
        if var stepPreset = result[.step],
           case var .step(step) = stepPreset.appearance.payload,
           step.gap == 12 {
            step.gap = ScreenshotStepResolvedLayout.defaultGap
            stepPreset.appearance.payload = .step(step)
            result[.step] = stepPreset
        }
        return result
    }

    private static func migratedWatermarkPreset(
        _ preset: LegacyScreenshotWatermarkPresetV18
    ) -> ScreenshotWatermarkPreset? {
        guard case let .text(content) = preset.content else { return nil }
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ScreenshotWatermarkPreset(
            id: preset.id,
            name: preset.name,
            style: ScreenshotWatermarkStyle(
                text: text,
                color: content.color,
                weight: content.weight,
                fontSizeFraction: content.fontSize / 1_280,
                density: 0.5,
                angleDegrees: -30,
                opacity: preset.opacity
            )
        )
    }

    private static func unique(_ tools: [ScreenshotToolbarItemID]) -> [ScreenshotToolbarItemID] {
        var seen: Set<ScreenshotToolbarItemID> = []
        return tools.filter { seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case toolOrder
        case quickToolIDs
        case hiddenToolIDs
        case toolPresets
        case recentColors
        case customConstraints
        case watermarkPresets
        case captureDefaults
        case retainsCaptureDefaults
        case confirmsDiscardBeforeClosing
        case automaticallyRecognizesHistory
        case outputFormat
        case jpegQuality
    }

    private static func normalizedColorChannel(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

private enum CustomConstraintKey: Hashable {
    case ratio(Int64)
    case fixedPixels(Int, Int)

    init(_ constraint: ScreenshotRegionConstraint) {
        switch constraint {
        case let .ratio(width, height):
            self = .ratio(Int64((width / height * 1_000_000).rounded()))
        case let .fixedPixels(width, height):
            self = .fixedPixels(width, height)
        case .free:
            preconditionFailure("Free constraints cannot be persisted as custom presets")
        }
    }
}

private struct NormalizedScreenshotColorKey: Hashable {
    let red: UInt64
    let green: UInt64
    let blue: UInt64

    init(_ color: ScreenshotColor) {
        red = color.red.bitPattern
        green = color.green.bitPattern
        blue = color.blue.bitPattern
    }
}

private enum LegacyScreenshotToolbarItemIDV13: String, Codable {
    case select, crop, arrow, line, rectangle, ellipse, freehand, text, highlight
    case blur, pixelate, counter, callout, spotlight, redact, magnifier, ocr

    var currentItem: ScreenshotToolbarItemID? {
        if self == .crop { return .aspectRatio }
        return ScreenshotToolbarItemID(rawValue: rawValue)
    }
}

private enum LegacyScreenshotEditorToolV13: String, Codable {
    case select, crop, arrow, line, rectangle, ellipse, freehand, text, highlight
    case blur, pixelate, counter, callout, spotlight, redact, magnifier

    var currentTool: ScreenshotEditorTool? {
        guard self != .crop else { return nil }
        return ScreenshotEditorTool(rawValue: rawValue)
    }
}

private struct LegacyScreenshotToolPresetV13: Codable {
    let tool: LegacyScreenshotEditorToolV13
    let appearance: ScreenshotElementAppearance
}

private struct LegacyScreenshotPreferencesV13: Decodable {
    let toolOrder: [LegacyScreenshotToolbarItemIDV13]
    let quickToolIDs: [LegacyScreenshotToolbarItemIDV13]
    let hiddenToolIDs: [LegacyScreenshotToolbarItemIDV13]
    let toolPresets: [LegacyScreenshotEditorToolV13: LegacyScreenshotToolPresetV13]
    let captureDefaults: ScreenshotCaptureDefaults
    let retainsCaptureDefaults: Bool
    let confirmsDiscardBeforeClosing: Bool
    let addsScreenshotTag: Bool
    let automaticallyRecognizesHistory: Bool
    let outputFormat: ScreenshotOutputFormat
    let jpegQuality: Double
}

private struct LegacyScreenshotPreferencesV14: Decodable {
    let toolOrder: [ScreenshotToolbarItemID]
    let quickToolIDs: [ScreenshotToolbarItemID]
    let hiddenToolIDs: [ScreenshotToolbarItemID]
    let toolPresets: [ScreenshotEditorTool: ScreenshotToolPreset]
    let recentColors: [ScreenshotColor]
    let captureDefaults: ScreenshotCaptureDefaults
    let retainsCaptureDefaults: Bool
    let confirmsDiscardBeforeClosing: Bool
    let addsScreenshotTag: Bool
    let automaticallyRecognizesHistory: Bool
    let outputFormat: ScreenshotOutputFormat
    let jpegQuality: Double
}

private struct LegacyScreenshotPreferencesV15: Decodable {
    let toolOrder: [ScreenshotToolbarItemID]
    let quickToolIDs: [ScreenshotToolbarItemID]
    let hiddenToolIDs: [ScreenshotToolbarItemID]
    let toolPresets: [ScreenshotEditorTool: ScreenshotToolPreset]
    let recentColors: [ScreenshotColor]
    let customConstraints: [ScreenshotCustomConstraintPreset]
    let captureDefaults: ScreenshotCaptureDefaults
    let retainsCaptureDefaults: Bool
    let confirmsDiscardBeforeClosing: Bool
    let addsScreenshotTag: Bool
    let automaticallyRecognizesHistory: Bool
    let outputFormat: ScreenshotOutputFormat
    let jpegQuality: Double
}

private struct LegacyScreenshotPreferencesV16: Decodable {
    let toolOrder: [ScreenshotToolbarItemID]
    let quickToolIDs: [ScreenshotToolbarItemID]
    let hiddenToolIDs: [ScreenshotToolbarItemID]
    let toolPresets: [ScreenshotEditorTool: ScreenshotToolPreset]
    let recentColors: [ScreenshotColor]
    let customConstraints: [ScreenshotCustomConstraintPreset]
    let captureDefaults: ScreenshotCaptureDefaults
    let retainsCaptureDefaults: Bool
    let confirmsDiscardBeforeClosing: Bool
    let addsScreenshotTag: Bool
    let automaticallyRecognizesHistory: Bool
    let outputFormat: ScreenshotOutputFormat
    let jpegQuality: Double
}

private struct LegacyScreenshotPreferencesV17: Decodable {
    let toolOrder: [ScreenshotToolbarItemID]
    let quickToolIDs: [ScreenshotToolbarItemID]
    let hiddenToolIDs: [ScreenshotToolbarItemID]
    let toolPresets: [ScreenshotEditorTool: ScreenshotToolPreset]
    let recentColors: [ScreenshotColor]
    let customConstraints: [ScreenshotCustomConstraintPreset]
    let captureDefaults: ScreenshotCaptureDefaults
    let retainsCaptureDefaults: Bool
    let confirmsDiscardBeforeClosing: Bool
    let addsScreenshotTag: Bool
    let automaticallyRecognizesHistory: Bool
    let outputFormat: ScreenshotOutputFormat
    let jpegQuality: Double
}

private struct LegacyScreenshotPreferencesV18: Decodable {
    let toolOrder: [ScreenshotToolbarItemID]
    let quickToolIDs: [ScreenshotToolbarItemID]
    let hiddenToolIDs: [ScreenshotToolbarItemID]
    let toolPresets: [ScreenshotEditorTool: ScreenshotToolPreset]
    let recentColors: [ScreenshotColor]
    let customConstraints: [ScreenshotCustomConstraintPreset]
    let watermarkPresets: [LegacyScreenshotWatermarkPresetV18]
    let captureDefaults: ScreenshotCaptureDefaults
    let retainsCaptureDefaults: Bool
    let confirmsDiscardBeforeClosing: Bool
    let automaticallyRecognizesHistory: Bool
    let outputFormat: ScreenshotOutputFormat
    let jpegQuality: Double
}

private struct LegacyScreenshotWatermarkPresetV18: Codable {
    let id: UUID
    var name: String
    var content: LegacyScreenshotWatermarkContentV18
    var defaultSizeFraction: Double
    var defaultPosition: LegacyScreenshotWatermarkPositionV18
    var marginFraction: Double
    var opacity: Double
}

private enum LegacyScreenshotWatermarkPositionV18: String, Codable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing
}

private struct LegacyScreenshotWatermarkTextContentV18: Codable {
    var text: String
    var color: ScreenshotColor
    var weight: ScreenshotTextWeight
    var alignment: ScreenshotTextAlignment
    var fontSize: Double
}

private struct LegacyScreenshotWatermarkSignatureContentV18: Codable {
    var assetID: String?
    var strokes: [LegacyScreenshotWatermarkStrokeV18]
}

private struct LegacyScreenshotWatermarkStrokeV18: Codable {
    var points: [ScreenshotPixelPoint]
    var color: ScreenshotColor
    var width: Double
}

private struct LegacyScreenshotWatermarkImageContentV18: Codable {
    var assetID: String
}

private enum LegacyScreenshotWatermarkContentV18: Codable {
    case text(LegacyScreenshotWatermarkTextContentV18)
    case signature(LegacyScreenshotWatermarkSignatureContentV18)
    case image(LegacyScreenshotWatermarkImageContentV18)
}
