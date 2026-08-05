import XCTest
@testable import Viewport

@MainActor
final class WebViewDataTests: XCTestCase {
    func testClearCookiesUsesCookieOnlyScope() async {
        let cleaner = RecordingWebsiteDataCleaner()
        let model = WebViewModel(dataCleaner: cleaner)

        model.clearCookies()
        await waitForClear(on: cleaner)

        XCTAssertEqual(cleaner.scopes, [.cookies])
        XCTAssertEqual(model.noticeMessage, "Cookies cleared")
        XCTAssertFalse(model.isClearingData)
    }

    func testClearAllWebsiteDataUsesAllDataScope() async {
        let cleaner = RecordingWebsiteDataCleaner()
        let model = WebViewModel(dataCleaner: cleaner)

        model.clearAllWebsiteData()
        await waitForClear(on: cleaner)

        XCTAssertEqual(cleaner.scopes, [.allData])
        XCTAssertEqual(model.noticeMessage, "Website data cleared")
        XCTAssertFalse(model.isClearingData)
    }

    func testClearCookiesAndWebsiteDataClearsBothScopes() async {
        let cleaner = RecordingWebsiteDataCleaner()
        let model = WebViewModel(dataCleaner: cleaner)

        model.clearCookiesAndWebsiteData()
        await waitForClearCount(on: cleaner, count: 2)

        XCTAssertEqual(cleaner.scopes, [.cookies, .allData])
        XCTAssertEqual(model.noticeMessage, "Cookies and website data cleared")
        XCTAssertFalse(model.isClearingData)
    }

    private func waitForClear(
        on cleaner: RecordingWebsiteDataCleaner
    ) async {
        await waitForClearCount(on: cleaner, count: 1)
    }

    private func waitForClearCount(
        on cleaner: RecordingWebsiteDataCleaner,
        count: Int
    ) async {
        for _ in 0..<40 where cleaner.scopes.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class RecordingWebsiteDataCleaner: WebsiteDataClearing {
    private(set) var scopes: [WebsiteDataScope] = []

    func clear(_ scope: WebsiteDataScope) async {
        scopes.append(scope)
    }
}
