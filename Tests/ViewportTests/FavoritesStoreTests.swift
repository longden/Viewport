import XCTest
@testable import Viewport

@MainActor
final class FavoritesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "FavoritesStoreTests"

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

    func testAddsDeduplicatesAndPersistsSites() throws {
        let store = FavoritesStore(defaults: defaults)
        let url = try XCTUnwrap(URL(string: "https://example.com/"))

        store.add(title: "Example", url: url)
        store.add(title: "Updated Example", url: url)

        XCTAssertEqual(store.sites.count, 1)
        XCTAssertEqual(store.sites.first?.title, "Updated Example")

        let restored = FavoritesStore(defaults: defaults)
        XCTAssertEqual(restored.sites, store.sites)
    }

    func testRemovesCurrentSite() throws {
        let store = FavoritesStore(defaults: defaults)
        let url = try XCTUnwrap(URL(string: "https://example.com/"))

        store.add(title: "Example", url: url)
        XCTAssertTrue(store.contains(url: url))

        store.remove(url: url)
        XCTAssertFalse(store.contains(url: url))
    }
}
