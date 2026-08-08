import XCTest
@testable import Viewport

final class DeviceAutomationTests: XCTestCase {
    func testNormalizedURLAddsHTTPSForBareHosts() {
        XCTAssertEqual(
            DeviceAutomationService.normalizedURL("example.com/path"),
            "https://example.com/path"
        )
        XCTAssertEqual(
            DeviceAutomationService.normalizedURL("https://example.com"),
            "https://example.com"
        )
        XCTAssertEqual(
            DeviceAutomationService.normalizedURL("myapp://home"),
            "myapp://home"
        )
        XCTAssertNil(DeviceAutomationService.normalizedURL("   "))
    }

    func testValidatedAPNsPayloadRequiresApsObject() throws {
        let data = try DeviceAutomationService.validatedAPNsPayloadData(
            DeviceAutomationService.defaultAPNsPayloadJSON
        )
        XCTAssertFalse(data.isEmpty)

        XCTAssertThrowsError(
            try DeviceAutomationService.validatedAPNsPayloadData(#"{"alert":"x"}"#)
        )
        XCTAssertThrowsError(
            try DeviceAutomationService.validatedAPNsPayloadData("not-json")
        )
        XCTAssertThrowsError(
            try DeviceAutomationService.validatedAPNsPayloadData("   ")
        )
    }

    func testShellSingleQuotedEscapesEmbeddedQuotes() {
        XCTAssertEqual(
            DeviceAutomationService.shellSingleQuoted("hello"),
            "'hello'"
        )
        XCTAssertEqual(
            DeviceAutomationService.shellSingleQuoted("it's"),
            "'it'\\''s'"
        )
    }

    func testInjectionResultSummary() {
        var result = DeviceInjectionResult(
            succeeded: ["Pixel_8"],
            skipped: ["Physical iPhones are view-only."]
        )
        XCTAssertEqual(
            result.summary(verb: "Opened"),
            "Opened on Pixel_8. Physical iPhones are view-only."
        )
        XCTAssertTrue(result.didSucceed)

        result = DeviceInjectionResult()
        XCTAssertEqual(result.summary(verb: "Opened"), "Nothing to do.")
        XCTAssertFalse(result.didSucceed)
    }
}
