import AppKit
import BlocksScreenshotCore
import SwiftUI

/// Screenshot-specific dimensions that layer on the global visual tokens.
///
/// These values describe document/editor geometry rather than a second visual
/// system. Shared surfaces, controls and motion continue to come from the
/// Blocks design foundation.
enum ScreenshotDesignTokens {
    static let iconVisualSize: CGFloat = 16
    static let toolbarMainHeight: CGFloat = 48
    static let toolbarPropertyHeight: CGFloat = 38
    static let ocrPanelSize = CGSize(width: 360, height: 260)
    static let hudSize = CGSize(width: 520, height: 64)
}

enum ScreenshotEditorChromeMetrics {
    static let statusBarHeight: CGFloat = 40
    static let statusChipSpacing = BlocksVisualTokens.Spacing.xs
    static let statusBarPadding = BlocksVisualTokens.Spacing.sm
    static let edgeInset = BlocksVisualTokens.Spacing.md
    static let cropGap = BlocksVisualTokens.Spacing.sm
    static let toolbarDividerHeight = BlocksVisualTokens.Spacing.xs
    static let bottomToolbarHeight = ScreenshotDesignTokens.toolbarPropertyHeight
        + toolbarDividerHeight
        + ScreenshotDesignTokens.toolbarMainHeight
    static let canvasTopInset = edgeInset + statusBarHeight + cropGap
    static let canvasBottomInset = cropGap + bottomToolbarHeight + edgeInset

    static func maximumWidth(
        in availableWidth: CGFloat,
        edgeMargin: CGFloat = BlocksVisualTokens.Spacing.xl
    ) -> CGFloat {
        max(0, availableWidth - edgeMargin * 2)
    }
}

struct ScreenshotEditorCropChromeFrames: Equatable {
    let canvas: CGRect
    let crop: CGRect
    let status: CGRect
    let toolbar: CGRect
}

enum ScreenshotEditorCanvasPresentation: Equatable {
    case cropSurround
    case displayOverlay

    /// Require captured pixels to cover the complete displayed source, not merely
    /// a similarly shaped crop. Coordinates may be negative on secondary screens.
    static func resolve(sourceFrame: CGRect, captureFrame: CGRect, displayFrames: [CGRect], isLongImage: Bool = false) -> Self {
        guard !isLongImage, !sourceFrame.isEmpty, !captureFrame.isEmpty, !displayFrames.isEmpty else { return .cropSurround }
        let coversSource = abs(sourceFrame.minX - captureFrame.minX) <= 1
            && abs(sourceFrame.minY - captureFrame.minY) <= 1
            && abs(sourceFrame.maxX - captureFrame.maxX) <= 1
            && abs(sourceFrame.maxY - captureFrame.maxY) <= 1
        let displayUnion = displayFrames.dropFirst().reduce(displayFrames[0]) { $0.union($1) }
        return coversSource && sourceFrame == displayUnion ? .displayOverlay : .cropSurround
    }
}

/// Synchronous intrinsic measurement includes localized labels and plugin views.
/// No first-frame estimate or deferred PreferenceKey width correction is needed.
struct ScreenshotChromeContentLayout: Layout {
    let maximumWidth: CGFloat
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let intrinsic = subviews.first?.sizeThatFits(.unspecified).width ?? 0
        return CGSize(width: min(maximumWidth, proposal.width ?? maximumWidth, intrinsic), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Each row retains its own content-sized surface; an empty inspector hint does
/// not paint a toolbar-wide blank slab. The controls row determines the cap.
struct ScreenshotEditorToolbarPanelLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(maximumWidth, proposal.width ?? maximumWidth,
                        subviews.first?.sizeThatFits(.unspecified).width ?? 0)
        return CGSize(width: width, height: ScreenshotEditorChromeMetrics.bottomToolbarHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: ScreenshotDesignTokens.toolbarMainHeight))
        let propertyWidth = min(bounds.width, subviews[1].sizeThatFits(.unspecified).width)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.maxY), anchor: .bottom,
                          proposal: ProposedViewSize(width: propertyWidth, height: ScreenshotDesignTokens.toolbarPropertyHeight))
    }
}

