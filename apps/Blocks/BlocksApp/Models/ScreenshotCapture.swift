import AppKit
import CoreGraphics
import Foundation
import BlocksScreenshotCore

@MainActor
final class ScreenshotSelectionSurfaceHandoff {
    private var completion: (() -> Void)?

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    var isPending: Bool {
        completion != nil
    }

    func complete() {
        guard let completion else { return }
        self.completion = nil
        completion()
    }

    deinit {
        completion?()
    }
}

struct ScreenshotEditingScreen: Equatable {
    let displayID: UInt32
    let frame: CGRect
}

struct ScreenshotEditingContext {
    let sourceContext: ScreenshotSourceContext
    let sourceFrame: CGRect
    let screens: [ScreenshotEditingScreen]
    let initialCropRect: ScreenshotPixelRect
    let supportsRangeExpansion: Bool
    let initialRegionConstraint: ScreenshotRegionConstraint

    init(
        sourceContext: ScreenshotSourceContext,
        sourceFrame: CGRect,
        screens: [ScreenshotEditingScreen],
        initialCropRect: ScreenshotPixelRect,
        supportsRangeExpansion: Bool,
        initialRegionConstraint: ScreenshotRegionConstraint = .free
    ) {
        self.sourceContext = sourceContext
        self.sourceFrame = sourceFrame
        self.screens = screens
        self.initialCropRect = initialCropRect
        self.supportsRangeExpansion = supportsRangeExpansion
        self.initialRegionConstraint = initialRegionConstraint
    }
}

struct ScreenshotCapture: Identifiable {
    let id: String
    let image: NSImage
    let pixelSize: CGSize
    let sourceRect: CGRect
    let kind: ScreenshotResolvedCaptureKind
    let displayScope: ScreenshotDisplayScope?
    let sourceSummary: String
    let editingContext: ScreenshotEditingContext?
    let defersOutputUntilEditorCompletion: Bool
    let scrollingSessionID: String?
    let watermarkPresetID: UUID?
    let selectionSurfaceHandoff: ScreenshotSelectionSurfaceHandoff?

    init(
        id: String,
        image: NSImage,
        pixelSize: CGSize,
        sourceRect: CGRect,
        kind: ScreenshotResolvedCaptureKind,
        displayScope: ScreenshotDisplayScope?,
        sourceSummary: String,
        editingContext: ScreenshotEditingContext? = nil,
        defersOutputUntilEditorCompletion: Bool = false,
        scrollingSessionID: String? = nil,
        watermarkPresetID: UUID? = nil,
        selectionSurfaceHandoff: ScreenshotSelectionSurfaceHandoff? = nil
    ) {
        self.id = id
        self.image = image
        self.pixelSize = pixelSize
        self.sourceRect = sourceRect
        self.kind = kind
        self.displayScope = displayScope
        self.sourceSummary = sourceSummary
        self.editingContext = editingContext
        self.defersOutputUntilEditorCompletion = defersOutputUntilEditorCompletion
        self.scrollingSessionID = scrollingSessionID
        self.watermarkPresetID = watermarkPresetID
        self.selectionSurfaceHandoff = selectionSurfaceHandoff
    }

    func attachingSelectionSurfaceHandoff(
        _ handoff: ScreenshotSelectionSurfaceHandoff?
    ) -> ScreenshotCapture {
        ScreenshotCapture(
            id: id,
            image: image,
            pixelSize: pixelSize,
            sourceRect: sourceRect,
            kind: kind,
            displayScope: displayScope,
            sourceSummary: sourceSummary,
            editingContext: editingContext,
            defersOutputUntilEditorCompletion: defersOutputUntilEditorCompletion,
            scrollingSessionID: scrollingSessionID,
            watermarkPresetID: watermarkPresetID,
            selectionSurfaceHandoff: handoff
        )
    }
}
