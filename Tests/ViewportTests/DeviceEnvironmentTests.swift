import CoreGraphics
import Foundation
import JavaScriptCore
import XCTest
@testable import Viewport

final class GeoCoordinateTests: XCTestCase {
    func testParsesCommonFormats() {
        XCTAssertEqual(GeoCoordinate.parse("37.3349, -122.009"), GeoCoordinate(latitude: 37.3349, longitude: -122.009))
        XCTAssertEqual(GeoCoordinate.parse("51.5 -0.12")?.longitude, -0.12)
        XCTAssertEqual(GeoCoordinate.parse("1;2")?.latitude, 1)
        XCTAssertNil(GeoCoordinate.parse("91, 0"))
        XCTAssertNil(GeoCoordinate.parse("hello"))
        XCTAssertNil(GeoCoordinate.parse("1, 2, 3"))
    }

    func testFormatsWithPOSIXDecimals() {
        let coordinate = GeoCoordinate(latitude: 37.5, longitude: -122.25)
        XCTAssertEqual(coordinate.simctlArgument, "37.500000,-122.250000")
        XCTAssertEqual(coordinate.displayText, "37.50000, -122.25000")
    }

    func testRouteInterpolatesByDistanceAndTime() throws {
        let route = LocationRoute(name: "Line", points: [
            GeoCoordinate(latitude: 0, longitude: 0),
            GeoCoordinate(latitude: 0, longitude: 0.01),
            GeoCoordinate(latitude: 0, longitude: 0.03)
        ])
        XCTAssertTrue(route.isPlayable)
        // 0.01° of longitude at the equator ≈ 1112 m.
        XCTAssertEqual(route.totalDistance, 3_335.8, accuracy: 2)
        let middle = try XCTUnwrap(route.coordinate(atDistance: route.totalDistance / 2))
        XCTAssertEqual(middle.longitude, 0.015, accuracy: 0.0001)
        XCTAssertEqual(route.coordinate(atDistance: -5), route.points.first)
        XCTAssertEqual(route.coordinate(atDistance: 1e9), route.points.last)
        XCTAssertEqual(route.duration(speed: 10), route.totalDistance / 10, accuracy: 0.001)
        let afterTen = try XCTUnwrap(route.coordinate(atElapsed: 10, speed: 111.2))
        XCTAssertEqual(afterTen.longitude, 0.01, accuracy: 0.0002)
    }

    func testSinglePointRouteIsNotPlayable() {
        let route = LocationRoute(name: "Pin", points: [GeoCoordinate(latitude: 1, longitude: 1)])
        XCTAssertFalse(route.isPlayable)
        XCTAssertEqual(route.coordinate(atDistance: 10), route.points.first)
    }
}

