import AppKit
import SwiftUI

/// The panel itself. Laid out as the original: target, tool and Run on across
/// the top; what the chosen host has; the tool's options; the curl form; the
/// Recent and Saved strips; the result; and the button row.
struct NetToolsView: View {
    @ObservedObject var model: NetToolsModel
    @Environment(Theme.self) private var theme
    @FocusState private var targetFocused: Bool

    var body: some View {
        let p = theme.p
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                head
                capsLine
                optionsRow
                if model.tool == "curl" { curlBlock }
                strips
            }
            .padding(.horizontal, 16).padding(.top, 14)

            ScrollView {
                outputView.padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            p.border.frame(height: 1)
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(p.panel)
        .frame(minWidth: 560, minHeight: 420)
        // Type a host and press Enter, straight away.
        .onAppear { DispatchQueue.main.async { targetFocused = true } }
    }

    // MARK: Head

    private var head: some View {
        let p = theme.p
        return HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Target").font(.system(size: 11)).foregroundStyle(p.muted)
                NTTextBox(placeholder: "host, host:port or URL — anything you want to test", text: $model.target,
                          onSubmit: { model.run() }, focus: $targetFocused)
                    .disabled(!model.needsTarget)
                    .opacity(model.needsTarget ? 1 : 0.45)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text("Tool").font(.system(size: 11)).foregroundStyle(p.muted)
                Menu {
                    ForEach(NetTool.all, id: \.id) { t in
                        let s = model.toolState(t)
                        Button {
                            model.selectTool(t.id)
                        } label: {
                            if t.id == model.tool { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                        .disabled(s.blocked)
                    }
                } label: {
                    Text(model.toolState(NetTool.find(model.tool) ?? NetTool.all[0]).label.components(separatedBy: "  —").first ?? model.tool)
                        .font(.system(size: 12.5))
                }
                .menuStyle(.button)
                .controlSize(.regular)
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Run on").font(.system(size: 11)).foregroundStyle(p.muted)
                Picker("", selection: Binding(get: { model.runOn }, set: { model.setRunOn($0) })) {
                    Text("This machine").tag("")
                    ForEach(model.sessions) { s in Text(s.label).tag(s.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.sessions.isEmpty)
                .help(model.sessions.isEmpty ? "Open a session to run these from a host"
                      : "Run the check from here, or from one of the sessions that is open")
            }
        }
        .padding(.bottom, 9)
    }

    // MARK: What the chosen host has

    @ViewBuilder
    private var capsLine: some View {
        let p = theme.p
        if !model.runOn.isEmpty {
            NTFlow(spacing: 7) {
                if let caps = model.caps {
                    do {
                        let has = ["curl", "dig", "nc", "openssl", "python3", "ping", "mtr", "traceroute", "telnet"].filter { caps.tools.contains($0) }
                        NTBadge(text: caps.os.isEmpty ? (caps.transport.isEmpty ? "host" : caps.transport) : caps.os)
                            .help(caps.error ?? "")
                        Text(caps.canProbeDirect
                             ? "reachability asked of the host itself (ssh -W), HTTP through a proxy over the session"
                             : caps.canForward
                                ? "no shared connection for ssh -W, so the port check uses the host\u{2019}s own tools; HTTP still goes through a proxy over the session"
                                : "this session cannot forward, so checks use what is installed there")
                            .font(.system(size: 11)).foregroundStyle(p.muted)
                        Text("· " + ["ping", "traceroute"].map { id in
                            NetTool.missing(NetTool.find(id), caps) != nil ? "no \(id)" : id
                        }.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(p.muted)
                        if !has.isEmpty { Text("· has " + has.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(p.muted) }
                        if !caps.hints.isEmpty {
                            Text("· missing " + caps.hints.map(\.tool).joined(separator: ", "))
                                .font(.system(size: 11)).foregroundStyle(p.amber)
                                .help(caps.hints.map { "\($0.tool): \($0.hint)" }.joined(separator: "\n"))
                        }
                    }
                } else {
                    Text("Checking what that host has…").font(.system(size: 11)).foregroundStyle(p.muted)
                }
                Button("Re-check") { model.loadCaps(refresh: true) }
                    .buttonStyle(.ghostSmall)
                    .help("Ask the host again — after installing something, say")
            }
            .padding(.top, 2).padding(.bottom, 8)
        }
    }

    // MARK: Options

    @ViewBuilder
    private var optionsRow: some View {
        switch model.tool {
        case "ping":
            NTFlow(spacing: 12) {
                NTField(label: "Packets") { NTTextBox(placeholder: "5", text: $model.count, width: 70) }
            }.padding(.bottom, 9)
        case "ports":
            NTFlow(spacing: 12) {
                NTField(label: "Ports", hint: "Blank uses the port in the target, else the usual SSH and Teleport ports") {
                    NTTextBox(placeholder: "22,443,3022-3025", text: $model.ports, width: 220, onSubmit: { model.run() })
                }
            }.padding(.bottom, 9)
        case "http":
            NTFlow(spacing: 12) {
                NTField(label: "Method") {
                    NTSelect(options: [("GET", "GET"), ("HEAD", "HEAD")], value: $model.method).fixedSize()
                }
            }.padding(.bottom, 9)
        case "telnet":
            let noTelnet = !model.runOn.isEmpty && (model.caps.map { !$0.tools.contains("telnet") } ?? false)
            NTFlow(spacing: 12) {
                NTField(label: "Port", hint: "A port in the target wins over this one") {
                    NTTextBox(placeholder: "23", text: $model.telnetPort, width: 80)
                }
                // What Return sends and local echo belong to the app's own
                // telnet client; from a host it is that host's telnet talking.
                if model.runOn.isEmpty {
                    NTField(label: "Enter sends") { NTSelect(options: newlineOptions, value: $model.telnetNewline).fixedSize() }
                    VStack { Spacer(minLength: 14); Toggle("Show what I type (local echo)", isOn: $model.telnetEcho).font(.system(size: 12)) }
                }
                VStack {
                    Spacer(minLength: 14)
                    Button(model.runOn.isEmpty ? "Open session" : "Open session there") { model.openTelnet() }
                        .buttonStyle(.ghostSmall)
                        .disabled(noTelnet)
                        .help(noTelnet
                              ? "That host has no telnet client — install the telnet package there, or run this from this machine"
                              : model.runOn.isEmpty ? "Open a telnet session to the target in a tab of its own"
                                                    : "Open a terminal on that host running telnet to the target")
                }
            }.padding(.bottom, 9)
        case "serial":
            NTFlow(spacing: 12) {
                NTField(label: "Port") { NTTextBox(placeholder: "/dev/tty.usbserial-1410 or COM3", text: $model.serialPath, width: 240) }
                NTField(label: "Speed") {
                    NTSelect(options: [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600].map { (String($0), String($0)) },
                             value: $model.serialBaud).fixedSize()
                }
                NTField(label: "Data bits") { NTSelect(options: ["8", "7", "6", "5"].map { ($0, $0) }, value: $model.serialDataBits).fixedSize() }
                NTField(label: "Parity") {
                    NTSelect(options: [("none", "None"), ("even", "Even"), ("odd", "Odd")], value: $model.serialParity).fixedSize()
                }
                NTField(label: "Stop bits") { NTSelect(options: [("1", "1"), ("2", "2")], value: $model.serialStopBits).fixedSize() }
                NTField(label: "Flow control") {
                    NTSelect(options: [("none", "None"), ("rtscts", "Hardware (RTS/CTS)"), ("xonxoff", "Software (XON/XOFF)")],
                             value: $model.serialFlow).fixedSize()
                }
                NTField(label: "Enter sends") { NTSelect(options: newlineOptions, value: $model.serialNewline).fixedSize() }
                VStack { Spacer(minLength: 14); Toggle("Show what I type (local echo)", isOn: $model.serialEcho).font(.system(size: 12)) }
                VStack {
                    Spacer(minLength: 14)
                    Button("Open console") { model.openSerial(model.serialPath) }
                        .buttonStyle(.ghostSmall)
                        .help("Open a serial console on this port, at these settings")
                }
            }.padding(.bottom, 9)
        default:
            EmptyView()
        }
    }

    /// What Return sends — the same three choices a saved console offers.
    private var newlineOptions: [(value: String, label: String)] {
        [("cr", "CR — most network gear"), ("lf", "LF — most Unix consoles"), ("crlf", "CRLF — telnet default")]
    }

    // MARK: curl

    private var curlBlock: some View {
        let p = theme.p
        return VStack(alignment: .leading, spacing: 8) {
            NTFlow(spacing: 12) {
                NTField(label: "Method") { NTSelect(options: NetCurl.methods.map { ($0, $0) }, value: $model.curlMethod).fixedSize() }
                NTField(label: "Timeout (s)") { NTTextBox(placeholder: "20", text: $model.curlTimeout, width: 70) }
            }
            NTField(label: "Headers (one per line)") {
                NTTextArea(placeholder: "Accept: application/json\nX-Request-Id: abc123", text: $model.curlHeaders, minHeight: 50)
            }
            NTField(label: "Body") {
                NTTextArea(placeholder: "{ \"name\": \"value\" }", text: $model.curlBody, minHeight: 70)
            }
            NTFlow(spacing: 12) {
                NTField(label: "Content type") {
                    NTSelect(options: [("application/json", "application/json"), ("application/x-www-form-urlencoded", "form-urlencoded"),
                                       ("text/plain", "text/plain"), ("", "none (let curl decide)")], value: $model.curlType).fixedSize()
                }
                NTField(label: "Bearer token") { NTTextBox(placeholder: "a token, if the API wants one", text: $model.curlBearer, width: 240) }
            }
            NTFlow(spacing: 12) {
                NTField(label: "Basic auth") { NTTextBox(placeholder: "user (basic auth)", text: $model.curlUser, width: 180) }
                NTField(label: "Password") { NTTextBox(placeholder: "password", text: $model.curlPass, width: 180, secure: true) }
            }
            Toggle("Follow redirects (-L)", isOn: $model.curlFollow).font(.system(size: 12))
            Toggle("Skip certificate verification (-k)", isOn: $model.curlInsecure).font(.system(size: 12))
            Text(model.curlPreview)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.top, 4).padding(.bottom, 2)
    }

    // MARK: Strips

    @ViewBuilder
    private var strips: some View {
        let showRecent = !model.recents.isEmpty
        let showSaved = model.tool == "curl"
        if showRecent || showSaved {
            VStack(alignment: .leading, spacing: 7) {
                if showRecent {
                    stripHead("Recent") {
                        Button("Clear") { NetSaved.clearRuns(); model.reloadStrips() }.buttonStyle(.ghostSmall)
                    }
                    NTFlow {
                        ForEach(model.recents.indices, id: \.self) { i in recentChip(model.recents[i]) }
                    }
                }
                if showSaved {
                    stripHead("Saved") {
                        Button("Save this…") { model.saveCurrentRequest() }.buttonStyle(.ghostSmall)
                            .help("Keep this request, headers and body, to run again")
                    }
                    if model.saved.isEmpty {
                        Text("Nothing saved yet — Examples… is a good place to start.")
                            .font(.system(size: 10)).foregroundStyle(theme.p.muted)
                    } else {
                        NTFlow {
                            ForEach(model.saved.indices, id: \.self) { i in savedChip(model.saved[i]) }
                        }
                    }
                }
            }
            .padding(.top, 9).padding(.bottom, 4)
        }
    }

    private func stripHead<B: View>(_ title: String, @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(theme.p.muted)
            Spacer()
            button()
        }
    }

    private func recentChip(_ r: JSON) -> some View {
        let tool = r["tool"].string ?? ""
        let on = r["on"]["label"].string ?? ""
        let at = r["at"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
        let tip = ["\(NetTool.label(tool)) \(r["target"].stringish ?? "")",
                   on.isEmpty ? "from this machine" : "from \(on)",
                   r["summary"].stringish ?? "",
                   at.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let main = (r["target"].stringish ?? "").isEmpty ? NetTool.label(tool) : r["target"].stringish!
        return NTChip(tag: String(NetTool.label(tool).split(separator: " ").first ?? ""), text: main,
                      host: on.isEmpty ? nil : "@" + String(on.split(separator: " ").first ?? ""), bad: r["ok"].bool == false)
            .help(tip)
            .onTapGesture { model.runRecent(r) }
    }

    private func savedChip(_ r: JSON) -> some View {
        let method = r["opts"]["method"].string ?? "GET"
        let on = r["on"]["label"].string ?? ""
        let tip = ["\(method) \(r["target"].stringish ?? "")", on.isEmpty ? "from this machine" : "from \(on)"].joined(separator: "\n")
        return NTChip(tag: method, text: r["name"].stringish ?? "", host: on.isEmpty ? nil : "@" + String(on.split(separator: " ").first ?? ""))
            .help(tip)
            .onTapGesture { model.runSaved(r) }
            .contextMenu {
                Text(r["name"].stringish ?? "")
                Button("Run it") { model.runSaved(r) }
                Button("Rename…") { model.renameSaved(r) }
                Button("Copy as curl") { model.copySavedAsCurl(r) }
                Divider()
                Button("Delete") { model.deleteSaved(r) }
            }
    }

    // MARK: Output

    @ViewBuilder
    private var outputView: some View {
        let p = theme.p
        switch model.output {
        case .help(let id):
            NetHelp(tool: id)
        case .running(let text):
            NTEmpty(text: text)
        case .loaded(let name, let why):
            VStack(spacing: 6) {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(why).font(.system(size: 12)).opacity(0.8)
                Text("Edit anything and press Run.").font(.system(size: 12)).opacity(0.7)
            }
            .foregroundStyle(p.muted).frame(maxWidth: .infinity).padding(.vertical, 18)
        case .error(let m):
            NTEmpty(text: m, color: p.red)
        case .result(let d):
            NetResultView(display: d, model: model)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let n = model.note {
                Text(n.text).font(.system(size: 11.5)).lineLimit(2)
                    .foregroundStyle(n.kind == .error ? theme.p.red : n.kind == .warn ? theme.p.amber
                                     : n.kind == .ok ? theme.p.green : theme.p.textDim)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Close") { model.handle?.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Copy output") { model.copyOutput() }.buttonStyle(.ghost)
            examplesMenu
            Button("Save output…") { model.saveOutput() }.buttonStyle(.ghost)
            Button("Run") { model.run() }.buttonStyle(.primary).disabled(model.running)
        }
    }

    private var examplesMenu: some View {
        let list = model.examples(for: model.tool)
        return Menu {
            Section("Typical \(NetTool.label(model.tool)) calls") {
                if list.isEmpty {
                    Button("Nothing to suggest for this tool") {}.disabled(true)
                } else {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, x in
                        Button(x.name) { model.loadExample(x) }.help(x.why)
                    }
                }
            }
        } label: {
            Text("Examples…").font(.system(size: 12))
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Typical things to run with the selected tool")
    }
}

/// `.nt-chip`.
struct NTChip: View {
    let tag: String
    let text: String
    var host: String? = nil
    var bad = false
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 5) {
            Text(tag).font(.system(size: 9.5, design: .monospaced)).kerning(0.4).foregroundStyle(bad ? p.red : p.accent)
            Text(text).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            if let host { Text(host).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(bad ? p.red : p.accent) }
        }
        .foregroundStyle(hover.on ? p.text : p.textDim)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 3).fill(p.panel3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(hover.on ? p.accent : .clear))
        .fixedSize()
        .onHover { hover.on = $0 }
        .contentShape(Rectangle())
    }
}

/// The help panel a tool opens with: what it tells you, and the two or three
/// things people typically run it for.
struct NetHelp: View {
    let tool: String

    static func hint(_ id: String) -> String {
        [
            "ping": "Round-trip time and packet loss.",
            "traceroute": "The path packets take, hop by hop.",
            "dns": "A, AAAA, CNAME, MX, TXT, NS and SRV records, plus PTR for an address.",
            "ports": "Whether a TCP port accepts a connection. A target written host:port checks that port.",
            "telnet": "Run connects and listens for a few seconds — what answered, and what it said. "
                + "Open session starts a real telnet session; from a host, that host\u{2019}s own telnet in a terminal there.",
            "serial": "The serial ports on this machine — USB adapters, console cables. Run lists them; "
                + "open one at the settings above. Hardware flow control on a cable with no CTS wire looks "
                + "exactly like a dead port, so leave it off unless the device asks for it.",
            "tls": "The certificate a server presents, valid or not.",
            "http": "Status, headers, timing and the redirect chain.",
            "curl": "A full HTTP request through curl itself — method, headers, body, auth — with the command shown as it will run.",
            "whois": "Registration for a domain or address.",
            "teleport": "A proxy\u{2019}s /webapi/ping — version, edition, auth and listeners. No login needed.",
            "local": "Interfaces and resolvers on this machine.",
        ][id] ?? "Press Run."
    }

    static func typical(_ id: String) -> [String] {
        [
            "ping": ["Five packets at a host, to see loss and round-trip time",
                     "Twenty at one that drops out, to catch loss that comes and goes",
                     "The default gateway, to rule out the local network first"],
            "traceroute": ["Find the hop where a route stops — usually the answer",
                           "Compare the path to a known-good address like 1.1.1.1"],
            "dns": ["Everything a name resolves to, in one pass", "A PTR for an address, to see which name claims it",
                    "An SRV record, for how clients discover a service"],
            "ports": ["The Teleport set — 443, 3023, 3024, 3025, 3080", "Just 22, when ssh hangs rather than refuses",
                      "The local end of a port forward, to prove the tunnel is up"],
            "telnet": ["A switch, PDU or terminal server that only answers on 23",
                       "What a port says when it is connected to — SSH, SMTP and friends name themselves",
                       "Which address a name resolves to today, the way telnet always told you"],
            "serial": ["Which USB serial adapters this machine can see right now",
                       "A console at 115200 8N1 — or 9600, for older network gear",
                       "Keep one you go back to as a saved connection"],
            "tls": ["How many days are left on a certificate", "Which names it actually covers (its SANs)",
                    "What a non-standard port is presenting"],
            "http": ["Whether a URL answers, and how quickly", "Where a redirect chain ends up", "Headers only, with a HEAD request"],
            "curl": ["GET a JSON API and read it back formatted", "POST a JSON body, with a bearer token if it needs one",
                     "Fire a webhook, and keep the call to fire again later"],
            "whois": ["Who a domain belongs to, and when it expires", "Which network an address belongs to"],
            "teleport": ["A cluster\u{2019}s version and edition, without logging in",
                         "Which auth connector is in play, and whether it is passwordless",
                         "Every listener, including Kubernetes and database addresses"],
            "local": ["This machine\u{2019}s addresses, when the problem may be here", "Which resolvers it is using"],
        ][id] ?? []
    }

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            Text(NetHelp.hint(tool)).font(.system(size: 12)).opacity(0.9).fixedSize(horizontal: false, vertical: true)
            let typical = NetHelp.typical(tool)
            if !typical.isEmpty {
                Text("TYPICAL THINGS TO RUN").font(.system(size: 10)).kerning(0.8).opacity(0.55).padding(.top, 9)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(typical, id: \.self) { t in
                        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(t).fixedSize(horizontal: false, vertical: true) }
                            .font(.system(size: 12))
                    }
                }
                .opacity(0.8).padding(.top, 5).padding(.leading, 4)
            }
            Text("Examples\u{2026} fills any of these in for you.").font(.system(size: 12)).opacity(0.7).padding(.top, 9)
        }
        .foregroundStyle(p.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }
}
