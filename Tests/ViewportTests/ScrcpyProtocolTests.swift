import Foundation
import XCTest
@testable import Viewport

final class ScrcpyProtocolTests: XCTestCase {
    @MainActor
    func testConnectedDeviceStreamWhenRequested() async throws {
        guard let serial = ProcessInfo.processInfo.environment[
            "VIEWPORT_ANDROID_TEST_SERIAL"
        ] else {
            throw XCTSkip("Set VIEWPORT_ANDROID_TEST_SERIAL for the hardware test.")
        }

        let stream = ScrcpyDeviceStream()
        let receivedFrame = expectation(description: "Decoded an H.264 frame")
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
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(didReceiveFrame)
    }

    func testParsesVideoSessionPacket() throws {
        let packet = Data([
            0x80, 0, 0, 0,
            0, 0, 0x04, 0x38,
            0, 0, 0x07, 0x80
        ])

        XCTAssertEqual(
            try ScrcpyVideoPacketHeader.parse(packet).kind,
            .session(width: 1_080, height: 1_920)
        )
    }

    func testParsesKeyVideoPacket() throws {
        let presentationTime: UInt64 = 42_000
        var encoded = presentationTime | (UInt64(1) << 61)
        encoded = encoded.bigEndian
        var size = UInt32(65_536).bigEndian
        var packet = Data(bytes: &encoded, count: MemoryLayout.size(ofValue: encoded))
        packet.append(Data(bytes: &size, count: MemoryLayout.size(ofValue: size)))

        XCTAssertEqual(
            try ScrcpyVideoPacketHeader.parse(packet).kind,
            .media(
                size: 65_536,
                presentationTime: presentationTime,
                isConfig: false,
                isKey: true
            )
        )
    }

    func testRejectsUnboundedVideoPacket() {
        let packet = Data([
            0, 0, 0, 0, 0, 0, 0, 1,
            0x04, 0x00, 0x00, 0x01
        ])

        XCTAssertThrowsError(try ScrcpyVideoPacketHeader.parse(packet))
    }

    func testAnnexBParsingDoesNotRequireContiguousCopy() {
        let nal = Data([0x67, 0x42, 0x00, 0x0A, 0xFF])
        var payload = Data([0, 0, 0, 1])
        payload.append(nal)
        payload.append(contentsOf: [0, 0, 1])
        payload.append(contentsOf: [0x68, 0xCE])

        let units = ScrcpyH264AnnexB.nalUnits(in: payload)
        XCTAssertEqual(units, [nal, Data([0x68, 0xCE])])

        let lengthPrefixed = ScrcpyH264AnnexB.lengthPrefixedData(from: units)
        XCTAssertEqual(
            lengthPrefixed.prefix(4),
            Data([0, 0, 0, UInt8(nal.count)])
        )
    }

    func testSessionPointMapsIntoVideoSizeAndClamps() {
        // The server encodes at sizes rounded to multiples of 8 (1008x2240
        // for a 1008x2244 panel) and drops events embedding any other size,
        // so mapping must use the announced session size, never `wm size`.
        let mid = ScrcpyControlMessage.sessionPoint(
            CGPoint(x: 0.5, y: 0.5),
            width: 1_008,
            height: 2_240
        )
        XCTAssertEqual(mid.x, 504)
        XCTAssertEqual(mid.y, 1_120)

        let edge = ScrcpyControlMessage.sessionPoint(
            CGPoint(x: 1.2, y: 1.0),
            width: 1_008,
            height: 2_240
        )
        XCTAssertEqual(edge.x, 1_007)
        XCTAssertEqual(edge.y, 2_239)

        let origin = ScrcpyControlMessage.sessionPoint(
            CGPoint(x: -0.3, y: 0),
            width: 1_008,
            height: 2_240
        )
        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 0)
    }

    func testSerializesInjectTouchEventLikeScrcpy() {
        // Mirrors scrcpy's `test_serialize_inject_touch_event`, using a finger
        // pointer id and zero buttons (Viewport injects touch, not mouse).
        let expected = Data([
            ScrcpyControlMessage.injectTouchType,
            0x00, // AMOTION_EVENT_ACTION_DOWN
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, // finger id -2
            0x00, 0x00, 0x00, 0x64, // x = 100
            0x00, 0x00, 0x00, 0xC8, // y = 200
            0x04, 0x38, // width = 1080
            0x07, 0x80, // height = 1920
            0xFF, 0xFF, // pressure = 1.0
            0x00, 0x00, 0x00, 0x00, // action button
            0x00, 0x00, 0x00, 0x00 // buttons
        ])

        XCTAssertEqual(
            ScrcpyControlMessage.injectTouch(
                action: .down,
                x: 100,
                y: 200,
                screenWidth: 1_080,
                screenHeight: 1_920
            ),
            expected
        )

        let up = ScrcpyControlMessage.injectTouch(
            action: .up,
            x: 100,
            y: 200,
            screenWidth: 1_080,
            screenHeight: 1_920
        )
        XCTAssertEqual(up[1], 1)
        XCTAssertEqual(up[22], 0)
        XCTAssertEqual(up[23], 0)
    }
}
