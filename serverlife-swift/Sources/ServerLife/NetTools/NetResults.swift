import SwiftUI

/// What a run produced, ready to draw (the renderers in nettools.js).
enum NetDisplay {
    case text(TextRun)
    case remoteText(TextRun, label: String)
    case dns(DNSResult)
    case ports(PortsResult)
    case remotePorts(PortsResult, label: String)
    case telnet(TelnetResult)
    case remoteTelnet(PortsResult, host: String, port: Int, label: String, hasTelnet: Bool)
    case serial([SerialPortInfo])
    case tls(TLSResult)
    case http(HTTPResult)
    case curl(CurlResult, from: String?)
    case teleport(WebAPIPing.Result)
    case local(LocalInfo)
    case hostFacts(HostFacts, label: String)
}

// MARK: - Shared wording

enum NetWords {
    static func portLine(_ r: PortsResult, from: String?) -> String {
        let open = r.results.filter { from == nil ? $0.state == "open" : $0.open == true }.count
        let head = from.map { "\($0) → \(r.host)" } ?? r.host
        return "\(head) — \(open) of \(r.results.count) open" + (from != nil && r.how != nil ? "  ·  asked with \(r.how!)" : "")
    }

    static let sshWHint = "The server was asked to open each connection over the session that is already "
        + "authenticated, so the answer is its own network stack and nothing had to be "
        + "installed. The verdict is whether that succeeded: accepted is open, a refusal "
        + "means the host is there with nothing listening, and silence means the packet "
        + "was dropped."

    static func statusKind(_ code: Int) -> String { code == 0 ? "warn" : code < 300 ? "ok" : "warn" }

    static func tlsRows(_ r: TLSResult) -> [(String, String?)] {
        [
            ("Verified", r.authorized ? "yes" : "no — \(r.authorizationError ?? "untrusted")"),
            ("Protocol", r.proto),
            ("Cipher", r.cipherName.map { "\($0) (\(r.cipherVersion ?? ""))" }),
            ("ALPN", r.alpn),
            ("Subject", TLSResult.dn(r.subject)),
            ("Issuer", TLSResult.dn(r.issuer)),
            ("Valid from", r.validFrom),
            ("Valid to", r.validTo.map { "\($0)\(r.daysLeft.map { " — \($0) days left" } ?? "")" }),
            ("Serial", r.serialNumber),
            ("SHA-256", r.fingerprint256),
            ("Names", r.san.map { $0.replacingOccurrences(of: "DNS:", with: "").replacingOccurrences(of: ",\\s*", with: ", ", options: .regularExpression) }),
            ("Chain", r.chain.count > 1 ? r.chain.enumerated().map { "\($0.offset): \($0.element.subject)  ← \($0.element.issuer)" }.joined(separator: "\n") : nil),
        ]
    }
}

// MARK: - The view