/// Canvas and both chrome rows are measured/placed together, so their anchors use
/// real content widths rather than the legacy settings-preview button estimate.
struct ScreenshotEditorOverlayLayout: Layout {
    let availableSize: CGSize
    let sourceRect: ScreenshotPixelRect
    let cropRect: ScreenshotPixelRect
    let zoomScale: CGFloat
    let panOffset: CGSize
    let presentation: ScreenshotEditorCanvasPresentation
    let safeAreaInsets: EdgeInsets

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { availableSize }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let frames = ScreenshotEditorCropChromeLayout.resolve(
            availableSize: bounds.size, sourceRect: sourceRect, cropRect: cropRect,
            zoomScale: zoomScale, panOffset: panOffset,
            statusWidth: subviews[1].sizeThatFits(.unspecified).width,
            toolbarWidth: subviews[2].sizeThatFits(.unspecified).width,
            presentation: presentation, safeAreaInsets: safeAreaInsets
        )
        for (subview, frame) in zip(subviews, [frames.canvas, frames.status, frames.toolbar]) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

enum ScreenshotEditorCropChromeLayout {
    static func resolve(
        availableSize: CGSize,
        sourceRect: ScreenshotPixelRect,
        cropRect: ScreenshotPixelRect,
        zoomScale: CGFloat,
        panOffset: CGSize,
        statusWidth: CGFloat,
        toolbarWidth: CGFloat,
        presentation: ScreenshotEditorCanvasPresentation = .cropSurround,
        safeAreaInsets: EdgeInsets = EdgeInsets()
    ) -> ScreenshotEditorCropChromeFrames {
        let fullCanvas = CGRect(origin: .zero, size: availableSize)
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            let toolbar = CGRect(
                x: centeredClampedX(
                    width: toolbarWidth,
                    anchorX: availableSize.width / 2,
                    availableWidth: availableSize.width
                ),
                y: max(
                    0,
                    availableSize.height - ScreenshotEditorChromeMetrics.edgeInset
                        - ScreenshotEditorChromeMetrics.bottomToolbarHeight
                ),
                width: toolbarWidth,
                height: ScreenshotEditorChromeMetrics.bottomToolbarHeight
            )
            let status = CGRect(
                x: centeredClampedX(
                    width: statusWidth,
                    anchorX: availableSize.width / 2,
                    availableWidth: availableSize.width
                ),
                y: ScreenshotEditorChromeMetrics.edgeInset,
                width: statusWidth,
                height: ScreenshotEditorChromeMetrics.statusBarHeight
            )
            return .init(canvas: fullCanvas, crop: .zero, status: status, toolbar: toolbar)
        }

        let fullCanvasCrop = projectedCrop(
            canvas: fullCanvas,
            sourceRect: sourceRect,
            cropRect: cropRect,
            zoomScale: zoomScale,
            panOffset: panOffset
        )
        let canvas = presentation == .displayOverlay ? fullCanvas : displayCanvas(
            availableSize: availableSize,
            projectedCrop: fullCanvasCrop
        )
        let crop = canvas == fullCanvas
            ? fullCanvasCrop
            : projectedCrop(
                canvas: canvas,
                sourceRect: sourceRect,
                cropRect: cropRect,
                zoomScale: zoomScale,
                panOffset: panOffset
            )

