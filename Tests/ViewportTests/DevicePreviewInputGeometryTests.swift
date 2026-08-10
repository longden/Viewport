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

    func testCenterCropMatchesDeviceAspectInsideHostWindow() throws {
        let crop = try XCTUnwrap(
            DevicePreviewInputGeometry.centerCroppedRect(
                of: CGSize(width: 1_200, height: 800),
                matching: CGSize(width: 1_080, height: 1_920)
            )
        )

        XCTAssertEqual(crop.width, 450, accuracy: 0.001)
        XCTAssertEqual(crop.height, 800, accuracy: 0.001)
        XCTAssertEqual(crop.origin.x, 375, accuracy: 0.001)
        XCTAssertEqual(crop.origin.y, 0, accuracy: 0.001)
    }

    func testHostWindowContentRectDropsTitleBar() throws {
        let rect = try XCTUnwrap(
            DevicePreviewInputGeometry.hostWindowContentRect(
                windowSize: CGSize(width: 400, height: 852),
                deviceAspect: CGSize(width: 390, height: 844),
                chromeInsets: DevicePreviewInputGeometry.hostWindowChromeInsets(
                    for: .iOS
                )
            )
        )

        XCTAssertGreaterThanOrEqual(rect.minY, 52)
        XCTAssertEqual(
            rect.width / rect.height,
            390.0 / 844.0,
            accuracy: 0.02
        )
    }

    func testHostWindowContentRectWithoutAspectStillInsetsChrome() throws {
        let rect = try XCTUnwrap(
            DevicePreviewInputGeometry.hostWindowContentRect(
                windowSize: CGSize(width: 500, height: 900),
                deviceAspect: nil,
                chromeInsets: DevicePreviewInputGeometry.hostWindowChromeInsets(
                    for: .android
                )
            )
        )

        XCTAssertEqual(rect.minY, 56, accuracy: 0.001)
        XCTAssertEqual(rect.height, 844, accuracy: 0.001)
        XCTAssertEqual(rect.width, 500, accuracy: 0.001)
    }
}

final class HostWindowDeviceTitleMatchingTests: XCTestCase {
    func testExactAndSeparatorPrefixMatch() {
        XCTAssertTrue(
            HostWindowDeviceTitleMatching.matches(
                title: "iPhone 16",
                deviceName: "iPhone 16"
            )
        )
        XCTAssertTrue(
            HostWindowDeviceTitleMatching.matches(
                title: "iPhone 16 — Safari",
                deviceName: "iPhone 16"
            )
        )
        XCTAssertTrue(
            HostWindowDeviceTitleMatching.matches(
                title: "iPhone 16 - Safari",
                deviceName: "iPhone 16"
            )
        )
    }

    func testRejectsLongerDeviceNameSubstring() {
        XCTAssertFalse(
            HostWindowDeviceTitleMatching.matches(
                title: "iPhone 16 Pro — Safari",
                deviceName: "iPhone 16"
            )
        )
        XCTAssertFalse(
            HostWindowDeviceTitleMatching.matches(
                title: "Pixel 7 Pro",
                deviceName: "Pixel 7"
            )
        )
    }
}
