import AppKit
import SwiftUI

/// Plan a sync, show every line of it, and run what survives review
/// (`openSyncDialog`). The list is the feature: every row has a tick, and the
/// summary says what would be deleted and what would overwrite something newer.
@MainActor
enum XPSyncDialog {
    @discardableResult
    static func open(_ owner: WindowModel?, connId: String, localDir: String, remoteDir: String,
                     onDone: (() -> Void)? = nil) async -> SyncPlanner.ApplyResult? {
        let st = XPSyncState(connId: connId, localDir: localDir, remoteDir: remoteDir)
        st.replan()
        let kept = await XPDialog.present(owner, title: "Synchronize", width: 860, height: 640, resizable: true,
                                          autosave: "sync") { (done: @escaping ([SyncPlanner.Action]?) -> Void) in
            AnyView(SyncView(st: st, owner: owner, done: done))
        }
        guard let kept, let planned = st.planned else { return nil }
        do {
            let r = try await FilesService.shared.syncApply(connId, planned, actions: kept)
            let bits = [r.uploads > 0 ? "\(r.uploads) up" : "", r.downloads > 0 ? "\(r.downloads) down" : "",
                        r.removed > 0 ? "\(r.removed) removed" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            xpStatus("Sync started: \(bits.isEmpty ? "nothing to move" : bits)", 9000)
            if !r.failures.isEmpty { xpToast(r.failures.prefix(3).joined(separator: "\n"), "error", 9000) }
            // The queue is where the work now is, so that is where to look.
            XPTransfer.showTransfers(owner)
            onDone?()
            return r
        } catch {
            xpToast(errorText(error), "error")
            return nil
        }
    }
}

@MainActor
final class XPSyncState: ObservableObject {
    let connId: String
    let localDir: String
    let remoteDir: String
    @Published var direction = "up" { didSet { if direction == "both" { del = false }; replan() } }
    @Published var del = false { didSet { if oldValue != del { replan() } } }
    @Published var compare = "both" { didSet { replan() } }
    @Published var planned: SyncPlanner.Plan?
    @Published var error: String?
    /// rel + op of the rows the user unticked.
    @Published var excluded: Set<String> = []
    private var seq = 0

    init(connId: String, localDir: String, remoteDir: String) {
        self.connId = connId; self.localDir = localDir; self.remoteDir = remoteDir
    }

    func replan() {
        planned = nil
        error = nil
        excluded = []
        seq += 1
        let mine = seq
        let req = SyncPlanner.Request(localDir: localDir, remoteDir: remoteDir, direction: direction, del: del, compare: compare)
        Task { @MainActor in
            do {
                let p = try await FilesService.shared.syncPlan(connId, req)
                if mine == seq { planned = p }
            } catch {
                if mine == seq { self.error = errorText(error) }
            }
        }
    }

    var doing: [SyncPlanner.Action] { (planned?.actions ?? []).filter(\.doing) }
    var kept: [SyncPlanner.Action] { doing.filter { !excluded.contains($0.rel + $0.op) } }

    func set(_ a: SyncPlanner.Action, on: Bool) {
        if on { excluded.remove(a.rel + a.op); return }
        excluded.insert(a.rel + a.op)
        // Removing a folder is not "remove it if it is empty": keeping anything
        // inside a folder keeps the folder, and is seen to.
        for k in XP.syncExcludesFor(a, in: planned?.actions ?? []) { excluded.insert(k) }
    }

    var summaryText: String {
        guard let planned else { return "" }
        let k = kept
        let bytes = k.filter { $0.op == "upload" || $0.op == "download" }.reduce(Int64(0)) { $0 + $1.size }
        let dels = k.filter { $0.op.hasPrefix("delete") || $0.op.hasPrefix("rmdir") }.count
        return !k.isEmpty
            ? "\(k.count) action(s) · \(Fmt.bytes(bytes)) to move" + (dels > 0 ? " · \(dels) deletion(s)" : "")
                + " · \(planned.summary.same) already identical"
            : "Nothing selected · \(planned.summary.same) identical file(s)"
    }

