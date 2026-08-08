import CoreGraphics
import CoreVideo
import ScreenCaptureKit
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
        XCTAssertEqual(layout.labels.count, 3)
        XCTAssertEqual(layout.images.map(\.height), [1_000, 1_000, 1_000])
        XCTAssertEqual(layout.images.map(\.minY), [0, 0, 0])
        XCTAssertEqual(layout.images[1].minX, layout.images[0].maxX + 10)
        XCTAssertEqual(layout.images[2].minX, layout.images[1].maxX + 10)
        XCTAssertEqual(layout.canvas.width, layout.images[2].maxX)
        XCTAssertEqual(layout.canvas.height, 1_000)
    }

    func testCompositeLayoutReservesLabelBandWhenEnabled() throws {
        let layout = try XCTUnwrap(
            CompositeScreenshotLayout.frames(
                for: [CGSize(width: 400, height: 800)],
                maximumHeight: 800,
                includeLabels: true
            )
        )

        XCTAssertEqual(
            layout.canvas.height,
            CompositeScreenshotLayout.labelBandHeight
                + CompositeScreenshotLayout.labelToImageSpacing
                + 800
        )
        XCTAssertEqual(layout.labels[0].minY, 0)
        XCTAssertEqual(
            layout.labels[0].height,
            CompositeScreenshotLayout.labelBandHeight
        )
        XCTAssertEqual(
            layout.images[0].minY,
            CompositeScreenshotLayout.labelBandHeight
                + CompositeScreenshotLayout.labelToImageSpacing
        )
    }

    func testCompositeLayoutRejectsInvalidInput() {
        XCTAssertNil(CompositeScreenshotLayout.frames(for: []))
        XCTAssertNil(
            CompositeScreenshotLayout.frames(
                for: [CGSize(width: 100, height: 0)]
            )
        )
    }

    func testFormatsPlatformLabels() {
        XCTAssertEqual(ScreenshotPlatformLabel.title(for: .web), "Web")
        XCTAssertEqual(ScreenshotPlatformLabel.title(for: .android), "Android")
        XCTAssertEqual(ScreenshotPlatformLabel.title(for: .iOS), "iOS")
    }

    func testPaneFilenameIncludesSource() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = WorkspaceScreenshotNaming.filename(
            source: .android,
            date: date
        )
        XCTAssertTrue(name.hasPrefix("Viewport-Android-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertTrue(name.contains(" at "))
    }

    func testCombinedFilenameOmitsSource() {
        let name = WorkspaceScreenshotNaming.filename()
        XCTAssertTrue(name.hasPrefix("Viewport "))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    func testRecordingFilenameUsesMp4Extension() {
        let name = WorkspaceScreenshotNaming.filename(fileExtension: "mp4")
        XCTAssertTrue(name.hasSuffix(".mp4"))
    }

    func testComposeIntoFixedCanvasScalesContent() async throws {
        let image = try XCTUnwrap(makeTestImage(width: 100, height: 200))
        let panes = [
            ScreenshotPaneCapture(source: .web, image: image, label: "Web"),
            ScreenshotPaneCapture(source: .android, image: image, label: "Android")
        ]
        let composed = try await MainActor.run {
            try WorkspaceScreenshotService().compose(
                panes,
                into: CGSize(width: 640, height: 360)
            )
        }
        XCTAssertEqual(composed.width, 640)
        XCTAssertEqual(composed.height, 360)
    }

    func testRecordingDefaults() async {
        let maxDuration = await MainActor.run {
            WorkspaceRecordingService.maxDuration
        }
        XCTAssertEqual(maxDuration, 5 * 60)
    }

    func testRecordingQualityPresets() {
        // High must match the original recorder: 60 fps, BGRA, 1080p,
        // bitrate max(5_000_000, w * h * 6).
        XCTAssertEqual(RecordingQuality.high.frameRate, 60)
        XCTAssertEqual(RecordingQuality.high.maximumOutputHeight, 1_080)
        XCTAssertEqual(
            RecordingQuality.high.pixelFormat,
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            RecordingQuality.high.bitRate(width: 1_920, height: 1_080),
            1_920 * 1_080 * 6
        )
        XCTAssertEqual(
            RecordingQuality.high.bitRate(width: 640, height: 360),
            5_000_000
        )
        XCTAssertEqual(RecordingQuality.high.captureResolution, .best)
        XCTAssertTrue(RecordingQuality.high.usesWindowCapture)

        XCTAssertEqual(RecordingQuality.smooth.frameRate, 30)
        XCTAssertEqual(RecordingQuality.smooth.maximumOutputHeight, 720)
        XCTAssertEqual(
            RecordingQuality.smooth.pixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            RecordingQuality.smooth.bitRate(width: 1_280, height: 720),
            1_280 * 720 * 2
        )
        XCTAssertEqual(RecordingQuality.smooth.captureResolution, .nominal)
        XCTAssertTrue(RecordingQuality.smooth.usesWindowCapture)

        XCTAssertEqual(RecordingQuality.composite.frameRate, 60)
        XCTAssertEqual(RecordingQuality.composite.maximumOutputHeight, 1_080)
        XCTAssertEqual(
            RecordingQuality.composite.pixelFormat,
            kCVPixelFormatType_32BGRA
        )
        XCTAssertFalse(RecordingQuality.composite.usesWindowCapture)
        XCTAssertEqual(
            RecordingQuality.composite.bitRate(width: 1_920, height: 1_080),
            RecordingQuality.high.bitRate(width: 1_920, height: 1_080)
        )

        XCTAssertNotEqual(
            RecordingQuality.high.pixelFormat,
            RecordingQuality.smooth.pixelFormat
        )
        XCTAssertNotEqual(
            RecordingQuality.high.frameRate,
            RecordingQuality.smooth.frameRate
        )
        XCTAssertNotEqual(
            RecordingQuality.high.maximumOutputHeight,
            RecordingQuality.smooth.maximumOutputHeight
        )
    }

    func testCompositeRecordingLayoutUsesEvenDimensions() throws {
        let canvas = try XCTUnwrap(
            CompositeRecordingLayout.outputCanvas(
                sourceSizes: [
                    CGSize(width: 390, height: 844),
                    CGSize(width: 1080, height: 2400)
                ],
                maximumHeight: 1_080
            )
        )
        XCTAssertEqual(Int(canvas.width) % 2, 0)
        XCTAssertEqual(Int(canvas.height) % 2, 0)
        XCTAssertLessThanOrEqual(canvas.height, 1_080)
    }

    func testRecordingCropUsesTopLeftWindowCoordinates() throws {
        let rect = try XCTUnwrap(
            WorkspaceRecordingGeometry.sourceRect(
                windowSize: CGSize(width: 1_200, height: 800),
                contentLayoutRect: CGRect(
                    x: 0,
                    y: 20,
                    width: 1_200,
                    height: 720
                )
            )
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 60, width: 1_200, height: 720))
    }

    func testRecordingAnchorCropConvertsFromScreenCoordinates() throws {
        let rect = try XCTUnwrap(
            WorkspaceRecordingGeometry.sourceRect(
                windowFrame: CGRect(x: 100, y: 200, width: 1_200, height: 800),
                captureRect: CGRect(x: 116, y: 216, width: 1_168, height: 700)
            )
        )
        XCTAssertEqual(rect, CGRect(x: 16, y: 84, width: 1_168, height: 700))
    }

    func testRecordingOutputIsEvenAndHeightLimited() {
        let size = WorkspaceRecordingGeometry.outputSize(
            sourceSize: CGSize(width: 1_200, height: 800),
            backingScale: 2,
            maximumHeight: 1_080
        )
        XCTAssertEqual(size, CGSize(width: 1_620, height: 1_080))
    }

    private func makeTestImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}
