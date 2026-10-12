import Combine
import Foundation
import Network
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
    @Published private(set) var viewportPreset: WebViewportPreset

    let webView: WKWebView

    private let dataCleaner: any WebsiteDataClearing
    private let consoleBridge: WebConsoleBridge
    private let defaults: UserDefaults
    private let viewportPresetKey: String
    private var consoleCaptureEnabled = false
    private(set) var geolocationOverride: GeoCoordinate?
    @Published private(set) var proxySettings: ProxySettings?
    private(set) var proxyCertificate: ProxyCertificate?
    private var hasLoadedInitialPage = false
    private var noticeGeneration = UUID()

    init(
        address: String = "https://example.com",
        dataCleaner: (any WebsiteDataClearing)? = nil,
        defaults: UserDefaults = .standard,
        viewportPresetKey: String = "webViewportPreset",
        onConsoleMessage: @escaping WebConsoleBridge.MessageHandler = {
            _, _, _ in
        }
    ) {
        self.address = address
        self.dataCleaner = dataCleaner ?? WebsiteDataCleaner()
        self.defaults = defaults
        self.viewportPresetKey = viewportPresetKey
        let consoleBridge = WebConsoleBridge(onMessage: onConsoleMessage)
        self.consoleBridge = consoleBridge

        viewportPreset = WebViewportPreset.resolved(
            rawValue: defaults.string(forKey: viewportPresetKey)
        ) ?? .fillPane

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        consoleBridge.install(in: configuration)
        // Installed up front so watches a page starts before an override is set
        // can still be moved onto the simulated position.
        configuration.userContentController.addUserScript(
            WebGeolocationOverride.userScript(initial: nil)
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
        applyViewportPreset(viewportPreset, reloadIfNeeded: false)
    }

    func setViewportPreset(_ preset: WebViewportPreset) {
        guard preset != viewportPreset else { return }
        viewportPreset = preset
        defaults.set(preset.rawValue, forKey: viewportPresetKey)
        applyViewportPreset(preset, reloadIfNeeded: hasLoadedInitialPage)
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

    /// Prototype helper for synchronized scrolling from device gestures.
    func scrollBy(deltaY: Double) {
        let dy = Int(deltaY.rounded())
        guard dy != 0 else { return }
        webView.evaluateJavaScript(
            "window.scrollBy(0, \(dy));",
            completionHandler: nil
        )
    }

    /// Routes web pane traffic through an HTTP CONNECT proxy. The optional CA
    /// is trusted for this web view only, so HTTPS interception works without
    /// adding it to the login keychain.
    func setProxy(_ settings: ProxySettings?, certificate: ProxyCertificate?) {
        let store = webView.configuration.websiteDataStore
        if let settings,
           settings.isValid,
           let port = NWEndpoint.Port(rawValue: UInt16(settings.port)) {
            proxySettings = settings
            proxyCertificate = certificate
            store.proxyConfigurations = [
                ProxyConfiguration(
                    httpCONNECTProxy: .hostPort(
                        host: NWEndpoint.Host(settings.trimmedHost),
                        port: port
                    )
                )
            ]
        } else {
            proxySettings = nil
            proxyCertificate = nil
            store.proxyConfigurations = []
        }
        if webView.url != nil {
            webView.reload()
        }
    }

    /// Accepts server certificates signed by the configured proxy CA.
    func acceptsProxyServerTrust(_ trust: SecTrust) -> Bool {
        guard proxySettings != nil, let proxyCertificate else { return false }
        return proxyCertificate.evaluate(trust)
    }

    /// Simulated position for `navigator.geolocation`; `nil` restores WebKit's.
    func setGeolocationOverride(_ coordinate: GeoCoordinate?) {
        geolocationOverride = coordinate
        reinstallUserScripts()
        // The document-start script only reaches new documents; patch the open
        // page too (the script ignores a second install), then move it.
        webView.evaluateJavaScript(
            WebGeolocationOverride.source(initial: coordinate)
                + WebGeolocationOverride.updateScript(coordinate),
            completionHandler: nil
        )
    }

    /// Updates the position without touching the document-start script; used
    /// for route playback so later reloads still start at the live position.
    func moveGeolocationOverride(to coordinate: GeoCoordinate) {
        guard geolocationOverride != nil else {
            setGeolocationOverride(coordinate)
            return
        }
        geolocationOverride = coordinate
        webView.evaluateJavaScript(
            WebGeolocationOverride.updateScript(coordinate),
            completionHandler: nil
        )
    }

    private func reinstallUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        consoleBridge.addUserScript(to: controller)
        // New documents start at this position; `__viewportSetGeo` moves it.
        controller.addUserScript(
            WebGeolocationOverride.userScript(initial: geolocationOverride)
        )
    }

    func setConsoleCaptureEnabled(_ enabled: Bool) {
        consoleCaptureEnabled = enabled
        consoleBridge.setEnabled(enabled, in: webView)
    }

    func clearCookies() {
        clearWebsiteData([.cookies], notice: "Cookies cleared")
    }

    func clearAllWebsiteData() {
        clearWebsiteData([.allData], notice: "Website data cleared")
    }

    func clearCookiesAndWebsiteData() {
        clearWebsiteData(
            [.cookies, .allData],
            notice: "Cookies and website data cleared"
        )
    }

    func navigationDidStart() {
        isLoading = true
        errorMessage = nil
        updateNavigationState()
    }

    func navigationDidFinish() {
        isLoading = false
        updateNavigationState()
        // User scripts reset page flags on each document; re-apply capture state.
        consoleBridge.setEnabled(consoleCaptureEnabled, in: webView)
        if let geolocationOverride {
            webView.evaluateJavaScript(
                WebGeolocationOverride.updateScript(geolocationOverride),
                completionHandler: nil
            )
        }
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

    private func applyViewportPreset(
        _ preset: WebViewportPreset,
        reloadIfNeeded: Bool
    ) {
        let previousAgent = webView.customUserAgent
        webView.customUserAgent = preset.customUserAgent
        webView.configuration.defaultWebpagePreferences.preferredContentMode =
            preset.prefersMobileContent ? .mobile : .desktop

        guard reloadIfNeeded,
              previousAgent != preset.customUserAgent,
              webView.url != nil else {
            return
        }
        webView.reload()
    }

    private func clearWebsiteData(
        _ scopes: [WebsiteDataScope],
        notice: String
    ) {
        guard !isClearingData, !scopes.isEmpty else { return }
        isClearingData = true

        Task { [weak self] in
            guard let self else { return }

            for scope in scopes {
                await dataCleaner.clear(scope)
            }
            self.isClearingData = false
            self.showNotice(notice)
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