struct NetResultView: View {
    let display: NetDisplay
    @ObservedObject var model: NetToolsModel

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            switch display {
            case .text(let r):
                if !r.command.isEmpty { NTCmd(text: r.command) }
                NTPre(text: r.text.isEmpty ? "(no output)" : r.text)
                if r.timedOut { NTHint(text: "Timed out before finishing.", color: p.amber).padding(.top, 6) }

            case .remoteText(let r, let label):
                if let missing = r.missing {
                    NTEmpty(text: "\(label.isEmpty ? (r.from ?? "That host") : label) has no \(missing).", color: p.amber)
                    if let hint = r.hint {
                        NTHead(text: "to install it")
                        NTPre(text: hint)
                        NTHint(text: "Then press Re-check beside the host, and the tool becomes available.").padding(.top, 4)
                    } else {
                        NTHint(text: "Its package manager was not recognised, so there is no command to suggest.")
                    }
                } else {
                    NTCmd(text: "\(label.isEmpty ? (r.from ?? "") : label) → \(r.host)"
                          + (r.tool != nil && r.tool != "traceroute" ? "  ·  \(r.tool!), since traceroute is not installed there" : ""))
                    NTPre(text: r.text.isEmpty ? "(no output)" : r.text)
                    NTHint(text: "Run on the host as: \(r.command)").padding(.top, 8)
                }

            case .dns(let r):
                if r.records.isEmpty && r.reverse == nil { NTEmpty(text: "Nothing resolves for \(r.host).") }
                ForEach(Array(r.records.enumerated()), id: \.offset) { _, rec in
                    VStack(alignment: .leading, spacing: 2) {
                        NTHead(text: rec.type)
                        ForEach(Array(rec.values.enumerated()), id: \.offset) { _, v in
                            Text(DNSResult.format(v)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        }
                    }.padding(.bottom, 13)
                }
                if let rev = r.reverse, !rev.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        NTHead(text: "PTR")
                        ForEach(rev, id: \.self) { Text($0).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled) }
                    }.padding(.bottom, 13)
                }
                if !r.servers.isEmpty { NTHint(text: "Resolvers: " + r.servers.joined(separator: ", ")).padding(.top, 10) }

            case .ports(let r):
                NTCmd(text: NetWords.portLine(r, from: nil))
                PortGrid(results: r.results, remote: false)

            case .remotePorts(let r, let label):
                NTCmd(text: NetWords.portLine(r, from: label.isEmpty ? (r.from ?? "") : label))
                PortGrid(results: r.results, remote: true)
                NTHint(text: r.how == "ssh -W" ? NetWords.sshWHint : "Answered by a tool on the host, since this session cannot forward.")
                    .padding(.top, 8)

            case .telnet(let r):
                telnetView(r)

            case .remoteTelnet(let r, let host, let port, let label, let hasTelnet):
                let first = r.results.first
                let s = PortStateInfo.of(state: first?.state, open: first?.open)
                NTCmd(text: "\(label) → \(host):\(port)" + (r.how.map { "  ·  asked with \($0)" } ?? ""))
                HStack(spacing: 5) {
                    NTBadge(text: s.label, kind: first?.open == true ? "ok" : "warn")
                    if let ms = first?.ms { NTBadge(text: "\(ms)ms") }
                }.padding(.bottom, 13)
                NTHint(text: (first?.error != nil && first?.open != true) ? first!.error! : s.why)
                if let banner = first?.banner {
                    NTHead(text: "What it said", top: 13)
                    NTPre(text: banner)
                }
                HStack(spacing: 6) {
                    Button("Open telnet on \(label)") { model.openTelnet() }.buttonStyle(.ghostSmall).disabled(!hasTelnet)
                    if !hasTelnet {
                        Text("That host has no telnet client — install the telnet package there, or run this from this machine.")
                            .font(.system(size: 10)).foregroundStyle(p.amber)
                    }
                }.padding(.top, 10)

            case .serial(let ports):
                if ports.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No serial ports on this machine right now.").font(.system(size: 12)).foregroundStyle(p.muted)
                        Text("Plug the adapter in and press Run again. If it still does not appear, it usually wants a driver "
                             + "(CP210x, FTDI or Prolific, depending on the chip) — or, on Linux, a udev rule. A path typed into "
                             + "Port above can be opened whether or not it is listed.")
                            .font(.system(size: 12)).foregroundStyle(p.muted.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 18)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ports, id: \.path) { port in
                            HStack(spacing: 8) {
                                Text(port.path).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                                Text(port.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                                    .lineLimit(1).truncationMode(.tail)
                                    .help([port.label, port.serialNumber.isEmpty ? "" : "serial \(port.serialNumber)",
                                           port.vendorId.isEmpty ? "" : "\(port.vendorId):\(port.productId)"]
                                        .filter { !$0.isEmpty }.joined(separator: "\n"))
                                Spacer(minLength: 4)
                                Button("Use") { model.serialPath = port.path; model.say("Port: \(port.path)") }
                                    .buttonStyle(.ghostSmall).help("Put this port in the Port field")
                                Button("Save…") { model.saveSerial(port.path) }
                                    .buttonStyle(.ghostSmall).help("Keep it as a saved serial connection, at these settings")
                                Button("Open console") { model.openSerial(port.path) }
                                    .buttonStyle(.ghostSmall).help("Open a serial console on it, at the settings above")
                            }.padding(.vertical, 3)
                        }
                    }
                }

            case .tls(let r):
                if !r.ok {
                    NTEmpty(text: r.error ?? "", color: p.red)
                } else {
                    NTCmd(text: "\(r.host):\(r.port)")
                    NTKV(rows: NetWords.tlsRows(r))
                    if let d = r.daysLeft, d < 21 {
                        NTHint(text: d < 0 ? "This certificate has expired." : "This certificate expires soon.",
                               color: d < 0 ? p.red : p.amber).padding(.top, 10)
                    }
                }

            case .http(let r):
                if let f = r.final {
                    NTFlow {
                        NTBadge(text: "\(f.status) \(f.statusMessage)".ntTrimmed, kind: NetWords.statusKind(f.status))
                        NTBadge(text: "\(f.ms)ms")
                        if f.bytes > 0 { NTBadge(text: Fmt.bytes(f.bytes)) }
                        if r.redirects > 0 { NTBadge(text: "\(r.redirects) redirect\(r.redirects == 1 ? "" : "s")", kind: "warn") }
                    }.padding(.bottom, 13)
                    if r.chain.count > 1 {
                        VStack(alignment: .leading, spacing: 2) {
                            NTHead(text: "Redirect chain")
                            ForEach(Array(r.chain.enumerated()), id: \.offset) { _, h in
                                HStack(spacing: 4) {
                                    NTBadge(text: String(h.status), kind: NetWords.statusKind(h.status))
                                    Text(h.url).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }.padding(.bottom, 13)
                    }
                    if !f.headers.isEmpty { NTSection(title: "Response headers", rows: f.headers.map { ($0.0, Optional($0.1)) }) }
                    if !f.preview.isEmpty {
                        NTDetails(title: "First 2 KB of body") { NTPre(text: f.preview, boxed: true) }
                    }
                }

            case .curl(let r, let from):
                curlView(r, from: from)

            case .teleport(let r):
                teleportView(r)

            case .local(let r):
                NTSection(title: "This machine", rows: [("Host name", r.hostname), ("Platform", r.platform),
                                                       ("Resolvers", r.dnsServers.joined(separator: ", "))])
                if !r.addresses.isEmpty {
                    NTSection(title: "Interfaces", rows: r.addresses.map { ("\($0.name) (\($0.family))", $0.cidr ?? $0.address) })
                }

            case .hostFacts(let f, let label):
                HStack(spacing: 8) {
                    NTBadge(text: f.hostname.isEmpty ? (label.isEmpty ? "host" : label) : f.hostname, kind: "name")
                    Text("as the host sees itself").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                }.padding(.bottom, 11)
                ForEach([("addresses", f.addresses), ("routes", f.routes), ("resolvers", f.resolvers)], id: \.0) { name, text in
                    if !text.isEmpty {
                        VStack(alignment: .leading, spacing: 0) { NTHead(text: name); NTPre(text: text) }.padding(.bottom, 13)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func telnetView(_ r: TelnetResult) -> some View {
        let p = Theme.shared.p
        let s = PortStateInfo.of(state: r.state)
        NTCmd(text: ["telnet \(r.host) \(r.port)",
                     r.address.flatMap { $0 != r.host ? "→ \($0)" : nil } ?? "",
                     r.connectMs.map { "connected in \($0)ms" } ?? ""].filter { !$0.isEmpty }.joined(separator: "  ·  "))
        NTFlow {
            NTBadge(text: s.label, kind: r.state == "open" ? "ok" : "warn")
            if r.telnet { NTBadge(text: "speaks telnet", kind: "ok") }
            if let g = r.guess, !r.telnet { NTBadge(text: g, kind: "name") }
            if r.closedByPeer && r.state == "open" { NTBadge(text: "closed by the far end", kind: "warn") }
        }.padding(.bottom, 13)
        if r.state != "open" {
            VStack(alignment: .leading, spacing: 6) {
                Text(r.error ?? s.why).font(.system(size: 12)).foregroundStyle(p.muted).textSelection(.enabled)
                Text(s.why).font(.system(size: 12)).foregroundStyle(p.muted.opacity(0.75))
            }.padding(.vertical, 12)
        } else {
            NTHead(text: "What it said")
            if !r.text.isEmpty {
                NTPre(text: r.text)
            } else {
                NTHint(text: "Nothing, in \(String(format: "%g", (Double(r.listenedMs) / 100).rounded() / 10))s. That is normal for a service that waits "
                       + "to be spoken to — HTTP, TLS and most databases do — and is still a yes: something accepted the connection.")
            }
            HStack(spacing: 6) {
                Button("Open a telnet session") { model.openTelnet() }.buttonStyle(.ghostSmall)
                Button("Copy command") { Clipboard.write(r.command); model.say("Copied") }.buttonStyle(.ghostSmall)
            }.padding(.top, 10)
        }
    }

    @ViewBuilder
    private func curlView(_ r: CurlResult, from: String?) -> some View {
        let p = Theme.shared.p
        let good = r.status != 0 && r.status < 400
        if let from {
            NTHint(text: "Sent from \(from), through a SOCKS proxy over that session — the name was resolved "
                   + "there too, so this is what that host sees.").padding(.bottom, 8)
        }
        HStack(spacing: 8) {
            Text(r.status == 0 ? "no status" : String(r.status))
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .foregroundStyle(Color(hex: "#0d1117"))
                .background(RoundedRectangle(cornerRadius: 3).fill(good ? p.green : p.red))
            Text(r.statusText).font(.system(size: 12))
            Spacer()
            Text([r.httpVersion.isEmpty ? "" : "HTTP/" + r.httpVersion,
                  r.contentType.isEmpty ? "" : String(r.contentType.split(separator: ";").first ?? ""),
                  Fmt.bytes(r.bytes), Fmt.duration(ms: r.ms)].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
        }.padding(.bottom, 11)

        if !r.hops.isEmpty {
            NTHead(text: "Redirects", top: 13)
            NTKV(rows: r.hops.dropLast().map { h in (String(h.status), h.header("Location") ?? h.statusText) }, keyWidth: 40)
        }
        NTHead(text: "Headers", top: 13)
        if r.headers.isEmpty { Text("(none)").font(.system(size: 11.5, design: .monospaced)) }
        NTKV(rows: r.headers.sorted { $0.0 < $1.0 }.map { ($0.0, Optional($0.1)) })
        NTHead(text: "Body", top: 13)
        NTPre(text: r.display.isEmpty ? "(empty)" : r.display)
        if r.displayCut {
            NTHint(text: "Showing the first \(Fmt.bytes(NetCurl.drawLimit)) of \(Fmt.bytes(r.bytes)) — Copy body or Save output… has all of it.",
                   color: p.amber).padding(.top, 4)
        }
        if !r.stderr.isEmpty {
            NTHead(text: "curl said", top: 13)
            NTPre(text: r.stderr, color: p.amber)
        }
        HStack(spacing: 6) {
            Button("Copy as curl") { Clipboard.write(r.command); model.say("Copied the curl command") }.buttonStyle(.ghostSmall)
            Button("Copy body") { Clipboard.write(r.body); model.say("Body copied") }.buttonStyle(.ghostSmall)
        }.padding(.top, 9)
        NTCmd(text: r.command).padding(.top, 7)
    }

    @ViewBuilder
    private func teleportView(_ r: WebAPIPing.Result) -> some View {
        NTCmd(text: "\(r.url) — \(r.ms)ms")
        NTFlow {
            ForEach(Array(r.badges.enumerated()), id: \.offset) { _, b in NTBadge(text: b.text, kind: b.kind) }
        }.padding(.bottom, 13)
        ForEach(Array(r.sections.enumerated()), id: \.offset) { _, s in
            NTSection(title: s.title, rows: s.rows.map { ($0.key, Optional($0.value)) })
        }
        if !r.licenseWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                NTHead(text: "License warnings")
                ForEach(r.licenseWarnings, id: \.self) { Text($0).foregroundStyle(Theme.shared.p.amber).font(.system(size: 12)) }
            }.padding(.bottom, 13)
        }
        // Everything, including fields this build has never heard of.
        NTDetails(title: "Raw JSON") { NTPre(text: NetText.pretty(r.ping), boxed: true) }
    }
}

/// `.nt-ports`: one cell per port, coloured by its verdict.
struct PortGrid: View {
    let results: [PortResult]
    let remote: Bool
    var body: some View {
        let p = Theme.shared.p
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 5)], alignment: .leading, spacing: 5) {
            ForEach(results, id: \.port) { r in
                let s = PortStateInfo.of(state: r.state, open: r.open)
                let edge: Color = s.cls == "open" ? p.green : s.cls == "closed" ? p.red : s.cls == "filtered" ? p.amber : p.border
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(r.port)).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    Text(s.label).font(.system(size: 11.5)).foregroundStyle(s.cls == "unknown" ? p.muted : p.textDim)
                    if remote, let b = r.banner {
                        Text(b).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.tail)
                    }
                    if remote, let e = r.error, r.open != true {
                        Text(e).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.tail)
                    }
                    if !remote, let d = r.detail {
                        Text(d).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 2)
                    Text("\(r.ms)ms").font(.system(size: 10)).foregroundStyle(p.muted)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(alignment: .leading) { edge.frame(width: 2) }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .help(s.why)
            }
        }
    }
}

