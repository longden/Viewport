import XCTest
@testable import Viewport

@MainActor
final class IOSSimulatorSurfaceStreamTests: XCTestCase {
    func testSurfaceStreamWhenRequested() async throws {
        guard let deviceID = ProcessInfo.processInfo.environment[
            "VIEWPORT_IOS_SIMULATOR_UDID"
        ] else {
            throw XCTSkip(
                "Set VIEWPORT_IOS_SIMULATOR_UDID for the Simulator IOSurface smoke test."
            )
        }

        let stream = IOSSimulatorSurfaceStream()
        guard stream.isAvailable else {
            throw XCTSkip("SimulatorKit is unavailable in this environment.")
        }

        let receivedFrame = expectation(description: "Received an IOSurface frame")
        var didReceiveFrame = false
        try stream.start(deviceID: deviceID, frameRate: 60) { _ in
            guard !didReceiveFrame else { return }
            didReceiveFrame = true
            receivedFrame.fulfill()
        } onFailure: { error in
            XCTFail(error.localizedDescription)
            receivedFrame.fulfill()
        }
        await fulfillment(of: [receivedFrame], timeout: 8)
        stream.stop()
        XCTAssertTrue(didReceiveFrame)
    }
}