        let statusX = centeredClampedX(
            width: statusWidth,
            anchorX: crop.midX,
            availableWidth: availableSize.width,
            leadingInset: presentation == .displayOverlay ? safeAreaInsets.leading : 0,
            trailingInset: presentation == .displayOverlay ? safeAreaInsets.trailing : 0
        )
        let toolbarX = centeredClampedX(
            width: toolbarWidth,
            anchorX: crop.midX,
            availableWidth: availableSize.width,
            leadingInset: presentation == .displayOverlay ? safeAreaInsets.leading : 0,
            trailingInset: presentation == .displayOverlay ? safeAreaInsets.trailing : 0
        )
        let statusPreferredY = presentation == .displayOverlay
            ? ScreenshotEditorChromeMetrics.edgeInset + safeAreaInsets.top
            : crop.minY
            - ScreenshotEditorChromeMetrics.cropGap
            - ScreenshotEditorChromeMetrics.statusBarHeight
        let statusY = min(
            max(ScreenshotEditorChromeMetrics.edgeInset, statusPreferredY),
            max(
                ScreenshotEditorChromeMetrics.edgeInset,
                availableSize.height - ScreenshotEditorChromeMetrics.edgeInset
                    - ScreenshotEditorChromeMetrics.statusBarHeight
            )
        )
        let toolbarPreferredY = presentation == .displayOverlay
            ? availableSize.height - ScreenshotEditorChromeMetrics.edgeInset
                - safeAreaInsets.bottom - ScreenshotEditorChromeMetrics.bottomToolbarHeight
            : crop.maxY + ScreenshotEditorChromeMetrics.cropGap
        let toolbarY = min(
            max(ScreenshotEditorChromeMetrics.edgeInset, toolbarPreferredY),
            max(
                ScreenshotEditorChromeMetrics.edgeInset,
                availableSize.height - ScreenshotEditorChromeMetrics.edgeInset
                    - ScreenshotEditorChromeMetrics.bottomToolbarHeight
            )
        )
        return .init(
            canvas: canvas,
            crop: crop,
            status: CGRect(
                x: statusX,
                y: statusY,
                width: statusWidth,
                height: ScreenshotEditorChromeMetrics.statusBarHeight
            ),
            toolbar: CGRect(
                x: toolbarX,
                y: toolbarY,
                width: toolbarWidth,
                height: ScreenshotEditorChromeMetrics.bottomToolbarHeight
            )
        )
    }

    private static func centeredClampedX(
        width: CGFloat,
        anchorX: CGFloat,
        availableWidth: CGFloat,
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0
    ) -> CGFloat {
        min(
            max(ScreenshotEditorChromeMetrics.edgeInset + leadingInset, anchorX - width / 2),
            max(
                ScreenshotEditorChromeMetrics.edgeInset + leadingInset,
                availableWidth - ScreenshotEditorChromeMetrics.edgeInset - trailingInset - width
            )
        )
    }

    private static func displayCanvas(
        availableSize: CGSize,
        projectedCrop: CGRect
    ) -> CGRect {
        let availableAbove = projectedCrop.minY
        let availableBelow = availableSize.height - projectedCrop.maxY
        let requiredAbove = ScreenshotEditorChromeMetrics.canvasTopInset
        let requiredBelow = ScreenshotEditorChromeMetrics.canvasBottomInset
        guard availableAbove + 0.5 < requiredAbove
                || availableBelow + 0.5 < requiredBelow else {
            return CGRect(origin: .zero, size: availableSize)
        }

        let height = max(
            1,
            availableSize.height - requiredAbove - requiredBelow
        )
        return CGRect(
            x: 0,
            y: min(requiredAbove, max(0, availableSize.height - height)),
            width: max(1, availableSize.width),
            height: height
        )
    }

    private static func projectedCrop(
        canvas: CGRect,
        sourceRect: ScreenshotPixelRect,
        cropRect: ScreenshotPixelRect,
        zoomScale: CGFloat,
        panOffset: CGSize
    ) -> CGRect {
        let baseScale = min(
            canvas.width / CGFloat(sourceRect.width),
            canvas.height / CGFloat(sourceRect.height)
        )
        let scale = max(0.001, baseScale * zoomScale)
        let imageSize = CGSize(
            width: CGFloat(sourceRect.width) * scale,
            height: CGFloat(sourceRect.height) * scale
        )
        let imageFrame = CGRect(
            x: canvas.midX - imageSize.width / 2 + panOffset.width,
            y: canvas.midY - imageSize.height / 2 + panOffset.height,
            width: imageSize.width,
            height: imageSize.height
        )
        return CGRect(
            x: imageFrame.minX + CGFloat(cropRect.x - sourceRect.x) * scale,
            y: imageFrame.minY + CGFloat(cropRect.y - sourceRect.y) * scale,
            width: CGFloat(cropRect.width) * scale,
            height: CGFloat(cropRect.height) * scale
        )
    }
}

enum ScreenshotEditorStatusBarModel {
    static func visibleElements(in snapshot: ScreenshotSceneSnapshot) -> [ScreenshotElement] {
        ScreenshotEditorSelectionModel.visibleElements(in: snapshot)
    }