// MARK: - Copy output (the body's innerText)

extension NetDisplay {
    var plainText: String {
        switch self {
        case .text(let r):
            return [r.command, r.text.isEmpty ? "(no output)" : r.text, r.timedOut ? "Timed out before finishing." : ""]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        case .remoteText(let r, let label):
            if let m = r.missing {
                return ["\(label) has no \(m).", r.hint.map { "to install it\n\($0)" } ?? "Its package manager was not recognised, so there is no command to suggest."].joined(separator: "\n")
            }
            return ["\(label) → \(r.host)", r.text, "Run on the host as: \(r.command)"].joined(separator: "\n")
        case .dns(let r):
            var out: [String] = []
            for rec in r.records { out.append(rec.type); out += rec.values.map(DNSResult.format) }
            if let rev = r.reverse { out.append("PTR"); out += rev }
            if !r.servers.isEmpty { out.append("Resolvers: " + r.servers.joined(separator: ", ")) }
            return out.isEmpty ? "Nothing resolves for \(r.host)." : out.joined(separator: "\n")
        case .ports(let r):
            return ([NetWords.portLine(r, from: nil)] + r.results.map { p in
                "\(p.port)\t\(PortStateInfo.of(state: p.state).label)\t\(p.ms)ms" + (p.detail.map { "\t\($0)" } ?? "")
            }).joined(separator: "\n")
        case .remotePorts(let r, let label):
            return ([NetWords.portLine(r, from: label)] + r.results.map { p in
                "\(p.port)\t\(PortStateInfo.of(state: p.state, open: p.open).label)\t\(p.ms)ms"
                    + (p.banner.map { "\t\($0)" } ?? "") + (p.open != true ? (p.error.map { "\t\($0)" } ?? "") : "")
            }).joined(separator: "\n")
        case .telnet(let r):
            let s = PortStateInfo.of(state: r.state)
            return ["telnet \(r.host) \(r.port)", s.label, r.guess ?? "", r.state == "open" ? r.text : (r.error ?? s.why)]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        case .remoteTelnet(let r, let host, let port, let label, _):
            let f = r.results.first
            let s = PortStateInfo.of(state: f?.state, open: f?.open)
            return ["\(label) → \(host):\(port)", s.label, f?.error ?? s.why, f?.banner ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        case .serial(let ports):
            return ports.isEmpty ? "No serial ports on this machine right now."
                : ports.map { [$0.path, $0.label].filter { !$0.isEmpty }.joined(separator: "  ") }.joined(separator: "\n")
        case .tls(let r):
            return r.ok ? "\(r.host):\(r.port)\n" + NTKV.text(NetWords.tlsRows(r)) : (r.error ?? "")
        case .http(let r):
            guard let f = r.final else { return "" }
            var out = ["\(f.status) \(f.statusMessage)  \(f.ms)ms  \(Fmt.bytes(f.bytes))"]
            if r.chain.count > 1 { out.append("Redirect chain"); out += r.chain.map { "\($0.status) \($0.url)" } }
            out.append("Response headers"); out += f.headers.map { "\($0.0)\t\($0.1)" }
            return out.joined(separator: "\n")
        case .curl(let r, _):
            var out = ["\(r.status) \(r.statusText)"]
            out.append("Headers"); out += r.headers.map { "\($0.0)\t\($0.1)" }
            out.append("Body"); out.append(r.display)
            if !r.stderr.isEmpty { out.append("curl said"); out.append(r.stderr) }
            out.append(r.command)
            return out.joined(separator: "\n")
        case .teleport(let r):
            return (["\(r.url) — \(r.ms)ms", r.badges.map(\.text).joined(separator: "  ")] + r.sections.map { s in
                s.title + "\n" + NTKV.text(s.rows.map { ($0.key, Optional($0.value)) })
            } + (r.licenseWarnings.isEmpty ? [] : ["License warnings\n" + r.licenseWarnings.joined(separator: "\n")]))
                .joined(separator: "\n\n")
        case .local(let r):
            return NTKV.text([("Host name", r.hostname), ("Platform", r.platform), ("Resolvers", r.dnsServers.joined(separator: ", "))])
                + "\n" + NTKV.text(r.addresses.map { ("\($0.name) (\($0.family))", $0.cidr ?? $0.address) })
        case .hostFacts(let f, _):
            return f.ntText
        }
    }
}
