import XCTest
@testable import Viewport

final class WebViewportPresetTests: XCTestCase {
    func testDistinctPhoneSizes() {
        XCTAssertEqual(
            WebViewportPreset.iPhoneSE.size,
            CGSize(width: 375, height: 667)
        )
        XCTAssertEqual(
            WebViewportPreset.iPhone16.size,
            CGSize(width: 393, height: 852)
        )
        XCTAssertEqual(
            WebViewportPreset.iPhone17.size,
            CGSize(width: 402, height: 874)
        )
        XCTAssertEqual(
            WebViewportPreset.iPhoneAir.size,
            CGSize(width: 420, height: 912)
        )
        XCTAssertEqual(
            WebViewportPreset.iPhone16Plus.size,
            CGSize(width: 430, height: 932)
        )
        XCTAssertEqual(
            WebViewportPreset.iPhone17ProMax.size,
            CGSize(width: 440, height: 956)
        )
    }

    func testTabletAndDesktopSizes() {
        XCTAssertEqual(
            WebViewportPreset.iPadMini.size,
            CGSize(width: 744, height: 1_133)
        )
        XCTAssertEqual(
            WebViewportPreset.iPad.size,
            CGSize(width: 820, height: 1_180)
        )
        XCTAssertEqual(
            WebViewportPreset.iPadPro11.size,
            CGSize(width: 834, height: 1_194)
        )
        XCTAssertEqual(
            WebViewportPreset.iPadPro13.size,
            CGSize(width: 1_024, height: 1_366)
        )
        XCTAssertEqual(
            WebViewportPreset.laptop.size,
            CGSize(width: 1_280, height: 800)
        )
        XCTAssertEqual(
            WebViewportPreset.desktop.size,
            CGSize(width: 1_440, height: 900)
        )
        XCTAssertEqual(
            WebViewportPreset.desktopFullHD.size,
            CGSize(width: 1_920, height: 1_080)
        )
        XCTAssertNil(WebViewportPreset.fillPane.size)
    }

    func testIPhone17AndProShareOnePreset() {
        XCTAssertEqual(WebViewportPreset.iPhone17.title, "iPhone 17 / Pro")
        XCTAssertNil(WebViewportPreset(rawValue: "iPhone17Pro"))
        XCTAssertEqual(
            WebViewportPreset.resolved(rawValue: "iPhone17Pro"),
            .iPhone17
        )
    }

    func testAllFixedPresetsHaveUniqueSizes() {
        var seen = Set<String>()
        for preset in WebViewportPreset.allCases {
            guard let size = preset.size else { continue }
            let key = "\(Int(size.width))x\(Int(size.height))"
            XCTAssertFalse(
                seen.contains(key),
                "Duplicate CSS size \(key) for \(preset.title)"
            )
            seen.insert(key)
        }
    }

    func testScaleNeverExceedsOne() {
        let available = CGSize(width: 2_000, height: 2_000)
        XCTAssertEqual(
            WebViewportPreset.iPhone17.scaleFitting(in: available),
            1,
            accuracy: 0.0001
        )
    }

    func testScaleShrinksToFitSmallerPane() {
        let available = CGSize(width: 201, height: 437)
        XCTAssertEqual(
            WebViewportPreset.iPhone17.scaleFitting(in: available),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WebViewportPreset.iPhone17.fittedLayoutSize(in: available),
            CGSize(width: 201, height: 437)
        )
    }

    func testMobilePresetsPreferMobileContentAndUA() {
        XCTAssertTrue(WebViewportPreset.iPhone17.prefersMobileContent)
        XCTAssertTrue(WebViewportPreset.iPad.prefersMobileContent)
        XCTAssertFalse(WebViewportPreset.desktop.prefersMobileContent)
        XCTAssertFalse(WebViewportPreset.laptop.prefersMobileContent)
        XCTAssertFalse(WebViewportPreset.fillPane.prefersMobileContent)
        XCTAssertNotNil(WebViewportPreset.iPhone17.customUserAgent)
        XCTAssertNotNil(WebViewportPreset.iPad.customUserAgent)
        XCTAssertNil(WebViewportPreset.desktop.customUserAgent)
        XCTAssertNil(WebViewportPreset.fillPane.customUserAgent)
    }
}

@MainActor
final class WebViewModelViewportTests: XCTestCase {
    func testPersistsViewportPresetSelection() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let key = "webViewportPreset"
        let model = WebViewModel(defaults: defaults, viewportPresetKey: key)

        XCTAssertEqual(model.viewportPreset, .fillPane)

        model.setViewportPreset(.iPhone17ProMax)
        XCTAssertEqual(model.viewportPreset, .iPhone17ProMax)
        XCTAssertEqual(defaults.string(forKey: key), "iPhone17ProMax")
        XCTAssertNotNil(model.webView.customUserAgent)

        let restored = WebViewModel(defaults: defaults, viewportPresetKey: key)
        XCTAssertEqual(restored.viewportPreset, .iPhone17ProMax)
    }

    func testMigratesLegacyIPhone17ProPreset() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let key = "webViewportPreset"
        defaults.set("iPhone17Pro", forKey: key)

        let model = WebViewModel(defaults: defaults, viewportPresetKey: key)
        XCTAssertEqual(model.viewportPreset, .iPhone17)
    }
}
