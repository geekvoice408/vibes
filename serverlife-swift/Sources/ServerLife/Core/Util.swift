import Foundation
import SwiftUI

// Ports of src/renderer/js/util.js and the small helpers every module used.

/// Escape a string for a single-quoted shell argument (`shellQuote`).
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// `uid(prefix)` from util.js: a short random id for UI objects.
func uid(_ prefix: String = "id") -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return prefix + "_" + String((0..<8).map { _ in chars.randomElement()! })
}

enum Fmt {
    /// `fmtBytes`: "512 B", "1.50 KB", "12.3 MB", "512 GB".
    static func bytes(_ n: Double?) -> String {
        guard let n else { return "" }
        if n < 1024 { return "\(Int(n)) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = n / 1024, i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        let s = v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        return "\(s) \(units[i])"
    }
    static func bytes(_ n: Int?) -> String { bytes(n.map(Double.init)) }
    static func bytes(_ n: Int64?) -> String { bytes(n.map(Double.init)) }
    static func bytes(_ n: UInt64?) -> String { bytes(n.map(Double.init)) }

    /// `fmtRate`.
    static func rate(_ bps: Double?) -> String {
        guard let bps, bps >= 1 else { return "" }
        return bytes(bps) + "/s"
    }

    /// `fmtDate`: "Mar  4 09:12" this year, "Mar  4  2024" otherwise.
    static func date(ms: Double?) -> String {
        guard let ms, ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let mon = DateFormatter.shortMonth.string(from: d)
        let day = String(format: "%2d", cal.component(.day, from: d))
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return String(format: "%@ %@ %02d:%02d", mon, day, cal.component(.hour, from: d), cal.component(.minute, from: d))
        }
        return "\(mon) \(day)  \(cal.component(.year, from: d))"
    }

    /// `fmtDuration`: ms → "350ms", "4.2s", "3m 12s", "2h 5m", "1d 3h".
    static func duration(ms: Double?) -> String {
        guard let ms else { return "" }
        if ms < 1000 { return "\(Int(ms))ms" }
        let s = Int((ms / 1000).rounded())
        if s < 60 { return String(format: "%.1fs", ms / 1000) }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s" }
        let h = m / 60
        if h < 24 { return "\(h)h \(m % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }

    /// "just now", "5m", "3h", "2d" — the compact ages the lists use.
    static func age(ms: Double) -> String {
        let s = max(0, (nowMs() - ms) / 1000)
        if s < 60 { return "<1m" }
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 48 { return "\(h)h" }
        return "\(h / 24)d"
    }

    /// "5m ago" style, with "just now" under a minute.
    static func ago(ms: Double) -> String {
        let s = max(0, (nowMs() - ms) / 1000)
        if s < 45 { return "just now" }
        return age(ms: ms) + " ago"
    }
}

extension DateFormatter {
    static let shortMonth: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM"; return f
    }()
}

/// POSIX path helpers (remote paths are always POSIX).
enum Posix {
    static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty || dir == "/" { return "/" + name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
    static func parent(_ p: String) -> String {
        if p.isEmpty || p == "/" { return "/" }
        var t = p
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        guard let i = t.lastIndex(of: "/") else { return "/" }
        return i == t.startIndex ? "/" : String(t[..<i])
    }
    static func basename(_ p: String) -> String {
        if p.isEmpty { return "" }
        var t = p
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        if let i = t.lastIndex(of: "/") { let b = String(t[t.index(after: i)...]); return b.isEmpty ? "/" : b }
        return t
    }
}

/// `compareNames`: case-insensitive and numeric, so node-2 < node-10.
func compareNames(_ a: String, _ b: String) -> ComparisonResult {
    a.compare(b, options: [.caseInsensitive, .numeric, .diacriticInsensitive], range: nil, locale: nil)
}

func namesAscending(_ a: String, _ b: String) -> Bool { compareNames(a, b) == .orderedAscending }

/// Glob (`*`, `?`) to an anchored, case-insensitive regex.
func globRegex(_ glob: String) -> NSRegularExpression? {
    var pattern = "^"
    for ch in glob {
        switch ch {
        case "*": pattern += ".*"
        case "?": pattern += "."
        default: pattern += NSRegularExpression.escapedPattern(for: String(ch))
        }
    }
    pattern += "$"
    return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

extension NSRegularExpression {
    func matches(_ s: String) -> Bool {
        firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
    /// Collapse the home directory to `~`.
    var tildePath: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}

/// The colours a host, folder or cluster can be marked with (`HOST_COLORS`).
struct HostColor: Identifiable, Hashable {
    let value: String
    let label: String
    let hex: String
    var id: String { value }
    var color: Color? { hex.isEmpty ? nil : Color(hex: hex) }

    static let all: [HostColor] = [
        HostColor(value: "", label: "None", hex: ""),
        HostColor(value: "red", label: "Red — production", hex: "#f85149"),
        HostColor(value: "amber", label: "Amber — staging", hex: "#d29922"),
        HostColor(value: "green", label: "Green — development", hex: "#3fb950"),
        HostColor(value: "blue", label: "Blue", hex: "#4c8dff"),
        HostColor(value: "purple", label: "Purple", hex: "#bc8cff"),
        HostColor(value: "cyan", label: "Cyan", hex: "#39c5cf"),
        HostColor(value: "pink", label: "Pink", hex: "#f778ba"),
        HostColor(value: "grey", label: "Grey", hex: "#8b949e"),
    ]

    /// `colorCss(name)`: nil for "not coloured".
    static func color(_ name: String?) -> Color? {
        guard let name, !name.isEmpty else { return nil }
        return all.first { $0.value == name }?.color
    }
}

/// The icons offered in the picker (`ICON_CHOICES`); anything pasted is accepted too.
let iconChoices: [String] = [
    "\u{1F525}", "\u{1F680}", "\u{1F6E0}\u{FE0F}", "\u{1F9EA}", "\u{1F512}", "\u{1F310}",
    "\u{1F4BE}", "\u{1F5A5}\u{FE0F}", "\u{2601}\u{FE0F}", "\u{1F433}", "\u{1F427}", "\u{1FA9F}",
    "\u{1F34E}", "\u{1F4C8}", "\u{1F50E}", "\u{1F4E6}", "\u{2699}\u{FE0F}", "\u{1F9F0}",
    "\u{1F6A6}", "\u{1F9EF}", "\u{1F514}", "\u{1F4DE}", "\u{1F4DA}", "\u{1F5C3}\u{FE0F}",
    "\u{1F7E2}", "\u{1F7E1}", "\u{1F534}", "\u{1F7E3}", "\u{2B50}", "\u{1F480}",
]

extension Color {
    /// "#rrggbb" or "#rrggbbaa".
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xff) / 255; g = Double((v >> 16) & 0xff) / 255
            b = Double((v >> 8) & 0xff) / 255; a = Double(v & 0xff) / 255
        } else {
            r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255
            b = Double(v & 0xff) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// Run `body` on the main actor after `seconds`.
func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
}

/// A cancellable debounce (`debounce` in util.js).
@MainActor
final class Debouncer {
    private var work: DispatchWorkItem?
    let delay: Double
    init(_ delay: Double = 0.15) { self.delay = delay }
    func call(_ body: @escaping @MainActor () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    func cancel() { work?.cancel(); work = nil }
}

/// A repeating main-actor timer that is easy to stop (setInterval).
@MainActor
final class Repeater {
    private var timer: Timer?
    func start(every seconds: Double, fireNow: Bool = false, _ body: @escaping @MainActor () -> Void) {
        stop()
        guard seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        if fireNow { body() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    var isRunning: Bool { timer != nil }
}
