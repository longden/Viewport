import XCTest
@testable import Viewport

final class CaptureDescriptorTests: XCTestCase {
    func testMatchesAndroidEmulatorProcess() {
        let descriptor = CaptureDescriptor(
            applicationName: "qemu-system-aarch64",
            bundleIdentifier: "",
            windowTitle: "Pixel 9 API 36"
        )

        XCTAssertTrue(descriptor.matches(.android))
        XCTAssertFalse(descriptor.matches(.iOS))
    }

    func testMatchesAppleSimulatorBundle() {
        let descriptor = CaptureDescriptor(
            applicationName: "Simulator",
            bundleIdentifier: "com.apple.iphonesimulator",
            windowTitle: "iPhone 17 Pro"
        )

        XCTAssertTrue(descriptor.matches(.iOS))
        XCTAssertFalse(descriptor.matches(.android))
    }

    func testDoesNotTreatOrdinaryWindowsAsDevices() {
        let descriptor = CaptureDescriptor(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Example Domain"
        )

        XCTAssertFalse(descriptor.matches(.android))
        XCTAssertFalse(descriptor.matches(.iOS))
    }
}
