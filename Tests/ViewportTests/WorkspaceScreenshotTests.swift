import XCTest
@testable import Viewport

final class WorkspaceScreenshotTests: XCTestCase {
    func testCompositeLayoutPlacesEveryImageInOneRow() throws {
        let layout = try XCTUnwrap(
            CompositeScreenshotLayout.frames(
                for: [
                    CGSize(width: 400, height: 800),
                    CGSize(width: 600, height: 1_200),
                    CGSize(width: 1_000, height: 1_000)
                ],
                maximumHeight: 1_000,
                spacing: 10
            )
        )

        XCTAssertEqual(layout.images.count, 3)
        XCTAssertEqual(layout.images.map(\.height), [1_000, 1_000, 1_000])
        XCTAssertEqual(layout.images[1].minX, layout.images[0].maxX + 10)
        XCTAssertEqual(layout.images[2].minX, layout.images[1].maxX + 10)
        XCTAssertEqual(layout.canvas.width, layout.images[2].maxX)
        XCTAssertEqual(layout.canvas.height, 1_000)
    }

    func testCompositeLayoutRejectsInvalidInput() {
        XCTAssertNil(CompositeScreenshotLayout.frames(for: []))
        XCTAssertNil(
            CompositeScreenshotLayout.frames(
                for: [CGSize(width: 100, height: 0)]
            )
        )
    }
}
