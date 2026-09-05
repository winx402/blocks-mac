import AppKit
import BlocksScreenshotCore
import CoreGraphics
import Foundation

struct TranslationScreenshotScreen: Equatable, Sendable {
    let displayID: UInt32?
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: CGFloat
}

/// Immutable screenshot handoff. The `NSImage` is created from the same
/// immutable `CGImage` and must not be mutated by consumers.
struct TranslationScreenshotCapture: @unchecked Sendable {
    let image: NSImage
    let cgImage: CGImage
    let logicalRect: CGRect
    let pixelSize: CGSize
    let screen: TranslationScreenshotScreen?
}

enum TranslationScreenshotCaptureError: Error, Equatable {
    case invalidRegion
    case imageUnavailable
}

@MainActor
protocol TranslationScreenshotCaptureProviding: AnyObject {
    func captureRegion() async throws -> TranslationScreenshotCapture
    func cancelCurrentCapture()
}

/// Reuses the production screenshot selection and ScreenCaptureKit path while
/// deliberately bypassing ScreenshotStore. Consequently this bridge does not
/// present the editor and has no clipboard/history output terminal.
@MainActor
final class TranslationScreenshotCaptureProvider: TranslationScreenshotCaptureProviding {
    private let captureService: any ScreenshotPurposeCapturing
    private let screensProvider: () -> [TranslationScreenshotScreen]

    init(
        captureService: (any ScreenshotPurposeCapturing)? = nil,
        screensProvider: @escaping () -> [TranslationScreenshotScreen] = {
            NSScreen.screens.map { screen in
                TranslationScreenshotScreen(
                    displayID: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                        .uint32Value,
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    backingScaleFactor: screen.backingScaleFactor
                )
            }
        }
    ) {
        self.captureService = captureService ?? ScreenCaptureKitAdapter()
        self.screensProvider = screensProvider
    }

    func captureRegion() async throws -> TranslationScreenshotCapture {
        let intent = try ScreenshotCaptureIntent(kind: .region)
        let capture: ScreenshotCapture
        do {
            capture = try await captureService.capture(
                intent: intent,
                requiresEditingContext: false,
                purpose: .translationOCR
            )
        } catch ScreenshotCaptureError.cancelled {
            throw CancellationError()
        } catch is ScreenshotCaptureArbitrationError {
            throw CancellationError()
        }
        guard capture.sourceRect.width.isFinite,
              capture.sourceRect.height.isFinite,
              capture.sourceRect.width > 0,
              capture.sourceRect.height > 0 else {
            throw TranslationScreenshotCaptureError.invalidRegion
        }
        guard let cgImage = capture.image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw TranslationScreenshotCaptureError.imageUnavailable
        }

        return TranslationScreenshotCapture(
            image: capture.image,
            cgImage: cgImage,
            logicalRect: capture.sourceRect,
            pixelSize: capture.pixelSize,
            screen: primaryScreen(for: capture.sourceRect)
        )
    }

    func cancelCurrentCapture() {
        captureService.cancelCurrentCapture()
    }

    private func primaryScreen(for region: CGRect) -> TranslationScreenshotScreen? {
        screensProvider()
            .map { screen in
                (
                    screen: screen,
                    area: translationScreenshotIntersectionArea(
                        region.intersection(screen.frame)
                    )
                )
            }
            .filter { $0.area > 0 }
            .max { lhs, rhs in lhs.area < rhs.area }?
            .screen
    }
}

private func translationScreenshotIntersectionArea(
    _ rect: CGRect
) -> CGFloat {
    guard !rect.isNull,
          !rect.isInfinite,
          rect.width > 0,
          rect.height > 0 else {
        return 0
    }
    return rect.width * rect.height
}
