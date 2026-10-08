import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A drag that started in an explorer: which one, and what it carries. The
/// pointer has to say *move* within one pane and *copy* between two before
/// the drop, when the payload cannot be read yet — so it is written down here.
@MainActor
enum XPDrag {
    static let type = UTType(exportedAs: "com.serverlife.explorer-entries")
    static var fromId: String?
    static var entries: [FileEntry] = []
}

/// Widths at which a narrow explorer sheds chrome (the stylesheet's
/// container queries).
struct XPWidths {
    let w: CGFloat
    var hideNav: Bool { w < 300 }
    var hideExtra: Bool { w < 250 }
    var hideOwner: Bool { w < 430 }
    var hidePerm: Bool { w < 360 }
    var tight: Bool { w < 360 }
    var hideDate: Bool { w < 285 }
    var hideSize: Bool { w < 215 }
}

/// One explorer, drawn (`.fpane`).
struct ExplorerView: View {
    let ex: ExplorerModel
    /// The copy drawn over the whole window while maximized.
    var filling = false

    var body: some View {
        if ex.maximized && !filling {
            // The pane itself is drawn over the window; nothing stays here.
            Theme.shared.p.panel
        } else {
            pane
        }
    }

    private var pane: some View {
        let p = Theme.shared.p
        return GeometryReader { g in
            let widths = XPWidths(w: g.size.width)
            VStack(spacing: 0) {
                XPHeader(ex: ex, widths: widths)
                XPPathBar(ex: ex)
                if ex.favScopeNow != nil { XPFavBar(ex: ex) }
                if ex.filterShown { XPFilterBar(ex: ex) }
                if ex.listReady && ex.city == nil { XPColumnHead(ex: ex, widths: widths) }
                if ex.listReady, let c = ex.city {
                    c.view.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    XPList(ex: ex, widths: widths)
                }
                XPStatusBar(ex: ex)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(p.panel)
        .overlay {
            if ex.dragOver { RoundedRectangle(cornerRadius: 2).stroke(p.accentDim, lineWidth: 2).allowsHitTesting(false) }
        }
        .onDrop(of: [XPDrag.type, .fileURL], delegate: XPDropDelegate(ex: ex, row: nil, pane: true))
        .onAppear {
            ex.render()
            // Shown again: load what never loaded, re-list what was paused.
            if ex.paneId != nil, !ex.isCompanion { XPFiles.catchUpVisible(ex.paneId) }
            Task { await ex.ensureLoaded() }
        }
    }
}

// MARK: - Header

private struct XPHeader: View {
    let ex: ExplorerModel
    let widths: XPWidths

    private func btn(_ label: String, _ help: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 12)) }
            .buttonStyle(IconButtonStyle(size: 20, active: active))
            .help(help)
    }

    var body: some View {
        let p = Theme.shared.p
        let s = Store.shared
        let companion = ex.paneId.flatMap { XPPaneExplorers.shared.companion(of: $0) }
        let isCompanion = ex.isCompanion
        HStack(spacing: 4) {
            XPSourcePicker(ex: ex)
            HStack(spacing: 1) {
                // One click to put the local filesystem below this one.
                btn("\u{1F4BB}", isCompanion ? "Hide the local file list" : "Show local files below (drag to upload/download)",
                    active: isCompanion || companion != nil) { ex.onChange?("toggle-local") }
                btn("⌖", "Go to a path…") { Task { await XPDialogs.goToPath(ex) } }
                btn("↑", "Parent") { Task { await ex.goParent() } }
                if !widths.hideNav {
                    btn("‹", "Back") { Task { await ex.historyGo(-1) } }
                    btn("›", "Forward") { Task { await ex.historyGo(1) } }
                }
                btn("⟳", "Refresh") { Task { await ex.refresh() } }
                if let scope = ex.favScopeNow {
                    Button { Task { await ex.toggleFavorite(ex.view.path) } } label: {
                        Text(ex.favOn ? "\u{2605}" : "\u{2606}").font(.system(size: 12))
                            .foregroundStyle(ex.favOn ? p.amber : p.muted)
                    }
                    .buttonStyle(IconButtonStyle(size: 20, active: ex.favOn))
                    .help(ex.favOn ? "Starred — click to remove \(ex.view.path ?? "")"
                                   : "Star \(ex.view.path ?? "this folder") for \(scope.label)")
                    .xpOnRightClick { Task { CtxMenu.show(await ex.starMenuItems()) } }
                }
                btn("\u{1F50E}", "Search this folder and everything under it…") { Task { await XPSearch.open(ex) } }
                if s.xpShow3d {
                    Button { ex.toggle3d() } label: {
                        Text("3D").font(.system(size: 10, weight: .bold)).padding(.horizontal, 2)
                    }
                    .buttonStyle(IconButtonStyle(size: 20, active: ex.city != nil))
                    .help("See this folder in 3D — fly over it, walk into folders")
                }
                if !widths.hideExtra {
                    btn("+", "New folder") { Task { await ex.makeDir() } }
                    Button { CtxMenu.show(ex.sortMenuItems()) } label: { Text("\u{21C5}").font(.system(size: 12)) }
                        .buttonStyle(IconButtonStyle(size: 20)).help("Sort")
                    btn("\u{21C4}", ex.compare != nil ? "Clear the comparison" : "Compare with the other list",
                        active: ex.compare != nil) {
                        if ex.compare != nil { ex.clearCompare() } else { Task { await ex.compareWith() } }
                    }
                    if !ex.isS3 {
                        btn("\u{21C6}", "Synchronize with the other list…") { Task { await ex.syncWith() } }
                        // Permissions and owner as columns — a view setting, not a per-pane one.
                        btn("≣", "Show permissions and owner", active: s.xpShowDetails) {
                            s.xpShowDetails.toggle()
                            Explorers.shared.forEach { $0.render() }
                        }
                    }
                    // Only the explorer bound to its own pane's session can follow that shell.
                    if ex.source.pinnedConnId == nil && !ex.isLocal && !ex.isS3 {
                        btn("⇲", "Follow the terminal’s folder", active: s.xpFollowTerminal) {
                            s.xpFollowTerminal.toggle()
                            // Switching it back on means "go to where the shell is".
                            if s.xpFollowTerminal { Explorers.shared.forEach { $0.followedCwd = nil } }
                        }
                    }
                }
                btn("⌕", "Filter by name", active: !ex.filter.isEmpty || ex.filterShown) { ex.toggleFilter() }
                btn("•", "Show hidden files", active: s.xpShowHidden) {
                    s.xpShowHidden.toggle()
                    Explorers.shared.forEach { $0.render() }
                }
                btn("×", "Hide this explorer") { ex.onChange?("hide") }
            }
            .fixedSize()
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .frame(width: widths.w, alignment: .leading)
        .background(p.panel2)
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
        .clipped()
    }
}

