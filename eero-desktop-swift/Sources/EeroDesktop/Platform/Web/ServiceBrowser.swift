#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import EeroCore

/// Private in-app browser for eero and partner services (port of `ServiceBrowserWindow`).
@MainActor
final class ServiceBrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let sampleHtml = "<html><body style='background:#101a2b;color:#e5ecf8;font:18px -apple-system,sans-serif;padding:40px'><h1>macOS service browser</h1><p>WebKit is running. This sample uses no account or network request.</p></body></html>"

    @Published var address: String
    @Published var notice = "Opening secure service…"
    @Published var importEnabled = false

    let webView: WKWebView
    let target: String
    let headers: String?
    let sample: Bool
    let providerNavigation: Bool
    let callbackMatch: ((URL) -> Bool)?
    let callback: (@MainActor (URL) async throws -> Void)?
    let importSession: (@MainActor (String) async throws -> Void)?
    weak var window: NSWindow?
    private var completing = false
    private(set) var isClosed = false
    private var tasks: [Task<Void, Never>] = []

    init(url: String, headers: String? = nil, importSession: (@MainActor (String) async throws -> Void)? = nil, preview: Bool = false,
         callbackMatch: ((URL) -> Bool)? = nil, callback: (@MainActor (URL) async throws -> Void)? = nil, providerNavigation: Bool = false) {
        target = url; self.headers = headers; self.importSession = importSession; sample = preview
        self.callbackMatch = callbackMatch; self.callback = callback; self.providerNavigation = providerNavigation
        address = preview ? "Sample service window" : (URL(string: url)?.host ?? url)
        webView = WebKitSupport.privateWebView()
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Port of `Initialize`.
    func start() {
        do {
            if sample { webView.loadHTMLString(Self.sampleHtml, baseURL: nil); return }
            guard let url = URL(string: target) else { throw EeroError.argument("The service address is not valid.") }
            var request = URLRequest(url: url)
            if let headers {
                try ServiceLinks.eero(target)
                for (name, value) in ServiceLinks.headerFields(headers) { request.setValue(value, forHTTPHeaderField: name) }
            }
            webView.load(request)
        } catch {
            notice = "The secure browser could not start: " + userMessage(error)
        }
    }

    func close() { if !isClosed { window?.close() } }

    /// Called when the window closes (the `lifetime` cancellation in the Windows client).
    func didClose() {
        isClosed = true
        tasks.forEach { $0.cancel() }
        tasks = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func spawn(_ work: @escaping @MainActor () async -> Void) {
        tasks.append(Task { await work() })
    }

    private func permitted(_ value: String) -> Bool {
        ServiceLinks.allowed(value) || providerNavigation && ServiceLinks.providerNavigation(value)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let value = url.absoluteString
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.targetFrame.map({ !$0.isMainFrame }) ?? false {
            // Embedded frames (captcha, payment widgets) stay inside the page; block non-web schemes.
            decisionHandler(["https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            return
        }
        if sample && (value == "about:blank" || scheme == "data") { decisionHandler(.allow); return }
        if let callbackMatch, callbackMatch(url) {
            decisionHandler(.cancel)
            if completing { return }
            completing = true
            spawn { [weak self] in
                guard let self else { return }
                defer { self.completing = false }
                do {
                    self.notice = "Verifying the service response…"
                    try await self.callback?(url)
                    self.close()
                } catch {
                    if !self.isClosed { self.notice = userMessage(error) }
                }
            }
            return
        }
        if !permitted(value) {
            decisionHandler(.cancel)
            notice = "This destination is outside the supported provider websites."
            return
        }
        if navigationAction.request.value(forHTTPHeaderField: "x-temp-user-token") != nil && !ServiceLinks.keepTemporaryHeader(target, value) {
            // Never forward the temporary token beyond the exact initial eero target.
            decisionHandler(.cancel)
            var stripped = navigationAction.request
            stripped.setValue(nil, forHTTPHeaderField: "x-temp-user-token")
            webView.load(stripped)
            return
        }
        if scheme == "https", let host = url.host {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            address = host + (path.isEmpty ? "/" : path)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           permitted(url.absoluteString) || (callbackMatch?(url) ?? false) {
            webView.load(URLRequest(url: url))
        } else {
            notice = "The provider requested a destination outside this service window."
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notice = sample ? "Local sample loaded. No account or network request." : "Secure provider service. Complete any sign-in or purchase yourself."
        if importSession != nil { importEnabled = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        if WebKitSupport.ignorable(error) || isClosed { return }
        notice = "The provider page did not finish loading (" + error.localizedDescription + ")."
        if importSession != nil { importEnabled = false }
    }

    /// "Use this sign-in": imports the verified eero API session cookie from this private browser.
    func importClick() {
        guard let importSession else { return }
        importEnabled = false
        spawn { [weak self] in
            guard let self else { return }
            defer { if !self.isClosed { self.importEnabled = true } }
            let store = self.webView.configuration.websiteDataStore.httpCookieStore
            let cookies: [HTTPCookie] = await withCheckedContinuation { c in store.getAllCookies { c.resume(returning: $0) } }
            let session = cookies.first { cookie in
                let domain = cookie.domain.lowercased().drop(while: { $0 == "." })
                return cookie.name == "s" && cookie.isSecure && (domain == "api-user.e2ro.com" || domain == "e2ro.com")
            }
            guard let session else {
                self.notice = "This website has not provided a reusable eero API session. Finish signing in, or use email/phone verification in the Mac app."
                return
            }
            do { try await importSession(session.value); self.close() }
            catch { if !self.isClosed { self.notice = userMessage(error) } }
        }
    }
}

struct ServiceBrowserView: View {
    @ObservedObject var controller: ServiceBrowserController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(controller.address).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if controller.importSession != nil {
                    Text("Sign in yourself on eero's website. Use this sign-in imports only a verified eero API session from this private app browser.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use this sign-in") { controller.importClick() }.disabled(!controller.importEnabled)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            WebViewHost(webView: controller.webView)
            Text(controller.notice)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 10, leading: 18, bottom: 16, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { controller.start() }
    }
}

extension AppModel {
    /// Opens a service browser window (constructor of `ServiceBrowserWindow` + `Show`).
    /// `onClose` ports `window.Closed` handlers (e.g. the billing refresh).
    @discardableResult
    func openServiceBrowser(_ title: String, _ url: String, headers: String? = nil,
                            importSession: (@MainActor (String) async throws -> Void)? = nil, preview: Bool = false,
                            callbackMatch: ((URL) -> Bool)? = nil, callback: (@MainActor (URL) async throws -> Void)? = nil,
                            providerNavigation: Bool = false, onClose: (() -> Void)? = nil) -> ServiceBrowserController {
        let controller = ServiceBrowserController(url: url, headers: headers, importSession: importSession, preview: preview,
                                                  callbackMatch: callbackMatch, callback: callback, providerNavigation: providerNavigation)
        let window = WebFlows.shared.present(title: title + " · eero Desktop", size: CGSize(width: 1080, height: 800), minSize: CGSize(width: 850, height: 650),
                                             onClose: { controller.didClose(); onClose?() },
                                             content: ServiceBrowserView(controller: controller))
        controller.window = window
        return controller
    }

    /// Port of `OpenServiceWindow`.
    func openServiceWindow(_ title: String, _ url: String, headers: String? = nil) throws {
        if !ServiceLinks.allowed(url) { throw EeroError.operation("The service returned an unsupported provider website.") }
        openServiceBrowser(title, url, headers: headers)
    }

    /// Port of `OpenPaymentService`: opens eero's web payments page with a temporary sign-in token.
    func openPaymentService(_ targetPage: String) async throws {
        if preview { throw EeroError.operation("Sign in to manage a subscription.") }
        let page = targetPage.addingPercentEncoding(withAllowedCharacters: ServiceLinks.unreserved) ?? targetPage
        let session = try await api.send("GET", "/2.2/login/temporary?client_type=WEB_PAYMENTS&target_page=" + page)
        let url = session.s("target_url")
        try ServiceLinks.eero(url)
        try openBillingWindow(url, header: try ServiceLinks.tokenHeader(session.s("temporary_token")))
    }

    /// Port of `WebsiteSignIn`: the user signs in on account.eero.com and imports the verified session.
    func websiteSignIn() {
        let remember = WebFlows.shared.remember
        let api = self.api
        Task { await api.setRemember(remember) }
        openServiceBrowser("Sign in on eero's website", "https://account.eero.com/", importSession: { [weak self] token in
            guard let self else { return }
            try await self.completeExternalSignIn {
                try await self.api.importBrowserSession(token)
                self.clearData()
                try await self.loadAccount()
                self.screen = .shell
                self.setNotice("Website sign-in verified with eero.")
            }
        })
    }
}

extension ServiceLinks {
    /// RFC 3986 unreserved characters (`Uri.EscapeDataString`).
    static let unreserved: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-._~")
        return s
    }()

    static func escapeData(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
}
#endif
