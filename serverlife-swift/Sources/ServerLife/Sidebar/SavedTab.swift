import SwiftUI

/// The Saved tab: profiles (the hosts owner's list, under this list's
/// headings), macros (fleet's, through `SidebarHooks.macros`) and S3 buckets.
struct SBSavedPanel: View {
    let window: WindowModel
    let sw: SidebarWindow
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch sw.savedView {
                case "macros": SBMacrosPanel(window: window, sw: sw)
                case "s3": S3SavedTab(window: window, filter: sw.filterText)
                default:
                    SavedProfilesList(window: window, filter: sw.filterText) { title, count, key, rows in
                        AnyView(SBSimpleGroup(sw: sw, title: title, count: count, key: key) { rows })
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2).padding(.bottom, 8)
        }
    }
}

/// A collapsible group with the host list's heading look, for lists that
/// are not hosts.
struct SBSimpleGroup<Content: View, Trailing: View>: View {
    let sw: SidebarWindow
    let title: String
    let count: Int
    let key: String
    var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @StateObject private var hover = LocalFlag()

    init(sw: SidebarWindow, title: String, count: Int, key: String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.sw = sw; self.title = title; self.count = count; self.key = key; self.trailing = trailing; self.content = content
    }

    var body: some View {
        let p = Theme.shared.p
        let collapsed = sw.collapsed.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("\u{25BC}").font(SBZoom.font(9)).rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(title.uppercased()).kerning(0.6).lineLimit(1)
                trailing()
                Spacer(minLength: 4)
                Text(String(count)).fontWeight(.regular).opacity(0.65)
            }
            .font(SBZoom.font(10.5, .semibold))
            .foregroundStyle(hover.on ? p.textDim : p.muted)
            .padding(.horizontal, 10).padding(.vertical, SBZoom.px(5))
            .contentShape(Rectangle())
            .onHover { hover.on = $0 }
            .onTapGesture { if collapsed { sw.collapsed.remove(key) } else { sw.collapsed.insert(key) } }
            if !collapsed { content() }
        }
        .padding(.bottom, 2)
    }
}

