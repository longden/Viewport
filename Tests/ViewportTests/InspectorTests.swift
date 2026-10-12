import CoreGraphics
import Foundation
import XCTest
@testable import Viewport

final class AndroidUIHierarchyParserTests: XCTestCase {
    private let xml = """
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
    <node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" bounds="[0,0][1080,2400]">\
    <node index="0" text="" resource-id="" class="android.widget.LinearLayout" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" bounds="[0,0][1080,2400]">\
    <node index="0" text="Sign in" resource-id="com.app:id/sign_in" class="android.widget.Button" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" bounds="[100,200][500,326]" />\
    <node index="1" text="" resource-id="" class="android.widget.ImageButton" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" bounds="[900,40][1000,140]" />\
    <node index="2" text="" resource-id="" class="android.widget.Switch" content-desc="Dark mode" checkable="true" checked="true" clickable="true" enabled="false" bounds="[0,400][1080,560]" />\
    </node></node></hierarchy>UI hierchary dumped to: /dev/tty
    """

    func testExtractsHierarchyFromDumpOutput() throws {
        let extracted = try XCTUnwrap(AndroidUIHierarchyParser.hierarchyXML(from: "noise " + xml))
        XCTAssertTrue(extracted.hasPrefix("<?xml"))
        XCTAssertTrue(extracted.hasSuffix("</hierarchy>"))
        XCTAssertNil(AndroidUIHierarchyParser.hierarchyXML(from: "ERROR: could not get idle state."))
    }

    func testParsesMeaningfulNodesNormalizedToTheScreen() throws {
        let snapshot = try AndroidUIHierarchyParser.parse(
            try XCTUnwrap(AndroidUIHierarchyParser.hierarchyXML(from: xml)),
            density: 420
        )
        XCTAssertEqual(snapshot.source, .android)
        XCTAssertEqual(snapshot.unit, "dp")
        // Layout containers without content are skipped.
        XCTAssertEqual(snapshot.elements.count, 3)

        let button = snapshot.elements[0]
        XCTAssertEqual(button.role, .button)
        XCTAssertEqual(button.text, "Sign in")
        XCTAssertEqual(button.identifier, "com.app:id/sign_in")
        XCTAssertEqual(button.frame.minX, 100.0 / 1080, accuracy: 0.0001)
        XCTAssertEqual(button.frame.minY, 200.0 / 2400, accuracy: 0.0001)
        XCTAssertEqual(button.size.width, 400 / 2.625, accuracy: 0.01)
        XCTAssertEqual(snapshot.screenSize.width, 1080 / 2.625, accuracy: 0.01)

        let icon = snapshot.elements[1]
        XCTAssertEqual(icon.role, .button)
        XCTAssertFalse(icon.hasAccessibleName)

        let toggle = snapshot.elements[2]
        XCTAssertEqual(toggle.role, .toggle)
        XCTAssertEqual(toggle.label, "Dark mode")
        XCTAssertEqual(toggle.value, "On")
        XCTAssertFalse(toggle.isEnabled)
    }

    func testParsesBoundsAndDensity() {
        XCTAssertEqual(
            AndroidUIHierarchyParser.parseBounds("[10,20][110,220]"),
            CGRect(x: 10, y: 20, width: 100, height: 200)
        )
        XCTAssertNil(AndroidUIHierarchyParser.parseBounds("[10,20]"))
        XCTAssertEqual(AndroidUIHierarchyParser.parseDensity("Physical density: 420\n"), 420)
        XCTAssertEqual(
            AndroidUIHierarchyParser.parseDensity("Physical density: 420\nOverride density: 480\n"),
            480
        )
    }

    func testNormalizesDialogWindowsAgainstTheDisplay() throws {
        // uiautomator's root is the dialog window, not the screen.
        let dialog = """
        <hierarchy rotation="0">\
        <node class="android.widget.FrameLayout" bounds="[60,800][1020,1600]">\
        <node text="OK" class="android.widget.Button" clickable="true" bounds="[540,1400][1000,1580]" />\
        </node></hierarchy>
        """
        let snapshot = try AndroidUIHierarchyParser.parse(
            dialog,
            density: 160,
            displaySize: CGSize(width: 1080, height: 2400)
        )
        let button = try XCTUnwrap(snapshot.elements.first)
        XCTAssertEqual(button.frame.minX, 540.0 / 1080, accuracy: 0.0001)
        XCTAssertEqual(button.frame.minY, 1400.0 / 2400, accuracy: 0.0001)
        XCTAssertEqual(snapshot.screenSize, CGSize(width: 1080, height: 2400))

        let landscape = try AndroidUIHierarchyParser.parse(
            dialog.replacingOccurrences(of: "rotation=\"0\"", with: "rotation=\"1\""),
            density: 160,
            displaySize: CGSize(width: 1080, height: 2400)
        )
        XCTAssertEqual(landscape.screenSize, CGSize(width: 2400, height: 1080))
    }

