import Foundation

/// One process, as the city's traffic sees it.
struct CityProc: Equatable, Sendable {
    var pid: Int
    /// Percent of a CPU (can exceed 100 on several cores).
    var cpu: Double
    /// Resident memory in bytes.
    var mem: Double
    var user: String
    var name: String
}

/// The processes on a machine, for the 3D city's traffic (procscan.js).
///
/// One `ps` and nothing else: pid, CPU share, resident memory, owner and
/// command. Every ps worth the name takes `-o` with these field names — GNU
/// procps, BSD and macOS all do — and the trailing `=` drops the header so
/// there is nothing to skip. `comm` goes last because it is the one field
/// that may contain spaces.
///
/// Busybox's ps does not know `pcpu`, so the remote command falls back to the
/// fields it does know and the CPU column comes back empty; those machines get
/// traffic sized by memory alone, which is still the more interesting half.
enum ProcScan {
    static let fields = "pid=,pcpu=,rss=,user=,comm="

    static func remoteCommand() -> String {
        "LC_ALL=C ps -axo \(fields) 2>/dev/null || LC_ALL=C ps -eo \(fields) 2>/dev/null || ps -o pid=,rss=,user=,comm="
    }

    private static let full = try! NSRegularExpression(pattern: #"^(\d+)\s+([\d.,]+)\s+(\d+)\s+(\S+)\s+(.+)$"#)
    private static let busybox = try! NSRegularExpression(pattern: #"^(\d+)\s+(\d+)\s+(\S+)\s+(.+)$"#)

    /// Lines of `pid pcpu rss user comm`, or `pid rss user comm` from busybox.
    static func parse(_ text: String, top: Int = 40) -> [CityProc] {
        var out: [CityProc] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = String(raw).trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let ns = t as NSString
            let range = NSRange(location: 0, length: ns.length)
            var pid = "", cpu = 0.0, rssKb = "", user = "", comm = ""
            if let m = full.firstMatch(in: t, range: range) {
                pid = ns.substring(with: m.range(at: 1))
                cpu = parseFloat(ns.substring(with: m.range(at: 2)).replacingFirst(",", with: "."))
                rssKb = ns.substring(with: m.range(at: 3))
                user = ns.substring(with: m.range(at: 4))
                comm = ns.substring(with: m.range(at: 5))
            } else if let m = busybox.firstMatch(in: t, range: range) {
                pid = ns.substring(with: m.range(at: 1))
                rssKb = ns.substring(with: m.range(at: 2))
                user = ns.substring(with: m.range(at: 3))
                comm = ns.substring(with: m.range(at: 4))
                cpu = 0
            } else {
                continue
            }
            let c = comm.trimmed
            let base = Posix.basename(c)
            out.append(CityProc(pid: Int(pid) ?? 0, cpu: cpu.isFinite ? cpu : 0,
                                mem: (Double(rssKb) ?? 0) * 1024, user: user, name: base.isEmpty ? c : base))
        }
        // The busiest, by a mix of the two: a percent of CPU weighed against a
        // hundred megabytes of memory, which is roughly where each starts to matter.
        func weight(_ p: CityProc) -> Double { p.cpu + p.mem / (100 * 1024 * 1024) }
        let sorted = out.enumerated().sorted { a, b in
            let wa = weight(a.element), wb = weight(b.element)
            return wa != wb ? wa > wb : a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(top))
    }

    /// JavaScript `parseFloat`: the longest leading number, NaN when none.
    static func parseFloat(_ s: String) -> Double {
        var best = Double.nan
        var cur = ""
        for ch in s.trimmingCharacters(in: .whitespaces) {
            cur.append(ch)
            if let d = Double(cur) { best = d } else if !(cur == "-" || cur == "+" || cur == "." || cur.hasSuffix("e") || cur.hasSuffix("e-")) { break }
        }
        return best
    }

    static func scanLocal(top: Int = 40) async throws -> [CityProc] {
        let r = await Proc.run("/bin/ps", ["-axo", fields], env: ["LC_ALL": "C"], timeout: 10)
        if !r.ok && r.out.isEmpty { throw AppError(r.message.isEmpty ? "ps failed" : r.message) }
        return parse(r.out, top: top)
    }
}

private extension String {
    func replacingFirst(_ target: String, with rep: String) -> String {
        guard let r = range(of: target) else { return self }
        return replacingCharacters(in: r, with: rep)
    }
}
