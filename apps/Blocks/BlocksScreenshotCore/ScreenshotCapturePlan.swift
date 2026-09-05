import Foundation

public struct ScreenshotDisplayDescriptor: Codable, Equatable, Sendable {
    public let id: UInt32
    public let selectionFrame: ScreenshotSelectionRect
    public let backingScale: Double

    public init(id: UInt32, selectionFrame: ScreenshotSelectionRect, backingScale: Double) {
        self.id = id
        self.selectionFrame = selectionFrame
        self.backingScale = backingScale
    }
}

public struct ScreenshotPixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct ScreenshotPixelRect: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ScreenshotCaptureSlice: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let sourcePixels: ScreenshotPixelRect
    public let destinationPixels: ScreenshotPixelRect

    public init(
        displayID: UInt32,
        sourcePixels: ScreenshotPixelRect,
        destinationPixels: ScreenshotPixelRect
    ) {
        self.displayID = displayID
        self.sourcePixels = sourcePixels
        self.destinationPixels = destinationPixels
    }
}

public struct ScreenshotCapturePlan: Codable, Equatable, Sendable {
    public let selectionRegion: ScreenshotSelectionRect
    public let outputScale: Double
    public let outputSize: ScreenshotPixelSize
    public let slices: [ScreenshotCaptureSlice]

    public init(
        selectionRegion: ScreenshotSelectionRect,
        outputScale: Double,
        outputSize: ScreenshotPixelSize,
        slices: [ScreenshotCaptureSlice]
    ) {
        self.selectionRegion = selectionRegion
        self.outputScale = outputScale
        self.outputSize = outputSize
        self.slices = slices
    }
}

public enum ScreenshotCapturePlanError: Error, Equatable {
    case invalidRegion
    case invalidDisplayScale
    case regionOutsideDisplays
    case displayNotFound
    case windowOutsideDisplays
    case outputDimensionExceeded
    case outputPixelCountExceeded
}

public struct ScreenshotCapturePlanner: Sendable {
    public static let maximumDimension = 32_768
    public static let maximumPixelCount = 120_000_000

    public init() {}

    public func planRegion(
        _ region: ScreenshotSelectionRect,
        displays: [ScreenshotDisplayDescriptor]
    ) throws -> ScreenshotCapturePlan {
        guard !region.isEmpty else {
            throw ScreenshotCapturePlanError.invalidRegion
        }
        guard displays.allSatisfy({ $0.backingScale > 0 }) else {
            throw ScreenshotCapturePlanError.invalidDisplayScale
        }

        let intersections = displays.compactMap { display -> (ScreenshotDisplayDescriptor, ScreenshotSelectionRect)? in
            guard let intersection = region.intersection(with: display.selectionFrame) else {
                return nil
            }
            return (display, intersection)
        }
        guard !intersections.isEmpty else {
            throw ScreenshotCapturePlanError.regionOutsideDisplays
        }

        let outputScale = try outputScale(for: region, displays: displays)
        let outputSize = ScreenshotPixelSize(
            width: pixelCeiling(region.width, scale: outputScale),
            height: pixelCeiling(region.height, scale: outputScale)
        )
        try validateOutputSize(outputSize)

        let slices = intersections.map { display, intersection in
            let sourceMinX = pixelBoundary(
                intersection.minX - display.selectionFrame.minX,
                scale: display.backingScale
            )
            let sourceMaxX = pixelBoundary(
                intersection.maxX - display.selectionFrame.minX,
                scale: display.backingScale
            )
            let sourceMinY = pixelBoundary(
                display.selectionFrame.maxY - intersection.maxY,
                scale: display.backingScale
            )
            let sourceMaxY = pixelBoundary(
                display.selectionFrame.maxY - intersection.minY,
                scale: display.backingScale
            )
            let destinationMinX = pixelBoundary(
                intersection.minX - region.minX,
                scale: outputScale
            )
            let destinationMaxX = min(
                outputSize.width,
                pixelBoundary(intersection.maxX - region.minX, scale: outputScale)
            )
            let destinationMinY = pixelBoundary(
                region.maxY - intersection.maxY,
                scale: outputScale
            )
            let destinationMaxY = min(
                outputSize.height,
                pixelBoundary(region.maxY - intersection.minY, scale: outputScale)
            )
            return ScreenshotCaptureSlice(
                displayID: display.id,
                sourcePixels: ScreenshotPixelRect(
                    x: sourceMinX,
                    y: sourceMinY,
                    width: max(1, sourceMaxX - sourceMinX),
                    height: max(1, sourceMaxY - sourceMinY)
                ),
                destinationPixels: ScreenshotPixelRect(
                    x: destinationMinX,
                    y: destinationMinY,
                    width: max(1, destinationMaxX - destinationMinX),
                    height: max(1, destinationMaxY - destinationMinY)
                )
            )
        }

        return ScreenshotCapturePlan(
            selectionRegion: region,
            outputScale: outputScale,
            outputSize: outputSize,
            slices: slices
        )
    }

