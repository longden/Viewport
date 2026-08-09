import Combine
import XCTest
@testable import Viewport

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "WorkspaceStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testVisibilityPreservesPlatformOrder() {
        let store = WorkspaceStore(defaults: defaults)

        store.setVisible(false, for: .android)

        XCTAssertEqual(store.orderedVisibleSources, [.web, .iOS])
    }

    func testCannotHideLastVisiblePane() {
        let store = WorkspaceStore(defaults: defaults)

        store.setVisible(false, for: .android)
        store.setVisible(false, for: .iOS)
        store.setVisible(false, for: .web)

        XCTAssertEqual(store.orderedVisibleSources, [.web])
    }

    func testVisibilityPersists() {
        let store = WorkspaceStore(defaults: defaults)
        store.setVisible(false, for: .web)

        let restored = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(restored.orderedVisibleSources, [.android, .iOS])
    }

    func testEveryNonEmptyVisibilityCombinationPreservesPlatformOrder() {
        for mask in 1..<(1 << ViewerSource.allCases.count) {
            defaults.removePersistentDomain(forName: suiteName)
            let store = WorkspaceStore(defaults: defaults)
            let expected = ViewerSource.allCases.enumerated().compactMap {
                index, source in
                mask & (1 << index) == 0 ? nil : source
            }

            for source in ViewerSource.allCases where !expected.contains(source) {
                store.setVisible(false, for: source)
            }

            XCTAssertEqual(store.orderedVisibleSources, expected)
        }
    }

    func testPaneWeightsSurviveVisibilityChangesAndRelaunch() {
        let store = WorkspaceStore(defaults: defaults)
        store.resizePanes(
            leading: .web,
            leadingWeight: 1.6,
            trailing: .android,
            trailingWeight: 0.4,
            persist: true
        )
        store.setVisible(false, for: .web)
        store.setVisible(true, for: .web)

        XCTAssertEqual(store.paneWeight(for: .web), 1.6)
        XCTAssertEqual(store.paneWeight(for: .android), 0.4)

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(restored.paneWeight(for: .web), 1.6)
        XCTAssertEqual(restored.paneWeight(for: .android), 0.4)
    }

    func testPaneResizePublishesOneAtomicWeightChange() {
        let store = WorkspaceStore(defaults: defaults)
        var updates = 0
        let observation = store.$paneWeights
            .dropFirst()
            .sink { _ in updates += 1 }

        store.resizePanes(
            leading: .web,
            leadingWeight: 1.25,
            trailing: .android,
            trailingWeight: 0.75,
            persist: false
        )

        XCTAssertEqual(updates, 1)
        XCTAssertEqual(store.paneWeight(for: .web), 1.25)
        XCTAssertEqual(store.paneWeight(for: .android), 0.75)
        withExtendedLifetime(observation) {}
    }

    func testPerformanceProfilePersists() {
        let store = WorkspaceStore(defaults: defaults)
        store.setPerformanceProfile(.sharp)

        let restored = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(restored.performanceProfile, .sharp)
    }

    func testCanAddSecondAndroidPaneAndPersistLayout() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.orderedVisiblePanes.count, 3)
        XCTAssertTrue(store.addPane(.android))
        XCTAssertEqual(store.paneCount(of: .android), 2)
        XCTAssertEqual(store.orderedVisiblePanes.count, 4)
        XCTAssertFalse(store.addPane(.iOS))

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(restored.paneCount(of: .android), 2)
        XCTAssertEqual(restored.orderedVisiblePanes.count, 4)
    }

    func testRemoveExtraPaneKeepsPrimary() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.iOS))
        XCTAssertTrue(store.removeExtraPane(.iOS))
        XCTAssertEqual(store.paneCount(of: .iOS), 1)
        XCTAssertTrue(store.isVisible(.iOS))
    }

    func testRemovePaneByIDOnlyRemovesExtraSlot() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.android))
        let extraID = store.orderedVisiblePanes.first {
            $0.source == ViewerSource.android.rawValue && $0.slot >= 1
        }?.id
        XCTAssertNotNil(extraID)
        let primaryID = store.orderedVisiblePanes.first {
            $0.source == ViewerSource.android.rawValue && $0.slot == 0
        }?.id
        XCTAssertNotNil(primaryID)

        XCTAssertFalse(store.removePane(id: primaryID!))
        XCTAssertEqual(store.paneCount(of: .android), 2)

        XCTAssertTrue(store.removePane(id: extraID!))
        XCTAssertEqual(store.paneCount(of: .android), 1)
        XCTAssertTrue(store.isVisible(.android))
    }

    func testHidingPlatformRemovesAllItsPanes() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.android))
        store.setVisible(false, for: .android)
        XCTAssertEqual(store.paneCount(of: .android), 0)
        XCTAssertFalse(store.isVisible(.android))
        XCTAssertEqual(store.orderedVisiblePanes.count, 2)
    }

    func testCaptureModeDefaultsToDirect() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.captureMode, .direct)
    }

    func testCaptureModePersists() {
        let store = WorkspaceStore(defaults: defaults)
        store.setCaptureMode(.classic)

        let restored = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(restored.captureMode, .classic)
    }

    func testScreenshotPlatformLabelsPersist() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertFalse(store.screenshotPlatformLabelsEnabled)

        store.setScreenshotPlatformLabelsEnabled(true)

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(restored.screenshotPlatformLabelsEnabled)
    }
}
