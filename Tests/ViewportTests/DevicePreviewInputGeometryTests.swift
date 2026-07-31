import CoreGraphics
import XCTest
@testable import Viewport

final class DevicePreviewInputGeometryTests: XCTestCase {
    func testMapsThroughAspectFitAndFlipsAppKitY() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let source = CGSize(width: 100, height: 200)

        let topLeft = DevicePreviewInputGeometry.normalizedPoint(
            CGPoint(x: 100, y: 400),
            in: bounds,
            sourceSize: source
        )
        let bottomRight = DevicePreviewInputGeometry.normalizedPoint(
            CGPoint(x: 300, y: 0),
            in: bounds,
            sourceSize: source
        )

        let unwrappedTopLeft = try XCTUnwrap(topLeft)
        let unwrappedBottomRight = try XCTUnwrap(bottomRight)
        XCTAssertEqual(unwrappedTopLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(unwrappedTopLeft.y, 0, accuracy: 0.001)
        XCTAssertEqual(unwrappedBottomRight.x, 1, accuracy: 0.001)
        XCTAssertEqual(unwrappedBottomRight.y, 1, accuracy: 0.001)
    }

    func testRejectsClicksInAspectFitMargins() {
        let point = DevicePreviewInputGeometry.normalizedPoint(
            CGPoint(x: 20, y: 200),
            in: CGRect(x: 0, y: 0, width: 400, height: 400),
            sourceSize: CGSize(width: 100, height: 200)
        )

        XCTAssertNil(point)
    }

    func testClampsDragAtDisplayedFrameEdge() throws {
        let point = DevicePreviewInputGeometry.normalizedPoint(
            CGPoint(x: 450, y: -50),
            in: CGRect(x: 0, y: 0, width: 400, height: 400),
            sourceSize: CGSize(width: 100, height: 200),
            clampsToDisplayedFrame: true
        )

        let unwrappedPoint = try XCTUnwrap(point)
        XCTAssertEqual(unwrappedPoint.x, 1, accuracy: 0.001)
        XCTAssertEqual(unwrappedPoint.y, 1, accuracy: 0.001)
    }
}
