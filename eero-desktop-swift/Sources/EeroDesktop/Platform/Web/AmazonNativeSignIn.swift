#if os(macOS)
import AppKit
import CryptoKit
import Security
import SwiftUI
import WebKit
import EeroCore

/// One Amazon "Login with Amazon" PKCE attempt as used by the eero mobile app.
/// Protocol constants, not SDK code (port of `AmazonNativeAttempt`).
final class AmazonNativeAttempt {
    static let tokenEndpoint = "https://api.amazon.com/auth/token"
    private static let deviceType = "A2W01JEFAJFTXI"
    static let amazonHosts = ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.co.jp", "amazon.com.au", "amazon.in", "amazon.com.mx", "amazon.com.br"]

    private let transport: HTTPTransport
    private let verifier: String
    private let state: String
    private let client: String
    private var consumed = false

    init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        verifier = Self.random(); state = Self.random()
        let serial = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        client = Array((serial + "#" + Self.deviceType).utf8).map { String(format: "%02x", $0) }.joined()
    }

    static func base64Url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        }
        return base64Url(Data(bytes))
    }

    static func challenge(_ value: String) -> String { base64Url(Data(SHA256.hash(data: Data(value.utf8)))) }

    var signInUrl: String {
        let fields: [(String, String)] = [
            ("openid.assoc_handle", "amzn_eero_mobile_android_us"), ("pageId", "eero_mobile_accounts"), ("language", "en_US"),
            ("openid.ns", "http://specs.openid.net/auth/2.0"), ("openid.mode", "checkid_setup"),
            ("openid.claimed_id", "http://specs.openid.net/auth/2.0/identifier_select"), ("openid.identity", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0"), ("openid.pape.max_auth_age", "0"),
            ("openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2"), ("openid.oa2.response_type", "code"),
            ("openid.oa2.scope", "device_auth_access"), ("openid.oa2.client_id", "device:" + client),
            ("openid.oa2.code_challenge", Self.challenge(verifier)), ("openid.oa2.code_challenge_method", "S256"),
            ("openid.return_to", "https://www.amazon.com/ap/maplanding?state=" + state), ("accountStatusPolicy", "P1"),
        ]
        return "https://www.amazon.com/ap/signin?" + fields.map { ServiceLinks.escapeData($0.0) + "=" + ServiceLinks.escapeData($0.1) }.joined(separator: "&")
    }

    /// True for Amazon's MAP landing page that carries the authorization code.
    static func returnAddress(_ url: URL?) -> Bool {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "https" && c.host?.lowercased() == "www.amazon.com" && (c.port ?? 443) == 443
            && c.user == nil && c.password == nil && c.percentEncodedPath == "/ap/maplanding" && (c.fragment ?? "").isEmpty
    }

    /// Navigation allowed inside the Amazon sign-in window.
    static func navigation(_ value: String) -> Bool {
        guard let c = ServiceLinks.secure(value), let host = c.host else { return false }
        return amazonHosts.contains { ServiceLinks.hostMatches(host, $0) }
    }

    func exchangeBody(_ returned: URL) throws -> JSON {
        if !Self.returnAddress(returned) { throw EeroError.data("Amazon returned to an unexpected address.") }
        let query = try SignInContracts.parameters(WebKitSupport.query(returned))
        guard let received = query["state"], received == state else {
            throw EeroError.data("The Amazon response did not match this sign-in attempt. Close this window and try again.")
        }
        if query["error"] != nil || query["openid.error"] != nil { throw EeroError.operation("Amazon sign-in was cancelled or rejected.") }
        guard let code = query["openid.oa2.authorization_code"], !code.isEmpty, code.count <= 8192,
              !code.unicodeScalars.contains(where: { $0.value <= 32 || $0.value >= 127 }) else {
            throw EeroError.data("Amazon did not return a valid authorization code.")
        }
        if let scope = query["openid.oa2.scope"], scope != "device_auth_access" { throw EeroError.data("Amazon returned an unexpected sign-in scope.") }
        return .obj(("app_name", "EeroDesktop"), ("app_version", "1.0.0"), ("source_token_type", "authorization_code"), ("source_token", code),
                    ("requested_token_type", "access_token"), ("code_verifier", verifier), ("code_algorithm", "SHA-256"), ("client_id", client), ("client_domain", "DeviceLegacy"))
    }

    /// Exchanges the returned authorization code for an Amazon access token (single use).
    func exchange(_ returned: URL) async throws -> String {
        let body = try exchangeBody(returned)
        if consumed { throw EeroError.operation("This sign-in attempt has already been used. Close this window and start again.") }
        consumed = true
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(EeroAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("api.amazon.com", forHTTPHeaderField: "x-amzn-identity-auth-domain")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let response = try await transport.send(request)
        if !response.isSuccess {
            var category = ""
            let failure = response.text
            if failure.count < 65536, let parsed = try? JSON.parse(failure) {
                let name = parsed.s("error").lowercased()
                if ["invalid_request", "invalid_grant", "invalid_client", "invalid_token", "unauthorized_client", "access_denied", "invalid_scope"].contains(name) { category = "." + name }
            }
            throw ApiError(code: response.status, error: "amazon.token.exchange" + category, session: false)
        }
        if response.body.count > 65536 { throw EeroError.data("Amazon returned an oversized sign-in response.") }
        guard let result = try? JSON.parse(response.body) else { throw EeroError.data("Amazon returned an unexpected sign-in response.") }
        let token = result.s("access_token")
        if result.s("token_type").lowercased() != "bearer" || token.isEmpty || token.count > 8192
            || token.unicodeScalars.contains(where: { $0.value <= 32 || $0.value >= 127 || $0 == ";" || $0 == "," }) {
            throw EeroError.data("Amazon did not return a valid access token.")
        }
        try Task.checkCancellation()
        return token
    }
}

/// Amazon sign-in window state (port of `AmazonNativeWindow`).
@MainActor
final class AmazonNativeController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var notice = "Opening Amazon’s secure sign-in…"
    @Published var address = "www.amazon.com"

    let attempt = AmazonNativeAttempt()
    let webView: WKWebView
    private let complete: @MainActor (String) async throws -> Void
    private let report: @MainActor (String, JSON?) -> Void
    private var completing = false
    private var isClosed = false
    private var started = false
    private var task: Task<Void, Never>?
    weak var window: NSWindow?

    init(complete: @escaping @MainActor (String) async throws -> Void, report: @escaping @MainActor (String, JSON?) -> Void) {
        self.complete = complete; self.report = report
        webView = WebKitSupport.privateWebView()
        webView.underPageBackgroundColor = NSColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func start() {
        if started { return }
        started = true
        guard let url = URL(string: attempt.signInUrl) else {
            notice = "The Amazon sign-in address is not valid."
            report("amazon_browser_error", .obj(("error_type", "UriFormatException")))
            return
        }
        report("amazon_browser_ready", nil)
        webView.load(URLRequest(url: url))
    }

    func didClose() {
        isClosed = true
        task?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if AmazonNativeAttempt.returnAddress(url) {
            decisionHandler(.cancel)
            if completing || isClosed { return }
            completing = true
            task = Task { [weak self] in await self?.finish(url) }
            return
        }
        if navigationAction.targetFrame.map({ !$0.isMainFrame }) ?? false {
            let scheme = url.scheme?.lowercased() ?? ""
            decisionHandler(["https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            return
        }
        if !AmazonNativeAttempt.navigation(url.absoluteString) {
            decisionHandler(.cancel)
            notice = "Amazon requested an unsupported destination."
            return
        }
        address = url.host ?? address
        decisionHandler(.allow)
    }

    private func finish(_ url: URL) async {
        var phase = "amazon_token_exchange"
        do {
            report("amazon_code_returned", nil)
            notice = "Finishing Amazon sign-in…"
            let token = try await attempt.exchange(url)
            report("amazon_token_received", nil)
            phase = "eero_account_verification"
            notice = "Verifying your eero account…"
            try await complete(token)
            if !isClosed { window?.close() }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            let failure = error as? ApiError
            let code = failure?.apiError ?? ""
            if !isClosed {
                notice = phase == "eero_account_verification" && code == "error.login.unknown"
                    ? "Amazon sign-in succeeded, but eero does not recognize this Amazon account for an existing eero login. Use your eero email or phone number. Amazon login can be managed in eero’s Account settings; no account was created or changed here."
                    : (phase == "amazon_token_exchange" ? "Amazon could not finish sign-in: " : "eero could not verify this Amazon sign-in: ") + userMessage(error) + " Close this window to start a fresh sign-in."
            }
            let safeCode = code.range(of: "^[a-zA-Z0-9_.-]{1,140}$", options: .regularExpression) != nil ? code : ""
            report("amazon_signin_error", .obj(("phase", phase), ("error_type", String(describing: type(of: error))),
                                               ("http_code", failure?.code ?? 0), ("api_error", safeCode)))
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, AmazonNativeAttempt.navigation(url.absoluteString) { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if completing || isClosed { return }
        notice = "Complete Amazon sign-in and any verification on the page above. The window closes only after eero verifies your account."
        report("amazon_page_loaded", nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        if completing || isClosed || WebKitSupport.ignorable(error) { return }
        notice = "The Amazon page could not load (" + error.localizedDescription + ")."
        report("amazon_page_error", .obj(("browser_error", "\((error as NSError).domain) \((error as NSError).code)")))
    }
}

struct AmazonNativeView: View {
    @ObservedObject var controller: AmazonNativeController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in with Amazon").font(.system(size: 24, weight: .semibold))
                Text("Sign in with the Amazon account linked to your eero account. This window closes after eero verifies your sign-in.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(controller.address).foregroundStyle(.secondary).padding(.bottom, 4)
            }
            WebViewHost(webView: controller.webView)
            VStack(alignment: .leading, spacing: 8) {
                Text(controller.notice).fixedSize(horizontal: false, vertical: true)
                Button("Cancel") { controller.window?.close() }
            }
            .padding(.top, 12)
        }
        .padding(16)
        .onAppear { controller.start() }
    }
}

extension AppModel {
    /// Port of `AmazonConsumerSignIn`: Login with Amazon in a private window, then eero verifies the account.
    func amazonSignIn() {
        let flows = WebFlows.shared
        if flows.activate("amazon-sign-in") { return }
        let controller = AmazonNativeController(complete: { [weak self] token in
            guard let self else { return }
            try await self.completeExternalSignIn {
                let previous = await self.api.remember
                var success = false
                do {
                    await self.api.setRemember(flows.remember)
                    _ = try await self.api.amazonSignIn(accessToken: token)
                    success = true
                    self.clearData()
                    try await self.loadAccount()
                    self.screen = .shell
                    self.setNotice("Signed in with Amazon.")
                } catch {
                    if !success { await self.api.setRemember(previous) }
                    throw error
                }
            }
        }, report: { state, details in flows.writeAmazonReport(state, details) })
        let window = flows.present(key: "amazon-sign-in", title: "Sign in with Amazon · eero Desktop",
                                   size: CGSize(width: 1080, height: 820), minSize: CGSize(width: 850, height: 650),
                                   onClose: { controller.didClose() }, content: AmazonNativeView(controller: controller))
        controller.window = window
    }
}
#endif
