import XCTest
@testable import Viewport

final class AndroidEmulatorLaunchArgumentsTests: XCTestCase {
    func testHeadlessLaunchArgumentsIncludeNoWindowAndGRPCPort() {
        XCTAssertEqual(
            AndroidEmulatorLaunchArguments.make(
                avdName: "Pixel_8",
                preferHeadless: true,
                runningEmulatorCount: 2
            ),
            ["-avd", "Pixel_8", "-no-window", "-grpc", "8556"]
        )
    }

    func testWindowedLaunchOmitsHeadlessFlags() {
        XCTAssertEqual(
            AndroidEmulatorLaunchArguments.make(
                avdName: "Pixel_8",
                preferHeadless: false,
                runningEmulatorCount: 2
            ),
            ["-avd", "Pixel_8"]
        )
    }

    func testGRPCPortUsesRunningEmulatorCount() {
        XCTAssertEqual(
            AndroidEmulatorLaunchArguments.grpcPort(forRunningEmulatorCount: 0),
            8554
        )
        XCTAssertEqual(
            AndroidEmulatorLaunchArguments.grpcPort(forRunningEmulatorCount: 3),
            8557
        )
    }

    func testConsoleAuthTokenReadsAVDFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let avdDirectory = home.appendingPathComponent(
            ".android/avd/Test_Device.avd",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: avdDirectory,
            withIntermediateDirectories: true
        )
        let tokenURL = avdDirectory.appendingPathComponent(
            "emulator_console_auth_token"
        )
        try "secret-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertEqual(
            AndroidEmulatorLaunchArguments.consoleAuthToken(
                forAVD: "Test_Device",
                homeDirectory: home
            ),
            "secret-token"
        )
    }

    func testConsoleAuthTokenRejectsPathTraversalAVDNames() {
        XCTAssertNil(
            AndroidEmulatorLaunchArguments.consoleAuthToken(
                forAVD: "../escape",
                homeDirectory: FileManager.default.temporaryDirectory
            )
        )
        XCTAssertFalse(AndroidEmulatorLaunchArguments.isSafeAVDName("foo/bar"))
        XCTAssertTrue(AndroidEmulatorLaunchArguments.isSafeAVDName("Pixel_8"))
    }
}
