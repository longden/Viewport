import XCTest
@testable import Viewport

final class PaneToolbarScrollFadeTests: XCTestCase {
    func testNoFadeWhenButtonsFit() {
        let overflow = PaneToolbarScrollOverflow(
            visibleMinX: 0,
            visibleMaxX: 240,
            contentWidth: 180
        )
        XCTAssertFalse(overflow.showsLeadingFade)
        XCTAssertFalse(overflow.showsTrailingFade)
    }

    func testTrailingFadeWhenButtonsAreClippedAtRest() {
        let overflow = PaneToolbarScrollOverflow(
            visibleMinX: 0,
            visibleMaxX: 160,
            contentWidth: 280
        )
        XCTAssertFalse(overflow.showsLeadingFade)
        XCTAssertTrue(overflow.showsTrailingFade)
    }

    func testBothFadesWhileScrolledBetweenEdges() {
        let overflow = PaneToolbarScrollOverflow(
            visibleMinX: 40,
            visibleMaxX: 200,
            contentWidth: 280
        )
        XCTAssertTrue(overflow.showsLeadingFade)
        XCTAssertTrue(overflow.showsTrailingFade)
    }

    func testLeadingFadeWhenScrolledToTheEnd() {
        let overflow = PaneToolbarScrollOverflow(
            visibleMinX: 120,
            visibleMaxX: 280,
            contentWidth: 280
        )
        XCTAssertTrue(overflow.showsLeadingFade)
        XCTAssertFalse(overflow.showsTrailingFade)
    }

    func testSubpixelSlopDoesNotFlicker() {
        let overflow = PaneToolbarScrollOverflow(
            visibleMinX: 0.4,
            visibleMaxX: 159.4,
            contentWidth: 160
        )
        XCTAssertFalse(overflow.showsLeadingFade)
        XCTAssertFalse(overflow.showsTrailingFade)
    }
}
