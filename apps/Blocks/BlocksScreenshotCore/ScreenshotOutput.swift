import CoreGraphics
import Foundation

public struct ScreenshotOutputAppearance: Codable, Equatable, Sendable {
    public static let minimumCornerRadius = 8
    public static let maximumCornerRadius = 48

    public var isRounded: Bool

    public init(isRounded: Bool = false) {
        self.isRounded = isRounded
    }

    public func cornerRadius(for size: ScreenshotPixelSize) -> Int {
        guard isRounded, size.width > 0, size.height > 0 else { return 0 }
        let proposed = Int((Double(min(size.width, size.height)) * 0.04).rounded())
        return min(Self.maximumCornerRadius, max(Self.minimumCornerRadius, proposed))
    }
}

public enum ScreenshotOutputProcessor {
    public static func process(
        image: CGImage,
        imageRect: ScreenshotPixelRect,
        outputRect: ScreenshotPixelRect,
        appearance: ScreenshotOutputAppearance
    ) throws -> CGImage {
        let imageBounds = CGRect(
            x: imageRect.x,
            y: imageRect.y,
            width: imageRect.width,
            height: imageRect.height
        )
        let requestedOutput = CGRect(
            x: outputRect.x,
            y: outputRect.y,
            width: outputRect.width,
            height: outputRect.height
        )
        let clipped = requestedOutput.intersection(imageBounds).integral
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            throw ScreenshotRenderError.invalidCrop
        }
        let localCrop = CGRect(
            x: clipped.minX - imageBounds.minX,
            y: clipped.minY - imageBounds.minY,
            width: clipped.width,
            height: clipped.height
        )
        guard let cropped = image.cropping(to: localCrop) else {
            throw ScreenshotRenderError.invalidCrop
        }
        return try applyAppearance(to: cropped, appearance: appearance)
    }

    public static func applyAppearance(
        to image: CGImage,
        appearance: ScreenshotOutputAppearance
    ) throws -> CGImage {
        let radius = appearance.cornerRadius(for: .init(width: image.width, height: image.height))
        guard radius > 0 else { return image }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenshotRenderError.bitmapContextCreationFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.clear(bounds)
        context.addPath(CGPath(
            roundedRect: bounds,
            cornerWidth: CGFloat(radius),
            cornerHeight: CGFloat(radius),
            transform: nil
        ))
        context.clip()
        context.draw(image, in: bounds)
        guard let output = context.makeImage() else {
            throw ScreenshotRenderError.imageCreationFailed
        }
        return output
    }
}
