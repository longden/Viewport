import Combine
import Foundation
import WebKit

struct WebNetworkEntry: Identifiable, Equatable {
    let id: UUID
    let url: String
    let method: String
    let status: Int?
    let durationMS: Double?
    let transferSize: Int?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        url: String,
        method: String,
        status: Int?,
        durationMS: Double?,
        transferSize: Int?,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.status = status
        self.durationMS = durationMS
        self.transferSize = transferSize
        self.timestamp = timestamp
    }
}

/// Web-first network overlay fed by Resource Timing + fetch hooks.
@MainActor
final class WebNetworkOverlayModel: ObservableObject {
    @Published private(set) var entries: [WebNetworkEntry] = []
    @Published private(set) var isEnabled = false

    private static let handlerName = "viewportNetworkOverlay"
    private let maximumEntries = 200
    private weak var webView: WKWebView?

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.add(
            WeakNetworkScriptHandler(delegate: self),
            name: Self.handlerName
        )
        controller.addUserScript(
            WKUserScript(
                source: Self.bridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    func bind(to webView: WKWebView) {
        self.webView = webView
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        let script =
            "window.__viewportNetworkOverlayEnabled = \(enabled ? "true" : "false");"
        webView?.evaluateJavaScript(script, completionHandler: nil)
        if !enabled {
            entries = []
        } else {
            refreshFromPerformance()
        }
    }

    func clear() {
        entries = []
    }

    func refreshFromPerformance() {
        guard isEnabled, let webView else { return }
        webView.evaluateJavaScript(Self.performanceDumpScript) {
            [weak self] result, _ in
            guard let rows = result as? [[String: Any]] else { return }
            Task { @MainActor [weak self] in
                self?.merge(rows)
            }
        }
    }

    fileprivate func handleMessage(_ body: Any) {
        guard isEnabled,
              let payload = body as? [String: Any],
              let url = payload["url"] as? String else { return }
        let entry = WebNetworkEntry(
            url: String(url.prefix(2_048)),
            method: (payload["method"] as? String) ?? "GET",
            status: payload["status"] as? Int,
            durationMS: payload["durationMS"] as? Double,
            transferSize: payload["transferSize"] as? Int
        )
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries = Array(entries.prefix(maximumEntries))
        }
    }

    private func merge(_ rows: [[String: Any]]) {
        let mapped = rows.compactMap { row -> WebNetworkEntry? in
            guard let url = row["url"] as? String else { return nil }
            return WebNetworkEntry(
                url: String(url.prefix(2_048)),
                method: (row["method"] as? String) ?? "GET",
                status: row["status"] as? Int,
                durationMS: row["durationMS"] as? Double,
                transferSize: row["transferSize"] as? Int
            )
        }
        guard !mapped.isEmpty else { return }
        var combined = mapped + entries
        if combined.count > maximumEntries {
            combined = Array(combined.prefix(maximumEntries))
        }
        entries = combined
    }

    private static let performanceDumpScript = """
    (() => {
      const entries = performance.getEntriesByType('resource').slice(-80);
      return entries.map((entry) => ({
        url: entry.name || '',
        method: 'GET',
        status: null,
        durationMS: entry.duration || 0,
        transferSize: entry.transferSize || 0
      }));
    })()
    """

    private static let bridgeScript = """
    (() => {
      if (window.__viewportNetworkOverlayInstalled) return;
      Object.defineProperty(window, '__viewportNetworkOverlayInstalled', {
        value: true,
        configurable: false
      });
      window.__viewportNetworkOverlayEnabled = false;
      const post = (payload) => {
        try {
          if (!window.__viewportNetworkOverlayEnabled) return;
          window.webkit.messageHandlers.viewportNetworkOverlay.postMessage(payload);
        } catch (_) {}
      };
      if (window.fetch) {
        const original = window.fetch.bind(window);
        window.fetch = async (...args) => {
          const started = performance.now();
          let method = 'GET';
          let url = '';
          try {
            if (typeof args[0] === 'string') url = args[0];
            else if (args[0] && args[0].url) url = args[0].url;
            if (args[1] && args[1].method) method = args[1].method;
          } catch (_) {}
          try {
            const response = await original(...args);
            post({
              url,
              method,
              status: response.status,
              durationMS: performance.now() - started,
              transferSize: null
            });
            return response;
          } catch (error) {
            post({
              url,
              method,
              status: 0,
              durationMS: performance.now() - started,
              transferSize: null
            });
            throw error;
          }
        };
      }
    })();
    """
}

private final class WeakNetworkScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WebNetworkOverlayModel?

    init(delegate: WebNetworkOverlayModel) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor [weak delegate] in
            delegate?.handleMessage(message.body)
        }
    }
}
