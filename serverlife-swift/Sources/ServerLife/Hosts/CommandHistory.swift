import AppKit
import SwiftUI

/// history.js: what this account has typed on this host before, read from
/// the host's own history files, searchable — and somewhere for the result
/// to go: the clipboard, the prompt, or a macro.
@MainActor
enum CommandHistory {
    /// Newest first, filtered by every word in the query, anywhere in the command.
    static func matching(_ entries: [ShellHistoryEntry], _ query: String) -> [ShellHistoryEntry] {
        let terms = query.trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if terms.isEmpty { return entries }
        return entries.filter { e in
            let c = e.command.lowercased()
            return terms.allSatisfy { c.contains($0) }
        }
    }

    /// `openHistoryDialog(pane)`: for a remote pane (its `paneId` and `connId`).
    static func open(_ window: WindowModel?, paneId: String?, connId: String?) {
        guard let connId, !connId.isEmpty else {
            return HToast.error("Command history is read from the host — open it on a server session")
        }
        let model = CommandHistoryModel(window: window, paneId: paneId, connId: connId)
        Modal.sheet(window, title: "Command history", width: 760) { handle in
            CommandHistoryView(model: model, close: { handle.close() })
        }
        model.load(refresh: false)
    }
}

@MainActor
final class CommandHistoryModel: ObservableObject {
    weak var window: WindowModel?
    let paneId: String?
    let connId: String
    let label: String?
    @Published var data: ShellHistory?
    @Published var error: String?
    @Published var selected: String?
    @Published var search = ""

    init(window: WindowModel?, paneId: String?, connId: String) {
        self.window = window
        self.paneId = paneId
        self.connId = connId
        label = ConnectionManager.shared.connection(connId)?.label
    }

    func load(refresh: Bool) {
        error = nil
        data = nil
        Task { @MainActor in
            do { data = try await ConnectionManager.shared.shellHistory(connId, refresh: refresh) }
            catch { self.error = hostsErrorText(error) }
        }
    }

    var found: [ShellHistoryEntry] { data.map { CommandHistory.matching($0.entries, search) } ?? [] }

    var countText: String {
        guard let data else { return "" }
        return search.trimmed.isEmpty ? "\(data.entries.count) commands" : "\(found.count) of \(data.entries.count)"
    }

    /// The pane this was opened on, if it is still there. Only that pane is
    /// ever typed into: a command read from one host must never land in
    /// another session.
    private func target() -> String? {
        guard let id = paneId, SessionsCore.owner(ofPane: id)?.pane(id) != nil else {
            HToast.error("That session has closed")
            return nil
        }
        return id
    }

    /// Paste it at the prompt, without pressing Enter.
    func insert(_ cmd: String) {
        guard let paneId = target() else { return }
        HostsOpen.sendText(cmd, enter: false, paneId: paneId, window: window)
        StatusBus.shared.show("Put at the prompt — press Enter to run it")
    }

    func run(_ cmd: String) {
        guard let paneId = target() else { return }
        HostsOpen.sendText(QuickConnect.replace(QuickConnect.re(#"\n*$"#), cmd), enter: true, paneId: paneId, window: window)
        StatusBus.shared.show("Ran on \(label ?? "the host")")
    }

    func copy(_ cmd: String) {
        Clipboard.write(cmd)
        StatusBus.shared.show("Copied")
    }

    /// fleet's macro editor, prefilled; it came off a server, so that is where it belongs.
    func toMacro(_ cmd: String) {
        let words = cmd.split(whereSeparator: { $0.isWhitespace }).prefix(3).joined(separator: " ")
        let macro: JSON = ["command": .string(cmd), "category": "Custom", "where": "hosts",
                           "name": .string(String(words.prefix(40)))]
        Actions.shared.perform("macro-edit", window: window, args: ["macro": macro, "reply": { (saved: JSON?) in
            if let saved {
                StatusBus.shared.show("Saved \(saved["name"].truthy ? saved["name"].stringish ?? "macro" : "macro") — it is in the ▶ menu now")
            }
        } as (JSON?) -> Void])
    }

    func need(_ f: (String) -> Void) {
        guard let s = selected else { return HToast.error("Pick a command from the list first") }
        f(s)
    }
}

private struct CommandHistoryView: View {
    @ObservedObject var model: CommandHistoryModel
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Command history", subtitle: model.label ?? "this host", width: 760, scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search the history…", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit {
                            // Enter on a search puts the top match at the prompt.
                            guard model.data != nil, let top = model.found.first else { return }
                            model.selected = top.command
                            model.insert(top.command)
                        }
                    Text(model.countText).font(.system(size: 11)).foregroundStyle(p.muted).fixedSize()
                    Button("Re-read") { model.load(refresh: true) }.buttonStyle(.ghostSmall)
                        .help("Ask the host again — after a shell has written more of it out")
                }
                HListBox(maxHeight: .infinity) { list }
                MiscHint(text: "Read from the host’s history files, newest first and each command once. "
                         + "bash writes its file when the shell exits, so what you are typing in the "
                         + "session next door is usually not in here yet — Re-read picks it up afterwards.")
                    .padding(.top, 1)
            }
        } footer: {
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Copy") { model.need(model.copy) }.buttonStyle(.ghost)
            Button("Make a macro…") { model.need(model.toMacro) }.buttonStyle(.ghost)
            Button("Run it") { model.need(model.run) }.buttonStyle(.ghost).help("Send it to this session and press Enter")
            Button("Put at the prompt") { model.need(model.insert) }.buttonStyle(.primary)
        }
        .frame(height: 560)
        .onAppear { after(0.05) { focused = true } }
    }

    @ViewBuilder private var list: some View {
        let p = Theme.shared.p
        if let e = model.error {
            VStack(alignment: .leading, spacing: 8) {
                Text(e).font(.system(size: 12)).foregroundStyle(p.red).textSelection(.enabled)
                MiscHint(text: "The history is read from the files the shell writes — "
                         + "~/.bash_history, ~/.zsh_history and the like. An account with none of "
                         + "them, or a shell configured not to keep one, has nothing to show.")
            }
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let data = model.data {
            let found = model.found
            if found.isEmpty {
                HEmpty(text: data.entries.isEmpty ? "No history found for this account." : "Nothing matches that.")
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(found.prefix(500).enumerated()), id: \.offset) { _, e in row(e) }
                        if found.count > 500 { HEmpty(text: "\(found.count - 500) more — narrow the search to see them.") }
                    }
                    .padding(4)
                }
            }
        } else {
            HEmpty(text: "Reading the history…").frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ e: ShellHistoryEntry) -> some View {
        let p = Theme.shared.p
        let on = e.command == model.selected
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(e.command)
                .font(.system(size: 11.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let at = e.at { Text(Fmt.date(ms: at)).font(.system(size: 11)).foregroundStyle(p.muted).fixedSize() }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(on ? p.accent.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .help(e.at.map { "\(e.command)\n\n\(Fmt.date(ms: $0))" } ?? e.command)
        // A click selects; the buttons act. Running something on a server is
        // not what a single click should mean.
        .gesture(TapGesture(count: 2).onEnded { model.insert(e.command) }
            .exclusively(before: TapGesture(count: 1).onEnded { model.selected = e.command }))
        .contextMenu {
            Section(String(e.command.prefix(80))) {
                Button("Put it at the prompt") { model.insert(e.command) }
                Button("Run it now") { model.run(e.command) }
                Divider()
                Button("Copy") { model.copy(e.command) }
                Button("Make a macro from it…") { model.toMacro(e.command) }
            }
        }
    }
}
