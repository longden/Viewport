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

    func testResourceOverridesAppendCoresAndMemory() {
        let resources = AndroidEmulatorResources(cores: 4, memoryMB: 4_096)
        XCTAssertEqual(
            AndroidEmulatorLaunchArguments.make(
                avdName: "Pixel_8",
                preferHeadless: true,
                runningEmulatorCount: 0,
                resources: resources
            ),
            ["-avd", "Pixel_8", "-no-window", "-grpc", "8554", "-cores", "4", "-memory", "4096"]
        )
        XCTAssertEqual(
            AndroidEmulatorLaunchArguments.make(
                avdName: "Pixel_8",
                preferHeadless: false,
                runningEmulatorCount: 0,
                resources: AndroidEmulatorResources(memoryMB: 2_048)
            ),
            ["-avd", "Pixel_8", "-memory", "2048"]
        )
    }

    func testResourcesRoundTripDefaultsAndTreatZeroAsAVDDefault() throws {
        let suiteName = "AndroidEmulatorResourcesTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AndroidEmulatorResources(defaults: defaults), AndroidEmulatorResources())
        XCTAssertFalse(AndroidEmulatorResources(defaults: defaults).hasOverrides)

        AndroidEmulatorResources(cores: 6, memoryMB: nil).save(to: defaults)
        let restored = AndroidEmulatorResources(defaults: defaults)
        XCTAssertEqual(restored.cores, 6)
        XCTAssertNil(restored.memoryMB)
        XCTAssertEqual(restored.launchArguments, ["-cores", "6"])

        XCTAssertNil(AndroidEmulatorResources(cores: 0, memoryMB: -1).cores)
    }

    func testResourceChoicesRespectHostLimitsAndKeepSavedValue() {
        XCTAssertEqual(AndroidEmulatorResources.coreChoices(hostCores: 18), [2, 4, 6, 8])
        XCTAssertEqual(AndroidEmulatorResources.coreChoices(hostCores: 6), [2, 4])
        XCTAssertEqual(
            AndroidEmulatorResources.coreChoices(hostCores: 6, including: 8),
            [2, 4, 8]
        )
        let eightGB: UInt64 = 8 * 1_024 * 1_024 * 1_024
        XCTAssertEqual(
            AndroidEmulatorResources.memoryChoicesMB(hostMemoryBytes: eightGB),
            [2_048, 4_096]
        )
    }

    @MainActor
    func testWorkspaceStorePersistsEmulatorResources() throws {
        let suiteName = "AndroidEmulatorResourcesStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.androidEmulatorResources, AndroidEmulatorResources())
        store.setAndroidEmulatorResources(AndroidEmulatorResources(cores: 4, memoryMB: 6_144))

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(
            restored.androidEmulatorResources,
            AndroidEmulatorResources(cores: 4, memoryMB: 6_144)
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
