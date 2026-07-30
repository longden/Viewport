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

    private func waitForClear(
        on cleaner: RecordingWebsiteDataCleaner
    ) async {
        for _ in 0..<20 where cleaner.scopes.isEmpty {
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
