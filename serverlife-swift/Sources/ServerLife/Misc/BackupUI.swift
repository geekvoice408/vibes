import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Moving a setup between machines, and sharing macros: the port of the
/// renderer's backup.js (the export/import dialogs). The envelope itself —
/// export, parse, describe, apply — is the data owner's (`BackupOps` below
/// adapts it).
///
/// Import is deliberately two steps: read the file, show what is in it, then
/// ask whether to merge or replace. Replacing is how you lose an afternoon's
/// work, so it never happens as a side effect of picking a file.
@MainActor
enum BackupUI {
    static let labels: [String: String] = [
        "profiles": "saved profiles",
        "folders": "folders",
        "snippets": "snippets",
        "macros": "macros",
        "requestTemplates": "saved access requests",
        "layouts": "layouts",
        "hiddenMacros": "hidden built-in macros",
    ]

    /// The order the original's objects list their keys in.
    static let order = ["profiles", "folders", "snippets", "macros", "requestTemplates", "layouts", "hiddenMacros"]

    static func summarise(_ counts: JSON) -> [String] {
        let e = counts.entries
        let keys = order.filter { e[$0] != nil } + e.keys.filter { !order.contains($0) }.sorted()
        return keys.compactMap { k in
            guard let n = e[k]?.int, n > 0 else { return nil }
            return "\(n) \(labels[k] ?? k)"
        }
    }

    /// Write everything, or just macros (optionally only `ids`), to a file the user picks.
    @discardableResult
    static func exportSettings(_ window: WindowModel? = nil, what: String = "all", ids: [String]? = nil) async -> URL? {
        let macrosOnly = what == "macros"
        let doc: JSON
        do { doc = try BackupOps.export(macrosOnly, ids) } catch {
            StatusBus.shared.toast((error as? AppError)?.message ?? "Export failed", kind: .error)
            return nil
        }
        let stamp = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
        guard let url = await MiscPanels.save(MiscPanels.parent(window),
                                              title: macrosOnly ? "Export macros" : "Export all settings",
                                              defaultName: "serverlife-\(macrosOnly ? "macros" : "settings")-\(stamp).json",
                                              directory: docs, types: [.json]) else { return nil }
        do {
            try doc.data(pretty: true).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
            return nil
        }
        let parts = summarise(doc["counts"])
        StatusBus.shared.toast(parts.isEmpty ? "Exported" : "Exported \(parts.joined(separator: ", "))", kind: .ok)
        StatusBus.shared.show("Written to " + url.path)
        return url
    }

    /// Read a file, show what it holds, and apply it the way the user
    /// chooses. Returns true when something was actually imported.
    static func importSettings(_ window: WindowModel? = nil) async -> Bool {
        guard let url = await MiscPanels.open(MiscPanels.parent(window), title: "Import ServerLife settings",
                                              types: [.json]) else { return false }
        let doc: JSON
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            doc = try BackupOps.parse(text)
        } catch {
            StatusBus.shared.toast((error as? AppError)?.message ?? "Could not read that file", kind: .error)
            return false
        }
        let summary = BackupOps.describe(doc)
        let parts = summarise(summary["counts"])
        let macrosOnly = summary["kind"].string == "macros"

        let mode: String? = await withCheckedContinuation { cont in
            var done = false
            let finish: (String?) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let h = Modal.sheet(window, title: macrosOnly ? "Import macros" : "Import settings", width: 560) { handle in
                ImportView(title: macrosOnly ? "Import macros" : "Import settings", path: url.path,
                           parts: parts, hasSettings: summary["hasSettings"].truthy,
                           exportedAt: summary["exportedAt"].string) { v in finish(v); handle.close() }
            }
            h.onClose.append { finish(nil) }
        }
        guard let mode else { return false }
        do {
            let res = try BackupOps.apply(doc, mode)
            let added = summarise(res["added"])
            StatusBus.shared.toast(mode == "replace" ? "Settings replaced"
                                   : (added.isEmpty ? "Nothing new to add" : "Added \(added.joined(separator: ", "))"),
                                   kind: .ok)
            return true
        } catch {
            StatusBus.shared.toast((error as? AppError)?.message ?? "Import failed", kind: .error)
            return false
        }
    }

    /// Reload everything an import may have touched, without restarting.
    static func reloadAfterImport() {
        Tools.homes = Store.shared.setting("tshHomes", [String]())
        Tools.setTshPath(Store.shared.setting("tshPath", ""))
        Tools.setSshPath(Store.shared.setting("sshPath", ""))
        Theme.shared.refresh()
        Actions.shared.perform("refresh")
        // S3 targets live in the store too.
        if Actions.shared.isRegistered("s3-reload") { Actions.shared.perform("s3-reload") }
    }
}

private struct ImportView: View {
    let title: String
    let path: String
    let parts: [String]
    let hasSettings: Bool
    let exportedAt: String?
    let done: (String?) -> Void

    private var exportedText: String? {
        guard let exportedAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: exportedAt) ?? ISO8601DateFormatter().date(from: exportedAt)
        guard let d else { return exportedAt }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .medium)
    }

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: title, subtitle: path) {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Contains").foregroundStyle(p.muted)
                        Text(parts.isEmpty ? "nothing recognisable" : parts.joined(separator: "\n"))
                    }
                    if hasSettings {
                        GridRow {
                            Text("Preferences").foregroundStyle(p.muted)
                            Text("yes — theme, fonts, defaults")
                        }
                    }
                    if let e = exportedText {
                        GridRow {
                            Text("Exported").foregroundStyle(p.muted)
                            Text(e)
                        }
                    }
                }
                .font(.system(size: 12))
                MiscHint(text: "Merge keeps what you have and adds anything new — entries already here, matched by id, are left alone. "
                         + "Replace makes this machine match the file.")
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Replace") {
                Task { @MainActor in
                    let ok = await MiscUI.confirm(title: "Replace everything?",
                                                  message: "Your current profiles, macros, snippets and saved requests are discarded.",
                                                  detail: "Export them first if you might want them back — this cannot be undone.",
                                                  confirmLabel: "Replace", danger: true)
                    if ok { done("replace") }
                }
            }
            .buttonStyle(GhostButtonStyle(destructive: true))
            // No Return default: in the original focus sat on Cancel.
            Button("Merge") { done("merge") }.buttonStyle(.primary)
        }
    }
}
