import CoreGraphics
import Foundation
import XCTest
@testable import Viewport

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

    func testAgesToZeroWhenIdle() {
        let meter = FrameRateMeter(windowSeconds: 0.5)
        let start: CFAbsoluteTime = 200
        meter.record(at: start)
        meter.record(at: start + 0.1)
        XCTAssertGreaterThan(meter.framesPerSecond, 0)
        let aged = meter.age(at: start + 1.0)
        XCTAssertEqual(aged, 0, accuracy: 0.01)
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
                    kind: .redact,
                    start: CGPoint(x: 0.5, y: 0.5),
                    end: CGPoint(x: 0.8, y: 0.9)
                )
            ]
        )
        XCTAssertEqual(annotated.width, 100)
        XCTAssertEqual(annotated.height, 100)

        // Redact region should be pixelated and opaque.
        let redacted = try XCTUnwrap(samplePixel(annotated, x: 65, y: 30))
        XCTAssertGreaterThan(redacted.a, 0.9)
    }

    func testRedactTitleIsHonest() {
        XCTAssertEqual(ScreenshotAnnotationKind.redact.title, "Redact")
    }

    func testStyleScaleMapsPreviewPointsOntoImagePixels() {
        let scale = ScreenshotAnnotationRenderer.styleScale(
            imageWidth: 2000,
            imageHeight: 1000,
            previewSize: CGSize(width: 800, height: 400)
        )
        XCTAssertEqual(scale, 2.5, accuracy: 0.001)
        XCTAssertEqual(
            ScreenshotAnnotationRenderer.styleScale(
                imageWidth: 100,
                imageHeight: 100,
                previewSize: .zero
            ),
            1
        )
    }

    func testArrowHeadScalesWithStyleScale() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let unscaled = ScreenshotAnnotationRenderer.arrowGeometry(
            from: start,
            to: end,
            scale: 1
        )
        let scaled = ScreenshotAnnotationRenderer.arrowGeometry(
            from: start,
            to: end,
            scale: 2
        )
        let unscaledHead = hypot(end.x - unscaled.left.x, end.y - unscaled.left.y)
        let scaledHead = hypot(end.x - scaled.left.x, end.y - scaled.left.y)
        XCTAssertEqual(scaledHead, unscaledHead * 2, accuracy: 0.01)
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

    private func samplePixel(
        _ image: CGImage,
        x: Int,
        y: Int
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        return (
            r: CGFloat(data[0]) / 255,
            g: CGFloat(data[1]) / 255,
            b: CGFloat(data[2]) / 255,
            a: CGFloat(data[3]) / 255
        )
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

    func testCanAddSecondDevicePaneUntilCap() {
        var layout = PaneGridLayout.defaultTriple
        XCTAssertTrue(layout.canAddPane(source: .android))
        XCTAssertNotNil(layout.addPane(source: .android))
        XCTAssertEqual(layout.count(of: .android), 2)
        XCTAssertFalse(layout.canAddPane(source: .android))
        // At 4 panes (web+2 android+ios), cannot add iOS 2.
        XCTAssertEqual(layout.nodes.count, 4)
        XCTAssertFalse(layout.canAddPane(source: .iOS))
    }

    func testRemoveExtraPaneDropsSecondarySlot() {
        var layout = PaneGridLayout.defaultTriple
        _ = layout.addPane(source: .iOS)
        XCTAssertTrue(layout.removeExtraPane(of: .iOS))
        XCTAssertEqual(layout.count(of: .iOS), 1)
        XCTAssertEqual(layout.nodes.first { $0.source == ViewerSource.iOS.rawValue }?.slot, 0)
    }

    func testRemoveExtraPaneDoesNotRemovePrimary() {
        var layout = PaneGridLayout.defaultTriple
        XCTAssertEqual(layout.count(of: .android), 1)
        XCTAssertFalse(layout.removeExtraPane(of: .android))
        XCTAssertEqual(layout.count(of: .android), 1)
    }
}

@MainActor
final class ExperimentalSettingsCouplingTests: XCTestCase {
    func testLaunchWithExperimentalOffClearsPersistedSyncScrollOnly() {
        let suiteName = "ViewportTests.Experimental.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: "experimentalFeaturesEnabled")
        defaults.set(true, forKey: "inputMirroringEnabled")
        defaults.set(true, forKey: "synchronizedScrollingEnabled")

        let store = WorkspaceStore(defaults: defaults)
        XCTAssertFalse(store.experimentalFeaturesEnabled)
        XCTAssertTrue(store.inputMirroringEnabled)
        XCTAssertFalse(store.synchronizedScrollingEnabled)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisablingExperimentalKeepsInputMirroring() {
        let suiteName = "ViewportTests.Experimental.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "experimentalFeaturesEnabled")
        defaults.set(true, forKey: "inputMirroringEnabled")

        let store = WorkspaceStore(defaults: defaults)
        store.setExperimentalFeaturesEnabled(false)

        XCTAssertFalse(store.experimentalFeaturesEnabled)
        XCTAssertTrue(store.inputMirroringEnabled)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
