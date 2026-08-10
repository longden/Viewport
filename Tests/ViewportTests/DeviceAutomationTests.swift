import XCTest
@testable import Viewport

final class DeviceAutomationTests: XCTestCase {
    func testNormalizedURLAddsHTTPSForBareHosts() {
        XCTAssertEqual(
            DeviceAutomationService.normalizedURL("example.com/path"),
            "https://example.com/path"
        )
        XCTAssertEqual(
            DeviceAutomationService.normalizedURL("https://example.com"),
            "https://example.com"
        )
        XCTAssertEqual(
            DeviceAutomationService.normalizedURL("myapp://home"),
            "myapp://home"
        )
        XCTAssertNil(DeviceAutomationService.normalizedURL("   "))
    }

    func testInjectionResultSummary() {
        var result = DeviceInjectionResult(
            succeeded: ["Pixel_8"],
            skipped: ["Physical iPhones are view-only."]
        )
        XCTAssertEqual(
            result.summary(verb: "Opened"),
            "Opened on Pixel_8. Physical iPhones are view-only."
        )
        XCTAssertTrue(result.didSucceed)

        result = DeviceInjectionResult()
        XCTAssertEqual(result.summary(verb: "Opened"), "Nothing to do.")
        XCTAssertFalse(result.didSucceed)
    }

    func testDeviceOrientationAndroidRotationValues() {
        XCTAssertEqual(DeviceOrientation.portrait.androidUserRotation, "0")
        XCTAssertEqual(DeviceOrientation.landscape.androidUserRotation, "1")
    }

    func testAppleScriptEscapedQuotes() {
        XCTAssertEqual(
            DeviceAutomationService.appleScriptEscaped(#"iPhone "16" Pro"#),
            #"iPhone \"16\" Pro"#
        )
    }

    func testIOSSystemGestureGeometry() {
        let home = DeviceAutomationService.iosHomeGesture
        XCTAssertEqual(home.from.x, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(home.from.y, 0.95)
        XCTAssertLessThan(home.to.y, home.from.y)
        XCTAssertGreaterThan(home.duration, 0.2)

        let back = DeviceAutomationService.iosBackGesture
        XCTAssertLessThan(back.from.x, 0.05)
        XCTAssertGreaterThan(back.to.x, 0.5)
        XCTAssertEqual(back.from.y, back.to.y, accuracy: 0.0001)
        XCTAssertGreaterThan(back.duration, 0.2)
    }

    @MainActor
    func testIOSSimulatorHIDReportsUnavailableWithoutBootedDevice() async {
        let input = IOSSimulatorHIDInput()
        // Frameworks should load on a Mac with Xcode; without a matching
        // booted UDID the home button press must fail cleanly.
        XCTAssertTrue(input.isAvailable)
        let succeeded = await input.pressHomeButton(
            udid: "00000000-0000-0000-0000-000000000000"
        )
        XCTAssertFalse(succeeded)
        XCTAssertNotNil(input.lastErrorMessage)
        XCTAssertFalse(input.lastErrorMessage?.isEmpty ?? true)
    }
}
