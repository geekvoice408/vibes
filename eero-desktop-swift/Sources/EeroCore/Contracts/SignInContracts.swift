import Foundation

/// Validation for internet-provider (SSO) sign-in (port of `SignInContracts`).
public enum SignInContracts {
    public static let ssoRedirect = "https://app.eero.com/auth/index.html"
    public static let ssoClientID = "28971b56-0016-4416-bef8-689caac23011"
    /// Provider list endpoint used by `SignInService.Providers`.
    public static let providersURL = URL(string: "https://sso.eero.com/api/v1/providers?assetType=mdpi")!
    /// Maximum size of the provider list response.
    public static let providersMaxBytes = 1024 * 1024

    /// True when `uri` is the eero SSO return page (or the `eero://jumpto/auth` deep link).
    public static func ssoReturn(_ uri: URL) -> Bool {
        guard let c = URLComponents(url: uri, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil else { return false }
        let scheme = (c.scheme ?? "").lowercased(), host = (c.host ?? "").lowercased()
        let path = c.percentEncodedPath
        if scheme == "https" && host == "app.eero.com" && (c.port == nil || c.port == 443) && path == "/auth/index.html" { return true }
        if scheme == "eero" && host == "jumpto" && path == "/auth" { return true }
        return false
    }

    /// Parses a query or fragment string, rejecting duplicate parameters.
    public static func parameters(_ query: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let trimmed = query.drop(while: { $0 == "?" || $0 == "#" })
        for item in trimmed.split(separator: "&", omittingEmptySubsequences: false) where !item.isEmpty {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String { let t = s.replacingOccurrences(of: "+", with: " "); return t.removingPercentEncoding ?? t }
            let key = decode(pair[0])
            if result[key] != nil { throw EeroError.data("The sign-in response contains duplicate parameters.") }
            result[key] = pair.count == 2 ? decode(pair[1]) : ""
        }
        return result
    }

    /// Hosted SSO page for a provider identifier returned by the provider list.
    public static func providerUrl(_ id: String?) throws -> String {
        guard let id, id.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw EeroError.argument("The provider identifier is invalid.")
        }
        return "https://sso.eero.com/?idp=" + escapeData(id) + "&redirect=" + escapeData(ssoRedirect) + "&clientID=" + ssoClientID
    }

    /// `Uri.EscapeDataString`: percent-encodes everything except RFC 3986 unreserved characters.
    public static func escapeData(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Provider choices (display name → idp) from the provider list response.
    public static func providerChoices(_ data: JSON) throws -> [String: String] {
        var choices: [String: String] = [:]
        for provider in data.list {
            let name = provider.s("name"), id = provider.s("idp")
            if !name.isEmpty && !id.isEmpty { choices[name] = id }
        }
        if choices.isEmpty { throw EeroError.operation("eero did not return any sign-in providers.") }
        return choices
    }

    /// Extracts the eero session token from the SSO return URL query.
    public static func returnToken(_ uri: URL) throws -> String {
        let query = try parameters(URLComponents(url: uri, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        guard let candidate = query["token"], !candidate.isEmpty else {
            throw EeroError.operation("The provider did not return an eero sign-in token.")
        }
        return candidate
    }
}