final class GPXRouteParserTests: XCTestCase {
    func testPrefersTrackPointsAndTrackName() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Export</name></metadata>
          <wpt lat="10" lon="10"><name>Start pin</name></wpt>
          <trk><name>Morning run</name><trkseg>
            <trkpt lat="37.1" lon="-122.1"><ele>10</ele></trkpt>
            <trkpt lat="37.2" lon="-122.2"/>
            <trkpt lat="999" lon="0"/>
          </trkseg></trk>
        </gpx>
        """
        let route = try GPXRouteParser.parse(Data(gpx.utf8))
        XCTAssertEqual(route.points.count, 2)
        XCTAssertEqual(route.points.first, GeoCoordinate(latitude: 37.1, longitude: -122.1))
        XCTAssertEqual(route.name, "Export")
    }

    func testFallsBackToRoutePointsThenWaypoints() throws {
        let route = try GPXRouteParser.parse(Data("""
        <gpx><rte><rtept lat="1" lon="2"/><rtept lat="3" lon="4"/></rte><wpt lat="9" lon="9"/></gpx>
        """.utf8), fallbackName: "file")
        XCTAssertEqual(route.points.map(\.latitude), [1, 3])
        XCTAssertEqual(route.name, "file")
        let waypoints = try GPXRouteParser.parse(Data("<gpx><wpt lat=\"9\" lon=\"8\"/></gpx>".utf8))
        XCTAssertEqual(waypoints.points.count, 1)
    }

    func testRejectsEmptyOrBrokenFiles() {
        XCTAssertThrowsError(try GPXRouteParser.parse(Data("<gpx></gpx>".utf8))) { error in
            XCTAssertEqual(error as? GPXRouteParserError, .noPoints)
        }
        XCTAssertThrowsError(try GPXRouteParser.parse(Data("<gpx><trk>".utf8)))
    }
}

final class LocationCommandTests: XCTestCase {
    func testBuildsSimctlAndConsoleCommands() {
        let coordinate = GeoCoordinate(latitude: 51.5, longitude: -0.1)
        XCTAssertEqual(
            LocationSimulationService.simctlSetArguments(udid: "UDID", coordinate: coordinate),
            ["location", "UDID", "set", "51.500000,-0.100000"]
        )
        // The emulator console takes longitude first.
        XCTAssertEqual(
            LocationSimulationService.emulatorGeoFixArguments(coordinate),
            ["geo", "fix", "-0.100000", "51.500000"]
        )
        XCTAssertEqual(
            LocationSimulationService.simctlStartArguments(udid: "UDID", metersPerSecond: 13),
            ["location", "UDID", "start", "--speed=13.00", "--interval=1", "-"]
        )
        let input = LocationSimulationService.simctlWaypointInput(
            LocationRoute(name: "r", points: [coordinate, GeoCoordinate(latitude: 1, longitude: 2)])
        )
        XCTAssertEqual(String(decoding: input, as: UTF8.self), "51.500000,-0.100000\n1.000000,2.000000\n")
    }

    func testWebGeolocationScriptEmbedsPosition() {
        XCTAssertEqual(WebGeolocationOverride.literal(nil), "null")
        XCTAssertEqual(
            WebGeolocationOverride.literal(GeoCoordinate(latitude: 1.5, longitude: -2)),
            "{latitude:1.500000,longitude:-2.000000}"
        )
        XCTAssertTrue(
            WebGeolocationOverride.source(initial: GeoCoordinate(latitude: 1, longitude: 2))
                .contains("coord: {latitude:1.000000,longitude:2.000000}")
        )
        XCTAssertTrue(WebGeolocationOverride.updateScript(nil).contains("__viewportSetGeo(null)"))
    }

    func testWebGeolocationWatchesFollowTheOverride() throws {
        let context = try XCTUnwrap(JSContext())
        // Minimal page: a fake WebKit geolocation and a synchronous setTimeout.
        context.evaluateScript("""
        var window = this;
        var setTimeout = (f) => f();
        var real = { active: new Set(), next: 1 };
        var navigator = { geolocation: {
          getCurrentPosition() {},
          watchPosition() { const id = real.next++; real.active.add(id); return id; },
          clearWatch(id) { real.active.delete(id); }
        } };
        """)
        context.evaluateScript(WebGeolocationOverride.source(initial: nil))
        context.evaluateScript("""
        var fixes = [];
        var watch = navigator.geolocation.watchPosition((p) => fixes.push(p.coords.latitude));
        """)
        // Started before an override: on the real feed.
        XCTAssertEqual(context.evaluateScript("real.active.size").toInt32(), 1)

        context.evaluateScript(
            WebGeolocationOverride.updateScript(GeoCoordinate(latitude: 1, longitude: 2))
        )
        XCTAssertEqual(context.evaluateScript("real.active.size").toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("fixes.join()").toString(), "1")

        context.evaluateScript(WebGeolocationOverride.updateScript(nil))
        XCTAssertEqual(context.evaluateScript("real.active.size").toInt32(), 1)

        context.evaluateScript("navigator.geolocation.clearWatch(watch)")
        XCTAssertEqual(context.evaluateScript("real.active.size").toInt32(), 0)
    }

    func testDetectsEmulatorConsoleFailures() {
        XCTAssertNil(DeviceCommandShell.emulatorConsoleFailure(in: "OK\n"))
        XCTAssertEqual(
            DeviceCommandShell.emulatorConsoleFailure(in: "KO: argument 'abc' is not a number\n"),
            "argument 'abc' is not a number"
        )
    }

    func testPlatformTargetsPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PlatformTargetsTests-\(UUID().uuidString)"))
        XCTAssertEqual(PlatformTargets(defaults: defaults, key: "t"), PlatformTargets())
        let saved = PlatformTargets(android: false, iOS: true, web: false)
        saved.save(to: defaults, key: "t")
        let restored = PlatformTargets(defaults: defaults, key: "t")
        XCTAssertEqual(restored, saved)
        XCTAssertFalse(restored.includes(.web))
        XCTAssertTrue(restored.includes(.iOS))
    }
}

final class AppEnvironmentTests: XCTestCase {
    func testParsesSimulatorAppsAndSkipsSystemApps() {
        let output = """
        {
            "com.apple.Bridge" =     {
                ApplicationType = System;
                CFBundleDisplayName = Watch;
            };
            "com.example.shop" =     {
                ApplicationType = User;
                CFBundleDisplayName = "Shop Dev";
                CFBundleName = Shop;
            };
            "com.example.alpha" =     {
                ApplicationType = User;
                CFBundleName = Alpha;
            };
        }
        """
        let apps = InstalledAppParser.parseSimulatorApps(output)
        XCTAssertEqual(apps.map(\.id), ["com.example.alpha", "com.example.shop"])
        XCTAssertEqual(apps.last?.name, "Shop Dev")
        XCTAssertEqual(apps.last?.menuLabel, "Shop Dev — com.example.shop")
        XCTAssertTrue(InstalledAppParser.parseSimulatorApps("not a plist").isEmpty)
    }

    func testParsesAndroidPackages() {
        let apps = InstalledAppParser.parseAndroidPackages("package:com.b.app\npackage:com.a.app\n\nnoise\n")
        XCTAssertEqual(apps.map(\.id), ["com.a.app", "com.b.app"])
        XCTAssertEqual(apps.first?.menuLabel, "com.a.app")
    }

    func testValidatesIdentifiers() {
        XCTAssertTrue(InstalledAppParser.isValidIdentifier("com.example.my-app_2"))
        XCTAssertFalse(InstalledAppParser.isValidIdentifier(""))
        XCTAssertFalse(InstalledAppParser.isValidIdentifier("com.example; rm -rf"))
        XCTAssertFalse(InstalledAppParser.isValidIdentifier("-flag"))
    }

    func testPermissionMappings() {
        XCTAssertEqual(AppPermission.locationAlways.simctlService, "location-always")
        XCTAssertNil(AppPermission.camera.simctlService)
        XCTAssertEqual(AppPermission.camera.androidPermissions, ["android.permission.CAMERA"])
        XCTAssertTrue(AppPermission.reminders.androidPermissions.isEmpty)
        XCTAssertEqual(
            AppEnvironmentService.simctlPrivacyArguments(
                udid: "U", action: .revoke, service: "photos", bundleID: "com.x"
            ),
            ["privacy", "U", "revoke", "photos", "com.x"]
        )
        XCTAssertEqual(
            AppEnvironmentService.androidPermissionCommands(
                action: .reset, package: "com.x", permission: "android.permission.CAMERA"
            ),
            [
                ["pm", "revoke", "com.x", "android.permission.CAMERA"],
                ["pm", "clear-permission-flags", "com.x", "android.permission.CAMERA", "user-set", "user-fixed"]
            ]
        )
    }

    func testExtractsPackageManagerExceptions() {
        let trace = """

