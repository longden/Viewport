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

    /// Soft identity for Resource Timing merges (URL + rough start bucket).
    var dedupeKey: String {
        "\(method.uppercased())|\(url)|\(Int((durationMS ?? 0).rounded()))"
    }
}

/// Web-first network overlay fed by Resource Timing + fetch/XHR hooks.
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
        guard enabled != isEnabled else {
            if enabled {
                reapplyEnabledFlag()
            }
            return
        }
        isEnabled = enabled
        reapplyEnabledFlag()
        if !enabled {
            entries = []
        } else {
            refreshFromPerformance()
        }
    }

    /// Re-push the enabled flag after navigations reset document-start scripts.
    func reapplyEnabledFlag() {
        let script =
            "window.__viewportNetworkOverlayEnabled = \(isEnabled ? "true" : "false");"
        webView?.evaluateJavaScript(script, completionHandler: nil)
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
        insert(entry)
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
        var seen = Set(entries.map(\.dedupeKey))
        var combined = entries
        for entry in mapped where !seen.contains(entry.dedupeKey) {
            seen.insert(entry.dedupeKey)
            combined.insert(entry, at: 0)
        }
        if combined.count > maximumEntries {
            combined = Array(combined.prefix(maximumEntries))
        }
        entries = combined
    }

    private func insert(_ entry: WebNetworkEntry) {
        if let existing = entries.firstIndex(where: { $0.dedupeKey == entry.dedupeKey }) {
            entries.remove(at: existing)
        }
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries = Array(entries.prefix(maximumEntries))
        }
    }

    private static let performanceDumpScript = """
    (() => {
      const entries = performance.getEntriesByType('resource').slice(-80);
      return entries.map((entry) => ({
        url: entry.name || '',
        method: (entry.initiatorType === 'xmlhttprequest' ? 'XHR' : 'GET'),
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
      const resolveRequest = (args) => {
        let method = 'GET';
        let url = '';
        try {
          const input = args[0];
          const init = args[1];
          if (typeof input === 'string') url = input;
          else if (input && input.url) {
            url = input.url;
            if (input.method) method = input.method;
          }
          if (init && init.method) method = init.method;
        } catch (_) {}
        return { method, url };
      };
      if (window.fetch) {
        const original = window.fetch.bind(window);
        window.fetch = async (...args) => {
          const started = performance.now();
          const { method, url } = resolveRequest(args);
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
      if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {
        const open = window.XMLHttpRequest.prototype.open;
        const send = window.XMLHttpRequest.prototype.send;
        window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          this.__viewportMethod = method || 'GET';
          this.__viewportURL = typeof url === 'string' ? url : String(url || '');
          return open.call(this, method, url, ...rest);
        };
        window.XMLHttpRequest.prototype.send = function(...args) {
          const started = performance.now();
          const method = this.__viewportMethod || 'GET';
          const url = this.__viewportURL || '';
          this.addEventListener('loadend', () => {
            post({
              url,
              method,
              status: this.status || 0,
              durationMS: performance.now() - started,
              transferSize: null
            });
          });
          return send.apply(this, args);
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