/// A plain list row (`.sb-item` with a dot, a name and tags).
struct SBPlainRow<Tags: View>: View {
    var dot: Color
    var name: String
    var help: String = ""
    @ViewBuilder var tags: () -> Tags
    var onDouble: () -> Void
    var menu: () -> [CtxItem]
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: SBZoom.px(7)) {
            SBDot(color: dot)
            Text(name).font(SBZoom.font(12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            tags()
        }
        .foregroundStyle(hover.on ? p.text : p.textDim)
        .padding(.leading, SBZoom.px(20)).padding(.trailing, 10).padding(.vertical, SBZoom.px(5))
        .background(hover.on ? p.panel2 : .clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help(help)
        .onTapGesture(count: 2) { onDouble() }
        .sbContextMenu(menu)
    }
}

// MARK: - Macros

private struct SBMacrosPanel: View {
    let window: WindowModel
    let sw: SidebarWindow

    /// The host behind the focused pane, if any.
    private func activeHost() -> (label: String, conn: Connection)? {
        guard let id = window.feature(SessionsWindow.self).activeConnId, let c = ConnectionManager.shared.connection(id) else { return nil }
        return (c.label.nilIfEmpty ?? c.info.hostname ?? "", c)
    }

    var body: some View {
        let p = Theme.shared.p
        if let src = SidebarHooks.macros {
            let all = src.all()
            let shown = all.filter { m in ["name", "command", "description", "category"].contains { sw.matches(m[$0].stringish) } }
            let host = activeHost()
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let host { Text("Runs in ") + Text(host.label).bold().foregroundColor(p.textDim) }
                    else { Text("No session focused — macros will offer to run on a host you pick.") }
                }
                .font(SBZoom.font(11)).foregroundStyle(p.muted)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
                if shown.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(sw.filterText.isEmpty ? "No macros yet." : "No matching macros.")
                        Button("New macro…") { Task { await src.edit([:], window: window) } }.buttonStyle(.ghost)
                    }
                    .font(SBZoom.font(12)).foregroundStyle(p.muted).padding(12)
                } else {
                    let groups = src.categories(shown)
                    ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                        SBSimpleGroup(sw: sw, title: g.category, count: g.items.count, key: "mac:" + g.category) {
                            if groups.count > 1 {
                                HStack(spacing: 1) {
                                    arrow("\u{25B2}", "Move \(g.category) up", disabled: i == 0) { Task { _ = await src.moveCategory(g.category, -1) } }
                                    arrow("\u{25BC}", "Move \(g.category) down", disabled: i == groups.count - 1) { Task { _ = await src.moveCategory(g.category, 1) } }
                                }
                            }
                        } content: {
                            ForEach(Array(g.items.enumerated()), id: \.offset) { _, m in macroRow(m, src) }
                        }
                    }
                    HStack(spacing: 6) {
                        Button("New macro…") { Task { await src.edit([:], window: window) } }.buttonStyle(.ghost)
                        Button("Restore built-ins") { Task { await src.restoreBuiltins() } }.buttonStyle(.ghost)
                            .help("Bring back any built-in macros you have hidden")
                        Button("Export…") { Actions.shared.perform("backup-export", window: window, args: ["what": "macros"]) }
                            .buttonStyle(.ghost).help("Write your macros to a file")
                        Button("Import…") { SBActions.runImport(window: window) }.buttonStyle(.ghost)
                            .help("Load macros, or a whole settings export, from a file")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                }
            }
        } else {
            SBEmptyText(lines: ["Macros are not available in this build."])
        }
    }

    private func arrow(_ glyph: String, _ help: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(glyph).font(SBZoom.font(7)).padding(.horizontal, 3) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.25 : 1).help(help)
    }

    private func macroRow(_ m: JSON, _ src: SidebarMacroSource) -> some View {
        let p = Theme.shared.p
        let id = m["id"].stringish ?? ""
        let scope = src.runScope(m)
        let desc = m["description"].stringish ?? ""
        return SBPlainRow(dot: m["confirm"].truthy ? p.amber : p.muted, name: m["name"].stringish ?? "",
                          help: (desc.isEmpty ? "" : desc + "\n\n") + (m["command"].stringish ?? "")) {
            if src.isPinned(id) {
                SBTag(text: src.pinnedIcon(id), kind: .pinned, help: "Pinned as a button — \(src.pinnedScopeLabel(id).lowercased())")
            }
            if m["confirm"].truthy { SBTag(text: "careful", kind: .mfa, help: "Asks before running") }
            if m["repeatSeconds"].truthy { SBTag(text: "repeats", help: "Runs on a timer once started") }
            if scope != "hosts" {
                SBTag(text: scope == "local" ? "local" : "local too", help: "Offered in: \(src.runScopeLabel(scope).lowercased())")
            }
            if !m["builtin"].truthy { SBTag(text: "mine") }
        } onDouble: {
            runHere(m, src)
        } menu: {
            menu(m, src)
        }
    }

    private func hasTerm() -> Bool {
        window.feature(SessionsWindow.self).activePane?.hasTerm ?? false
    }

    private func runHere(_ m: JSON, _ src: SidebarMacroSource) {
        if hasTerm() { src.send(m, all: false, window: window); return }
        Task {
            if let host = await pickMacroHost() { src.runOnHost(m, host: host, login: HostPrefs.preferredLogin(host), window: window) }
        }
    }

    private func pickMacroHost() async -> Host? {
        let hosts = (Inventory.shared.allNodes + Inventory.shared.sshHosts).filter { SB2.visibleHost($0, sw) }
        if hosts.isEmpty { SBActions.toast("No hosts available", .error); return nil }
        return await SBModal.ask(window, width: 460) { finish in
            DialogScaffold(title: "Run on which host?", width: 460) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(hosts.prefix(200)), id: \.id) { h in
                        SBPickerRow(title: h.name.nilIfEmpty ?? h.alias ?? "") {
                            SBTag(text: h.type == Host.teleport ? (h.cluster ?? "") : "ssh")
                        } action: { finish(h) }
                    }
                }
            } footer: {
                Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            }
            .frame(height: 480)
        }
    }

    private func menu(_ m: JSON, _ src: SidebarMacroSource) -> [CtxItem] {
        let host = activeHost()
        let term = hasTerm()
        var items: [CtxItem] = [
            CtxItem(host.map { "Send to \($0.label)" } ?? "Send to focused terminal") { runHere(m, src) },
            CtxItem("Send to every pane in this tab") { src.send(m, all: true, window: window) },
            CtxItem("Run on a host and show output…") {
                Task { if let h = await pickMacroHost() { src.runOnHost(m, host: h, login: HostPrefs.preferredLogin(h), window: window) } }
            },
        ]
        if !m["interactive"].truthy && !m["noEnter"].truthy {
            items.append(CtxItem("Repeat in the focused pane every…", disabled: !term, title: term ? nil : "Open a session first") {
                src.promptRepeat(m, window: window)
            })
        }
        let builtin = m["builtin"].truthy
        items += [
            .sep,
            CtxItem(src.isPinned(m["id"].stringish ?? "") ? "Unpin from session headers" : "Pin as a button…") {
                Task { await src.togglePin(m, window: window) }
            },
            CtxItem("Copy command") { Clipboard.write(m["command"].stringish ?? ""); SBActions.status("Copied") },
            CtxItem(builtin ? "Duplicate and edit…" : "Edit…") {
                var e = m
                if builtin { e["name"] = .string((m["name"].stringish ?? "") + " copy") }
                Task { await src.edit(e, window: window) }
            },
            CtxItem(builtin ? "Hide this built-in" : "Delete") { Task { _ = await src.delete(m, window: window) } },
        ]
        return items
    }
}