    func testParsesDisplaySize() {
        XCTAssertEqual(
            AndroidUIHierarchyParser.parseDisplaySize("Physical size: 1080x2400\n"),
            CGSize(width: 1080, height: 2400)
        )
        XCTAssertEqual(
            AndroidUIHierarchyParser.parseDisplaySize("Physical size: 1080x2400\nOverride size: 720x1600\n"),
            CGSize(width: 720, height: 1600)
        )
        XCTAssertNil(AndroidUIHierarchyParser.parseDisplaySize("error"))
    }

    func testRejectsHierarchyWithoutNodes() {
        XCTAssertThrowsError(
            try AndroidUIHierarchyParser.parse("<hierarchy rotation=\"0\"></hierarchy>")
        )
    }
}

final class IOSAccessibilityMapperTests: XCTestCase {
    func testMapsTranslatorEntriesAgainstTheApplicationFrame() {
        let entries: [[String: Any]] = [
            ["role": "AXApplication", "frame": NSValue(rect: NSRect(x: 0, y: 0, width: 402, height: 874)), "depth": 0],
            ["role": "AXButton", "label": "Photos", "identifier": "Photos",
             "frame": NSValue(rect: NSRect(x: 121, y: 289, width: 68, height: 91)), "depth": 1, "enabled": true],
            // Anonymous groups are dropped so they don't swallow hits.
            ["role": "AXGroup", "frame": NSValue(rect: NSRect(x: 0, y: 0, width: 402, height: 400)), "depth": 1],
            ["role": "AXButton", "label": "Close", "identifier": "closeButton",
             "frame": NSValue(rect: NSRect(x: 350, y: 60, width: 30, height: 30)), "depth": 2]
        ]
        let snapshot = IOSAccessibilityMapper.snapshot(from: entries)
        XCTAssertEqual(snapshot.screenSize, CGSize(width: 402, height: 874))
        XCTAssertEqual(snapshot.unit, "pt")
        XCTAssertEqual(snapshot.elements.count, 2)
        let photos = snapshot.elements[0]
        XCTAssertEqual(photos.role, .button)
        XCTAssertEqual(photos.label, "Photos")
        // UIKit mirrors the label into the identifier; don't report it twice.
        XCTAssertNil(photos.identifier)
        XCTAssertEqual(photos.frame.minX, 121.0 / 402, accuracy: 0.0001)
        XCTAssertEqual(photos.size, CGSize(width: 68, height: 91))
        XCTAssertEqual(snapshot.elements[1].identifier, "closeButton")
    }

    func testRoleMapping() {
        XCTAssertEqual(IOSAccessibilityMapper.role(for: "AXStaticText", subrole: nil), .text)
        XCTAssertEqual(IOSAccessibilityMapper.role(for: "AXButton", subrole: "AXTabButton"), .tab)
        XCTAssertEqual(IOSAccessibilityMapper.role(for: "AXSecureTextField", subrole: nil), .textField)
        XCTAssertEqual(IOSAccessibilityMapper.role(for: "AXSwitch", subrole: nil), .toggle)
        XCTAssertEqual(IOSAccessibilityMapper.role(for: "AXUnknownThing", subrole: nil), .other)
    }

    func testEmptyTranslatorResultYieldsEmptySnapshot() {
        XCTAssertTrue(IOSAccessibilityMapper.snapshot(from: []).elements.isEmpty)
    }
}

