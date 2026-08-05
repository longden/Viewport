import Foundation
import WebKit

final class WebConsoleBridge: NSObject, WKScriptMessageHandler {
    typealias MessageHandler = @MainActor (
        DeveloperLogLevel,
        String,
        Date
    ) -> Void

    private static let handlerName = "viewportDeveloperConsole"
    private let onMessage: MessageHandler
    private(set) var isEnabled = false

    init(onMessage: @escaping MessageHandler) {
        self.onMessage = onMessage
    }

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.add(
            WeakScriptMessageHandler(delegate: self),
            name: Self.handlerName
        )
        controller.addUserScript(
            WKUserScript(
                source: Self.bridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
    }

    func setEnabled(_ enabled: Bool, in webView: WKWebView) {
        isEnabled = enabled
        let script =
            "window.__viewportDeveloperConsoleEnabled = \(enabled ? "true" : "false");"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard isEnabled,
              message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let rawLevel = body["level"] as? String,
              let rawMessage = body["message"] as? String else {
            return
        }
        let level = Self.level(from: rawLevel)
        let text = String(rawMessage.prefix(16_384))
        let timestamp: Date
        if let milliseconds = body["timestamp"] as? Double,
           milliseconds.isFinite {
            timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else {
            timestamp = Date()
        }
        Task { @MainActor [onMessage] in
            onMessage(level, text, timestamp)
        }
    }

    static func level(from value: String) -> DeveloperLogLevel {
        switch value.lowercased() {
        case "debug": .debug
        case "warn", "warning": .warning
        case "error": .error
        default: .info
        }
    }

    private static let bridgeScript = """
    (() => {
      if (window.__viewportDeveloperConsoleInstalled) return;
      Object.defineProperty(window, "__viewportDeveloperConsoleInstalled", {
        value: true,
        configurable: false
      });
      window.__viewportDeveloperConsoleEnabled = false;

      const handler = window.webkit?.messageHandlers?.viewportDeveloperConsole;
      if (!handler) return;

      const render = (value) => {
        if (typeof value === "string") return value;
        if (value instanceof Error) return value.stack || value.message || String(value);
        if (typeof value === "undefined") return "undefined";
        if (typeof value === "bigint") return `${value}n`;
        if (typeof value === "function") return value.toString();
        try {
          const seen = new WeakSet();
          const json = JSON.stringify(value, (_key, item) => {
            if (typeof item === "bigint") return `${item}n`;
            if (item && typeof item === "object") {
              if (seen.has(item)) return "[Circular]";
              seen.add(item);
            }
            return item;
          });
          return json === undefined ? String(value) : json;
        } catch (_) {
          try { return String(value); } catch (_) { return "[Unprintable]"; }
        }
      };

      const send = (level, values) => {
        if (!window.__viewportDeveloperConsoleEnabled) return;
        try {
          handler.postMessage({
            level,
            message: values.map(render).join(" ").slice(0, 16384),
            timestamp: Date.now(),
            url: location.href
          });
        } catch (_) {}
      };

      for (const level of ["debug", "info", "log", "warn", "error"]) {
        const original = console[level]?.bind(console);
        if (!original) continue;
        console[level] = (...values) => {
          original(...values);
          send(level, values);
        };
      }

      addEventListener("error", (event) => {
        send("error", [event.error || event.message]);
      });
      addEventListener("unhandledrejection", (event) => {
        send("error", ["Unhandled promise rejection:", event.reason]);
      });
    })();
    """
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(
            userContentController,
            didReceive: message
        )
    }
}
