import AppKit
import SwiftUI

/// The Multi-Exec panel: Command / Macros / Recent runs, the target choice
/// (ticks or a tag query), who it runs as, the hosts that could not be dialled,
/// and the runs streaming back per host.
struct DockMultiExecPanel: View {
    let window: WindowModel

    var body: some View {
        let fw = window.feature(FleetWindow.self)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FleetTabs(tabs: [("command", "Command"), ("macros", "Macros"), ("history", "Recent runs")],
                          selection: Binding(get: { fw.mxView }, set: { fw.mxView = $0 }))
                    .padding(.bottom, 8)
                /*
                 * Two ways to say what to run: type it, or pick a macro. They share
                 * the "run as" login and the host selection, so the tabs swap only
                 * the part that differs.
                 */
                switch fw.mxView {
                case "macros": MXMacroPicker(window: window, fw: fw)
                case "history": MXHistory(window: window, fw: fw)
                default: MXCommandForm(window: window, fw: fw)
                }
                MXSelectorRow(window: window, fw: fw)
                Text(fw.targetsLine(runAs: fw.lastRunAs))
                    .font(.system(size: 11)).foregroundStyle(Theme.shared.p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 9)
                if let f = fw.lastFailed, !f.hosts.isEmpty { MXFailedBox(fw: fw, failed: f) }
                ForEach(MultiExecService.shared.runs) { run in MXRunView(window: window, fw: fw, run: run) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The command line: command, run as, Run, Save YAML…, Load YAML…, Ansible….
private struct MXCommandForm: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 7) {
            TextField("Command to run on all selected hosts\u{2026}", text: $fw.lastCommand)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                .autocorrectionDisabled()
                .onSubmit { run() }
            MXRunAsField(fw: fw)
            Button("Run") { run() }.buttonStyle(.primary)
            Button("Save YAML\u{2026}") { Task { @MainActor in await fw.saveRunYaml(fw.lastCommand) } }
                .buttonStyle(.ghost).help("Save this command and host selection as a reusable run")
            Button("Load YAML\u{2026}") { Task { @MainActor in await fw.loadRunYaml() } }
                .buttonStyle(.ghost).help("Open a saved run")
            Button("Ansible\u{2026}") { Task { @MainActor in await fw.exportAnsible(fw.lastCommand) } }
                .buttonStyle(.ghost).help("Turn this command and host selection into a playbook")
        }
        .padding(.bottom, 9)
    }

    private func run() {
        let cmd = fw.lastCommand
        let who = fw.lastRunAs.trimmed
        Task { @MainActor in await fw.runMulti(cmd, runAs: who.nilIfEmpty) }
    }
}

/**
 * Which account to run as. Teleport's ssh_config User is a cluster principal,
 * not necessarily a valid account on each node, so naming one here is often
 * the difference between working and "access denied".
 */
private struct MXRunAsField: View {
    @Bindable var fw: FleetWindow
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 2) {
            TextField("run as\u{2026}", text: $fw.lastRunAs)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
            let logins = fw.knownLogins()
            if !logins.isEmpty {
                Menu {
                    ForEach(logins, id: \.self) { l in Button(l) { fw.lastRunAs = l } }
                } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: 140)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
        .help("Login to use on every selected host")
    }
}

/**
 * Macros as multi-exec targets: the same commands the Saved tab runs on one
 * host, run across the whole selection. A macro that follows a log never ends,
 * one meant to be edited first cannot be edited on fifty hosts at once, and
 * one set to run only in the local shell has no server here — none are listed.
 */
private struct MXMacroPicker: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let all = Macros.shared.all.filter { !$0.interactive && !$0.noEnter && Macros.runsOn($0, "remote") }
        let q = fw.mxMacroFilter.trimmed.lowercased()
        let shown = q.isEmpty ? all : all.filter { "\($0.name) \($0.description) \($0.command) \($0.category)".lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                FleetField(placeholder: "Filter macros\u{2026}", text: $fw.mxMacroFilter)
                MXRunAsField(fw: fw)
            }
            if shown.isEmpty {
                Text(q.isEmpty ? "No macros defined." : "No macro matches.").font(.system(size: 11)).foregroundStyle(p.muted)
                    .padding(.vertical, 6).padding(.horizontal, 2)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(shown, id: \.id) { m in MXMacroButton(macro: m, fw: fw) }
                }
            }
            Text("Runs on every selected host. Macros that follow a log, or that are meant to be edited first, are not listed.")
                .font(.system(size: 11)).foregroundStyle(p.muted).padding(.vertical, 6).padding(.horizontal, 2)
        }
        .padding(.bottom, 4)
    }
}

