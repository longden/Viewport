import Combine
import Foundation
import WebKit

@MainActor
final class WebViewModel: ObservableObject {
    @Published var address: String
    @Published private(set) var title = "Web"
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var isClearingData = false

    let webView: WKWebView

    private let dataCleaner: any WebsiteDataClearing
    private var hasLoadedInitialPage = false
    private var noticeGeneration = UUID()

    init(
        address: String = "https://example.com",
        dataCleaner: (any WebsiteDataClearing)? = nil
    ) {
        self.address = address
        self.dataCleaner = dataCleaner ?? WebsiteDataCleaner()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
    }

    var currentURL: URL? {
        webView.url ?? Self.normalizedURL(from: address)
    }

    func loadInitialPageIfNeeded() {
        guard !hasLoadedInitialPage else { return }
        hasLoadedInitialPage = true
        loadAddress()
    }

    func loadAddress() {
        guard let url = Self.normalizedURL(from: address) else {
            errorMessage = "Enter a valid web address."
            return
        }

        errorMessage = nil
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        address = url.absoluteString
        loadAddress()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func clearCookies() {
        clearWebsiteData(.cookies)
    }

    func clearAllWebsiteData() {
        clearWebsiteData(.allData)
    }

    func navigationDidStart() {
        isLoading = true
        errorMessage = nil
        updateNavigationState()
    }

    func navigationDidFinish() {
        isLoading = false
        updateNavigationState()
    }

    func navigationDidFail(_ error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        updateNavigationState()
    }

    func updateNavigationState() {
        if canGoBack != webView.canGoBack {
            canGoBack = webView.canGoBack
        }
        if canGoForward != webView.canGoForward {
            canGoForward = webView.canGoForward
        }

        if let currentURL = webView.url {
            let updatedAddress = currentURL.absoluteString
            if address != updatedAddress {
                address = updatedAddress
            }
        }

        if let pageTitle = webView.title,
           !pageTitle.isEmpty,
           title != pageTitle {
            title = pageTitle
        }
    }

    private func clearWebsiteData(_ scope: WebsiteDataScope) {
        guard !isClearingData else { return }
        isClearingData = true

        Task { [weak self] in
            guard let self else { return }

            await dataCleaner.clear(scope)
            self.isClearingData = false

            switch scope {
            case .cookies:
                self.showNotice("Cookies cleared")
            case .allData:
                self.showNotice("Website data cleared")
            }

            self.reload()
        }
    }

    private func showNotice(_ message: String) {
        let generation = UUID()
        noticeGeneration = generation
        noticeMessage = message

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self,
                  self.noticeGeneration == generation else {
                return
            }
            self.noticeMessage = nil
        }
    }

    nonisolated static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme,
           !scheme.isEmpty {
            guard ["http", "https"].contains(scheme.lowercased()) else {
                return nil
            }
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        return url
    }
}
