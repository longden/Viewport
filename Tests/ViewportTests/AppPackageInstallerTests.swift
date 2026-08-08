import Foundation
import XCTest
@testable import Viewport

final class AppPackageInstallerTests: XCTestCase {
    func testClassifiesInstallablePackagesByExtension() {
        XCTAssertEqual(
            AppPackageInstaller.classify(
                URL(fileURLWithPath: "/builds/App-debug.apk")
            ),
            .androidAPK
        )
        XCTAssertEqual(
            AppPackageInstaller.classify(
                URL(fileURLWithPath: "/DerivedData/MyApp.app")
            ),
            .iOSAppBundle
        )
        XCTAssertEqual(
            AppPackageInstaller.classify(
                URL(fileURLWithPath: "/exports/MyApp.ipa")
            ),
            .iOSIPA
        )
        XCTAssertNil(
            AppPackageInstaller.classify(
                URL(fileURLWithPath: "/notes/readme.txt")
            )
        )
        XCTAssertNil(
            AppPackageInstaller.classify(
                URL(fileURLWithPath: "/builds/App.aab")
            )
        )
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(
            AppPackageInstaller.classify(
                URL(fileURLWithPath: "/builds/App.APK")
            ),
            .androidAPK
        )
        XCTAssertEqual(
            AppPackageInstaller.classify(
                URL(fileURLWithPath: "/builds/MyApp.APP")
            ),
            .iOSAppBundle
        )
    }

    func testDeviceKindAcceptsMatchingPackagesOnly() {
        XCTAssertTrue(StreamedDeviceKind.androidDevice.accepts(.androidAPK))
        XCTAssertTrue(StreamedDeviceKind.androidEmulator.accepts(.androidAPK))
        XCTAssertFalse(StreamedDeviceKind.androidDevice.accepts(.iOSAppBundle))

        XCTAssertTrue(StreamedDeviceKind.iOSSimulator.accepts(.iOSAppBundle))
        XCTAssertTrue(StreamedDeviceKind.iOSSimulator.accepts(.iOSIPA))
        XCTAssertFalse(StreamedDeviceKind.iOSSimulator.accepts(.androidAPK))

        XCTAssertTrue(StreamedDeviceKind.iOSDevice.accepts(.iOSAppBundle))
        XCTAssertTrue(StreamedDeviceKind.iOSDevice.accepts(.iOSIPA))
        XCTAssertFalse(StreamedDeviceKind.iOSDevice.accepts(.androidAPK))
    }

    func testCompatiblePackagesFiltersAndPreservesOrder() {
        let urls = [
            URL(fileURLWithPath: "/a/readme.txt"),
            URL(fileURLWithPath: "/a/One.apk"),
            URL(fileURLWithPath: "/a/Two.app"),
            URL(fileURLWithPath: "/a/Three.apk")
        ]

        let android = AppPackageInstaller.compatiblePackages(
            in: urls,
            for: .androidDevice
        )
        XCTAssertEqual(android.map(\.url.lastPathComponent), ["One.apk", "Three.apk"])

        let ios = AppPackageInstaller.compatiblePackages(
            in: urls,
            for: .iOSSimulator
        )
        XCTAssertEqual(ios.map(\.url.lastPathComponent), ["Two.app"])
    }

    func testCleanInstallMessagePrefersLastActionableLine() {
        let message = AppPackageInstaller.cleanInstallMessage(
            stdout: "Performing Streamed Install\nSuccess\n",
            stderr: "",
            fallback: "failed"
        )
        XCTAssertEqual(message, "Success")

        let failure = AppPackageInstaller.cleanInstallMessage(
            stdout: "Performing Streamed Install",
            stderr: "adb: failed to install\nFailure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]",
            fallback: "failed"
        )
        XCTAssertEqual(failure, "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]")

        XCTAssertEqual(
            AppPackageInstaller.cleanInstallMessage(
                stdout: "  ",
                stderr: "",
                fallback: "adb install failed."
            ),
            "adb install failed."
        )
    }
}
