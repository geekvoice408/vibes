import AppKit
import SwiftUI

/// Search this folder and everything under it: by name, and by a string
/// inside the files. Both are capped — on a server by `head` on the far end —
/// and the note always says why a search stopped.
@MainActor
enum XPSearch {
    static func open(_ ex: ExplorerModel) async {
        if ex.isS3 { xpToast("Search does not reach into buckets yet", "error"); return }
        guard ex.isLocal || ex.isRemote else { return }
        let local = ex.isLocal
        let startDir = ex.view.path ?? (local ? NSHomeDirectory() : "/")
        let st = XPSearchState(dir: startDir)
        let subtitle = local ? "This machine" : (ex.conn?.label ?? "Server")
        _ = await XPDialog.present(ex.window, title: "Search", width: 760, height: 620, resizable: true,
                                   autosave: "search") { (done: @escaping (Bool?) -> Void) in
            AnyView(SearchView(ex: ex, st: st, subtitle: subtitle, done: done))
        }
    }

    /// "12 results — stopped after 6s; narrow the name or lower the depth".
    static func note(_ r: FindFiles.Outcome) -> String {
        let why: String
        if r.stopped == "time" {
            why = " — stopped after \(Int(((r.elapsedMs ?? 0) / 1000).rounded()))s; narrow the name or lower the depth"
        } else if r.stopped == "entries" {
            why = " — stopped after a quarter of a million entries; start somewhere narrower"
        } else if r.truncated {
            why = " — stopped at the result cap, so narrow it if the one you want is missing"
        } else { why = "" }
        return "\(r.results.count) result\(r.results.count == 1 ? "" : "s")" + why
            + ((r.scanned ?? 0) > 0 ? "  ·  \(r.scanned!) entries looked at" : "")
    }
}

@MainActor
final class XPSearchState: ObservableObject {
    @Published var dir: String
    @Published var name = ""
    @Published var text = ""
    @Published var caseSensitive = false
    @Published var kinds = "all"
    @Published var depth = "6"
    @Published var results: [FindFiles.Hit] = []
    @Published var note = ""
    @Published var running = false
    @Published var nameFocus = 0
    init(dir: String) { self.dir = dir }
}

private struct SearchView: View {
    let ex: ExplorerModel
    @ObservedObject var st: XPSearchState
    let subtitle: String
    let done: (Bool?) -> Void

    private func run() {
        if st.running { return }
        let pattern = st.name.trimmed, content = st.text.trimmed
        if pattern.isEmpty && content.isEmpty { xpToast("Give a name to look for, or some text", "error"); return }
        st.running = true
        st.results = []
        st.note = "Searching…"
        var o = FindFiles.Options(dir: st.dir.trimmed)
        o.pattern = pattern
        o.content = content
        o.caseSensitive = st.caseSensitive
        o.kinds = content.isEmpty ? st.kinds : "files"
        o.maxDepth = Int(st.depth) ?? 6
        if o.maxDepth == 0 { o.maxDepth = 6 }
        o.limit = 400
        Task { @MainActor in
            defer { st.running = false }
            do {
                guard let src = ex.fileSource else { throw AppError("No session for that pane") }
                let r = try await src.search(o)
                if r.results.isEmpty {
                    st.note = content.isEmpty ? "Nothing under there matches that name." : "Nothing under there contains that."
                    return
                }
                st.results = r.results
                st.note = XPSearch.note(r)
            } catch {
                st.results = []
                st.note = errorText(error)
            }
        }
    }

    /// Clicking goes to it: into the folder, or to the folder holding the
    /// file with the file selected, which is what "show me" means.
    private func show(_ hit: FindFiles.Hit) {
        let dir = hit.type == .directory
        let target = dir ? hit.path : (ex.isLocal ? XP.parentLocal(hit.path) : Posix.parent(hit.path))
        Task {
            try? await ex.navigate(target)
            if !dir {
                ex.view.selection = [hit.path]
                ex.render()
                ex.scrollTo(hit.path, center: true)
            }
        }
    }

    private func openHit(_ hit: FindFiles.Hit) {
        Task {
            if hit.type == .directory { try? await ex.navigate(hit.path) } else { await ex.openFavFile(hit.path) }
        }
    }

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Search", subtitle: subtitle, scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Start in") {
                    XPTextField(text: $st.dir, placeholder: "/var/log", size: 12, onEnter: run).modifier(XPFieldBox())
                }
                HStack(alignment: .top, spacing: 12) {
                    MiscField(label: "Name", hint: "A bare word matches anywhere in the name; * and ? work as usual") {
                        XPTextField(text: $st.name, placeholder: "nginx.conf, or *.log", size: 12, focusToken: st.nameFocus,
                                    onEnter: run).modifier(XPFieldBox())
                    }
                    MiscField(label: "Containing (optional)") {
                        XPTextField(text: $st.text, placeholder: "optional — a string inside the files", size: 12,
                                    onEnter: run).modifier(XPFieldBox())
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    MiscField(label: "What to find") {
                        Picker("", selection: $st.kinds) {
                            Text("Files and folders").tag("all")
                            Text("Files only").tag("files")
                            Text("Folders only").tag("dirs")
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                    MiscField(label: "Depth") {
                        TextField("", text: $st.depth).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                }
                MiscCheck(label: "Match case", isOn: $st.caseSensitive)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(st.results, id: \.self) { hit in SearchRow(hit: hit, ex: ex, show: show, openHit: openHit) }
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                MiscHint(text: st.note, size: 11).padding(.top, 8)
            }
        } footer: {
            Button("Close") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Search", action: run).buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .onAppear { after(0.05) { st.nameFocus += 1 } }
    }
}

private struct SearchRow: View {
    let hit: FindFiles.Hit
    let ex: ExplorerModel
    let show: (FindFiles.Hit) -> Void
    let openHit: (FindFiles.Hit) -> Void
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        HStack(alignment: .top, spacing: 8) {
            Text(hit.type == .directory ? "\u{1F4C1}" : "\u{1F4C4}").font(.system(size: 11)).opacity(0.8)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name + (hit.line.map { "  :\($0)" } ?? "")).font(.system(size: 12)).foregroundStyle(p.text)
                Text(hit.path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted)
                    .lineLimit(1).truncationMode(.head)
                if let ex = hit.excerpt, !ex.isEmpty {
                    Text(ex).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textDim).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(hit.size.map { Fmt.bytes($0) } ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hover.on ? p.panel3 : Color.clear)
        .contentShape(Rectangle())
        .help(hit.path)
        .onHover { hover.on = $0 }
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { openHit(hit) } else { show(hit) }
        }
        .xpOnRightClick {
            CtxMenu.show([
                .heading(hit.path),
                CtxItem("Show it in the list") { show(hit) },
                hit.type != .directory ? CtxItem("Open it") { openHit(hit) } : CtxItem("Go here") { Task { try? await ex.navigate(hit.path) } },
                CtxItem("Copy the path") { Clipboard.write(hit.path); xpStatus("Copied " + hit.path) },
            ])
        }
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
    }
}

/// A text box drawn like the original's inputs.
struct XPFieldBox: ViewModifier {
    func body(content: Content) -> some View {
        let p = Theme.shared.p
        content
            .padding(.horizontal, 7).padding(.vertical, 4)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}
