import Foundation
import XCTest
@testable import Viewport

final class ProjectBuildPlayTests: XCTestCase {
    func testIsXcodeProjectRecognizesProjectAndWorkspace() {
        XCTAssertTrue(
            ProjectBuildPlayService.isXcodeProject(
                URL(fileURLWithPath: "/dev/MyApp.xcodeproj")
            )
        )
        XCTAssertTrue(
            ProjectBuildPlayService.isXcodeProject(
                URL(fileURLWithPath: "/dev/MyApp.xcworkspace")
            )
        )
        XCTAssertFalse(
            ProjectBuildPlayService.isXcodeProject(
                URL(fileURLWithPath: "/dev/MyApp")
            )
        )
    }

    func testIsGradleProjectRecognizesGradleRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(ProjectBuildPlayService.isGradleProject(at: root))

        try Data().write(to: root.appendingPathComponent("build.gradle"))
        XCTAssertTrue(ProjectBuildPlayService.isGradleProject(at: root))
    }

    func testParseSchemesFromProjectJSON() throws {
        let json = """
        {
          "project": {
            "name": "Demo",
            "schemes": ["Beta", "Demo"]
          }
        }
        """.data(using: .utf8)!
        XCTAssertEqual(
            ProjectBuildPlayService.parseSchemes(from: json),
            ["Beta", "Demo"]
        )
    }

    func testParseSchemesFromWorkspaceJSON() throws {
        let json = """
        {
          "workspace": {
            "name": "Demo",
            "schemes": ["WorkspaceScheme"]
          }
        }
        """.data(using: .utf8)!
        XCTAssertEqual(
            ProjectBuildPlayService.parseSchemes(from: json),
            ["WorkspaceScheme"]
        )
    }

    func testIsSafeXcodeSchemeRejectsFlagInjection() {
        XCTAssertTrue(ProjectBuildPlayService.isSafeXcodeScheme("Demo"))
        XCTAssertTrue(ProjectBuildPlayService.isSafeXcodeScheme("My App"))
        XCTAssertFalse(ProjectBuildPlayService.isSafeXcodeScheme("-scheme"))
        XCTAssertFalse(ProjectBuildPlayService.isSafeXcodeScheme("../Evil"))
        XCTAssertFalse(ProjectBuildPlayService.isSafeXcodeScheme(""))
    }

    func testBundleIdentifierFromInfoPlistXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>com.example.viewport</string>
        </dict>
        </plist>
        """
        XCTAssertEqual(
            ProjectBuildPlayService.bundleIdentifier(fromInfoPlistXML: xml),
            "com.example.viewport"
        )
    }

    func testParsePackageNameFromAaptBadging() {
        let output = """
        package: name='com.example.app' versionCode='1' versionName='1.0'
        launchable-activity: name='com.example.app.MainActivity'
        """
        XCTAssertEqual(
            ProjectBuildPlayService.parsePackageName(fromBadging: output),
            "com.example.app"
        )
    }
}