final class WebElementSnapshotTests: XCTestCase {
    func testParsesScriptPayload() throws {
        let json = """
        {"viewportWidth":400,"viewportHeight":800,"elements":[
          {"role":"button","tag":"button","label":"Sign in","text":"Sign in","identifier":"login",
           "value":null,"x":40,"y":80,"width":120,"height":40,"interactive":true,"enabled":true,"depth":3},
          {"role":"generic","tag":"div","label":null,"text":"Welcome back","identifier":null,
           "value":null,"x":0,"y":0,"width":400,"height":60,"interactive":false,"enabled":true,"depth":1}
        ]}
        """
        let snapshot = try WebElementSnapshot.parse(json)
        XCTAssertEqual(snapshot.unit, "px")
        XCTAssertEqual(snapshot.screenSize, CGSize(width: 400, height: 800))
        let button = snapshot.elements[0]
        XCTAssertEqual(button.role, .button)
        XCTAssertEqual(button.label, "Sign in")
        // Text equal to the label isn't repeated.
        XCTAssertNil(button.text)
        XCTAssertEqual(button.frame, CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05))
        XCTAssertEqual(snapshot.elements[1].role, .container)
        XCTAssertEqual(snapshot.elements[1].platformRole, "div")
    }

    func testRoleMapping() {
        XCTAssertEqual(WebElementSnapshot.role(for: "link"), .link)
        XCTAssertEqual(WebElementSnapshot.role(for: "searchbox"), .textField)
        XCTAssertEqual(WebElementSnapshot.role(for: "checkbox"), .toggle)
        XCTAssertEqual(WebElementSnapshot.role(for: "img"), .image)
        XCTAssertEqual(WebElementSnapshot.role(for: "combobox"), .picker)
    }
}

final class ElementSnapshotHitTestTests: XCTestCase {
    func testPrefersSmallestInteractiveElementUnderPoint() {
        let snapshot = makeSnapshot([
            element(0, .container, CGRect(x: 0, y: 0, width: 1, height: 1)),
            element(1, .button, CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.1), label: "Continue"),
            element(2, .text, CGRect(x: 0.15, y: 0.12, width: 0.25, height: 0.05), label: "Continue")
        ])
        // The label inside the button is smaller, but taps belong to the button.
        XCTAssertEqual(snapshot.hitTest(CGPoint(x: 0.2, y: 0.14))?.id, 1)
        XCTAssertEqual(snapshot.hitTest(CGPoint(x: 0.9, y: 0.9))?.id, 0)
    }

    func testPlatformDistance() {
        let snapshot = makeSnapshot([], screen: CGSize(width: 400, height: 800))
        XCTAssertEqual(snapshot.platformDistance(dx: 0.1, dy: -0.05), CGSize(width: 40, height: 40))
    }
}

final class ElementMatcherTests: XCTestCase {
    func testNormalizesNamesAndIdentifiers() {
        XCTAssertEqual(ElementMatcher.normalizedKey("  Sign-In!  "), "sign in")
        XCTAssertEqual(ElementMatcher.normalizedKey("Café"), "cafe")
        XCTAssertEqual(ElementMatcher.identifierKey("com.app:id/sign_in_button"), "signinbutton")
        XCTAssertEqual(ElementMatcher.identifierKey("signInButton"), "signinbutton")
    }

    func testFindsTheSameControlAcrossPlatforms() throws {
        let iOS = element(0, .button, CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.06), label: "Sign in")
        let android = makeSnapshot([
            element(0, .text, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.05), text: "Welcome"),
            element(1, .button, CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.06), text: "SIGN IN"),
            element(2, .link, CGRect(x: 0.1, y: 0.9, width: 0.3, height: 0.04), text: "Forgot password?")
        ])
        let match = try XCTUnwrap(ElementMatcher.bestMatch(for: iOS, in: android))
        XCTAssertEqual(match.element.id, 1)
        XCTAssertEqual(match.score, 1, accuracy: 0.001)
    }

    func testMatchesByIdentifierWhenLabelsDiffer() throws {
        let web = element(0, .button, .zero, label: "Log in", identifier: "sign-in-button")
        let iOS = makeSnapshot([
            element(0, .button, .zero, label: "Continue", identifier: "signInButton")
        ])
        XCTAssertEqual(try XCTUnwrap(ElementMatcher.bestMatch(for: web, in: iOS)).element.id, 0)
    }

    func testRejectsUnrelatedElements() {
        let source = element(0, .button, .zero, label: "Checkout")
        let other = makeSnapshot([element(0, .button, .zero, label: "Settings")])
        XCTAssertNil(ElementMatcher.bestMatch(for: source, in: other))
    }

    func testParityFindings() {
        let source = element(0, .button, .zero, label: "Sign in")
        let findings = ElementParityCheck.findings(
            for: source,
            in: .iOS,
            counterparts: [
                (.android, ElementMatcher.Match(element: element(1, .text, .zero, text: "Sign in now"), score: 0.7)),
                (.web, nil)
            ]
        )
        XCTAssertTrue(findings.contains { $0.kind == .labelDiffers && $0.source == .android })
        XCTAssertTrue(findings.contains { $0.kind == .roleDiffers && $0.source == .android })
        XCTAssertTrue(findings.contains { $0.kind == .missing && $0.source == .web })
    }
}