private struct XPSourcePicker: View {
    let ex: ExplorerModel
    var body: some View {
        let opts = ex.sourceOptions()
        let value = ex.sourceValue
        Picker("", selection: Binding(get: { opts.contains { $0.value == value } ? value : (opts.first?.value ?? "local") },
                                      set: { v in Task { await ex.pickSource(v) } })) {
            ForEach(opts, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(.system(size: 11))
        .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(-1)
        .help("What this explorer shows")
    }
}

// MARK: - Path, starred, filter

private struct XPPathBar: View {
    let ex: ExplorerModel
    @StateObject private var text = Local("")
    @StateObject private var editing = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let path = ex.view.path ?? ""
        XPTextField(text: $text.value, placeholder: "/", size: 11.5,
                    onEnter: { Task { try? await ex.navigate(text.value.trimmed) } },
                    onEscape: { text.value = path; NSApp.keyWindow?.makeFirstResponder(nil) },
                    onFocus: { f in editing.on = f; ex.pathEditing = f })
            .padding(.horizontal, 7).padding(.vertical, 3)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(editing.on ? p.accentDim : p.border))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
            .onAppear { text.value = path }
            .onChange(of: path) { _, v in if !editing.on { text.value = v } }
            .onChange(of: ex.sourceValue) { _, _ in if !editing.on { text.value = ex.view.path ?? "" } }
    }
}

/// The starred folders, as a list above the files.
private struct XPFavBar: View {
    let ex: ExplorerModel

