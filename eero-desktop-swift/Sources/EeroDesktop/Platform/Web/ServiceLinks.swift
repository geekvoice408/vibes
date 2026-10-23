#if os(macOS)
import Foundation
import EeroCore

/// Allow-list and validation for the embedded service browser (port of `ServiceLinks`).
enum ServiceLinks {
    static let domains = ["eero.com", "e2ro.com", "amazon.com", "alexa.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.ca", "amazon.com.au", "amazon.co.jp", "amazon.in", "amazon.com.mx", "amazon.com.br", "guardianapp.com", "1password.com", "malwarebytes.com", "stripe.com", "paypal.com", "eero.zendesk.com"]

    /// An absolute https URL on the default port without user info, or nil.
    static func secure(_ value: String) -> URLComponents? {
        guard let c = URLComponents(string: value), let scheme = c.scheme?.lowercased(), scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, (c.port ?? 443) == 443 else { return nil }
        return c
    }

    static func hostMatches(_ host: String, _ domain: String) -> Bool {
        let h = host.lowercased()
        return h == domain || h.hasSuffix("." + domain)
    }

    /// Validates a URL as a secure eero web address.
    @discardableResult
    static func eero(_ value: String) throws -> URL {
        guard let c = secure(value), let host = c.host, hostMatches(host, "eero.com"), let url = c.url else {
            throw EeroError.data("The service did not return a secure eero web address.")
        }
        return url
    }

    /// Builds the temporary sign-in header block for an eero web page.
    static func tokenHeader(_ token: String) throws -> String {
        if token.isEmpty || token.count > 8192 || token.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }) {
            throw EeroError.data("The web service did not return a valid temporary sign-in token.")
        }
        return "x-temp-user-token: " + token + "\r\n"
    }

    /// The temporary header is only kept for the exact initial eero target.
    static func keepTemporaryHeader(_ initial: String, _ request: String) -> Bool {
        guard let target = try? eero(initial), let resource = secure(request)?.url else { return false }
        return target.absoluteString == resource.absoluteString
    }

    static func allowed(_ value: String) -> Bool {
        if value == "about:blank" { return true }
        guard let c = secure(value), let host = c.host else { return false }
        return domains.contains { hostMatches(host, $0) }
    }

    /// Payment and identity providers may navigate to any standard secure page.
    static func providerNavigation(_ value: String) -> Bool { secure(value) != nil }

    /// Location of the app's web-service profile. Browsers here use non-persistent data stores, so it is informational.
    static var profileDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        return (base as NSString).appendingPathComponent("EeroDesktop/WebServices")
    }

    /// Port of `CheckRuntime` (`--browser-runtime-test`): WebKit is part of macOS, so it is always available.
    static func checkRuntime(_ output: String) -> Int32 {
        let version = Bundle(identifier: "com.apple.WebKit")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "system"
        do {
            try JSON.obj(("ok", true), ("webkit_runtime", version)).serialized().write(toFile: output, atomically: true, encoding: .utf8)
            return 0
        } catch { return 1 }
    }

    /// Parses a header block of `name: value\r\n` lines.
    static func headerFields(_ block: String) -> [(String, String)] {
        block.components(separatedBy: "\r\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }
}
#endif
