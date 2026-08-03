import XCTest
@testable import Viewport

final class AndroidEmulatorGrpcStreamTests: XCTestCase {
    func testMapsEmulatorSerialToGrpcPort() {
        XCTAssertEqual(AndroidEmulatorGrpcStream.grpcPort(for: "emulator-5554"), 8554)
        XCTAssertEqual(AndroidEmulatorGrpcStream.grpcPort(for: "emulator-5556"), 8555)
        XCTAssertEqual(AndroidEmulatorGrpcStream.grpcPort(for: "emulator-5558"), 8556)
    }

    func testWindowUpdateFrameEncodesIncrement() {
        // Keep a lightweight encoding check so flow-control frames don't regress.
        let frame = Data([
            0x00, 0x00, 0x04, // length
            0x08,             // WINDOW_UPDATE
            0x00,             // flags
            0x00, 0x00, 0x00, 0x00, // stream 0
            0x00, 0x00, 0x01, 0x00  // increment 256
        ])
        XCTAssertEqual(frame.count, 13)
        XCTAssertEqual(frame[3], 0x08)
        let increment = UInt32(frame[9]) << 24
            | UInt32(frame[10]) << 16
            | UInt32(frame[11]) << 8
            | UInt32(frame[12])
        XCTAssertEqual(increment, 256)
    }

    func testRejectsPhysicalAndMalformedSerials() {
        XCTAssertNil(AndroidEmulatorGrpcStream.grpcPort(for: "RF8M123ABCD"))
        XCTAssertNil(AndroidEmulatorGrpcStream.grpcPort(for: "emulator"))
        XCTAssertNil(AndroidEmulatorGrpcStream.grpcPort(for: "emulator-abcd"))
        XCTAssertNil(AndroidEmulatorGrpcStream.grpcPort(for: "emulator-5553"))
    }

    func testParsesDiscoveryINIForGrpcTokenAndPort() {
        let values = EmulatorGrpcDiscovery.parseINI(
            """
            port.serial=5554
            grpc.port=8554
            grpc.token=abc/def+ghi==
            avd.name=Pixel_8
            """
        )
        XCTAssertEqual(values["port.serial"], "5554")
        XCTAssertEqual(values["grpc.port"], "8554")
        XCTAssertEqual(values["grpc.token"], "abc/def+ghi==")
    }

    @MainActor
    func testGrpcScreenshotStreamWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment[
            "VIEWPORT_ANDROID_EMULATOR_GRPC"
        ] == "1" else {
            throw XCTSkip(
                "Set VIEWPORT_ANDROID_EMULATOR_GRPC=1 with a running emulator for the smoke test."
            )
        }

        let serial = ProcessInfo.processInfo.environment[
            "VIEWPORT_ANDROID_TEST_SERIAL"
        ] ?? "emulator-5554"
        let stream = AndroidEmulatorGrpcStream()
        let receivedFrame = expectation(description: "Received a gRPC RGBA frame")
        var didReceiveFrame = false
        let started = try await stream.start(
            serial: serial,
            profile: .smooth
        ) { _ in
            guard !didReceiveFrame else { return }
            didReceiveFrame = true
            receivedFrame.fulfill()
        } onFailure: { error in
            XCTFail(error.localizedDescription)
            receivedFrame.fulfill()
        }
        XCTAssertTrue(started)
        await fulfillment(of: [receivedFrame], timeout: 8)
        stream.stop()
        XCTAssertTrue(didReceiveFrame)
    }
}
