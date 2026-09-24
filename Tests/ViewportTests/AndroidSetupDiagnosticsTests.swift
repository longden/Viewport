import XCTest
@testable import Viewport

final class AndroidSetupDiagnosticsTests: XCTestCase {
    func testNeededInstallGuidesHidesSatisfiedEntries() {
        let report = AndroidSetupReport(
            items: [
                ready("sdk"),
                ready("adb"),
                ready("emulator"),
                missing("android-cli"),
                ready("system-images"),
                ready("scrcpy"),
                ready("simslim"),
                ready("xcode"),
                ready("avds")
            ],
            canCreateEmulators: false,
            canLaunchEmulators: true,
            existingEmulatorCount: 1
        )

        let neededIDs = report.neededInstallGuides.map(\.id)
        XCTAssertEqual(neededIDs, ["android-cli"])
    }

    func testAndroidStudioGuideRequiresSDKEmulatorAndImages() {
        let partial = AndroidSetupReport(
            items: [
                ready("sdk"),
                ready("adb"),
                ready("emulator"),
                missing("system-images"),
                optionalMissing("scrcpy"),
                optionalMissing("simslim"),
                missing("xcode")
            ],
            canCreateEmulators: false,
            canLaunchEmulators: true,
            existingEmulatorCount: 0
        )

        XCTAssertFalse(SetupInstallGuides.androidStudio.isSatisfied(by: partial))
        XCTAssertTrue(SetupInstallGuides.adb.isSatisfied(by: partial))
        XCTAssertFalse(SetupInstallGuides.scrcpy.isSatisfied(by: partial))
        XCTAssertFalse(SetupInstallGuides.xcode.isSatisfied(by: partial))

        let neededIDs = Set(partial.neededInstallGuides.map(\.id))
        XCTAssertTrue(neededIDs.contains("android-studio"))
        XCTAssertFalse(neededIDs.contains("adb"))
        XCTAssertTrue(neededIDs.contains("scrcpy"))
        XCTAssertTrue(neededIDs.contains("simslim"))
        XCTAssertTrue(neededIDs.contains("xcode"))
    }

    func testPhysicalAndroidTipWhenADBReadyButEmulatorStackIncomplete() {
        let report = AndroidSetupReport(
            items: [
                missing("sdk"),
                ready("adb"),
                missing("emulator"),
                missing("system-images")
            ],
            canCreateEmulators: false,
            canLaunchEmulators: false,
            existingEmulatorCount: 0
        )

        XCTAssertTrue(report.supportsPhysicalAndroid)
        XCTAssertFalse(report.hasEmulatorRuntime)
        XCTAssertTrue(report.shouldShowPhysicalAndroidTip)
    }

    func testPhysicalAndroidTipHiddenWhenEmulatorRuntimeReady() {
        let report = AndroidSetupReport(
            items: [
                ready("sdk"),
                ready("adb"),
                ready("emulator"),
                ready("system-images")
            ],
            canCreateEmulators: true,
            canLaunchEmulators: true,
            existingEmulatorCount: 2
        )

        XCTAssertFalse(report.shouldShowPhysicalAndroidTip)
    }

    func testBrewRequirementDetection() {
        XCTAssertTrue(SetupTerminalInstaller.requiresBrew("brew install scrcpy"))
        XCTAssertTrue(
            SetupTerminalInstaller.requiresBrew(SimSlimClient.installCommand)
        )
        XCTAssertTrue(
            SetupTerminalInstaller.requiresBrew(
                "brew tap android/tap && brew install android-cli"
            )
        )
        XCTAssertFalse(SetupTerminalInstaller.requiresBrew("echo hello"))
    }

    func testSimSlimInstallUsesLocatedHomebrewBinary() throws {
        let command = try SetupTerminalInstaller.terminalCommand(
            for: SimSlimClient.installCommand,
            brewExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        )
        XCTAssertEqual(command, "'/opt/homebrew/bin/brew' install mobai-app/tap/simslim")
    }

    func testSimSlimInstallReportsMissingHomebrew() {
        XCTAssertThrowsError(
            try SetupTerminalInstaller.terminalCommand(
                for: SimSlimClient.installCommand,
                brewExecutable: nil
            )
        ) { error in
            guard case SetupTerminalInstaller.InstallError.brewMissing = error else {
                return XCTFail("Expected missing Homebrew, got \(error)")
            }
        }
    }

    private func ready(_ id: String) -> SetupCheckItem {
        SetupCheckItem(id: id, title: id, status: .ready, detail: "ok")
    }

    private func missing(_ id: String) -> SetupCheckItem {
        SetupCheckItem(id: id, title: id, status: .missing, detail: "missing")
    }

    private func optionalMissing(_ id: String) -> SetupCheckItem {
        SetupCheckItem(id: id, title: id, status: .optionalMissing, detail: "optional")
    }
}