    var body: some View {
        let p = Theme.shared.p
        let collapsed = Store.shared.xpFavListCollapsed
        let favs = ex.favList
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("▼").font(.system(size: 8)).rotationEffect(.degrees(collapsed ? -90 : 0))
                Text("STARRED").font(.system(size: 9.5, weight: .semibold)).kerning(0.8)
                Spacer()
                Text(favs.isEmpty ? "" : String(favs.count)).font(.system(size: 9.5)).opacity(0.7)
            }
            .foregroundStyle(p.muted)
            .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 3)
            .contentShape(Rectangle())
            .onTapGesture { ex.setFavListCollapsed(!collapsed) }
            if !collapsed {
                if favs.isEmpty {
                    Text("Nothing starred here yet — the ☆ in the toolbar keeps this folder.")
                        .font(.system(size: 11)).foregroundStyle(p.muted).opacity(0.75)
                        .padding(.horizontal, 9).padding(.bottom, 5)
                        .help("The star in the toolbar keeps the folder you are in")
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(favs) { f in XPFavRow(ex: ex, f: f, here: f.path == ex.view.path) }
                        }
                    }
                    .frame(maxHeight: min(CGFloat(favs.count) * 20, 140))
                }
            }
        }
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
    }
}

private struct XPFavRow: View {
    let ex: ExplorerModel
    let f: XPFavorite
    let here: Bool
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let file = f.kind == "file"
        HStack(spacing: 7) {
            Text("★").font(.system(size: 9)).foregroundStyle(here ? .white : file ? p.accent : p.amber)
            Text(f.label).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer(minLength: 4)
            Text(XP.shortPath(f.path)).font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(here ? Color.white.opacity(0.85) : p.muted).lineLimit(1).truncationMode(.head)
            if f.scope == "hosts" {
                Text("ALL").font(.system(size: 9)).kerning(0.4).foregroundStyle(here ? .white : p.purple)
                    .help("Starred for every host")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(here ? Color.white : hover.on ? p.text : p.textDim)
        .padding(.horizontal, 9).padding(.vertical, 2)
        .frame(height: 20)
        .background(here ? p.accentDim : hover.on ? p.panel2 : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help(f.path + (f.scope == "hosts" ? "  ·  starred for every host" : "")
              + (f.builtin ? "  ·  one of the built-in ones" : "")
              + (file ? "  ·  a file; opens when clicked" : ""))
        .onTapGesture {
            Task { if file { await ex.openFavFile(f.path) } else { try? await ex.navigate(f.path) } }
        }
        .xpOnRightClick { CtxMenu.show(ex.favRowMenuItems(f)) }
    }
}

/// The name filter, directly under the path it applies to — tinted, so a
/// filter still in force is obvious at a glance.
private struct XPFilterBar: View {
    let ex: ExplorerModel
    @StateObject private var text = Local("")

    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 4) {
            XPTextField(text: $text.value, placeholder: "Filter by name — *.log, conf, id_*", size: 11.5,
                        tooltip: "Matches anywhere in the name. * and ? are wildcards.\n↑ ↓ move through the matches · Enter opens · Esc clears",
                        focusToken: ex.filterFocusToken,
                        onChange: { ex.filterChanged($0) },
                        onEnter: { ex.openFromFilter() },
                        onEscape: {
                            // Clear first, close only if it was already empty.
                            if !ex.filter.isEmpty { ex.clearFilter() } else { ex.toggleFilter(false); ex.listFocusToken += 1 }
                        },
                        onArrow: { ex.moveSelection($0) })
                .padding(.horizontal, 7).padding(.vertical, 3)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
            Button("×") { ex.clearFilter(); ex.toggleFilter(false) }
                .buttonStyle(IconButtonStyle(size: 20)).help("Clear the filter")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(p.accent.opacity(0.07))
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
        .onAppear { text.value = ex.filter }
        .onChange(of: ex.filter) { _, v in if text.value != v { text.value = v } }
    }
}

// MARK: - Columns and rows

private struct XPColumnHead: View {
    let ex: ExplorerModel
    let widths: XPWidths

    private func cell(_ key: String, _ label: String) -> some View {
        let on = ex.sort.key == key
        return Text(label.uppercased() + (on ? (ex.sort.dir == 1 ? " \u{25B4}" : " \u{25BE}") : ""))
            .foregroundStyle(on ? Theme.shared.p.text : Theme.shared.p.muted)
            .contentShape(Rectangle())
            .onTapGesture { ex.sortBy(key) }
            .help("Sort by \(label.lowercased()) — click again to reverse")
    }

