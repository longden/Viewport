import XCTest
@testable import Viewport

final class DeviceClientParsingTests: XCTestCase {
    func testParsesAndroidAVDListWithoutWarnings() {
        let output = """
        FlowTester_Resizable_2
        Resizable_Experimental
        Error: ignored warning
        """

        XCTAssertEqual(
            AndroidDeviceClient.parseAVDNames(output),
            ["FlowTester_Resizable_2", "Resizable_Experimental"]
        )
    }

    func testRejectsAndroidDiagnosticsAndTableHeaders() {
        let output = """
        WARN | Emulator acceleration is unavailable
        AVD ID  AVD Name  API Level  Status  Serial
        AVD_ID
        FlowTester_Resizable_2
        Resizable-Experimental.api_37
        INFO:
        OK
        """

        XCTAssertEqual(
            AndroidDeviceClient.parseAVDNames(output),
            [
                "FlowTester_Resizable_2",
                "Resizable-Experimental.api_37"
            ]
        )
    }

    func testParsesOnlineADBDevicesIncludingPhysicalPhones() {
        let output = """
        List of devices attached
        emulator-5554 device product:sdk_gphone model:sdk_gphone
        emulator-5556 offline
        ABC123 device product:husky model:Pixel_8_Pro
        LOCKED unauthorized usb:1-2
        """

        XCTAssertEqual(
            AndroidDeviceClient.parseADBSerials(output),
            ["emulator-5554", "ABC123"]
        )

        XCTAssertEqual(
            AndroidDeviceClient.parseADBDevices(output),
            [
                ADBDeviceRecord(
                    serial: "emulator-5554",
                    state: "device",
                    model: "sdk_gphone"
                ),
                ADBDeviceRecord(
                    serial: "emulator-5556",
                    state: "offline",
                    model: nil
                ),
                ADBDeviceRecord(
                    serial: "ABC123",
                    state: "device",
                    model: "Pixel_8_Pro"
                ),
                ADBDeviceRecord(
                    serial: "LOCKED",
                    state: "unauthorized",
                    model: nil
                )
            ]
        )
    }

    func testADBDeviceRecordFormatsPhysicalModelName() {
        let device = ADBDeviceRecord(
            serial: "ABC123",
            state: "device",
            model: "Pixel_8_Pro"
        )

        XCTAssertFalse(device.isEmulator)
        XCTAssertTrue(device.isOnline)
        XCTAssertEqual(device.displayModel, "Pixel 8 Pro")
    }

    func testParsesWMSizePreferringOverride() {
        XCTAssertEqual(
            AndroidDeviceClient.parseWMSize(
                """
                Physical size: 1440x3120
                Override size: 1080x2400
                """
            ),
            CGSize(width: 1_080, height: 2_400)
        )
        XCTAssertEqual(
            AndroidDeviceClient.parseWMSize("Physical size: 1080x2400\n"),
            CGSize(width: 1_080, height: 2_400)
        )
        XCTAssertEqual(
            AndroidDeviceClient.parseWMSize("1080x1920"),
            CGSize(width: 1_080, height: 1_920)
        )
        XCTAssertNil(AndroidDeviceClient.parseWMSize("unavailable"))
    }

    func testParsesAVDNameBeforeOKMarker() {
        XCTAssertEqual(
            AndroidDeviceClient.parseAVDNameResponse(
                "FlowTester_Resizable_2\nOK\n"
            ),
            "FlowTester_Resizable_2"
        )
    }

    func testAVDNameResponseSkipsDiagnostics() {
        XCTAssertEqual(
            AndroidDeviceClient.parseAVDNameResponse(
                "WARN | transient adb message\nResizable_Experimental\nOK\n"
            ),
            "Resizable_Experimental"
        )
    }

    func testParsesCreateProfilesAndPrefersMediumPhone() {
        let profiles = AndroidDeviceClient.parseCreateProfiles(
            """
            large_desktop
            medium_phone
            small_phone
            WARN | ignore me
            """
        )

        XCTAssertEqual(
            profiles.map(\.id),
            ["medium_phone", "large_desktop", "small_phone"]
        )
        XCTAssertTrue(profiles[0].isRecommended)
        XCTAssertEqual(profiles[0].displayName, "Medium Phone")
    }

