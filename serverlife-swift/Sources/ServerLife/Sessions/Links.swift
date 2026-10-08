import AppKit
import SwiftUI

/// Links in terminal output: finding them, and opening them on purpose — the
/// port of links.js.
///
/// A terminal is not a web page. The text in it arrives from somewhere else,
/// and a mis-aimed click on a scrolling log can hand a URL you never read to
/// your default browser. So opening is a deliberate act here: the click still
/// works, but it asks first and shows the address it would use, with the host
/// called out. The asking can be turned off.
enum TermLinks {
    /// What counts as a URL in a wall of text. Quotes, angle brackets,
    /// whitespace and control characters end it.
    static let urlRegex = try! NSRegularExpression(
        pattern: "(?:https?://|www\\.)[^\\s\"'`<>\\u0000-\\u001f\\u007f]+", options: [.caseInsensitive])

    /// Closers that only belong to the URL when it opened them itself.
    private static let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]

    /// Trim the punctuation that belongs to the sentence, not the address.
    static func trimTrailing(_ url: String) -> String {
        var out = url
        while let last = out.last {
            if ".,;:!?\u{2019}'\"".contains(last) { out.removeLast(); continue }
            if let open = pairs[last] {
                let opens = out.filter { $0 == open }.count
                let closes = out.filter { $0 == last }.count
                if closes > opens { out.removeLast(); continue }
            }
            break
        }
        return out
    }

    /// A bare `www.` host is a URL in everything but the scheme.
    static func normalize(_ url: String) -> String {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.lowercased().hasPrefix("www.") ? "https://" + u : u
    }

    /// Only http and https are ever opened.
    static func openable(_ url: String) -> Bool {
        let n = normalize(url)
        guard let r = try? NSRegularExpression(pattern: "^https?://\\S", options: [.caseInsensitive]) else { return false }
        return r.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil
    }

    struct Hit: Equatable { var url: String; var raw: String; var start: Int; var end: Int }

    /// The URL covering `index` (a UTF-16 offset) in `text`, or nil.
    static func urlAt(_ text: String, _ index: Int) -> Hit? {
        let ns = text as NSString
        guard index >= 0, index < ns.length else { return nil }
        for m in urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = m.range.location
            let end = start + m.range.length
            if index < start { return nil }
            if index < end {
                let raw = ns.substring(with: m.range)
                let url = trimTrailing(raw)
                if url.isEmpty { return nil }
                // Clicking the full stop after a URL is not clicking the URL.
                let urlLen = (url as NSString).length
                if index >= start + urlLen { return nil }
                return Hit(url: normalize(url), raw: raw, start: start, end: start + urlLen)
            }
        }
        return nil
    }

    /// The host, for saying plainly where a link goes.
    static func hostOf(_ url: String) -> String {
        guard let c = URLComponents(string: normalize(url)), c.scheme != nil, let h = c.host, !h.isEmpty else { return "" }
        let host = h.lowercased()
        if let p = c.port { return "\(host):\(p)" }
        return host
    }

    /// Is a click on a link asked about first? On unless told otherwise.
    @MainActor static var confirmsLinks: Bool { Store.shared.settingJSON("confirmLinkOpen").bool != false }

    /// Open a link, asking first unless that has been turned off.
    @MainActor @discardableResult
    static func openLink(_ url: String, ask: Bool? = nil, window: WindowModel? = nil) async -> Bool {
        let full = normalize(url)
        if !openable(full) {
            StatusBus.shared.show("Only http and https links open in the browser")
            return false
        }
        if ask ?? confirmsLinks {
            if !(await askToOpen(full, window: window)) { return false }
        }
        guard let u = URL(string: full) ?? URL(string: full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            return false
        }
        NSWorkspace.shared.open(u)
        let host = hostOf(full)
        StatusBus.shared.show("Opening \(host.isEmpty ? full : host)…")
        return true
    }

    /// The question itself: the address shown whole, as text, with the host
    /// on its own line above it.
    @MainActor private static func askToOpen(_ url: String, window: WindowModel?) async -> Bool {
        await withCheckedContinuation { cont in
            var resumed = false
            let finish: (Bool) -> Void = { v in if !resumed { resumed = true; cont.resume(returning: v) } }
            let h = Modal.sheet(window, title: "Open this link?", width: 520) { handle in
                OpenLinkDialog(url: url, host: hostOf(url)) { ok, stop in
                    if ok && stop { Store.shared.setSetting("confirmLinkOpen", false) }
                    finish(ok)
                    handle.close()
                }
            }
            h.onClose.append { finish(false) }
        }
    }
}

private struct OpenLinkDialog: View {
    let url: String
    let host: String
    let done: (Bool, Bool) -> Void
    @StateObject private var stop = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Open this link?", width: 520) {
            VStack(alignment: .leading, spacing: 10) {
                if !host.isEmpty {
                    (Text("Opens your browser at ").foregroundColor(p.muted) + Text(host).bold())
                        .font(.system(size: 13))
                }
                ScrollView {
                    Text(url)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
                Toggle("Stop asking — open links as soon as they are clicked", isOn: $stop.on)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
        } footer: {
            Button("Cancel") { done(false, false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Open") { done(true, stop.on) }.buttonStyle(.primary)
        }
    }
}