    var body: some View {
        let p = Theme.shared.p
        let details = Store.shared.xpShowDetails && !ex.isS3
        HStack(spacing: widths.tight ? 5 : 7) {
            Color.clear.frame(width: 10, height: 1)
            Color.clear.frame(width: 15, height: 1)
            cell("name", "Name").frame(minWidth: widths.tight ? 96 : 132, maxWidth: .infinity, alignment: .leading)
            if details && !widths.hidePerm { Text("MODE").frame(width: 78, alignment: .leading) }
            if details && !widths.hideOwner { Text("OWNER").frame(width: 96, alignment: .leading) }
            if !widths.hideSize { cell("size", "Size").frame(width: widths.tight ? 50 : 58, alignment: .trailing) }
            if !widths.hideDate { cell("mtime", "Date").frame(width: 78, alignment: .leading) }
        }
        .font(.system(size: 9.5))
        .kerning(0.4)
        .foregroundStyle(p.muted)
        .lineLimit(1)
        .padding(.leading, 10).padding(.trailing, 8).padding(.top, 2).padding(.bottom, 3)
        .background(p.panel)
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
    }
}

private struct XPList: View {
    let ex: ExplorerModel
    let widths: XPWidths
    @FocusState private var focused: Bool
    static let rowHeight: CGFloat = 21

    var body: some View {
        let p = Theme.shared.p
        GeometryReader { g in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        content(height: g.size.height)
                    }
                }
                .onChange(of: ex.scrollTarget?.token) { _, _ in
                    if let t = ex.scrollTarget { withAnimation(nil) { proxy.scrollTo(t.path, anchor: t.center ? .center : nil) } }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: ex.listFocusToken) { _, _ in focused = true }
        .onChange(of: focused) { _, f in ex.listFocused = f }
        .onKeyPress(phases: .down) { press in
            let key: String
            switch press.key {
            case .upArrow: key = "up"
            case .downArrow: key = "down"
            case .leftArrow: key = "left"
            case .rightArrow: key = "right"
            case .return: key = "return"
            case .escape: key = "escape"
            case .delete: key = "delete"
            case .deleteForward: key = "forwardDelete"
            default: key = ""
            }
            let m = press.modifiers
            return ex.handleKey(key, chars: press.characters, command: m.contains(.command), control: m.contains(.control),
                                option: m.contains(.option)) ? .handled : .ignored
        }
        .background(p.panel)
    }

    @ViewBuilder
    private func content(height: CGFloat) -> some View {
        let p = Theme.shared.p
        if let notice = XPNotice.of(ex) {
            notice.frame(maxWidth: .infinity).padding(.horizontal, 14).padding(.vertical, 22)
                .xpOnRightClick { ex.showContextMenu(for: nil) }
        } else {
            let rows = ex.rows()
            let details = Store.shared.xpShowDetails && !ex.isS3
            if rows.isEmpty { XPEmptyNotice(ex: ex).frame(maxWidth: .infinity).padding(.vertical, 22) }
            ForEach(rows) { r in
                switch r.kind {
                case .entry(let e):
                    XPRowView(ex: ex, entry: e, depth: r.depth, details: details, widths: widths,
                              selected: ex.view.selection.contains(e.path), expanded: ex.view.expanded.contains(e.path),
                              verdict: ex.compare?[e.name]) { focused = true }
                        .id(e.path)
                case .note(let text, let err):
                    Text(text).font(.system(size: 12)).italic()
                        .foregroundStyle(err ? p.red : p.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat(8 + r.depth * 14) + 2).padding(.vertical, 3)
                        .frame(height: XPList.rowHeight)
                }
            }
            // The blank space below the rows: its menu is about this folder.
            Color.clear
                .frame(height: max(40, height - CGFloat(rows.count) * XPList.rowHeight))
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                .xpOnRightClick { ex.showContextMenu(for: nil) }
        }
    }
}