private struct MXMacroButton: View {
    let macro: Macro
    let fw: FleetWindow
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        let m = macro
        Button {
            let who = fw.lastRunAs.trimmed.nilIfEmpty
            Task { @MainActor in await fw.runMacroMulti(m, login: who) }
        } label: {
            HStack(spacing: 6) {
                Text(m.category.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.muted)
                Text(m.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if m.confirm { FleetTag(text: "careful", color: p.amber) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(hover.on ? p.text : p.textDim)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover.on ? p.panel3 : p.panel2))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(hover.on ? p.accentDim : p.borderSoft))
            .overlay(alignment: .leading) { if m.confirm { p.amber.frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help((m.description.isEmpty ? "" : m.description + "\n\n") + m.command)
    }
}

/**
 * The runs made before, with the hosts each was made on. "The same thing
 * again" is the most common multi-exec, and the tedious part is never the
 * command, it is re-ticking eleven hosts.
 */
private struct MXHistory: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let _ = fw.historyRevision
        let list = FleetStore.execRuns()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("A run is remembered by its command and the hosts it ran on, not its output.")
                    .font(.system(size: 11.5)).foregroundStyle(p.muted)
                Spacer()
                Button("Clear") { FleetStore.clearExecRuns() }.buttonStyle(.ghostSmall)
            }
            .padding(.bottom, 7)
            if list.isEmpty {
                FleetEmpty(text: "No runs yet.", detail: "Every multi-exec is remembered here with the hosts it ran on, so it can be run again.")
            }
            ForEach(list.indices, id: \.self) { i in
                let run = list[i]
                let hosts = run["hosts"].items.compactMap(\.stringish)
                let ok = run["ok"].int ?? 0, failed = run["failed"].int ?? 0
                let query = run["selector"]["query"]
                let byTag = run["selector"].object != nil && !query.isNull
                FleetRow {
                    FleetTag(text: failed > 0 ? "\(ok)/\(ok + failed)" : "\(ok)", color: failed > 0 ? p.red : p.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run["command"].stringish ?? "").font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                        Text([run["label"].stringish ?? "",
                              byTag && !(query.stringish ?? "").isEmpty ? "by tag: \(query.stringish ?? "")" : "\(hosts.count) host\(hosts.count == 1 ? "" : "s")",
                              run["runAs"].truthy ? "as " + (run["runAs"].stringish ?? "") : "",
                              Fmt.date(ms: run["at"].double)].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  "))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                        // The hosts it ran on, by name, as chips — every one of them in the tooltip.
                        if !hosts.isEmpty && !(byTag && !(query.stringish ?? "").isEmpty) {
                            FlowChips(hosts: hosts)
                                .help(hosts.joined(separator: "\n"))
                                .padding(.top, 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Run again") { Task { @MainActor in await fw.rerun(run) } }
                        .buttonStyle(GhostButtonStyle(small: true, prominent: true))
                        .help("Re-select those hosts and run the same command")
                    Button("Edit") { fw.editRun(run) }.buttonStyle(.ghostSmall)
                        .help("Put the command and its hosts back, without running it")
                    Button("\u{00D7}") { if let id = run["id"].string { FleetStore.deleteExecRun(id) } }
                        .buttonStyle(.icon).help("Forget this run")
                }
            }
        }
        .padding(.bottom, 8)
    }
}

/// Up to twelve host chips, then "+N more".
private struct FlowChips: View {
    let hosts: [String]
    var body: some View {
        let p = Theme.shared.p
        let shown = Array(hosts.prefix(12))
        FleetFlowLayout(spacing: 3) {
            ForEach(shown.indices, id: \.self) { FleetTag(text: shown[$0]).font(.system(size: 10.5)) }
            if hosts.count > 12 { Text("+\(hosts.count - 12) more").font(.system(size: 10.5)).foregroundStyle(p.muted) }
        }
    }
}

/// A simple wrapping layout for chips.
struct FleetFlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            widest = max(widest, x)
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/**
 * How the targets are chosen: the ticks in the sidebar, or a cluster and a
 * tag query resolved at run time. The second is what "every prod web node"
 * means, and it does not go stale when a node is added.
 */
private struct MXSelectorRow: View {
    let window: WindowModel
    @Bindable var fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let sel = fw.tagSelector
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { fw.tagSelector.on }, set: { fw.tagSelector.on = $0 })) {
                Text("Choose by tag instead of ticking hosts").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                FleetPicker(options: [("", "Every logged-in cluster")]
                                + Inventory.shared.profiles.filter { !$0.expired }.map { ($0.proxy, $0.cluster.nilIfEmpty ?? $0.proxy) },
                            selection: Binding(get: { fw.tagSelector.proxy }, set: { fw.tagSelector.proxy = $0 }))
                    .frame(maxWidth: 220)
                TextField("env=prod role:web  \u{2014}  the same syntax as the host filter",
                          text: Binding(get: { fw.tagSelector.query }, set: { fw.tagSelector.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    .autocorrectionDisabled()
                Button("Tags\u{2026}") { tags() }.buttonStyle(.ghostSmall).help("Browse the labels in the inventory")
            }
            .opacity(sel.on ? 1 : 0.45)
            .disabled(!sel.on)
        }
        .padding(.top, 2).padding(.bottom, 8)
    }

    private func tags() {
        let current = fw.tagSelector.query
        guard Actions.shared.isRegistered("tag-browser") else {
            StatusBus.shared.show("\u{201C}tag-browser\u{201D} is not available in this build", kind: .warn)
            return
        }
        let get: () -> String = { [weak fw] in fw?.tagSelector.query ?? current }
        let set: (String?) -> Void = { [weak fw] term in
            guard let fw else { return }
            fw.tagSelector.query = term == nil ? "" : "\(fw.tagSelector.query) \(term!)".trimmed
        }
        Actions.shared.perform("tag-browser", window: window, args: ["getFilter": get, "setFilter": set])
    }
}