    func testParsesAvailableIOSDevicesAndSortsBootedFirst() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              {
                "udid": "SHUTDOWN",
                "name": "iPhone 17 Pro",
                "state": "Shutdown",
                "isAvailable": true
              },
              {
                "udid": "BOOTED",
                "name": "iPhone 17",
                "state": "Booted",
                "isAvailable": true
              },
              {
                "udid": "UNAVAILABLE",
                "name": "iPhone 16",
                "state": "Shutdown",
                "isAvailable": false
              }
            ]
          }
        }
        """

        let devices = try IOSSimulatorClient.parseDevices(Data(json.utf8))

        XCTAssertEqual(devices.map(\.id), ["BOOTED", "SHUTDOWN"])
        XCTAssertEqual(devices.first?.runtime, "iOS 26.5")
        XCTAssertEqual(devices.first?.state, .booted)
    }

    func testLightSimCompanionRowsSitAlongsideStockSimulators() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              {
                "udid": "BOOTED",
                "name": "iPhone 17",
                "state": "Booted",
                "isAvailable": true
              }
            ]
          }
        }
        """

        let stock = try IOSSimulatorClient.parseDevices(Data(json.utf8))
        let devices = IOSSimulatorClient.withLightSimCompanionRows(stock)

        XCTAssertEqual(
            devices.map(\.id),
            ["BOOTED", "lightsim:BOOTED"]
        )
        XCTAssertEqual(devices[0].guestID, "BOOTED")
        XCTAssertEqual(devices[1].guestID, "BOOTED")
        XCTAssertFalse(devices[0].isLightSim)
        XCTAssertTrue(devices[1].isLightSim)
        XCTAssertEqual(devices[1].name, "Light Sim — iPhone 17")
        XCTAssertTrue(
            devices[1].matchesSessionGuest(
                StreamedDevice(
                    id: "BOOTED",
                    name: "iPhone 17",
                    source: .iOS,
                    pixelSize: nil,
                    kind: .iOSSimulator
                )
            )
        )
    }

    func testSimSlimOnArgumentsKeepWebAndSkipRebootWhenAlreadyBooted() {
        XCTAssertEqual(
            SimSlimClient.onArguments(udid: "UDID-1", noReboot: false),
            ["on", "UDID-1", "--except", "web"]
        )
        XCTAssertEqual(
            SimSlimClient.onArguments(udid: "UDID-1", noReboot: true),
            ["on", "UDID-1", "--no-reboot", "--except", "web"]
        )
        XCTAssertEqual(
            SimSlimClient.offArguments(udid: "UDID-1"),
            ["off", "UDID-1"]
        )
        XCTAssertEqual(
            SimSlimClient.statusArguments(udid: "UDID-1"),
            ["status", "UDID-1", "--json"]
        )
    }

    func testLightSimUsesLiveSlimmingForOlderOrUnknownRuntimes() {
        XCTAssertTrue(
            SimSlimClient.shouldUseNoReboot(
                isBooted: false,
                runtime: "iOS 17.5"
            )
        )
        XCTAssertTrue(
            SimSlimClient.shouldUseNoReboot(
                isBooted: false,
                runtime: "iOS 18.3"
            )
        )
        XCTAssertTrue(
            SimSlimClient.shouldUseNoReboot(
                isBooted: false,
                runtime: nil
            )
        )
        XCTAssertTrue(
            SimSlimClient.shouldUseNoReboot(
                isBooted: true,
                runtime: "iOS 26.5"
            )
        )
        XCTAssertFalse(
            SimSlimClient.shouldUseNoReboot(
                isBooted: false,
                runtime: "iOS 18.5"
            )
        )
        XCTAssertFalse(
            SimSlimClient.shouldUseNoReboot(
                isBooted: false,
                runtime: "iOS 26"
            )
        )
    }

    func testLightSimAvailabilityUpdatesAfterCLIInstall() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let toolchains = ToolchainLocator(environment: ["PATH": directory.path])
        let client = IOSSimulatorClient(toolchains: toolchains)
        try XCTSkipIf(
            client.isLightSimAvailable,
            "A global simslim installation masks the temporary executable"
        )

        let executable = directory.appendingPathComponent("simslim")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertTrue(client.isLightSimAvailable)
    }

    func testSimSlimStatusJSONTreatsManagedDisabledAsSlim() throws {
        let slim = """
        {"managedDisabled":170,"managedTotal":180,"booted":true,"persistent":true,"verdict":"slim"}
        """
        let stock = """
        {"managedDisabled":0,"managedTotal":180,"booted":true,"persistent":true,"verdict":"stock"}
        """
        XCTAssertTrue(
            try SimSlimClient.isSlimmed(statusJSON: Data(slim.utf8))
        )
        XCTAssertFalse(
            try SimSlimClient.isSlimmed(statusJSON: Data(stock.utf8))
        )
    }

    func testRecognizesAppleIOSCaptureDevice() {
        XCTAssertTrue(
            DeviceFrameClient.isConnectedIOSCaptureDevice(
                name: "Lorem Phone",
                modelID: "iPhone17,1",
                manufacturer: "Apple Inc.",
                isContinuityCamera: false
            )
        )
        XCTAssertTrue(
            DeviceFrameClient.isConnectedIOSCaptureDevice(
                name: "Test Phone",
                modelID: "iPhone17,1",
                manufacturer: "",
                isContinuityCamera: false
            )
        )
    }

    func testRejectsContinuityCameraAndNonAppleCaptureDevices() {
        XCTAssertFalse(
            DeviceFrameClient.isConnectedIOSCaptureDevice(
                name: "Lorem Phone",
                modelID: "iPhone17,1",
                manufacturer: "Apple Inc.",
                isContinuityCamera: true
            )
        )
        XCTAssertFalse(
            DeviceFrameClient.isConnectedIOSCaptureDevice(
                name: "USB Capture Card",
                modelID: "UVC-1",
                manufacturer: "Example",
                isContinuityCamera: false
            )
        )
    }
}

final class AndroidDeviceProbeCacheTests: XCTestCase {
    func testRotatesCachedSizeWhenLiveFrameOrientationFlips() {
        let portrait = CGSize(width: 1080, height: 1920)
        let landscapeLive = CGSize(width: 576, height: 324)
        XCTAssertEqual(
            AndroidDeviceProbeCache.sizeReconcilingOrientation(
                portrait,
                to: landscapeLive
            ),
            CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(
            AndroidDeviceProbeCache.sizeReconcilingOrientation(
                portrait,
                to: CGSize(width: 576, height: 1024)
            ),
            portrait
        )
    }

    func testSizeCacheExpiresAfterInvalidate() {
        let serial = "emulator-probe-\(UUID().uuidString)"
        AndroidDeviceProbeCache.storeSize(
            CGSize(width: 1080, height: 1920),
            for: serial
        )
        XCTAssertEqual(
            AndroidDeviceProbeCache.size(for: serial),
            CGSize(width: 1080, height: 1920)
        )
        AndroidDeviceProbeCache.invalidateSize(for: serial)
        XCTAssertNil(AndroidDeviceProbeCache.size(for: serial))
    }
}