    static func title(for element: ScreenshotElement) -> String {
        let base = element.kind.tool.toolbarItemID.localizedTitle
        guard element.kind == .step, let stepNumber = element.stepNumber else { return base }
        return "\(base) \(stepNumber)"
    }

    static func nextElementID(
        afterDeleting id: UUID,
        from elements: [ScreenshotElement]
    ) -> UUID? {
        ScreenshotEditorSelectionModel.nextElementID(afterDeleting: id, from: elements)
    }
}

/// Resolves the visual width of the status strip independently from the main
/// toolbar. The strip hugs its chips until it reaches the toolbar/safe-area
/// limit, at which point its existing horizontal overflow behavior takes over.
enum ScreenshotEditorStatusBarLayout {
    private static let iconWidth: CGFloat = 12
    private static let iconTitleSpacing = BlocksVisualTokens.Spacing.xs
    private static let chipHorizontalPadding = BlocksVisualTokens.Spacing.sm * 2

    static func estimatedContentWidth(elements: [ScreenshotElement]) -> CGFloat {
        let titles = [
            L10n.string("screenshot.editor.status.size"),
            L10n.string("screenshot.editor.cornerRadius")
        ] + elements.map(ScreenshotEditorStatusBarModel.title(for:))
        let font = NSFont.systemFont(
            ofSize: BlocksVisualTokens.Typography.caption,
            weight: .medium
        )
        let chipsWidth = titles.reduce(CGFloat.zero) { partial, title in
            let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            return partial + iconWidth + iconTitleSpacing + textWidth + chipHorizontalPadding
        }
        let spacing = CGFloat(max(0, titles.count - 1))
            * ScreenshotEditorChromeMetrics.statusChipSpacing
        return ceil(
            chipsWidth
                + spacing
                + ScreenshotEditorChromeMetrics.statusBarPadding * 2
        )
    }

    static func resolvedWidth(
        measuredContentWidth: CGFloat,
        estimatedContentWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat {
        let contentWidth = measuredContentWidth > 0
            ? measuredContentWidth
            : estimatedContentWidth
        return min(
            max(0, maximumWidth),
            max(BlocksVisualTokens.Control.minimumHitTarget, ceil(contentWidth))
        )
    }
}

enum ScreenshotFloatingPanelLayout {
    static func frame(
        anchorFrame: CGRect,
        panelSize: CGSize,
        visibleBounds: CGRect,
        gap: CGFloat = BlocksVisualTokens.Spacing.sm,
        edgeInset: CGFloat = BlocksVisualTokens.Spacing.md
    ) -> CGRect {
        let safeBounds = visibleBounds.insetBy(dx: edgeInset, dy: edgeInset)
        let candidateOrigins = [
            CGPoint(x: anchorFrame.maxX - panelSize.width, y: anchorFrame.maxY + gap),
            CGPoint(x: anchorFrame.minX, y: anchorFrame.maxY + gap),
            CGPoint(x: anchorFrame.maxX - panelSize.width, y: anchorFrame.minY - gap - panelSize.height),
            CGPoint(x: anchorFrame.minX, y: anchorFrame.minY - gap - panelSize.height),
        ]
        if let fittingOrigin = candidateOrigins.first(where: {
            safeBounds.contains(CGRect(origin: $0, size: panelSize))
        }) {
            return CGRect(origin: fittingOrigin, size: panelSize)
        }

        let bestOrigin = candidateOrigins.max { lhs, rhs in
            let lhsArea = intersectionArea(
                safeBounds,
                CGRect(origin: lhs, size: panelSize)
            )
            let rhsArea = intersectionArea(
                safeBounds,
                CGRect(origin: rhs, size: panelSize)
            )
            return lhsArea < rhsArea
        } ?? safeBounds.origin
        let clampedOrigin = CGPoint(
            x: min(
                max(bestOrigin.x, safeBounds.minX),
                max(safeBounds.minX, safeBounds.maxX - panelSize.width)
            ),
            y: min(
                max(bestOrigin.y, safeBounds.minY),
                max(safeBounds.minY, safeBounds.maxY - panelSize.height)
            )
        )
        return CGRect(origin: clampedOrigin, size: panelSize)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