/**
 * The hosts that never answered, with the way back. Above the results rather
 * than below, because a run that reached eighteen of twenty is read as a
 * success otherwise.
 */
private struct MXFailedBox: View {
    let fw: FleetWindow
    let failed: MXFailed
    var body: some View {
        let p = Theme.shared.p
        let n = failed.hosts.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(p.amber).monospacedDigit()
                Text("host\(n == 1 ? "" : "s") could not be connected" + (failed.runAs.map { " as \($0)" } ?? ""))
                    .font(.system(size: 12))
                Spacer()
                Button("Retry these") { Task { @MainActor in await fw.retryFailed() } }
                    .buttonStyle(GhostButtonStyle(small: true, prominent: true))
                    .help("Dial them again and run the same command \u{2014} only on these hosts")
                Button("Dismiss") { fw.lastFailed = nil }.buttonStyle(.ghostSmall)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(alignment: .bottom) { p.amber.opacity(0.3).frame(height: 1) }
            ForEach(failed.hosts.indices, id: \.self) { i in
                let h = failed.hosts[i]
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(h.target.label + (h.login.map { " (\($0))" } ?? ""))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.textDim).fixedSize()
                    Text(h.error).font(.system(size: 11.5)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(p.amber.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.amber))
        .padding(.top, 8).padding(.bottom, 4)
    }
}

/// One run: the command, the counts, Cancel or Save results…, and a card per host.
private struct MXRunView: View {
    let window: WindowModel
    let fw: FleetWindow
    let run: MultiExecView

    var body: some View {
        let p = Theme.shared.p
        let ok = run.results.filter { $0.status == "done" }.count
        let failed = run.results.filter { ["error", "timeout"].contains($0.status) }.count
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(run.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
                Text("\(ok) ok \u{00B7} \(failed) failed \u{00B7} \(run.results.count) total")
                    .font(.system(size: 11.5)).foregroundStyle(p.muted)
                if run.running {
                    Button("Cancel") { MultiExecService.shared.cancel(run.id) }.buttonStyle(.ghostSmall)
                } else {
                    Button("Save results\u{2026}") { Task { @MainActor in await fw.saveResults(run) } }
                        .buttonStyle(.ghostSmall).help("Write these results to a YAML file")
                }
            }
            ForEach(run.results) { r in MXResultCard(fw: fw, runId: run.id, result: r) }
        }
        .padding(.bottom, 14)
    }
}

private struct MXResultCard: View {
    let fw: FleetWindow
    let runId: String
    let result: MultiExecResult

    var body: some View {
        let p = Theme.shared.p
        let r = result
        let key = runId + "/" + r.connId
        // A clean success starts folded; anything with stderr or a failure open.
        let expanded = fw.expanded[key] ?? !(r.status == "done" && r.stderr.isEmpty)
        // Who it ran as, first — a wall of "permission denied" is read very
        // differently once you can see which account produced it.
        let meta = [ConnectionManager.shared.connection(r.connId)?.login ?? "", r.status,
                    r.exitCode.map { "exit \($0)" } ?? "", r.durationMs.map { Fmt.duration(ms: $0) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MXStatusDot(status: r.status)
                Text(r.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.text)
                Spacer()
                Text(meta).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(p.panel2)
            .contentShape(Rectangle())
            .onTapGesture { fw.expanded[key] = !expanded }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !r.stdout.isEmpty { Text(r.stdout).foregroundStyle(p.textDim) }
                        if !r.stderr.isEmpty { Text(r.stderr).foregroundStyle(p.red) }
                        if r.stdout.isEmpty && r.stderr.isEmpty { Text("(no output)").opacity(0.5) }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .background(p.panel2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.borderSoft))
    }
}

private struct MXStatusDot: View {
    let status: String
    @StateObject private var pulse = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        let c: Color = status == "done" ? p.green : status == "running" ? p.amber
            : (status == "error" || status == "timeout") ? p.red : p.muted
        Circle().fill(c).frame(width: 7, height: 7)
            .opacity(status == "running" && pulse.on ? 0.35 : 1)
            .animation(status == "running" ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse.on)
            .onAppear { if status == "running" { pulse.on = true } }
    }
}
