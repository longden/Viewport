import XCTest
@testable import Viewport

final class CapturePerformanceProfileTests: XCTestCase {
    func testDirectCaptureIntervalsTradeResponsivenessForLowerWork() {
        XCTAssertLessThan(
            CapturePerformanceProfile.smooth.directCaptureInterval,
            CapturePerformanceProfile.balanced.directCaptureInterval
        )
        XCTAssertLessThan(
            CapturePerformanceProfile.balanced.directCaptureInterval,
            CapturePerformanceProfile.sharp.directCaptureInterval
        )
    }

    func testHigherDetailProfilesDoNotIncreaseFrameRate() {
        XCTAssertGreaterThanOrEqual(
            CapturePerformanceProfile.smooth.targetFrameRate,
            CapturePerformanceProfile.balanced.targetFrameRate
        )
        XCTAssertGreaterThanOrEqual(
            CapturePerformanceProfile.balanced.targetFrameRate,
            CapturePerformanceProfile.sharp.targetFrameRate
        )
        XCTAssertGreaterThan(
            CapturePerformanceProfile.smooth.hostWindowFrameRate,
            CapturePerformanceProfile.balanced.hostWindowFrameRate
        )
        XCTAssertLessThanOrEqual(
            CapturePerformanceProfile.smooth.maximumHostWindowScale,
            CapturePerformanceProfile.balanced.maximumHostWindowScale
        )
    }
}