final class AccessibilityAuditTests: XCTestCase {
    func testFlagsUnlabelledAndSmallTargets() {
        let snapshot = makeSnapshot([
            element(0, .button, .zero, size: CGSize(width: 30, height: 30)),
            element(1, .button, .zero, label: "OK", size: CGSize(width: 80, height: 44)),
            element(2, .textField, .zero, label: "Email", size: CGSize(width: 300, height: 34)),
            element(3, .text, .zero, size: CGSize(width: 10, height: 10))
        ], source: .iOS)
        let issues = AccessibilityAudit.issues(in: snapshot)
        XCTAssertEqual(Set(issues.filter { $0.elementID == 0 }.map(\.kind)), [.missingLabel, .smallTarget])
        XCTAssertTrue(issues.filter { $0.elementID == 1 }.isEmpty)
        XCTAssertEqual(issues.filter { $0.elementID == 2 }.map(\.kind), [.smallTarget])
        XCTAssertTrue(issues.filter { $0.elementID == 3 }.isEmpty)
    }

    func testUsesPlatformMinimumsAndExemptsInlineWebLinks() {
        XCTAssertEqual(AccessibilityAudit.minimumTargetSize(for: .android), 48)
        let web = makeSnapshot([
            element(0, .link, .zero, label: "Learn more", size: CGSize(width: 80, height: 18)),
            element(1, .button, .zero, label: "Go", size: CGSize(width: 30, height: 30))
        ], source: .web)
        XCTAssertTrue(AccessibilityAudit.issues(in: web).isEmpty)
    }
}

final class InspectorOverlayGeometryTests: XCTestCase {
    func testAspectFitsDeviceFramesAndFillsWeb() {
        let frame = InspectorOverlayGeometry.contentFrame(
            in: CGSize(width: 400, height: 400),
            contentSize: CGSize(width: 1080, height: 2160)
        )
        XCTAssertEqual(frame, CGRect(x: 100, y: 0, width: 200, height: 400))
        XCTAssertEqual(
            InspectorOverlayGeometry.contentFrame(in: CGSize(width: 300, height: 500), contentSize: nil),
            CGRect(x: 0, y: 0, width: 300, height: 500)
        )
    }

    func testNormalizesRoundTripAndRejectsLetterbox() {
        let frame = CGRect(x: 100, y: 0, width: 200, height: 400)
        let point = CGPoint(x: 150, y: 100)
        let normalized = try? XCTUnwrap(InspectorOverlayGeometry.normalized(point, in: frame))
        XCTAssertEqual(normalized, CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(InspectorOverlayGeometry.point(CGPoint(x: 0.25, y: 0.25), in: frame), point)
        XCTAssertNil(InspectorOverlayGeometry.normalized(CGPoint(x: 50, y: 100), in: frame))
        XCTAssertEqual(
            InspectorOverlayGeometry.clampedNormalized(CGPoint(x: 50, y: 500), in: frame),
            CGPoint(x: 0, y: 1)
        )
        XCTAssertEqual(
            InspectorOverlayGeometry.rect(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.25), in: frame),
            CGRect(x: 200, y: 200, width: 100, height: 100)
        )
    }

    func testGridLinesAndColumns() {
        XCTAssertEqual(
            InspectorOverlayGeometry.gridLines(spacing: 0.25, length: 100, origin: 10),
            [35, 60, 85]
        )
        XCTAssertTrue(InspectorOverlayGeometry.gridLines(spacing: 0.001, length: 100, origin: 0).isEmpty)
        let columns = InspectorOverlayGeometry.columns(count: 2, margin: 20, gutter: 20, screenWidth: 200)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].lowerBound, 0.1, accuracy: 0.0001)
        XCTAssertEqual(columns[0].upperBound, 0.45, accuracy: 0.0001)
        XCTAssertEqual(columns[1].lowerBound, 0.55, accuracy: 0.0001)
    }
}

