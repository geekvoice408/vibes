import SwiftUI
import WebKit

/// Hosts the SSO login flow in-app instead of the system browser. Loads tshd's own local
/// redirector URL (http://127.0.0.1:<port>/<uuid>, captured via TshdProcess.awaitSSOLoginURL),
/// which 302s to the real identity provider (Google, Entra ID, etc.) exactly as it would for a
/// real browser — WKWebView follows the whole redirect chain, including the final redirect back
/// to tshd's own local callback listener that completes the Login RPC. No different from a
/// browser tab from tshd's point of view; it never knows the difference.
///
/// Some providers (Google notably) actively detect and refuse to render their login form inside
/// an embedded WebView as an anti-phishing measure, showing "This browser or app may not be
/// secure" instead. Setting a realistic desktop Safari user agent — the standard workaround many
/// native apps use for exactly this — avoids that in most cases, though providers can still
/// change their detection at any time.
struct SSOBrowserView: NSViewRepresentable {
    let url: URL
    var onError: ((String) -> Void)?
    var onNavigate: ((URL) -> Void)?

    private static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.customUserAgent = Self.desktopSafariUserAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError, onNavigate: onNavigate)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onError: ((String) -> Void)?
        let onNavigate: ((URL) -> Void)?

        init(onError: ((String) -> Void)?, onNavigate: ((URL) -> Void)?) {
            self.onError = onError
            self.onNavigate = onNavigate
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError?("Failed to load sign-in page: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError?("Sign-in page load error: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url {
                onNavigate?(url)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                onError?("Sign-in page returned HTTP \(http.statusCode) for \(http.url?.absoluteString ?? "?")")
            }
            decisionHandler(.allow)
        }
    }
}
