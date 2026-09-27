import XCTest
@testable import Viewport

final class CaptureStallDeadlineTests: XCTestCase {
    func testSleepAndWallClockChangesDoNotCauseFallback() {
        let clock = TestClock()
        let deadline = CaptureStallDeadline(timeout: 5, now: { clock.uptime })
        clock.advance(awake: 2, wall: 2)
        XCTAssertEqual(deadline.remaining, 3)

        // An hour asleep advances wall time, but not the macOS uptime clock.
        clock.advance(awake: 0, wall: 3_600)
        XCTAssertEqual(deadline.remaining, 3)
        clock.advance(awake: 0, wall: -7_200)
        XCTAssertEqual(deadline.remaining, 3)

        clock.advance(awake: 1, wall: 1)
        deadline.recordActivity()
        XCTAssertEqual(deadline.remaining, 5)
    }

    func testRealStallStillExpiresAfterFiveAwakeSeconds() {
        let clock = TestClock()
        let deadline = CaptureStallDeadline(timeout: 5, now: { clock.uptime })
        clock.advance(awake: 4.5, wall: 4.5)
        XCTAssertEqual(deadline.remaining, 0.5)
        clock.advance(awake: 0.5, wall: 0.5)
        XCTAssertEqual(deadline.remaining, 0)
        clock.advance(awake: 10, wall: 10)
        XCTAssertEqual(deadline.remaining, 0)
    }

    func testSubMillisecondRemainderDoesNotRenewWatchdog() {
        let almostDue = TestClock()
        let deadline = CaptureStallDeadline(timeout: 5, now: { almostDue.uptime })
        almostDue.advance(awake: 4.9995, wall: 4.9995)
        XCTAssertGreaterThan(deadline.remaining, 0)
        XCTAssertFalse(deadline.shouldRenew)

        let stillWaiting = TestClock()
        let renewing = CaptureStallDeadline(timeout: 5, now: { stillWaiting.uptime })
        stillWaiting.advance(awake: 4.9, wall: 4.9)
        XCTAssertTrue(renewing.shouldRenew)
    }

    func testNewFrameRenewsDeadline() {
        let clock = TestClock()
        let deadline = CaptureStallDeadline(timeout: 5, now: { clock.uptime })
        clock.advance(awake: 4, wall: 4)
        deadline.recordActivity()
        clock.advance(awake: 2, wall: 2)
        XCTAssertEqual(deadline.remaining, 3)
    }
}

private final class TestClock: @unchecked Sendable {
    var uptime: TimeInterval = 100
    var wallTime: TimeInterval = 1_000

    func advance(awake: TimeInterval, wall: TimeInterval) {
        uptime += awake
        wallTime += wall
    }
}