final class DesignToolsTests: XCTestCase {
    func testEstimatesSimulatorScale() {
        XCTAssertEqual(PaneMetrics.estimatedIOSScale(pixelSize: CGSize(width: 1206, height: 2622)), 3)
        XCTAssertEqual(PaneMetrics.estimatedIOSScale(pixelSize: CGSize(width: 750, height: 1334)), 2)
        XCTAssertEqual(PaneMetrics.estimatedIOSScale(pixelSize: CGSize(width: 2064, height: 2752)), 2)
        let metrics = PaneMetrics.estimated(
            for: .android,
            pixelSize: CGSize(width: 1080, height: 2400),
            androidDensity: 480
        )
        XCTAssertEqual(metrics, PaneMetrics(screenSize: CGSize(width: 360, height: 800), unit: "dp"))
        XCTAssertEqual(metrics.size(of: CGSize(width: -0.5, height: 0.1)), CGSize(width: 180, height: 80))
        XCTAssertEqual(metrics.normalizedSpacing(8).width, 8.0 / 360, accuracy: 0.0001)
    }

    func testSpacingBetweenFrames() {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let right = CGRect(x: 0.4, y: 0.15, width: 0.1, height: 0.1)
        let below = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1)
        XCTAssertEqual(ElementSpacing.between(a, right).horizontal ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertNil(ElementSpacing.between(a, right).vertical)
        XCTAssertEqual(ElementSpacing.between(below, a).vertical ?? 0, 0.2, accuracy: 0.0001)
    }

    func testMeasurementRectIsOrderIndependent() {
        let measurement = PaneMeasurement(
            paneID: UUID(),
            start: CGPoint(x: 0.6, y: 0.4),
            end: CGPoint(x: 0.2, y: 0.1)
        )
        XCTAssertEqual(measurement.rect.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(measurement.rect.height, 0.3, accuracy: 0.0001)
    }

    func testSamplesPixelsAndBuildsLoupe() throws {
        let image = try XCTUnwrap(makeSplitImage())
        let left = try XCTUnwrap(PixelSampler.color(in: image, at: CGPoint(x: 0.25, y: 0.5), source: .iOS))
        let right = try XCTUnwrap(PixelSampler.color(in: image, at: CGPoint(x: 0.75, y: 0.5), source: .iOS))
        XCTAssertEqual(left.hex, "#FF0000")
        XCTAssertEqual(right.hex, "#0000FF")
        XCTAssertEqual(right.rgbText, "rgb(0, 0, 255)")
        let loupe = try XCTUnwrap(PixelSampler.loupe(in: image, at: CGPoint(x: 0.5, y: 0.5), radius: 3))
        XCTAssertEqual(loupe.width, 7)
        // Edges clip the loupe rather than failing.
        XCTAssertEqual(PixelSampler.loupe(in: image, at: .zero, radius: 3)?.width, 4)
        XCTAssertEqual(PixelSampler.pixel(for: CGPoint(x: 1, y: 1), width: 10, height: 10).x, 9)
    }

    func testOverlayAspectCheck() throws {
        let overlay = DesignOverlay(url: URL(fileURLWithPath: "/mock.png"), image: try XCTUnwrap(makeSplitImage()))
        XCTAssertTrue(overlay.matchesAspect(of: CGSize(width: 200, height: 100)))
        XCTAssertFalse(overlay.matchesAspect(of: CGSize(width: 100, height: 200)))
    }

    /// 20×10 image: left half red, right half blue.
    private func makeSplitImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        return context.makeImage()
    }
}

// MARK: - Helpers

private func element(
    _ id: Int,
    _ role: ElementRole,
    _ frame: CGRect,
    label: String? = nil,
    text: String? = nil,
    identifier: String? = nil,
    size: CGSize = CGSize(width: 100, height: 50)
) -> InspectedElement {
    InspectedElement(
        id: id,
        role: role,
        platformRole: role.rawValue,
        label: label,
        text: text,
        identifier: identifier,
        value: nil,
        frame: frame,
        size: size,
        isInteractive: role.isInteractive,
        isEnabled: true,
        depth: 0
    )
}

private func makeSnapshot(
    _ elements: [InspectedElement],
    source: ViewerSource = .android,
    screen: CGSize = CGSize(width: 400, height: 800)
) -> ElementSnapshot {
    ElementSnapshot(
        source: source,
        elements: elements,
        screenSize: screen,
        unit: source == .iOS ? "pt" : (source == .web ? "px" : "dp"),
        capturedAt: Date()
    )
}
