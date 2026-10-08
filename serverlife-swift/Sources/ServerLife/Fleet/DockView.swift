import AppKit
import SwiftUI

/// The bottom dock (dock.js): Transfers, Multi-Exec, Tunnels, Connection log,
/// Downloads and Watch, with Clear and close.
struct FleetDockView: View {
    let window: WindowModel

    static let tabs: [(id: String, label: String)] = [
        ("transfers", "Transfers"), ("multiexec", "Multi-Exec"), ("forwards", "Tunnels"),
        ("log", "Connection log"), ("downloads", "Downloads"), ("watch", "Watch"),
    ]

    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Self.tabs, id: \.id) { t in DockTabButton(window: window, id: t.id, label: t.label) }
                Spacer()
                HStack(spacing: 5) {
                    Button("Clear") { Task { @MainActor in await FleetDock.clear(window) } }.buttonStyle(.ghostSmall)
                    Button("\u{00D7}") { window.dockVisible = false }
                        .buttonStyle(IconButtonStyle(size: 20)).help("Close")
                }
                .padding(.trailing, 7)
            }
            .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
            Group {
                switch window.dockTab {
                case "multiexec": DockMultiExecPanel(window: window)
                case "forwards": ScrollView { DockTunnelsPanel(window: window).padding(.horizontal, 10).padding(.vertical, 8) }
                case "log": DockLogPanel(window: window)
                case "downloads": ScrollView { DockDownloadsPanel(window: window).padding(.horizontal, 10).padding(.vertical, 8) }
                case "watch": ScrollView { DockWatchPanel().padding(.horizontal, 10).padding(.vertical, 8) }
                default: ScrollView { DockTransfersPanel(window: window).padding(.horizontal, 10).padding(.vertical, 8) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(p.panel)
        .overlay(alignment: .top) { p.border.frame(height: 1) }
    }
}

private struct DockTabButton: View {
    let window: WindowModel
    let id: String
    let label: String
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        let on = window.dockTab == id
        Button { window.showDock(id) } label: {
            Text(label).font(.system(size: 11.5))
                .foregroundStyle(on || hover.on ? p.text : p.muted)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .overlay(alignment: .bottom) { (on ? p.accent : Color.clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

@MainActor
enum FleetDock {
    /// The window's focused session's connection (`state.activeConnId`).
    static func activeConnId(_ w: WindowModel) -> String? { w.feature(SessionsWindow.self).activeConnId }

    /// The dock's Clear: what it clears depends on the panel.
    static func clear(_ w: WindowModel) async {
        switch w.dockTab {
        case "transfers":
            if let id = activeConnId(w) { FilesService.shared.queue(id).clearFinished() }
        case "multiexec":
            MultiExecService.shared.clear()
        case "downloads":
            // The files are the point of the list, so emptying it is worth a
            // question — and worth saying that it only forgets.
            let ok = await MiscUI.confirm(w, title: "Clear the download list", message: "Forget every entry in this list?",
                                          detail: "The downloaded files themselves are left exactly where they are.",
                                          confirmLabel: "Clear the list")
            if ok { DownloadHistory.clear() }
        default:
            break
        }
    }

    static func connLabel(_ connId: String) -> String? {
        SessConnRecords.shared.label(connId) ?? ConnectionManager.shared.connection(connId)?.label
    }
}

// MARK: - Transfers

struct DockTransfersPanel: View {
    let window: WindowModel

    private struct Row: Identifiable {
        let connId: String
        let job: TransferJobView
        var id: String { connId + "/" + job.id }
    }

    var body: some View {
        let queues = FilesService.shared.queues
        let rows = queues.flatMap { (connId, q) in q.jobs.map { Row(connId: connId, job: $0) } }
            .sorted { ($0.job.startedAt ?? 0) > ($1.job.startedAt ?? 0) }
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                FleetEmpty(text: "No transfers yet. Drag files onto the remote pane, or use the file browser context menu.")
            } else {
                let active = rows.filter { ["running", "queued", "paused"].contains($0.job.status) }
                if !active.isEmpty { TransferBar(active: active.map { ($0.connId, $0.job) }) }
                ForEach(rows) { r in TransferRow(connId: r.connId, job: r.job) }
            }
        }
    }
}

/**
 * Queue-wide control, above the rows: hold everything while a call is on, put
 * it back afterwards, and cap the speed so a big upload does not take the link
 * with it. The limit is a preference and applies to every connection, because
 * what is being protected is this machine's uplink rather than any one transfer.
 */
private struct TransferBar: View {
    let active: [(String, TransferJobView)]
    @StateObject private var limit = Local(String(Store.shared.settingJSON("transferLimitKb").int ?? 0))
    @FocusState private var focused: Bool

    private var stored: Int { Store.shared.settingJSON("transferLimitKb").int ?? 0 }

    var body: some View {
        let p = Theme.shared.p
        let paused = active.filter { $0.1.status == "paused" }
        let allPaused = !paused.isEmpty && paused.count == active.count
        HStack(spacing: 7) {
            Button(allPaused ? "Resume all" : "Pause all") {
                for connId in Set(active.map(\.0)) {
                    let q = FilesService.shared.queue(connId)
                    if allPaused { q.resumeAll() } else { q.pauseAll() }
                }
            }
            .buttonStyle(.ghostSmall)
            .help("Hold every transfer between chunks; nothing is torn down, so resuming is instant")
            Spacer()
            Text("Limit").font(.system(size: 11)).foregroundStyle(p.muted)
            TextField("0", text: $limit.value)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 66)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                .help("KB/s across every transfer; 0 for no limit")
                .focused($focused)
                .onSubmit { apply() }
                // Like the original's `change`: also when the field is left.
                .onChange(of: focused) { _, now in if !now { apply() } }
                // A change made elsewhere (Settings) shows here.
                .onChange(of: stored) { _, v in if !focused { limit.value = String(v) } }
            // The number input's arrows, 128 KB/s a step.
            Stepper("", onIncrement: { step(128) }, onDecrement: { step(-128) })
                .labelsHidden().controlSize(.mini)
            Text("KB/s").font(.system(size: 11)).foregroundStyle(p.muted)
        }
        .padding(.horizontal, 2).padding(.bottom, 8)
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
        .padding(.bottom, 6)
    }

    private func step(_ d: Int) {
        limit.value = String(max(0, (Int(limit.value.trimmed) ?? 0) + d))
        apply()
    }

    private func apply() {
        let kb = max(0, Int(limit.value.trimmed) ?? 0)
        guard kb != stored || limit.value.trimmed != String(kb) else { return }
        limit.value = String(FilesService.shared.setLimit(kbPerSecond: Double(kb)))
        StatusBus.shared.show(kb > 0 ? "Transfers limited to \(kb) KB/s" : "Transfer speed limit off")
    }
}

private struct TransferRow: View {
    let connId: String
    let job: TransferJobView

    var body: some View {
        let p = Theme.shared.p
        let j = job
        let pct = j.totalBytes > 0 ? min(100, Double(j.doneBytes) / Double(j.totalBytes) * 100) : (j.status == "done" ? 100 : 0)
        let finishing = j.status == "running" && j.phase != nil
        FleetRow {
            Text(j.kind == "upload" ? "\u{2191}" : "\u{2193}").opacity(0.7).frame(width: 12)
            FleetLabel(main: j.label, sub: ([FleetDock.connLabel(connId)] + meta.map { Optional($0) })
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  "))
            ZStack(alignment: .leading) {
                Capsule().fill(p.panel3)
                Capsule().fill(barColor(p)).frame(width: 180 * pct / 100)
                    .opacity(finishing ? 0.7 : (j.status == "paused" ? 0.6 : 1))
            }
            .frame(width: 180, height: 5)
            Text(j.status != "running" ? j.status : finishing ? "finishing" : String(format: "%.0f%%", pct))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(finishing ? p.accent : j.status == "paused" ? p.amber : p.muted)
                .frame(width: 78, alignment: .trailing)
            let q = FilesService.shared.queue(connId)
            // Pause and resume for anything still in flight; retry for anything
            // that stopped early, which picks up the partial file.
            if ["running", "queued", "paused"].contains(j.status) {
                Button(j.status == "paused" ? "\u{25B6}" : "\u{2759}\u{2759}") {
                    if j.status == "paused" { q.resume(j.id) } else { q.pause(j.id) }
                }
                .buttonStyle(.icon).help(j.status == "paused" ? "Resume" : "Pause")
            }
            if j.status == "queued" {
                Button("\u{2191}") { q.move(j.id, -1) }.buttonStyle(.icon).help("Move earlier in the queue")
                Button("\u{2193}") { q.move(j.id, 1) }.buttonStyle(.icon).help("Move later in the queue")
            }
            if ["error", "cancelled"].contains(j.status) {
                Button("Retry") { q.retry(j.id) }.buttonStyle(.ghostSmall)
                    .help("Run it again, continuing any file that was part-way through")
            }
            if ["running", "queued", "paused"].contains(j.status) {
                Button("\u{00D7}") { q.cancel(j.id) }.buttonStyle(.icon).help("Cancel")
            } else {
                Color.clear.frame(width: 22, height: 1)
            }
        }
    }

    private var meta: [String] {
        let j = job
        var m: [String] = []
        if j.status == "running" {
            m.append("\(Fmt.bytes(j.doneBytes)) / \(Fmt.bytes(j.totalBytes))")
            if j.rate > 0 { m.append(Fmt.rate(j.rate)) }
            if j.fileCount > 1 { m.append("file \(j.fileIndex)/\(j.fileCount)") }
            // The bytes are all accounted for but the transfer is not over:
            // say what it is waiting for, so a bar frozen at 100% is not a hang.
            if let ph = j.phase { m.append(ph) }
        } else if j.status == "done" {
            m.append(Fmt.bytes(j.totalBytes))
            if let e = j.endedAt, let s = j.startedAt { m.append(Fmt.duration(ms: e - s)) }
        } else if let e = j.error {
            m.append(e)
        }
        if j.status == "paused" { m.append("paused") }
        if j.resumed && j.status == "running" { m.append("resumed") }
        return m
    }

    private func barColor(_ p: Palette) -> Color {
        switch job.status {
        case "done": return p.green
        case "error": return p.red
        case "cancelled": return p.muted
        case "paused": return p.amber
        default: return p.accent
        }
    }
}

// MARK: - Connection log

struct DockLogPanel: View {
    let window: WindowModel
    var body: some View {
        let p = Theme.shared.p
        if let connId = FleetDock.activeConnId(window) {
            if let c = ConnectionManager.shared.connection(connId) {
                if c.log.isEmpty {
                    FleetEmpty(text: "No log output.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(c.log) { e in
                                    Text(e.text.replacingOccurrences(of: "\r", with: ""))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(e.stream == "sys" ? p.accent.opacity(0.75) : p.textDim)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(e.id)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .onAppear { if let last = c.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                        .onChange(of: c.log.count) { _, _ in if let last = c.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            } else {
                FleetEmpty(text: "No such connection: \(connId)")
            }
        } else {
            FleetEmpty(text: "No active session.")
        }
    }
}

// MARK: - Downloads

/**
 * Everything pulled down to this machine, newest first. A transfer row answers
 * "is it done"; this answers "where did it go". A file that has since been
 * moved or deleted is kept and marked, not hidden.
 */
struct DockDownloadsPanel: View {
    let window: WindowModel
    /// Whether each file is still there, asked off the main thread (a path on
    /// a slow or unmounted volume must not stall the window). Until it
    /// answers, every file is treated as present.
    @StateObject private var present = Local<[String: Bool]>([:])

    var body: some View {
        let rows = DownloadHistory.list()
        Group {
            if rows.isEmpty {
                FleetEmpty(text: "Nothing downloaded yet.",
                           detail: "Files you pull from a server or a bucket are listed here, with where they landed.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in DownloadRow(row: r, gone: present.value[r.localPath] == false) }
                }
            }
        }
        .task(id: rows.map(\.localPath)) {
            let paths = rows.map(\.localPath)
            let found = await Task.detached(priority: .utility) { () -> [String: Bool] in
                var out: [String: Bool] = [:]
                for p in paths { out[p] = FileManager.default.fileExists(atPath: p) }
                return out
            }.value
            present.value = found
        }
    }
}

private struct DownloadRow: View {
    let row: DownloadHistory.Row
    let gone: Bool
    var body: some View {
        let p = Theme.shared.p
        let r = row
        let meta = [r.from, r.kind == "folder" ? "\(r.files) file\(r.files == 1 ? "" : "s")" : Fmt.bytes(r.bytes),
                    Fmt.date(ms: r.at), r.source].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ")
        FleetRow(padding: 7) {
            Text(r.kind == "folder" ? "\u{1F4C1}" : "\u{2193}").opacity(0.7).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name + (gone ? "  \u{2014} moved or deleted" : "")).font(.system(size: 12))
                    .foregroundStyle(gone ? p.amber : p.text).lineLimit(1)
                Text(meta).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                Text(r.localPath).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted).opacity(0.72)
                    .lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(r.kind == "folder" ? "Open folder" : "Open") {
                do { try LocalFS.open(r.localPath) } catch { StatusBus.shared.toast(errorText(error), kind: .error) }
            }
            .buttonStyle(.ghostSmall).disabled(gone)
            .help(gone ? "The file is no longer at that path" : "Open " + r.localPath)
            // Distinct from Open for a file, and the only way to get at a download
            // whose own application would not be the useful thing to launch.
            Button("Show in Finder") { LocalFS.reveal(r.localPath) }.buttonStyle(.ghostSmall).disabled(gone)
            Button("Copy name") { Clipboard.write(r.name); StatusBus.shared.show("Copied " + r.name) }
                .buttonStyle(.ghostSmall).help("Copy \u{201C}\(r.name)\u{201D}")
            Button("Copy path") { Clipboard.write(r.localPath); StatusBus.shared.show("Copied " + r.localPath) }
                .buttonStyle(.ghostSmall)
            Button("\u{00D7}") { DownloadHistory.forget(r.id) }
                .buttonStyle(.icon).help("Forget this entry (the file is not touched)")
        }
        .opacity(gone ? 0.72 : 1)
    }
}

// MARK: - Watch

/**
 * Everything currently being watched and pushed to a server. Two kinds in one
 * list because they are the same bargain: something on this machine is being
 * uploaded on every save, and that continues until stopped.
 */
struct DockWatchPanel: View {
    var body: some View {
        let p = Theme.shared.p
        let list = Watches.shared.list
        if list.isEmpty {
            FleetEmpty(text: "Nothing is being watched.", detailView: AnyView(VStack(alignment: .leading, spacing: 4) {
                (Text("Right-click a remote file \u{2192} ") + Text("Edit in my editor").bold() + Text(" to open it here and have every save go back."))
                (Text("Right-click a remote folder \u{2192} ") + Text("Keep this folder up to date").bold() + Text(" to upload a local folder as it changes."))
            }))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { w in
                    let isEdit = w.kind == "edit"
                    let meta = [w.label, w.uploads > 0 ? "\(w.uploads) upload\(w.uploads == 1 ? "" : "s")" : "nothing yet",
                                w.lastAt.map { "last " + Fmt.date(ms: $0) } ?? "",
                                w.errors > 0 ? "\(w.errors) error\(w.errors == 1 ? "" : "s")" : ""]
                        .filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ")
                    let third = w.lastError ?? (isEdit ? "local copy: \(w.localPath ?? "")" : (w.lastFile.map { "last file: \($0)" } ?? ""))
                    FleetRow(padding: 7) {
                        Text(isEdit ? "\u{270E}" : "\u{1F441}").opacity(0.75).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(isEdit ? (w.remotePath ?? "") : "\(w.localDir)  \u{2192}  \(w.remoteDir ?? "")")
                                .font(.system(size: 12)).foregroundStyle(w.lastError != nil ? p.amber : p.text).lineLimit(1)
                            Text(meta).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                            if !third.isEmpty {
                                Text(third).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted).opacity(0.72)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            if w.flatOnly {
                                Text("Subfolders are not watched on this platform \u{2014} only files directly in the folder.")
                                    .font(.system(size: 10.5)).foregroundStyle(p.amber)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if isEdit {
                            Button("Reveal") { if let lp = w.localPath { LocalFS.reveal(lp) } }
                                .buttonStyle(.ghostSmall).help("Show the local copy in the Finder")
                        } else {
                            Button("Open folder") { try? LocalFS.open(w.localDir) }.buttonStyle(.ghostSmall)
                        }
                        Button("Stop") {
                            Watches.shared.stop(w.id)
                            StatusBus.shared.show(isEdit ? "Stopped editing " + (w.remotePath ?? "") : "Stopped watching " + w.localDir)
                        }
                        .buttonStyle(GhostButtonStyle(small: true, destructive: true))
                        .help(isEdit ? "Stop watching and delete the local copy" : "Stop uploading changes from this folder")
                    }
                    .opacity(w.lastError != nil ? 0.72 : 1)
                }
            }
        }
    }
}

// MARK: - Status bar

/// "2 transfers · 41%" while anything is running.
struct TransferStatusItem: View {
    let window: WindowModel
    var body: some View {
        var running = 0
        var bytes: Int64 = 0, total: Int64 = 0
        for q in FilesService.shared.queues.values {
            for j in q.jobs where j.status == "running" { running += 1; bytes += j.doneBytes; total += j.totalBytes }
        }
        let pct = total > 0 ? Int((Double(bytes) / Double(total) * 100).rounded()) : 0
        return Group {
            if running > 0 {
                Text("\(running) transfer\(running > 1 ? "s" : "") \u{00B7} \(pct)%")
            }
        }
    }
}

/// "3 tunnels" while any are open.
struct ForwardStatusItem: View {
    let window: WindowModel
    var body: some View {
        let n = ConnectionManager.shared.allForwards().count
        return Group {
            if n > 0 {
                Text("\(n) tunnel\(n > 1 ? "s" : "")")
            }
        }
    }
}

/// Something uploading in the background belongs in the status bar too.
struct WatchStatusItem: View {
    let window: WindowModel
    var body: some View {
        let n = Watches.shared.list.count
        return Group {
            if n > 0 {
                Text("\(n) watching")
                    .help("Folders and files being uploaded as they change (Watch panel)")
            }
        }
    }
}
