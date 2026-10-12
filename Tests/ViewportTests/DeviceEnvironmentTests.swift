import CoreGraphics
import Foundation
import JavaScriptCore
import XCTest
@testable import Viewport

final class DeviceAccessibilitySettingsTests: XCTestCase {
    func testTextSizeMapsToSimulatorCategories() {
        XCTAssertEqual(DeviceFontScale.defaultScale.iOSContentSize, "large")
        XCTAssertEqual(DeviceFontScale.small.iOSContentSize, "small")
        XCTAssertEqual(DeviceFontScale.extraLarge.iOSContentSize, "extra-extra-large")
    }

    func testContrastValues() {
        XCTAssertEqual(DeviceContrast.increased.iOSValue, "enabled")
        XCTAssertEqual(DeviceContrast.standard.androidValue, "0")
    }
}
