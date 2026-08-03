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
}
