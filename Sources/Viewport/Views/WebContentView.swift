import SwiftUI
import WebKit

struct WebContentView: NSViewRepresentable {
    let model: WebViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        model.webView.navigationDelegate = context.coordinator
        DispatchQueue.main.async {
            model.loadInitialPageIfNeeded()
        }
        return model.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.navigationDelegate !== context.coordinator {
            nsView.navigationDelegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let model: WebViewModel

        init(model: WebViewModel) {
            self.model = model
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation?
        ) {
            model.navigationDidStart()
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation?
        ) {
            model.navigationDidFinish()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            model.navigationDidFail(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            model.navigationDidFail(error)
        }

        func webView(
            _ webView: WKWebView,
            respondTo challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod
                    == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  model.acceptsProxyServerTrust(trust) else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
}