    public func outputScale(
        for region: ScreenshotSelectionRect,
        displays: [ScreenshotDisplayDescriptor]
    ) throws -> Double {
        guard !region.isEmpty else {
            throw ScreenshotCapturePlanError.invalidRegion
        }
        guard displays.allSatisfy({ $0.backingScale > 0 }) else {
            throw ScreenshotCapturePlanError.invalidDisplayScale
        }
        let scales = displays.compactMap { display in
            region.intersection(with: display.selectionFrame) == nil ? nil : display.backingScale
        }
        guard let scale = scales.max() else {
            throw ScreenshotCapturePlanError.regionOutsideDisplays
        }
        return scale
    }

    public func planDisplays(
        scope: ScreenshotDisplayScope,
        currentDisplayID: UInt32,
        displays: [ScreenshotDisplayDescriptor]
    ) throws -> ScreenshotCapturePlan {
        switch scope {
        case .current:
            guard let display = displays.first(where: { $0.id == currentDisplayID }) else {
                throw ScreenshotCapturePlanError.displayNotFound
            }
            return try planRegion(display.selectionFrame, displays: [display])

        case let .displayID(displayID):
            guard let display = displays.first(where: { $0.id == displayID }) else {
                throw ScreenshotCapturePlanError.displayNotFound
            }
            return try planRegion(display.selectionFrame, displays: [display])

        case .all:
            guard let first = displays.first else {
                throw ScreenshotCapturePlanError.displayNotFound
            }
            let selectionRegion = displays.dropFirst().reduce(first.selectionFrame) { partial, display in
                partial.union(with: display.selectionFrame)
            }
            return try planRegion(selectionRegion, displays: displays)
        }
    }

    public func planWindow(
        _ window: ScreenshotWindowCandidate,
        displays: [ScreenshotDisplayDescriptor]
    ) throws -> ScreenshotCapturePlan {
        do {
            return try planRegion(window.frame, displays: displays)
        } catch ScreenshotCapturePlanError.regionOutsideDisplays {
            throw ScreenshotCapturePlanError.windowOutsideDisplays
        } catch {
            throw error
        }
    }

    private func validateOutputSize(_ size: ScreenshotPixelSize) throws {
        guard size.width <= Self.maximumDimension, size.height <= Self.maximumDimension else {
            throw ScreenshotCapturePlanError.outputDimensionExceeded
        }
        let (pixelCount, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        guard !overflow, pixelCount <= Self.maximumPixelCount else {
            throw ScreenshotCapturePlanError.outputPixelCountExceeded
        }
    }

    private func pixelBoundary(_ value: Double, scale: Double) -> Int {
        Int((value * scale).rounded())
    }

    private func pixelCeiling(_ value: Double, scale: Double) -> Int {
        Int(ceil(value * scale))
    }
}

private extension ScreenshotSelectionRect {
    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func intersection(with other: ScreenshotSelectionRect) -> ScreenshotSelectionRect? {
        let minX = max(x, other.x)
        let minY = max(y, other.y)
        let maxX = min(x + width, other.x + other.width)
        let maxY = min(y + height, other.y + other.height)
        guard maxX > minX, maxY > minY else {
            return nil
        }
        return ScreenshotSelectionRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    func union(with other: ScreenshotSelectionRect) -> ScreenshotSelectionRect {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width)
        let maxY = max(y + height, other.y + other.height)
        return ScreenshotSelectionRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}
