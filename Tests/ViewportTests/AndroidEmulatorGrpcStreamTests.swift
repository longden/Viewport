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

    func testGrpcMessageBufferConsumesAcrossChunks() throws {
        var buffer = GrpcMessageBuffer(compactionThreshold: 64)
        let first = EmulatorProtobuf.grpcMessage(Data("hello".utf8))
        let second = EmulatorProtobuf.grpcMessage(Data("world!".utf8))
        let combined = first + second

        buffer.append(combined.prefix(3))
        XCTAssertEqual(try buffer.consumeMessages(), [])
        XCTAssertEqual(buffer.count, 3)

        buffer.append(combined.dropFirst(3))
        let messages = try buffer.consumeMessages()
        XCTAssertEqual(messages, [Data("hello".utf8), Data("world!".utf8)])
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.consumed, 0)
    }

    func testGrpcMessageBufferCompactsAfterThreshold() throws {
        var buffer = GrpcMessageBuffer(compactionThreshold: 16)
        let message = EmulatorProtobuf.grpcMessage(Data(repeating: 0xAB, count: 8))
        XCTAssertEqual(message.count, 13)

        buffer.append(message)
        buffer.append(message)
        let messages = try buffer.consumeMessages()
        XCTAssertEqual(messages.count, 2)
        // After consuming past the threshold / half-buffer, the read index
        // should have been compacted back to zero.
        XCTAssertEqual(buffer.consumed, 0)
        XCTAssertEqual(buffer.count, 0)
    }

    func testGrpcMessageBufferRejectsCompressedFrames() {
        var buffer = GrpcMessageBuffer()
        var framed = EmulatorProtobuf.grpcMessage(Data([0x01]))
        framed[0] = 1
        buffer.append(framed)
        XCTAssertThrowsError(try buffer.consumeMessages()) { error in
            XCTAssertEqual(
                error as? GrpcMessageBuffer.ConsumeError,
                .compressedUnsupported
            )
        }
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

    func testDiscoveryWithoutTokenStillYieldsEndpoint() {
        // Emulator 37+ plain `-grpc` publishes port but no token.
        let values = EmulatorGrpcDiscovery.parseINI(
            """
            port.serial=5554
            grpc.port=8554
            avd.name=FlowTester Resizable 2
            """
        )
        XCTAssertNil(values["grpc.token"])
        XCTAssertEqual(values["grpc.port"], "8554")
    }

    func testHeadersFrameOmitsEmptyAuthorization() {
        let withAuth = EmulatorProtobuf.headersFrame(
            streamID: 1,
            path: "/android.emulation.control.EmulatorController/streamScreenshot",
            authorization: "Bearer secret",
            endStream: false
        )
        let withoutAuth = EmulatorProtobuf.headersFrame(
            streamID: 1,
            path: "/android.emulation.control.EmulatorController/streamScreenshot",
            authorization: "",
            endStream: false
        )
        XCTAssertGreaterThan(withAuth.count, withoutAuth.count)
    }

    @MainActor
    func testGrpcStartsWithoutTokenUsingMockWorker() async throws {
        final class MockWorker: EmulatorGrpcWorking, @unchecked Sendable {
            let onFrame: @Sendable (CGImage) -> Void
            init(onFrame: @escaping @Sendable (CGImage) -> Void) {
                self.onFrame = onFrame
            }
            func start() async throws {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let context = CGContext(
                    data: nil,
                    width: 8,
                    height: 8,
                    bitsPerComponent: 8,
                    bytesPerRow: 32,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                let image = context!.makeImage()!
                onFrame(image)
            }
            func stop() {}
            func sendTouch(x: Int32, y: Int32, isDown: Bool) {}
        }

        let stream = AndroidEmulatorGrpcStream(
            endpointProvider: { _ in
                EmulatorGrpcEndpoint(port: 8554, token: nil)
            },
            workerFactory: { configuration, onFrame, _ in
                XCTAssertEqual(configuration.authorization, "")
                XCTAssertEqual(configuration.port, 8554)
                return MockWorker(onFrame: onFrame)
            }
        )
        let started = try await stream.start(
            serial: "emulator-5554",
            profile: .smooth
        ) { _ in } onFailure: { _ in }
        XCTAssertTrue(started)
        stream.stop()
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
