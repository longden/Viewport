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