        Exception occurred while executing 'grant':
        java.lang.IllegalArgumentException: Unknown permission android.permission.FOO
        \tat com.android.server.pm.PackageManagerShellCommand.runGrantRevokePermission(PackageManagerShellCommand.java:2704)
        """
        let message = AppEnvironmentService.androidShellException(trace)
        XCTAssertEqual(message, "Unknown permission android.permission.FOO")
        XCTAssertTrue(AppEnvironmentService.isIgnorableAndroidPermissionFailure(message ?? ""))
        XCTAssertTrue(AppEnvironmentService.isIgnorableAndroidPermissionFailure(
            "Package com.x has not requested permission android.permission.CAMERA"
        ))
        XCTAssertFalse(AppEnvironmentService.isIgnorableAndroidPermissionFailure("Unknown package: com.x"))
    }

    func testValidatesPushPayloads() throws {
        for template in PushPayloadTemplate.allCases {
            XCTAssertNoThrow(try PushPayloadValidator.validate(template.json), template.title)
        }
        XCTAssertThrowsError(try PushPayloadValidator.validate("{\"alert\": 1}")) {
            XCTAssertEqual($0 as? PushPayloadValidator.ValidationError, .missingAPS)
        }
        XCTAssertThrowsError(try PushPayloadValidator.validate("[1]")) {
            XCTAssertEqual($0 as? PushPayloadValidator.ValidationError, .notAnObject)
        }
        XCTAssertThrowsError(try PushPayloadValidator.validate("{aps"))
        let big = "{\"aps\":{\"alert\":\"\(String(repeating: "x", count: 5_000))\"}}"
        XCTAssertThrowsError(try PushPayloadValidator.validate(big)) {
            guard case .tooLarge = $0 as? PushPayloadValidator.ValidationError else {
                return XCTFail("Expected tooLarge")
            }
        }
    }
}

final class NetworkConditionsTests: XCTestCase {
    func testEmulatorProfileCommands() {
        XCTAssertEqual(
            NetworkConditionsService.emulatorProfileCommands(.threeG),
            [["network", "speed", "umts"], ["network", "delay", "umts"]]
        )
        XCTAssertEqual(
            NetworkConditionsService.emulatorProfileCommands(.unrestricted),
            [["network", "speed", "full"], ["network", "delay", "none"]]
        )
        XCTAssertEqual(
            NetworkConditionsService.airplaneModeArguments(true),
            ["cmd", "connectivity", "airplane-mode", "enable"]
        )
        XCTAssertEqual(NetworkConditionsService.legacyRadioCommands(false).first, ["svc", "wifi", "enable"])
    }

    func testProxySettings() {
        let local = ProxySettings(host: " localhost ", port: 9090)
        XCTAssertTrue(local.isValid)
        XCTAssertTrue(local.isLoopback)
        XCTAssertEqual(local.androidProxyValue, "127.0.0.1:9090")
        let remote = ProxySettings(host: "192.168.1.20", port: 8888)
        XCTAssertFalse(remote.isLoopback)
        XCTAssertEqual(remote.androidProxyValue, "192.168.1.20:8888")
        XCTAssertFalse(ProxySettings(host: "", port: 80).isValid)
        XCTAssertFalse(ProxySettings(host: "a b", port: 80).isValid)
        XCTAssertFalse(ProxySettings(host: "proxy", port: 70_000).isValid)
        XCTAssertEqual(NetworkConditionsService.androidReverseArguments(port: 9090), ["reverse", "tcp:9090", "tcp:9090"])
        XCTAssertEqual(
            NetworkConditionsService.androidProxyArguments(":0"),
            ["settings", "put", "global", "http_proxy", ":0"]
        )
        XCTAssertEqual(ProxyPreset.charles.defaultPort, 8888)
        XCTAssertNil(ProxyPreset.custom.defaultPort)
    }

    func testDecodesPEMAndDERCertificates() throws {
        let der = Data([0x30, 0x82, 0x01, 0x0A, 0x02])
        let pem = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString())\n-----END CERTIFICATE-----\n"
        XCTAssertEqual(ProxyCertificate.derData(from: Data(pem.utf8)), der)
        XCTAssertEqual(ProxyCertificate.derData(from: der), der)
        XCTAssertNil(ProxyCertificate.derData(from: Data("hello".utf8)))
        XCTAssertNil(ProxyCertificate.derData(from: Data("-----BEGIN CERTIFICATE-----\nAAAA".utf8)))
        let certificate = ProxyCertificate(url: URL(fileURLWithPath: "/ca.pem"), derData: der)
        XCTAssertEqual(ProxyCertificate.derData(from: Data(certificate.pemText.utf8)), der)
    }
}

final class DeepLinkHistoryTests: XCTestCase {
    func testRecordsMostRecentFirstWithoutDuplicates() {
        var history = DeepLinkHistory(limit: 3)
        history.record("myapp://a")
        history.record(" myapp://b ")
        history.record("myapp://a")
        XCTAssertEqual(history.entries, ["myapp://a", "myapp://b"])
        history.record("myapp://c")
        history.record("myapp://d")
        XCTAssertEqual(history.entries, ["myapp://d", "myapp://c", "myapp://a"])
        history.record("   ")
        history.remove("myapp://c")
        XCTAssertEqual(history.entries, ["myapp://d", "myapp://a"])
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testRestoresTrimmedUniqueEntries() {
        let history = DeepLinkHistory(entries: ["a://1", "a://1", "", "a://2"], limit: 5)
        XCTAssertEqual(history.entries, ["a://1", "a://2"])
    }

    func testFavoritesMoveOutOfRecentlyAndBack() {
        var history = DeepLinkHistory(entries: ["a://1", "a://2"], limit: 5)
        history.addFavorite("a://2")
        XCTAssertEqual(history.favorites, ["a://2"])
        XCTAssertEqual(history.entries, ["a://1"])
        XCTAssertTrue(history.isFavorite(" a://2 "))
        // Sending a favorite doesn't duplicate it into Recently.
        history.record("a://2")
        XCTAssertEqual(history.entries, ["a://1"])
        history.clear()
        XCTAssertEqual(history.favorites, ["a://2"])
        history.removeFavorite("a://2")
        XCTAssertTrue(history.favorites.isEmpty)
        XCTAssertEqual(history.entries, ["a://2"])
    }

    func testRestoredFavoritesAreRemovedFromRecently() {
        let history = DeepLinkHistory(entries: ["a://1", "a://2"], favorites: ["a://1", "a://1", " "])
        XCTAssertEqual(history.favorites, ["a://1"])
        XCTAssertEqual(history.entries, ["a://2"])
    }

    func testOnlyHTTPLinksLoadInTheWebPane() {
        XCTAssertTrue(DeepLinkHistory.isWebLoadable("https://example.com/path"))
        XCTAssertTrue(DeepLinkHistory.isWebLoadable("example.com"))
        XCTAssertFalse(DeepLinkHistory.isWebLoadable("myapp://orders/1"))
        XCTAssertFalse(DeepLinkHistory.isWebLoadable(""))
    }

    @MainActor
    func testStorePersistsHistory() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeepLinkHistoryTests-\(UUID().uuidString)"))
        let store = DeepLinkHistoryStore(defaults: defaults, key: "links")
        store.record("myapp://home")
        store.record("myapp://cart")
        store.addFavorite("myapp://home")
        let restored = DeepLinkHistoryStore(defaults: defaults, key: "links").history
        XCTAssertEqual(restored.entries, ["myapp://cart"])
        XCTAssertEqual(restored.favorites, ["myapp://home"])
    }
}

final class DeviceAccessibilitySettingsTests: XCTestCase {
    func testTextSizeMapsToSimulatorCategories() {
        XCTAssertEqual(DeviceFontScale.defaultScale.iOSContentSize, "large")
        XCTAssertEqual(DeviceFontScale.small.iOSContentSize, "small")
        XCTAssertEqual(DeviceFontScale.extraLarge.iOSContentSize, "extra-extra-large")
    }

    func testContrastValues() {
        XCTAssertEqual(DeviceContrast.increased.iOSValue, "enabled")
        XCTAssertEqual(DeviceContrast.standard.androidValue, "0")
    }
}

final class ScreenshotCalloutTests: XCTestCase {
    func testStepNumbersContinueAfterTheHighest() {
        XCTAssertEqual(ScreenshotAnnotation.nextStepNumber(in: []), 1)
        let annotations = [
            ScreenshotAnnotation(kind: .step, start: .zero, end: .zero, number: 1),
            ScreenshotAnnotation(kind: .arrow, start: .zero, end: .zero),
            ScreenshotAnnotation(kind: .step, start: .zero, end: .zero, number: 4)
        ]
        XCTAssertEqual(ScreenshotAnnotation.nextStepNumber(in: annotations), 5)
    }

    func testCalloutText() {
        XCTAssertEqual(ScreenshotAnnotation(kind: .text, start: .zero, end: .zero, text: "  Tap here ").calloutText, "Tap here")
        XCTAssertNil(ScreenshotAnnotation(kind: .text, start: .zero, end: .zero, text: "   ").calloutText)
        XCTAssertEqual(ScreenshotAnnotation(kind: .step, start: .zero, end: .zero, number: 3).calloutText, "3")
        XCTAssertNil(ScreenshotAnnotation(kind: .box, start: .zero, end: .zero).calloutText)
        XCTAssertTrue(ScreenshotAnnotationKind.step.isCallout)
        XCTAssertFalse(ScreenshotAnnotationKind.arrow.isCallout)
    }

    func testLeaderGeometry() {
        XCTAssertFalse(ScreenshotAnnotationRenderer.hasLeader(from: .zero, to: CGPoint(x: 5, y: 5)))
        XCTAssertTrue(ScreenshotAnnotationRenderer.hasLeader(from: .zero, to: CGPoint(x: 30, y: 0)))
        // Scaled exports need proportionally longer drags.
        XCTAssertFalse(ScreenshotAnnotationRenderer.hasLeader(from: .zero, to: CGPoint(x: 30, y: 0), scale: 3))
        let bubble = CGRect(x: 0, y: 0, width: 40, height: 20)
        let start = ScreenshotAnnotationRenderer.leaderStart(bubble: bubble, toward: CGPoint(x: 120, y: 10))
        XCTAssertEqual(start.x, 40, accuracy: 0.001)
        XCTAssertEqual(start.y, 10, accuracy: 0.001)
        let step = ScreenshotAnnotationRenderer.calloutBubble(
            kind: .step,
            center: CGPoint(x: 50, y: 50),
            textSize: CGSize(width: 8, height: 12),
            scale: 2
        )
        XCTAssertEqual(step.height, ScreenshotAnnotationRenderer.stepMarkerRadius * 4, accuracy: 0.001)
        XCTAssertEqual(step.midX, 50, accuracy: 0.001)
    }

    func testRendersStepAndTextCallouts() throws {
        let image = try XCTUnwrap(makeImage(width: 200, height: 200))
        let rendered = try ScreenshotAnnotationRenderer.render(image, annotations: [
            ScreenshotAnnotation(kind: .step, start: CGPoint(x: 0.25, y: 0.25), end: CGPoint(x: 0.25, y: 0.25), number: 1),
            ScreenshotAnnotation(kind: .text, start: CGPoint(x: 0.5, y: 0.75), end: CGPoint(x: 0.9, y: 0.95), text: "Tap"),
            ScreenshotAnnotation(kind: .text, start: CGPoint(x: 0.8, y: 0.2), end: CGPoint(x: 0.8, y: 0.2), text: " ")
        ])
        // Step marker is red at its rim, off the white digit.
        let marker = try XCTUnwrap(PixelSampler.color(in: rendered, at: CGPoint(x: 0.25 - 10.0 / 200, y: 0.25), source: .iOS))
        XCTAssertGreaterThan(marker.red, 200)
        XCTAssertLessThan(marker.blue, 120)
        // Text bubble is a dark pill.
        let pill = try XCTUnwrap(PixelSampler.color(in: rendered, at: CGPoint(x: 0.5 - 18.0 / 200, y: 0.75), source: .iOS))
        XCTAssertLessThan(pill.red + pill.green + pill.blue, 200)
        // An empty text callout draws nothing.
        let untouched = try XCTUnwrap(PixelSampler.color(in: rendered, at: CGPoint(x: 0.8, y: 0.2), source: .iOS))
        XCTAssertGreaterThan(untouched.blue, 150)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
