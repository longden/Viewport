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

    func testAndroidGeoFixArgumentsUseLongitudeFirst() {
        XCTAssertEqual(
            DeviceAutomationService.androidGeoFixArguments(
                latitude: 37.334900,
                longitude: -122.009000
            ),
            ["emu", "geo", "fix", "-122.009000", "37.334900"]
        )
    }

    func testIOSLocationArgumentFormatsCoordinatePair() {
        XCTAssertEqual(
            DeviceAutomationService.iosLocationArgument(
                latitude: 51.507400,
                longitude: -0.127800
            ),
            "51.507400,-0.127800"
        )
    }

    func testValidateCoordinateRejectsOutOfRangeValues() {
        XCTAssertThrowsError(
            try DeviceAutomationService.validateCoordinate(
                latitude: 95,
                longitude: 0
            )
        )
        XCTAssertThrowsError(
            try DeviceAutomationService.validateCoordinate(
                latitude: 0,
                longitude: 200
            )
        )
    }

    func testDeviceOrientationAndroidRotationValues() {
        XCTAssertEqual(DeviceOrientation.portrait.androidUserRotation, "0")
        XCTAssertEqual(DeviceOrientation.landscape.androidUserRotation, "1")
    }

    func testFirstGPXCoordinateParsesTrackPoint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-test-\(UUID().uuidString).gpx")
        try """
        <?xml version="1.0"?>
        <gpx>
          <trk><trkseg>
            <trkpt lat="37.331705" lon="-122.030237"></trkpt>
          </trkseg></trk>
        </gpx>
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinate = try DeviceAutomationService.firstGPXCoordinate(from: url)
        XCTAssertEqual(coordinate.latitude, 37.331705, accuracy: 0.000001)
        XCTAssertEqual(coordinate.longitude, -122.030237, accuracy: 0.000001)
    }

    func testFirstGPXCoordinateIgnoresCommentsAndPrefersWaypoint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-test-\(UUID().uuidString).gpx")
        try """
        <?xml version="1.0"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1">
          <!-- lat="1.0" lon="2.0" -->
          <wpt lat="51.5074" lon="-0.1278"><name>London</name></wpt>
          <trk><trkseg>
            <trkpt lat="37.331705" lon="-122.030237"></trkpt>
          </trkseg></trk>
        </gpx>
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinate = try DeviceAutomationService.firstGPXCoordinate(from: url)
        XCTAssertEqual(coordinate.latitude, 51.5074, accuracy: 0.0001)
        XCTAssertEqual(coordinate.longitude, -0.1278, accuracy: 0.0001)
    }

    func testAppleScriptEscapedQuotes() {
        XCTAssertEqual(
            DeviceAutomationService.appleScriptEscaped(#"iPhone "16" Pro"#),
            #"iPhone \"16\" Pro"#
        )
    }
}
