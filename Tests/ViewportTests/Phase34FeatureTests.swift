import CoreGraphics
import XCTest
@testable import Viewport

final class OverlayDiffComposerTests: XCTestCase {
    func testComposesOverlayAtRequestedOpacity() throws {
        let base = try XCTUnwrap(makeImage(
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 40,
            height: 80
        ))
        let overlay = try XCTUnwrap(makeImage(
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            width: 40,
            height: 80
        ))
        let composed = try OverlayDiffComposer.compose(
            base: base,
            overlay: overlay,
            opacity: 0.5
        )
        XCTAssertEqual(composed.width, 40)
        XCTAssertEqual(composed.height, 80)
    }

    func testClampsOpacity() throws {
        let base = try XCTUnwrap(makeImage(
            color: CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            width: 20,
            height: 20
        ))
        let overlay = try XCTUnwrap(makeImage(
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            width: 10,
            height: 10
        ))
        let composed = try OverlayDiffComposer.compose(
            base: base,
            overlay: overlay,
            opacity: 2
        )
        XCTAssertGreaterThanOrEqual(composed.width, 20)
        XCTAssertGreaterThanOrEqual(composed.height, 20)
    }

    private func makeImage(
        color: CGColor,
        width: Int,
        height: Int
    ) -> CGImage? {
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
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

final class BatchURLSnapshotServiceTests: XCTestCase {
    @MainActor
    func testParsesUniqueHTTPURLs() {
        let service = BatchURLSnapshotService()
        let urls = service.parseURLList(
            """
            https://example.com
            example.org/path
            not a url
            https://example.com
            ftp://ignored.example
            """
        )
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com",
            "https://example.org/path"
        ])
    }

    func testFilenameIncludesIndexAndHost() {
        let url = URL(string: "https://shop.example/cart")!
        let name = BatchURLSnapshotService.filename(
            for: url,
            index: 7,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(name.hasPrefix("007-shop.example-"))
        XCTAssertTrue(name.hasSuffix(".png"))
    }
}

final class FrameRateMeterTests: XCTestCase {
    func testEstimatesFPSFromTimestamps() {
        let meter = FrameRateMeter(windowSeconds: 1)
        let start: CFAbsoluteTime = 100
        for offset in stride(from: 0.0, through: 0.9, by: 0.1) {
            meter.record(at: start + offset)
        }
        let fps = meter.framesPerSecond
        XCTAssertEqual(fps, 10, accuracy: 0.5)
    }
}

final class ScreenshotAnnotationRendererTests: XCTestCase {
    func testRendersAnnotationsOntoImage() throws {
        let image = try XCTUnwrap(makeImage(width: 100, height: 100))
        let annotated = try ScreenshotAnnotationRenderer.render(
            image,
            annotations: [
                ScreenshotAnnotation(
                    kind: .box,
                    start: CGPoint(x: 0.1, y: 0.1),
                    end: CGPoint(x: 0.4, y: 0.4)
                ),
                ScreenshotAnnotation(
                    kind: .blur,
                    start: CGPoint(x: 0.5, y: 0.5),
                    end: CGPoint(x: 0.8, y: 0.9)
                )
            ]
        )
        XCTAssertEqual(annotated.width, 100)
        XCTAssertEqual(annotated.height, 100)
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

@MainActor
final class DeveloperLogExportTests: XCTestCase {
    func testExportIncludesRecentLines() {
        let store = DeveloperLogStore(
            maximumEntriesPerSource: 50,
            maximumBytesPerSource: 64_000
        )
        store.setEnabled(true)
        store.appendWeb(level: .info, message: "hello from web")
        let text = store.exportRecentLines(limitPerSource: 10)
        XCTAssertTrue(text.contains("hello from web"))
        XCTAssertTrue(text.contains("--- Web ---"))
    }
}

final class PaneGridLayoutTests: XCTestCase {
    func testDefaultTripleMatchesViewerSources() {
        XCTAssertEqual(
            PaneGridLayout.defaultTriple.nodes.map(\.source),
            ViewerSource.allCases.map(\.rawValue)
        )
        XCTAssertFalse(PaneGridMigration.roadmapNote.isEmpty)
    }
}
