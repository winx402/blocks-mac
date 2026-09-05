import AppKit
import BlocksScreenshotCore

enum ScreenshotEditingContextError: Error {
    case missingDisplayImage(UInt32)
    case invalidSourceBounds
    case unableToAllocateComposite
}

private struct ScreenshotSourceImageTile {
    let descriptor: ScreenshotSourceTileDescriptor
    let image: CGImage
}

struct ScreenshotEditingContextBuilder {
    static func make(
        plan: ScreenshotCapturePlan,
        displays: [ScreenshotDisplayDescriptor],
        displayImages: [UInt32: CGImage],
        cleanCaptureImage: CGImage? = nil,
        initialRegionConstraint: ScreenshotRegionConstraint = .free
    ) throws -> ScreenshotEditingContext {
        let relevantDisplayIDs = Set(plan.slices.map(\.displayID))
        let relevantDisplays = displays.filter { relevantDisplayIDs.contains($0.id) }
        guard let firstDisplay = relevantDisplays.first else {
            throw ScreenshotEditingContextError.invalidSourceBounds
        }
        let sourceFrame = relevantDisplays.dropFirst().reduce(cgRect(firstDisplay.selectionFrame)) {
            $0.union(cgRect($1.selectionFrame))
        }
        let scale = relevantDisplays.map(\.backingScale).max() ?? plan.outputScale
        let sourceBounds = ScreenshotPixelRect(
            x: 0,
            y: 0,
            width: max(1, pixelBoundary(sourceFrame.width * scale)),
            height: max(1, pixelBoundary(sourceFrame.height * scale))
        )

        var tiles: [ScreenshotSourceImageTile] = try relevantDisplays.map { display in
            guard let image = displayImages[display.id] else {
                throw ScreenshotEditingContextError.missingDisplayImage(display.id)
            }
            let frame = cgRect(display.selectionFrame)
            return ScreenshotSourceImageTile(
                descriptor: ScreenshotSourceTileDescriptor(
                    id: "display-\(display.id)",
                    bounds: quantizedBounds(frame, relativeTo: sourceFrame, scale: scale)
                ),
                image: image
            )
        }
        let initialCropRect = quantizedBounds(
            cgRect(plan.selectionRegion),
            relativeTo: sourceFrame,
            scale: scale
        )
        if let cleanCaptureImage {
            tiles.append(ScreenshotSourceImageTile(
                descriptor: ScreenshotSourceTileDescriptor(id: "capture-overlay", bounds: initialCropRect),
                image: cleanCaptureImage
            ))
        }

        let composite = try compose(tiles: tiles, bounds: sourceBounds)
        return ScreenshotEditingContext(
            sourceContext: ScreenshotSourceContext(
                sourceBounds: sourceBounds,
                tileDescriptors: tiles.map(\.descriptor),
                compositeSource: composite
            ),
            sourceFrame: sourceFrame,
            screens: relevantDisplays.map {
                ScreenshotEditingScreen(displayID: $0.id, frame: cgRect($0.selectionFrame))
            },
            initialCropRect: initialCropRect,
            supportsRangeExpansion: true,
            initialRegionConstraint: initialRegionConstraint
        )
    }

    private static func compose(
        tiles: [ScreenshotSourceImageTile],
        bounds: ScreenshotPixelRect
    ) throws -> CGImage {
        do {
            return try ScreenshotImageCompositor.compose(
                size: .init(width: bounds.width, height: bounds.height),
                tiles: tiles.map { tile in
                    ScreenshotImageCompositeTile(
                        image: tile.image,
                        destination: tile.descriptor.bounds,
                        blendMode: .normal
                    )
                }
            )
        } catch {
            throw ScreenshotEditingContextError.unableToAllocateComposite
        }
    }

    private static func quantizedBounds(
        _ frame: CGRect,
        relativeTo sourceFrame: CGRect,
        scale: Double
    ) -> ScreenshotPixelRect {
        let minX = pixelBoundary((frame.minX - sourceFrame.minX) * scale)
        let maxX = pixelBoundary((frame.maxX - sourceFrame.minX) * scale)
        let minY = pixelBoundary((sourceFrame.maxY - frame.maxY) * scale)
        let maxY = pixelBoundary((sourceFrame.maxY - frame.minY) * scale)
        return ScreenshotPixelRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }

    private static func pixelBoundary(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private static func cgRect(_ rect: ScreenshotSelectionRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
