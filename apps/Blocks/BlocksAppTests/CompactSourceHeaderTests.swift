import AppKit
import XCTest
@testable import Blocks
@testable import BlocksCore

final class CompactSourceHeaderTests: XCTestCase {
    func testSourceHeadersUseTextHeightWhileControlsOverlay() {
        let expected = NSLayoutManager().defaultLineHeight(
            for: NSFont.preferredFont(forTextStyle: .subheadline)
        )

        for source in TranslationInputSource.allCases {
            XCTAssertEqual(
                TranslationPanelSourceLayout.sourceHeaderHeight(
                    for: source
                ),
                expected
            )
        }
        XCTAssertLessThan(
            expected,
            TranslationPanelMetrics.compactIconHitTarget
        )
    }

    func testSourceSectionGeometryKeepsCompactActionHeightAcrossSources() {
        let textHeaderHeight =
            TranslationPanelSourceLayout.sourceTextHeaderHeight
        let sourceEditorHeight =
            TranslationPanelSourceLayout.expandedEditorHeight(for: .manual)

        XCTAssertEqual(
            TranslationPanelSourceLayout.sourceSectionHeight(
                for: .manual,
                scrollOffset: 0
            ),
            textHeaderHeight
                + TranslationPanelSourceLayout.sourceEditorSpacing
                + sourceEditorHeight
        )
        XCTAssertEqual(
            TranslationPanelSourceLayout.sourceHeaderHeight(
                for: .screenshotOCR
            ),
            textHeaderHeight
        )
        XCTAssertEqual(
            TranslationPanelSourceLayout.sourceEditorSpacing,
            BlocksVisualTokens.Spacing.xs
        )
    }
}
