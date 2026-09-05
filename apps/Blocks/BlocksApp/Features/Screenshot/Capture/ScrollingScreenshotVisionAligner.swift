import BlocksScreenshotCore
import CoreGraphics
import Foundation
import Vision

struct ScrollingScreenshotVisionAligner {
    private struct Estimate {
        let verticalRows: Int
        let horizontalRows: Int
        let confidence: Double
    }

    func alignmentHint(previous: CGImage, incoming: CGImage) -> ScrollingFrameAlignmentHint? {
        visionAlignmentHint(previous: previous, incoming: incoming)
            ?? denseMultiRegionAlignmentHint(previous: previous, incoming: incoming)
    }

    private func visionAlignmentHint(
        previous: CGImage,
        incoming: CGImage
    ) -> ScrollingFrameAlignmentHint? {
        guard previous.width == incoming.width,
              previous.height == incoming.height,
              previous.width >= 96,
              previous.height >= 96 else { return nil }

        let scale = min(
            1,
            min(960.0 / Double(previous.width), 720.0 / Double(previous.height))
        )
        guard let referenceImage = downsample(previous, scale: scale),
              let targetImage = downsample(incoming, scale: scale) else { return nil }
        let width = referenceImage.width
        let height = referenceImage.height
        let topInset = max(8, height / 8)
        let bottomInset = max(8, height / 12)
        let usableHeight = height - topInset - bottomInset
        guard usableHeight >= 64 else { return nil }

        let bands = [
            (width * 18 / 100)..<(width * 43 / 100),
            (width * 43 / 100)..<(width * 68 / 100),
            (width * 68 / 100)..<(width * 93 / 100),
        ]
        let estimates = bands.compactMap { band -> Estimate? in
            let rect = CGRect(
                x: band.lowerBound,
                y: topInset,
                width: band.count,
                height: usableHeight
            )
            guard let reference = referenceImage.cropping(to: rect),
                  let target = targetImage.cropping(to: rect) else { return nil }
            let request = VNTranslationalImageRegistrationRequest(
                targetedCGImage: target,
                options: [:]
            )
            let handler = VNImageRequestHandler(cgImage: reference, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            guard let observation = request.results?.first else { return nil }
            let transform = observation.alignmentTransform
            // Vision returns the target translation required to align it with the reference.
            let vertical = Int((-transform.ty / scale).rounded())
            let horizontal = Int((transform.tx / scale).rounded())
            guard vertical > 0,
                  vertical < previous.height - 24,
                  abs(horizontal) <= max(8, previous.width / 20) else { return nil }
            return Estimate(
                verticalRows: vertical,
                horizontalRows: horizontal,
                confidence: Double(observation.confidence)
            )
        }
        guard estimates.count >= 2 else { return nil }

        let sortedRows = estimates.map(\.verticalRows).sorted()
        let medianRows = sortedRows[sortedRows.count / 2]
        let tolerance = max(6, medianRows / 8)
        let agreeing = estimates.filter { abs($0.verticalRows - medianRows) <= tolerance }
        guard agreeing.count >= 2, agreeing.count * 2 > estimates.count else { return nil }
        let sortedHorizontal = agreeing.map(\.horizontalRows).sorted()
        let confidence = agreeing.map(\.confidence).reduce(0, +) / Double(agreeing.count)
        return ScrollingFrameAlignmentHint(
            scrollRows: medianRows,
            horizontalShift: sortedHorizontal[sortedHorizontal.count / 2],
            agreeingRegions: agreeing.count,
            sampledRegions: estimates.count,
            confidence: confidence
        )
    }

    private struct LumaFrame {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        subscript(x: Int, y: Int) -> Double {
            Double(pixels[y * width + x])
        }
    }

    private func denseMultiRegionAlignmentHint(
        previous: CGImage,
        incoming: CGImage
    ) -> ScrollingFrameAlignmentHint? {
        guard previous.width == incoming.width,
              previous.height == incoming.height,
              let lhs = makeLumaFrame(previous),
              let rhs = makeLumaFrame(incoming) else { return nil }
        let topInset = max(8, lhs.height / 8)
        let bottomInset = max(8, lhs.height / 12)
        let contentHeight = lhs.height - topInset - bottomInset
        guard contentHeight >= 64 else { return nil }

        let regions = [
            (lhs.width * 18 / 100)..<(lhs.width * 43 / 100),
            (lhs.width * 43 / 100)..<(lhs.width * 68 / 100),
            (lhs.width * 68 / 100)..<(lhs.width * 93 / 100),
        ]
        let estimates = regions.compactMap { region in
            denseVerticalEstimate(
                previous: lhs,
                incoming: rhs,
                xRange: region,
                topInset: topInset,
                contentHeight: contentHeight
            )
        }
        guard estimates.count >= 2 else { return nil }
        let sortedRows = estimates.map(\.verticalRows).sorted()
        let medianRows = sortedRows[sortedRows.count / 2]
        let tolerance = max(4, medianRows / 20)
        let agreeing = estimates.filter { abs($0.verticalRows - medianRows) <= tolerance }
        guard agreeing.count >= 2, agreeing.count * 2 > estimates.count else { return nil }
        let confidence = agreeing.map(\.confidence).reduce(0, +) / Double(agreeing.count)
        return ScrollingFrameAlignmentHint(
            scrollRows: medianRows,
            horizontalShift: 0,
            agreeingRegions: agreeing.count,
            sampledRegions: estimates.count,
            confidence: confidence
        )
    }

    private func denseVerticalEstimate(
        previous: LumaFrame,
        incoming: LumaFrame,
        xRange: Range<Int>,
        topInset: Int,
        contentHeight: Int
    ) -> Estimate? {
        let minimumOverlap = max(24, contentHeight / 8)
        let maximumScroll = contentHeight - minimumOverlap
        guard maximumScroll > 0, xRange.count >= 8 else { return nil }
        var ranked: [(rows: Int, difference: Double)] = []
        ranked.reserveCapacity(maximumScroll)

        for scrollRows in 1...maximumScroll {
            let overlap = contentHeight - scrollRows
            var totalDifference = 0.0
            var texturedSamples = 0
            let yStride = max(1, overlap / 160)
            let xStride = max(1, xRange.count / 28)
            var y = 1
            while y < overlap {
                var x = max(1, xRange.lowerBound)
                while x < xRange.upperBound {
                    let lhsY = topInset + scrollRows + y
                    let rhsY = topInset + y
                    let lhsValue = previous[x, lhsY]
                    let rhsValue = incoming[x, rhsY]
                    let lhsTexture = abs(lhsValue - previous[x - 1, lhsY])
                        + abs(lhsValue - previous[x, lhsY - 1])
                    let rhsTexture = abs(rhsValue - incoming[x - 1, rhsY])
                        + abs(rhsValue - incoming[x, rhsY - 1])
                    if max(lhsTexture, rhsTexture) >= 8 {
                        totalDifference += abs(lhsValue - rhsValue) / 255 * 0.7
                            + abs(lhsTexture - rhsTexture) / 510 * 0.3
                        texturedSamples += 1
                    }
                    x += xStride
                }
                y += yStride
            }
            guard texturedSamples >= 24 else { continue }
            ranked.append((scrollRows, totalDifference / Double(texturedSamples)))
        }

        ranked.sort { $0.difference < $1.difference }
        guard ranked.count >= 2 else { return nil }
        let best = ranked[0]
        let runnerUp = ranked.first(where: { abs($0.rows - best.rows) > 2 }) ?? ranked[1]
        let separation = runnerUp.difference - best.difference
        guard best.difference <= 0.08,
              separation >= max(0.002, best.difference * 0.2),
              runnerUp.difference >= best.difference * 1.4 else { return nil }
        return Estimate(
            verticalRows: best.rows,
            horizontalRows: 0,
            confidence: min(1, max(0, 1 - best.difference * 4))
        )
    }

    private func makeLumaFrame(_ image: CGImage) -> LumaFrame? {
        let width = min(192, image.width)
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let created = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? LumaFrame(width: width, height: height, pixels: pixels) : nil
    }

    private func downsample(_ image: CGImage, scale: Double) -> CGImage? {
        guard scale < 0.999 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
