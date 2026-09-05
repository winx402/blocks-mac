import AppKit

struct ScreenshotDisplayGeometry: Equatable {
    let id: CGDirectDisplayID
    let appKitFrame: CGRect
    let quartzFrame: CGRect
    let backingScale: CGFloat
}

struct ScreenshotCoordinateBridge {
    let primaryAppKitFrame: CGRect
    let primaryQuartzFrame: CGRect

    func selectionRect(fromQuartzRect rect: CGRect) -> CGRect {
        CGRect(
            x: primaryAppKitFrame.minX + rect.minX - primaryQuartzFrame.minX,
            y: primaryAppKitFrame.maxY - (rect.maxY - primaryQuartzFrame.minY),
            width: rect.width,
            height: rect.height
        )
    }

    func quartzRect(fromSelectionRect rect: CGRect) -> CGRect {
        CGRect(
            x: primaryQuartzFrame.minX + rect.minX - primaryAppKitFrame.minX,
            y: primaryQuartzFrame.minY + primaryAppKitFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    func displayLocalSourceRect(
        forSelectionRect rect: CGRect,
        on display: ScreenshotDisplayGeometry
    ) -> CGRect? {
        let intersection = rect.intersection(display.appKitFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        return CGRect(
            x: intersection.minX - display.appKitFrame.minX,
            y: display.appKitFrame.maxY - intersection.maxY,
            width: intersection.width,
            height: intersection.height
        )
    }
}

struct ScreenshotWindowCaptureRequest: Equatable {
    let outputWidth: Int
    let outputHeight: Int
    let ignoresGlobalClip: Bool

    init(windowFrame: CGRect, pointPixelScale: CGFloat) {
        let scale = max(1, pointPixelScale)
        outputWidth = max(1, Int(ceil(windowFrame.width * scale)))
        outputHeight = max(1, Int(ceil(windowFrame.height * scale)))
        ignoresGlobalClip = true
    }
}