    var notes: [String] {
        guard let s = planned?.summary else { return [] }
        var n: [String] = []
        if s.localMissing { n.append("\(localDir) does not exist on this machine.") }
        if s.remoteMissing { n.append("\(remoteDir) does not exist on the server.") }
        if s.truncated { n.append("One of the trees was too large to walk fully — this plan is partial.") }
        if s.links > 0 { n.append("\(s.links) symlink(s) ignored: copying one would replace the link with its target.") }
        if s.overwritesNewer > 0 { n.append("\(s.overwritesNewer) file(s) would overwrite a newer copy — ticked rows in amber.") }
        // The commonest surprise: a file deleted on the source side is left
        // alone unless deleting is asked for, and nothing on screen said so.
        if !del && s.wouldDelete > 0 {
            n.append("\(s.wouldDelete) file(s) exist only on the other side and are being left alone. "
                + "Tick \"Delete what the source does not have\" to remove them.")
        }
        return n
    }
}

private struct SyncView: View {
    @ObservedObject var st: XPSyncState
    let owner: WindowModel?
    let done: ([SyncPlanner.Action]?) -> Void

    private func synchronize() {
        let k = st.kept
        if k.isEmpty { xpToast("Nothing selected", "error"); return }
        let dels = k.filter { $0.op.hasPrefix("delete") || $0.op.hasPrefix("rmdir") }
        if dels.isEmpty { done(k); return }
        Task {
            let detail = dels.prefix(15).map { ($0.op.hasSuffix("Remote") ? "server: " : "here: ") + $0.rel
                + (($0.dir ?? false) ? "  (folder, and anything still in it)" : "") }.joined(separator: "\n")
                + (dels.count > 15 ? "\n…and \(dels.count - 15) more" : "")
            if await MiscUI.confirm(owner, title: "Delete \(dels.count) file(s)?",
                                    message: "This sync removes files as well as copying them.",
                                    detail: detail, confirmLabel: "Delete them", danger: true) {
                done(k)
            }
        }
    }

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Synchronize", subtitle: "\(st.localDir)  ↔  \(st.remoteDir)", scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 12) {
                    MiscField(label: "Direction") {
                        Picker("", selection: $st.direction) {
                            Text("This machine → server").tag("up")
                            Text("Server → this machine").tag("down")
                            Text("Both ways (newer wins)").tag("both")
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    MiscField(label: "Files match on") {
                        Picker("", selection: $st.compare) {
                            Text("Size and time").tag("both")
                            Text("Size only").tag("size")
                            Text("Time only").tag("time")
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    // Deleting in a two-way sync has no meaning: neither side is the source.
                    MiscCheck(label: "Delete what the source does not have", isOn: $st.del)
                        .disabled(st.direction == "both")
                        .opacity(st.direction == "both" ? 0.5 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let e = st.error {
                            Text(e).font(.system(size: 12)).foregroundStyle(p.red).padding(16)
                        } else if let planned = st.planned {
                            if st.doing.isEmpty {
                                VStack(spacing: 6) {
                                    Text("Already in sync.")
                                    Text("\(planned.summary.same) identical file(s) on both sides.").opacity(0.75)
                                }
                                .font(.system(size: 12)).foregroundStyle(p.muted)
                                .frame(maxWidth: .infinity).padding(20)
                            }
                            ForEach(st.doing, id: \.self) { a in SyncRow(a: a, st: st) }
                        } else {
                            Text("Comparing…").font(.system(size: 12)).foregroundStyle(p.muted)
                                .frame(maxWidth: .infinity).padding(20)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                MiscHint(text: st.summaryText, size: 11).padding(.top, 9)
                if !st.notes.isEmpty {
                    Text(st.notes.joined(separator: "\n")).font(.system(size: 12)).foregroundStyle(p.amber)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Synchronize", action: synchronize).buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

private struct SyncRow: View {
    let a: SyncPlanner.Action
    @ObservedObject var st: XPSyncState

    var body: some View {
        let p = Theme.shared.p
        let meta = XP.syncOps[a.op]
        let risky = a.overwritesNewer ?? false
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(get: { !st.excluded.contains(a.rel + a.op) }, set: { st.set(a, on: $0) }))
                .toggleStyle(.checkbox).labelsHidden()
            Text(meta?.glyph ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(p.accent)
                .frame(width: 14).help(meta?.label ?? "")
            Text(a.rel).font(.system(size: 12)).lineLimit(1).truncationMode(.head).help(a.rel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(a.why + (risky ? " — overwrites a newer copy" : "")).font(.system(size: 10.5))
                .foregroundStyle(risky ? p.amber : p.muted).lineLimit(1)
            Text(a.size > 0 ? Fmt.bytes(a.size) : "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(risky ? Color(hex: "#d29922").opacity(0.10) : Color.clear)
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
    }
}
