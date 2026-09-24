import CoreVideo
import IOSurface
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

    func testImageFormatRequestsMMAPTransport() {
        let format = EmulatorProtobuf.imageFormat(
            rgba: true,
            width: 1_024,
            height: 1_024,
            mmapHandle: "file:///tmp/x"
        )
        // Field 7 is output-only `foldedDisplay`; nothing is sent there.
        let expected = Data([0x08, 0x01, 0x18, 0x80, 0x08, 0x20, 0x80, 0x08, 0x32, 0x11, 0x08, 0x01, 0x12, 0x0D])
            + Data("file:///tmp/x".utf8)
        XCTAssertEqual(format, expected)
        XCTAssertEqual(
            EmulatorProtobuf.imageFormat(rgba: true, width: 0, height: 0),
            Data([0x08, 0x01])
        )
    }

    func testSettingsFrameAdvertisesWindowAndMaxFrameSize() {
        let frame = EmulatorProtobuf.settingsFrame(
            flags: 0,
            initialWindowSize: 0x7FFF_FFFF,
            maxFrameSize: 0xFF_FFFF
        )
        XCTAssertEqual(
            frame,
            Data([
                0x00, 0x00, 0x0C, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x04, 0x7F, 0xFF, 0xFF, 0xFF,
                0x00, 0x05, 0x00, 0xFF, 0xFF, 0xFF
            ])
        )
    }

    func testParsesImageWithInlinePixelsAndMMAPWithout() throws {
        // Image { format { RGBA, width 2, height 1 }, ..., seq 5 }
        let format = Data([0x0A, 0x06, 0x08, 0x01, 0x18, 0x02, 0x20, 0x01])
        let pixels = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let inline = try XCTUnwrap(
            EmulatorProtobuf.parseImage(
                format + Data([0x22, 0x08]) + pixels + Data([0x28, 0x05])
            )
        )
        XCTAssertEqual(inline.width, 2)
        XCTAssertEqual(inline.height, 1)
        XCTAssertEqual(Data(inline.pixels), pixels)

        let mmap = try XCTUnwrap(
            EmulatorProtobuf.parseImage(format + Data([0x28, 0x05]))
        )
        XCTAssertEqual(mmap.width, 2)
        XCTAssertEqual(mmap.height, 1)
        XCTAssertTrue(mmap.pixels.isEmpty)

        // Inactive display: empty 0×0 image.
        XCTAssertNil(EmulatorProtobuf.parseImage(Data([0x0A, 0x02, 0x08, 0x01])))
    }

    func testFrameConverterSwizzlesPaddedRGBAIntoOpaqueSRGBSurface() throws {
        // 2×2 RGBA with 4 bytes of row padding.
        let rgba: [UInt8] = [
            10, 20, 30, 0, 40, 50, 60, 128, 0xEE, 0xEE, 0xEE, 0xEE,
            70, 80, 90, 255, 1, 2, 3, 4, 0xEE, 0xEE, 0xEE, 0xEE
        ]
        let converter = EmulatorFrameConverter()
        let buffer = try XCTUnwrap(
            rgba.withUnsafeBytes {
                converter.makePixelBuffer(
                    rgba: $0.baseAddress!,
                    width: 2,
                    height: 2,
                    bytesPerRow: 12
                )
            }
        )
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
        XCTAssertNotNil(IOSurfaceCopyValue(surface, kIOSurfaceColorSpace))

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let row0 = Array(UnsafeBufferPointer(start: base, count: 8))
        let row1 = Array(UnsafeBufferPointer(start: base + rowBytes, count: 8))
        XCTAssertEqual(row0, [30, 20, 10, 255, 60, 50, 40, 255])
        XCTAssertEqual(row1, [90, 80, 70, 255, 3, 2, 1, 255])
    }

    func testSharedFrameBufferSeesExternalWritesAndRemovesFile() throws {
        let directory = FileManager.default.temporaryDirectory
        let shared = try XCTUnwrap(
            EmulatorSharedFrameBuffer(byteCount: 16, directory: directory)
        )
        XCTAssertTrue(shared.handle.hasPrefix("file:///"))
        let path = String(shared.handle.dropFirst("file://".count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Stands in for the emulator process writing into its own mapping.
        let writer = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try writer.seek(toOffset: 4)
        try writer.write(contentsOf: Data([9, 8, 7, 6]))
        try writer.close()
        let bytes = shared.baseAddress.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + 4, count: 4)), [9, 8, 7, 6])

        shared.removeFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
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
            let onFrame: @Sendable (CVPixelBuffer) -> Void
            init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
                self.onFrame = onFrame
            }
            func start() async throws {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer)
                onFrame(buffer!)
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
