import XCTest
@testable import Viewport

@MainActor
final class WebViewModelTests: XCTestCase {
    func testAddsHTTPSWhenSchemeIsMissing() {
        XCTAssertEqual(
            WebViewModel.normalizedURL(from: "example.com")?.absoluteString,
            "https://example.com"
        )
    }

    func testPreservesLocalHTTPAddress() {
        XCTAssertEqual(
            WebViewModel.normalizedURL(from: "http://localhost:3000")?.absoluteString,
            "http://localhost:3000"
        )
    }

    func testRejectsNonWebSchemes() {
        XCTAssertNil(WebViewModel.normalizedURL(from: "javascript:alert(1)"))
        XCTAssertNil(WebViewModel.normalizedURL(from: ""))
    }

    func testInstallsDeveloperConsoleBridgeAtDocumentStart() {
        let model = WebViewModel()
        let scripts = model.webView.configuration.userContentController.userScripts

        // Console bridge (all frames) plus network overlay (main frame).
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.allSatisfy { $0.injectionTime == .atDocumentStart })
        XCTAssertFalse(scripts[0].isForMainFrameOnly)
        XCTAssertTrue(scripts[1].isForMainFrameOnly)
    }
}
