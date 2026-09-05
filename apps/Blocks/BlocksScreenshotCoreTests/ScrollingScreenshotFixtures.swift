import Foundation
@testable import BlocksScreenshotCore

struct ScrollingScreenshotSyntheticFrame: Equatable {
    let id: String
    let rows: [[UInt8]]

    var descriptor: ScrollingFrameDescriptor {
        ScrollingFrameDescriptor(
            id: id,
            pixelSize: ScreenshotPixelSize(width: rows.first?.count ?? 0, height: rows.count),
            sampleWidth: rows.first?.count ?? 0,
            lumaSamples: rows.flatMap { $0 }
        )
    }
}

enum ScrollingScreenshotFixtures {
    static func rows(_ identifiers: some Sequence<Int>, width: Int = 8) -> [[UInt8]] {
        identifiers.map { identifier in
            (0..<width).map { column in
                var value = UInt64(truncatingIfNeeded: identifier) &* 0x9E37_79B9_7F4A_7C15
                value ^= UInt64(column) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
                return UInt8(truncatingIfNeeded: value ^ (value >> 31))
            }
        }
    }

    static func frame(
        _ id: String,
        rowIdentifiers: some Sequence<Int>,
        width: Int = 8
    ) -> ScrollingScreenshotSyntheticFrame {
        ScrollingScreenshotSyntheticFrame(id: id, rows: rows(rowIdentifiers, width: width))
    }

    static func frame(
        _ id: String,
        headerIdentifiers: some Sequence<Int>,
        contentIdentifiers: some Sequence<Int>,
        width: Int = 8
    ) -> ScrollingScreenshotSyntheticFrame {
        ScrollingScreenshotSyntheticFrame(
            id: id,
            rows: rows(headerIdentifiers, width: width) + rows(contentIdentifiers, width: width)
        )
    }

    static func viewport(
        _ id: String,
        documentStart: Int,
        height: Int = 72,
        width: Int = 48,
        fixedHeaderRows: Int = 8,
        fixedSidebarColumns: Int = 8,
        dynamicRect: (x: Range<Int>, y: Range<Int>)? = nil
    ) -> ScrollingScreenshotSyntheticFrame {
        let rows = (0..<height).map { y in
            (0..<width).map { x -> UInt8 in
                let base: Int
                if y < fixedHeaderRows {
                    base = Int(pattern(identifier: y, column: x, salt: 33))
                } else if x < fixedSidebarColumns {
                    base = Int(pattern(identifier: y, column: x, salt: 71))
                } else {
                    let documentRow = documentStart + y - fixedHeaderRows
                    base = Int(pattern(identifier: documentRow, column: x, salt: 113))
                }
                if let dynamicRect,
                   dynamicRect.x.contains(x),
                   dynamicRect.y.contains(y) {
                    return UInt8(truncatingIfNeeded: base &+ 91)
                }
                return UInt8(truncatingIfNeeded: base)
            }
        }
        return ScrollingScreenshotSyntheticFrame(id: id, rows: rows)
    }

    private static func pattern(identifier: Int, column: Int, salt: UInt64) -> UInt8 {
        var value = UInt64(truncatingIfNeeded: identifier) &* 0x9E37_79B9_7F4A_7C15
        value ^= UInt64(column) &* 0xBF58_476D_1CE4_E5B9
        value ^= salt &* 0x94D0_49BB_1331_11EB
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return UInt8(truncatingIfNeeded: value ^ (value >> 31))
    }

    static var exactMatcher: ScrollingScreenshotMatcher {
        ScrollingScreenshotMatcher(configuration: .init(
            minimumOverlapRows: 3,
            minimumFixedHeaderRows: 2,
            maximumFixedHeaderRows: 3,
            minimumFixedFooterRows: 2,
            maximumFixedFooterRows: 3,
            coarseCandidateCount: 16,
            horizontalSearchRadius: 0,
            minimumBlockSimilarity: 0.99,
            minimumMatchScore: 0.95,
            minimumMatchedBlockRatio: 0.75,
            ambiguityScoreTolerance: 0
        ))
    }

    static var exactAssembler: ScrollingScreenshotAssembler {
        ScrollingScreenshotAssembler(matcher: exactMatcher)
    }
}
