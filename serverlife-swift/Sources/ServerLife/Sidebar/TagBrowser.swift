import SwiftUI

/// Port of tagbrowser.js — every label in the inventory grouped by key with a
/// count per value (clicking one toggles it into the filter), and every label
/// on one node, Teleport's internal ones included.
@MainActor
enum SBTagBrowser {
    /// `openTagBrowser({ getFilter, setFilter })`: by default the sidebar's
    /// filter; another owner (multi-exec's "Tags…") passes its own. `setFilter`
    /// gets a term to toggle in, or nil for "clear".
    static func open(window: WindowModel?, getFilter: (() -> String)? = nil, setFilter: ((String?) -> Void)? = nil) {
        guard let w = window ?? WindowManager.shared.focused else { return }
        let sw = w.feature(SidebarWindow.self)
        let get = getFilter ?? { sw.filterText }
        let set = setFilter ?? { term in if let term { sw.toggleTerm(term) } else { sw.setFilter("") } }
        Modal.sheet(w, title: "Tags", width: 720) { handle in
            TagBrowserView(getFilter: get, setFilter: set) { handle.close() }
        }
    }

    static func openHostTags(_ host: Host, window: WindowModel?) {
        guard let w = window ?? WindowManager.shared.focused else { return }
        let sw = w.feature(SidebarWindow.self)
        Modal.sheet(w, title: "Tags", width: 640) { handle in
            HostTagsView(host: host, sw: sw) { handle.close() }
        }
    }
}

private struct TagBrowserView: View {
    let getFilter: () -> String
    let setFilter: (String?) -> Void
    let close: () -> Void
    @StateObject private var search = Local("")
    @StateObject private var tick = Local(0)
    @FocusState private var focused: Bool

    private func apply(_ term: String?) { setFilter(term); tick.value += 1 }

    var body: some View {
        let p = Theme.shared.p
        let nodes = Inventory.shared.allNodes
        let tags = Tags.collectTags(nodes)
        let q = search.value.trimmed.lowercased()
        let active = tick.value >= 0 ? getFilter() : ""
        DialogScaffold(title: "Tags",
                       subtitle: "\(tags.count) label\(tags.count == 1 ? "" : "s") across \(nodes.count) Teleport node\(nodes.count == 1 ? "" : "s")",
                       width: 720, scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Find a label…", text: $search.value)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .padding(.bottom, 11)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if nodes.isEmpty {
                            MiscHint(text: "No Teleport nodes loaded. Log in and refresh the inventory.", size: 12).padding(12)
                        } else if tags.isEmpty {
                            MiscHint(text: "None of the visible nodes carry labels.", size: 12).padding(12)
                        } else {
                            let groups = tags.compactMap { t -> (String, [(value: String, count: Int)])? in
                                let vals = t.values
                                    .filter { q.isEmpty || t.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
                                    .sorted { $0.count != $1.count ? $0.count > $1.count : Tags.localeLess($0.value, $1.value) }
                                return vals.isEmpty ? nil : (t.key, vals)
                            }
                            if groups.isEmpty { MiscHint(text: "No label matches “\(q)”.", size: 12).padding(12) }
                            ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(g.0).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(p.textDim)
                                        Button("any") { apply(Tags.termFor(g.0, "")) }
                                            .buttonStyle(.ghostSmall)
                                            .help("Filter to every node that has a \(g.0) label")
                                    }
                                    SBFlow(spacing: 4) {
                                        ForEach(g.1, id: \.value) { v in
                                            let term = Tags.termFor(g.0, v.value)
                                            let on = Tags.hasTerm(active, term)
                                            SBChip(value: v.value.isEmpty ? "(empty)" : v.value, count: v.count, on: on, size: 11,
                                                   help: on ? "Remove \(term) from the filter" : "Filter by \(term)") { apply(term) }
                                        }
                                    }
                                }
                                .padding(.vertical, 7)
                                .overlay(alignment: .top) { if i > 0 { p.borderSoft.frame(height: 1) } }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 460)
            }
        } footer: {
            Button("Copy filter") {
                let f = getFilter()
                if f.isEmpty { SBActions.status("The filter is empty"); return }
                Clipboard.write(f)
                SBActions.status("Copied: " + f)
            }.buttonStyle(.ghost)
            Button("Clear filter") { apply(nil) }.buttonStyle(.ghost)
            Button("Done") { close() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
        }
        .frame(height: 600)
    }
}

private struct HostTagsView: View {
    let host: Host
    let sw: SidebarWindow
    let close: () -> Void

    var body: some View {
        let p = Theme.shared.p
        let all = Tags.labelEntries(host, includeInternal: true)
        DialogScaffold(title: "Tags", subtitle: "\(HostPrefs.label(host))\(host.cluster.map { " · " + $0 } ?? "")", width: 640) {
            if all.isEmpty {
                MiscHint(text: "This node has no labels.", size: 12)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    ForEach(all, id: \.key) { t in
                        let term = Tags.termFor(t.key, t.value)
                        let on = Tags.hasTerm(sw.filterText, term)
                        GridRow {
                            Text(t.key).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.muted)
                                .opacity(Tags.isInternalLabel(t.key) ? 0.55 : 1).textSelection(.enabled)
                            Text(t.value.isEmpty ? "—" : t.value).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            SBChip(value: on ? "filtering" : "filter", on: on, size: 10.5,
                                   help: on ? "Remove \(term) from the filter" : "Filter the list by \(term)") { sw.toggleTerm(term) }
                        }
                    }
                }
            }
        } footer: {
            Button("Copy") {
                Clipboard.write(all.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
                SBActions.status("Copied \(all.count) tag\(all.count == 1 ? "" : "s")")
            }.buttonStyle(.ghost)
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }
}
