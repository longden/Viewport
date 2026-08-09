import CoreGraphics
import XCTest
@testable import Viewport

final class DeviceBezelRendererTests: XCTestCase {
    func testDrawExpandsCanvasAroundSourceImage() throws {
        let source = try XCTUnwrap(makeImage(width: 100, height: 200))
        let framed = try XCTUnwrap(DeviceBezelRenderer.draw(image: source))
        XCTAssertGreaterThan(framed.width, source.width)
        XCTAssertGreaterThan(framed.height, source.height)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
