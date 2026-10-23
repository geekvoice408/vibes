import Foundation

/// Recognises billing-window completion callbacks (port of `BillingContracts`).
public enum BillingContracts {
    static let pages = ["pluspurchasecomplete", "businesspurchasecomplete", "datapackpurchasecomplete"]

    /// True when `url` is one of eero's purchase-completion return pages. A return does not prove that a
    /// purchase succeeded; callers refresh the entitlement from the API afterwards.
    public static func `return`(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if c.user != nil || c.password != nil { return false }
        let scheme = (c.scheme ?? "").lowercased(), host = (c.host ?? "").lowercased()
        let path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if scheme == "eero" && host == "jumpto" {
            return pages.contains(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        if scheme == "https" && host == "app.eero.com" && (c.port == nil || c.port == 443) {
            return pages.contains { p in path == "/" + p || path == "/" + p + "/index.html" || path == "/jumpto/" + p }
        }
        return false
    }

    public static func `return`(_ text: String) -> Bool {
        guard let url = URL(string: text) else { return false }
        return `return`(url)
    }
}
