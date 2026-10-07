import XCTest
@testable import Viewport

@MainActor
final class UpdateTests: XCTestCase {
    func testOverlappingOperationsMustBothFinishBeforeRestart() throws {
        let activity = AppActivityStore()
        let recording = try activity.begin(.recording)
        let build = try activity.begin(.build)
        let installation = UpdateInstallationCoordinator(activity: activity)
        var installs = 0
        installation.postpone { installs += 1 }

        XCTAssertFalse(installation.resume())
        activity.end(recording)
        XCTAssertFalse(installation.resume())
        activity.end(build)
        XCTAssertEqual(installs, 0, "Becoming idle must not restart the app automatically")
        XCTAssertTrue(installation.resume())
        XCTAssertEqual(installs, 1)
        XCTAssertThrowsError(try activity.begin(.recording))
        XCTAssertFalse(installation.resume(), "Repeated clicks must not invoke installation twice")
    }

    func testCancelledTerminationCanRetryAndAbortClearsContinuation() throws {
        let activity = AppActivityStore()
        let installation = UpdateInstallationCoordinator(activity: activity)
        var installs = 0
        installation.postpone { installs += 1 }
        XCTAssertTrue(installation.resume())
        installation.cancelTermination()
        XCTAssertTrue(installation.hasPendingInstallation)
        let build = try activity.begin(.build)
        XCTAssertFalse(installation.resume())
        activity.end(build)
        XCTAssertTrue(installation.resume())
        XCTAssertEqual(installs, 2)
        installation.clear()
        XCTAssertFalse(installation.hasPendingInstallation)
        XCTAssertFalse(activity.isTerminating)
        XCTAssertFalse(installation.resume())
    }

    func testOrdinaryQuitCanReserveForRecordingButNotForBuild() throws {
        let activity = AppActivityStore()
        let recording = try activity.begin(.recording)
        XCTAssertFalse(activity.reserveTermination())
        XCTAssertTrue(activity.reserveTermination(allowRecording: true))
        XCTAssertThrowsError(try activity.begin(.build))
        activity.cancelTermination()
        let build = try activity.begin(.build)
        XCTAssertFalse(activity.reserveTermination(allowRecording: true))
        activity.end(build)
        activity.update(recording, to: .savingRecording)
        XCTAssertFalse(activity.reserveTermination(allowRecording: true))
        activity.end(recording)
        XCTAssertTrue(activity.reserveTermination())
    }

    func testUnrelatedUpdateCycleCannotReleaseOrdinaryQuitReservation() throws {
        let activity = AppActivityStore()
        let installation = UpdateInstallationCoordinator(activity: activity)
        XCTAssertTrue(activity.reserveTermination())
        installation.clear()
        XCTAssertTrue(activity.isTerminating)
        XCTAssertThrowsError(try activity.begin(.build))
    }

    func testRecordingCannotStartDuringTermination() async {
        let activity = AppActivityStore()
        XCTAssertTrue(activity.reserveTermination())
        let recording = WorkspaceRecordingService(activity: activity)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = WorkspaceStore(defaults: defaults)
        do {
            try await recording.start(web: WebViewModel(), workspace: workspace)
            XCTFail("Recording cannot begin while the app is terminating")
        } catch {
            XCTAssertEqual((error as NSError).domain, "Viewport.Activity")
            XCTAssertFalse(activity.isBusy)
        }
    }

    func testProductionUpdatesRequireExplicitConfigurationAndNeverRunInDebug() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "3",
            "ViewportUpdatesEnabled": true,
            "SUFeedURL": "https://longden.github.io/Viewport/updates/appcast.xml",
            "ViewportAppleSigningUpdates": true
        ]
        XCTAssertTrue(UpdateConfiguration(info: info, isDevelopmentBuild: false).isEnabled)
        XCTAssertFalse(UpdateConfiguration(info: info, isDevelopmentBuild: true).isEnabled)
        XCTAssertEqual(UpdateConfiguration(info: info, isDevelopmentBuild: false).installedVersion, "0.3.0 (3)")
        for (key, invalid) in [
            ("ViewportUpdatesEnabled", false as Any),
            ("ViewportAppleSigningUpdates", false as Any),
            ("SUPublicEDKey", "unexpected-key" as Any),
            ("SUPublicDSAKey", "unexpected-key" as Any),
            ("SUVerifyUpdateBeforeExtraction", true as Any),
            ("SURequireSignedFeed", true as Any),
            ("SUFeedURL", "http://example.com/feed.xml" as Any),
            ("SUFeedURL", "https://user:password@example.com/feed.xml" as Any)
        ] {
            var changed = info
            changed[key] = invalid
            XCTAssertFalse(UpdateConfiguration(info: changed, isDevelopmentBuild: false).isEnabled)
        }
    }

    func testDisabledControllerDoesNotStartSparkle() {
        let controller = UpdateController(
            activity: AppActivityStore(),
            configuration: UpdateConfiguration(info: [:], isDevelopmentBuild: true)
        )
        controller.start()
        XCTAssertFalse(controller.canCheckForUpdates)
    }
}