private struct XPRowView: View {
    let ex: ExplorerModel
    let entry: FileEntry
    let depth: Int
    let details: Bool
    let widths: XPWidths
    let selected: Bool
    let expanded: Bool
    let verdict: String?
    let focusList: () -> Void
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let dir = XP.isDir(entry)
        let link = entry.type == .symlink
        let broken = entry.targetType == .broken
        let dim: Color = selected ? Color.white.opacity(0.8) : p.muted
        let nameColor: Color = selected ? .white : broken ? p.red : link ? p.purple : dir ? p.accent : p.text
        let edge: Color = {
            switch verdict {
            case "newer": return p.green
            case "older": return p.accent
            case "only": return p.amber
            case "differs": return p.purple
            default: return .clear
            }
        }()
        HStack(spacing: widths.tight ? 5 : 7) {
            Group {
                if dir {
                    Text(expanded ? "−" : "+").font(.system(size: 12)).foregroundStyle(dim)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await ex.toggleExpand(entry) } }
                        .help(expanded ? "Collapse" : "Expand")
                } else { Color.clear }
            }
            .frame(width: 10)
            Text(XP.fileIcon(entry)).font(.system(size: 11)).frame(width: 15)
            Text(entry.name)
                .font(.system(size: 12, weight: dir ? .medium : .regular))
                .italic(link)
                .strikethrough(broken)
                .foregroundStyle(nameColor)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: widths.tight ? 96 : 132, maxWidth: .infinity, alignment: .leading)
            if let v = verdict, v != "same" {
                Text(XP.compareGlyphs[v] ?? "").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : edge).frame(width: 14)
                    .help(XP.compareTitles[v] ?? "")
            }
            if details && !widths.hidePerm {
                Text(entry.modeString).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(dim).frame(width: 78, alignment: .leading)
            }
            if details && !widths.hideOwner {
                Text(XP.ownerText(entry)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(dim)
                    .lineLimit(1).truncationMode(.tail).frame(width: 96, alignment: .leading)
            }
            if !widths.hideSize {
                Text(dir ? "" : Fmt.bytes(entry.size)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(dim)
                    .lineLimit(1).frame(width: widths.tight ? 50 : 58, alignment: .trailing)
            }
            if !widths.hideDate {
                Text(Fmt.date(ms: entry.mtime)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(dim)
                    .lineLimit(1).frame(width: 78, alignment: .leading)
            }
        }
        .padding(.leading, CGFloat(8 + depth * 14)).padding(.trailing, 8)
        .frame(height: XPList.rowHeight)
        .background(selected ? p.accentDim : hover.on ? p.panel2 : Color.clear)
        .overlay(alignment: .leading) { edge.frame(width: 2) }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help(tooltip)
        .onTapGesture {
            focusList()
            let ev = NSApp.currentEvent
            if (ev?.clickCount ?? 1) >= 2 { Task { await ex.open(entry) }; return }
            let m = ev?.modifierFlags ?? []
            ex.select(entry, command: m.contains(.command), shift: m.contains(.shift))
        }
        .xpOnRightClick { ex.showContextMenu(for: entry) }
        .onDrag {
            let sel = ex.selected()
            XPDrag.fromId = ex.id
            XPDrag.entries = sel.contains(where: { $0.path == entry.path }) ? sel : [entry]
            let p = NSItemProvider()
            p.registerDataRepresentation(forTypeIdentifier: XPDrag.type.identifier, visibility: .ownProcess) { done in
                done(Data(entry.path.utf8), nil)
                return nil
            }
            p.suggestedName = entry.name
            return p
        }
        .onDrop(of: [XPDrag.type, .fileURL], delegate: XPDropDelegate(ex: ex, row: entry, pane: false))
    }

    private var tooltip: String {
        let own = XP.ownerText(entry)
        return [
            "\(entry.modeString)  \(entry.name)",
            own.isEmpty ? nil : "owner: " + own,
            // Only for files: a directory's link count is arithmetic, not information.
            !XP.isDir(entry) && (entry.links ?? 0) > 1 ? "\(entry.links!) hard links" : nil,
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

// MARK: - Notices

/// What the list says instead of entries: no session, not connected, the MFA
/// gate, a failed listing.
private enum XPNotice {
    @MainActor
    static func of(_ ex: ExplorerModel) -> AnyView? {
        let p = Theme.shared.p
        let view = ex.view
        if ex.isRemote {
            guard let conn = ex.conn else { return AnyView(dim("No session selected.")) }
            if !conn.connected {
                let down = conn.state == "error" || conn.state == "closed"
                if down { ex.maybeHealTmux() }
                return AnyView(VStack(spacing: 5) {
                    dim(ex.reconnecting ? "Reconnecting…" : "Session is \(conn.state).")
                    if down, let e = conn.error { Text(e).font(.system(size: 11)).foregroundStyle(p.muted).opacity(0.75) }
                    if down && !ex.reconnecting {
                        Button("Reconnect files") { Task { await ex.reconnect() } }
                            .buttonStyle(.primary).padding(.top, 5)
                            .help("Reuses the connection if it is still up; dials again if it is not")
                    }
                })
            }
            // MFA host, nothing loaded yet: ask before spending an approval.
            if conn.transport == "tsh" && view.path == nil && conn.needsMfaApproval {
                let leaf = conn.transportForced == "leaf"
                return AnyView(VStack(spacing: 5) {
                    dim(view.mfaFailed ? "Could not open the file channel."
                        : leaf ? "Files open on a second tsh channel." : "This host asks for MFA per session.")
                    Text(leaf ? "This node is in a leaf cluster, so files go through tsh rather than the terminal’s own channel."
                              : "Opening files needs one more approval, separate from the terminal.")
                        .font(.system(size: 11)).foregroundStyle(p.muted).opacity(0.75).multilineTextAlignment(.center)
                    Button(view.mfaFailed ? "Try again" : leaf ? "Load files" : "Load files (approve MFA)") {
                        view.mfaFailed = false
                        Task { await ex.ensureLoaded(force: true, user: true) }
                    }
                    .buttonStyle(.primary).padding(.top, 5)
                })
            }
        }
        if let e = view.error {
            // A remote listing that failed gets a way to try again in place.
            return AnyView(VStack(spacing: 5) {
                Text(e).font(.system(size: 12)).foregroundStyle(p.red).multilineTextAlignment(.center)
                if ex.isRemote && !ex.reconnecting {
                    Button("Try again") { Task { await ex.reconnect() } }.buttonStyle(.ghostSmall).padding(.top, 5)
                }
            })
        }
        if view.path == nil {
            return AnyView(dim(view.loading || view.firstLoading ? "Loading…" : ""))
        }
        return nil
    }

    @MainActor
    static func dim(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Theme.shared.p.muted).multilineTextAlignment(.center)
    }
}

/// An empty list says why: the filter first (the likelier reason), then hidden files.
private struct XPEmptyNotice: View {
    let ex: ExplorerModel
    var body: some View {
        let c = ex.counts
        VStack(spacing: 9) {
            if c.filtered > 0 {
                XPNotice.dim("No name matches “\(ex.filter.trimmed)” — \(c.filtered) item\(c.filtered == 1 ? "" : "s") filtered out.")
                Button("Clear the filter") { ex.clearFilter(); ex.filterFocusToken += 1 }.buttonStyle(.ghost)
            } else if c.hidden == 0 {
                XPNotice.dim("Empty directory.")
            } else {
                XPNotice.dim("Nothing visible — \(c.hidden) hidden item\(c.hidden == 1 ? "" : "s").")
                Button("Show hidden files") {
                    Store.shared.xpShowHidden = true
                    Explorers.shared.forEach { $0.render() }
                }
                .buttonStyle(.ghost)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct XPStatusBar: View {
    let ex: ExplorerModel
    var body: some View {
        let p = Theme.shared.p
        let s = ex.statusLine
        HStack {
            Text(s.text).foregroundStyle(s.error ? p.red : p.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(height: 20)
        .overlay(alignment: .top) { p.borderSoft.frame(height: 1) }
    }
}

// MARK: - Drops

/// The whole pane takes a drop; the row under the pointer decides the folder
/// when there is one.
struct XPDropDelegate: DropDelegate {
    let ex: ExplorerModel
    let row: FileEntry?
    let pane: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [XPDrag.type, .fileURL]) }

    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { ex.dragOver = true } }
    func dropExited(info: DropInfo) { if pane { MainActor.assumeIsolated { ex.dragOver = false } } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            ex.dragOver = true
            let ours = info.hasItemsConforming(to: [XPDrag.type])
            return DropProposal(operation: ours && XPDrag.fromId == ex.id ? .move : .copy)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            ex.dragOver = false
            guard let dest = ex.dropDestination(row: row) else { return false }
            if info.hasItemsConforming(to: [XPDrag.type]), let from = XPDrag.fromId {
                let entries = XPDrag.entries
                XPDrag.fromId = nil
                Task { await ex.dropEntries(entries, from: from, destDir: dest) }
                return true
            }
            let providers = info.itemProviders(for: [.fileURL])
            guard !providers.isEmpty else { return false }
            let box = XPURLBox()
            let group = DispatchGroup()
            for prov in providers {
                group.enter()
                _ = prov.loadObject(ofClass: NSURL.self) { obj, _ in
                    if let u = obj as? URL { box.add(u.path) } else if let u = obj as? NSURL, let p = u.path { box.add(p) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated {
                    let paths = box.paths
                    Task { await ex.dropFinder(paths, destDir: dest) }
                }
            }
            return true
        }
    }
}

private final class XPURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ p: String) { lock.lock(); list.append(p); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

/// A maximized explorer, drawn over its whole window (`.fpane.c3-max`).
struct XPMaxOverlay: View {
    let ex: ExplorerModel
    var body: some View {
        ExplorerView(ex: ex, filling: true)
            .padding(.top, 30)
            .background(Theme.shared.p.panel)
    }
}
