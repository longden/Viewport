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
}
