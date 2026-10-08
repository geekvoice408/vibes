import AppKit
import SwiftUI

/// The dialog half of folders.js: making or editing a folder (with the rule
/// built rather than recalled, and what it matches right now on screen),
/// the "list in both or move?" question, and export / import.
@MainActor
enum FolderDialogs {
    static func install() {
        // The drop question, asked in the app's own dialog.
        FolderModel.askBothOrOne = { subject, folder, current in
            await askBothOrOne(nil, subject: subject, folder: folder, current: current)
        }
    }

    // MARK: Rule text helpers (pure)

    /// Append to a rule, putting the `and` in for you between two conditions
    /// and leaving a space after an operator.
    static func insert(_ text: String, into rule: String, operator op: Bool = false) -> String {
        let cur = rule.trimmed
        let open = cur.isEmpty || QuickConnect.test(QuickConnect.re(#"(\(|\b(and|or|not)\b|\|\||&&|!)\s*$"#, ci: true), cur)
        return cur + (cur.isEmpty ? "" : (op || open ? " " : " and ")) + text + (op ? " " : "")
    }

    /// What the rule editor says under the box.
    struct RuleNote: Equatable {
        var text: String
        var warn: Bool
        var hits: [String]
    }

    static func ruleNote(_ rule: String, hosts: [Host]) -> RuleNote {
        let q = rule.trimmed
        if q.isEmpty { return RuleNote(text: "No rule: the folder holds only what you drag into it.", warn: false, hits: []) }
        let c = Tags.compileQuery(q)
        if let e = c.error {
            return RuleNote(text: "\(e). Reading it as a plain list of conditions for now.", warn: true, hits: [])
        }
        let hit = hosts.filter { c.match($0) }
        return RuleNote(text: hit.isEmpty ? "Nothing here matches that yet — the folder will fill itself when something does."
                                          : "Matches \(hit.count) of \(hosts.count) in this group right now.",
                        warn: hit.isEmpty, hits: hit.map { $0.name.nilIfEmpty ?? $0.alias ?? "" })
    }

    // MARK: New / edit

    /// `openFolderDialog({ group, parent, folder, hosts })`.
    static func openFolderDialog(_ window: WindowModel?, group: String, parent: String? = nil, folder: HostFolder? = nil,
                                 hosts: [Host], done: ((HostFolder?) -> Void)? = nil) {
        let model = FolderDialogModel(group: group, parent: parent, folder: folder, hosts: hosts)
        // `done` is answered exactly once: the folder, or nil however the dialog went away.
        var answered = false
        let answer: (HostFolder?) -> Void = { f in if !answered { answered = true; done?(f) } }
        let h = Modal.sheet(window, title: folder == nil ? "New folder" : "Edit folder", width: 620) { handle in
            FolderDialogView(model: model) { ok in
                guard ok else { answer(nil); handle.close(); return }
                let name = model.name.trimmed
                if name.isEmpty { return HToast.error("Give the folder a name") }
                if let f = folder {
                    FolderModel.updateFolder(f.id, name: name, parent: .some(model.parent.nilIfEmpty), rule: model.rule.trimmed,
                                             icon: model.icon, color: model.color)
                    StatusBus.shared.show("Saved “\(name)”")
                    answer(FolderModel.folder(id: f.id))
                } else {
                    let made = FolderModel.createFolder(name: name, group: group, parent: model.parent.nilIfEmpty,
                                                        rule: model.rule.trimmed, icon: model.icon, color: model.color)
                    StatusBus.shared.show("Created “\(made.name)”")
                    answer(made)
                }
                handle.close()
            }
        }
        h.onClose.append { answer(nil) }
    }

    // MARK: Both or one

    /// A host dragged into a folder under a different root: list it in both,
    /// or move it? "both", "move", or nil.
    static func askBothOrOne(_ window: WindowModel?, subject: String, folder: HostFolder, current: [HostFolder]) async -> String? {
        let where_ = current.map(FolderModel.pathLabel)
        return await withCheckedContinuation { cont in
            var answered = false
            let finish: (String?) -> Void = { v in if !answered { answered = true; cont.resume(returning: v) } }
            let h = Modal.sheet(window, title: "\(subject) is already filed", width: 560) { handle in
                DialogScaffold(title: "\(subject) is already filed", subtitle: where_.joined(separator: " · "), width: 560) {
                    MiscHint(text: "It is in \(where_.count == 1 ? "that folder" : "those folders") already. "
                             + "Put it in “\(folder.name)” as well, or move it there?", size: 12)
                } footer: {
                    Button("Cancel") { finish(nil); handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                    Button("List in both") { finish("both"); handle.close() }.buttonStyle(.ghost)
                    Button("Move it here") { finish("move"); handle.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
                }
            }
            h.onClose.append { finish(nil) }
        }
    }

    // MARK: Export / import

    static func exportFileName(_ groupKey: String?) -> String {
        "serverlife-folders\(groupKey.map { "-" + QuickConnect.replace(QuickConnect.re(#"[^\w.-]+"#), $0, with: "_") } ?? "").json"
    }

    /// Write the arrangement out, for a colleague or for a backup.
    static func exportFolders(_ window: WindowModel?, groupKey: String?) async {
        let data = FolderModel.exportData(groupKey)
        let n = data["folders"].items.count
        if n == 0 { return HToast.error("There are no folders to export") }
        if let url = await Modal.saveText(window, data.text(pretty: true), defaultName: exportFileName(groupKey)) {
            StatusBus.shared.show("Exported \(n) folder\(n == 1 ? "" : "s") to \(url.path)")
        }
    }

    /// Read one back in: merge or replace, and — for a file from a cluster
    /// this machine does not have — the offer to land it somewhere else.
    static func importFolders(_ window: WindowModel?, groups: [FolderGroup]) async {
        guard let url = await Modal.openFiles(window, multiple: false).first else { return }
        let data: JSON
        do {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw AppError("Could not read that file") }
            data = try FolderModel.parseImport(text)
        } catch {
            return HToast.error(hostsErrorText(error))
        }
        var fileGroups: [String] = []
        for f in data["folders"].items { let g = f["group"].stringish ?? ""; if !fileGroups.contains(g) { fileGroups.append(g) } }
        let here = Set(groups.map(\.key))
        let unknown = fileGroups.filter { !here.contains($0) }
        let n = data["folders"].items.count
        var subtitle = "\(n) folder\(n == 1 ? "" : "s")"
        if let at = data["exportedAt"].string, let d = TPText.parseDate(at) {
            subtitle += " · exported " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: d / 1000), dateStyle: .short, timeStyle: .none)
        }
        let mode = Local("merge"), remap = Local("")
        let ok: Bool = await withCheckedContinuation { cont in
            var answered = false
            let finish: (Bool) -> Void = { v in if !answered { answered = true; cont.resume(returning: v) } }
            let h = Modal.sheet(window, title: "Import folders", width: 620) { handle in
                ImportFoldersView(subtitle: subtitle, unknown: unknown, allUnknown: unknown.count == fileGroups.count,
                                  groups: groups, mode: mode, remap: remap) { v in finish(v); handle.close() }
            }
            h.onClose.append { finish(false) }
        }
        guard ok else { return }
        let out = FolderModel.importData(data, mode: mode.value, remap: remap.value.nilIfEmpty)
        StatusBus.shared.show("Imported \(out.folders) folder\(out.folders == 1 ? "" : "s")")
    }
}

@MainActor
final class FolderDialogModel: ObservableObject {
    let group: String
    let editing: HostFolder?
    let hosts: [Host]
    @Published var name: String
    @Published var rule: String
    @Published var parent: String
    @Published var icon: String
    @Published var color: String
    let parentOptions: [(value: String, label: String)]
    let tags: [(key: String, values: [(value: String, count: Int)])]

    init(group: String, parent: String?, folder: HostFolder?, hosts: [Host]) {
        self.group = group
        editing = folder
        self.hosts = hosts
        name = folder?.name ?? ""
        rule = folder?.rule ?? ""
        icon = folder?.icon ?? ""
        color = folder?.color ?? ""
        // Its own descendants are not offered: a folder cannot be put inside itself.
        let banned = Set(folder.map { FolderModel.subtreeIds($0.id) } ?? [])
        var opts: [(String, String)] = [("", "(top level)")]
        for f in FolderModel.allFolders() where f.group == group && !banned.contains(f.id) {
            opts.append((f.id, FolderModel.pathLabel(f)))
        }
        parentOptions = opts
        let want = folder != nil ? (folder?.parent ?? "") : (parent ?? "")
        self.parent = opts.contains { $0.0 == want } ? want : ""
        tags = Tags.collectTags(hosts)
    }

    var note: FolderDialogs.RuleNote { FolderDialogs.ruleNote(rule, hosts: hosts) }

    func insert(_ text: String, operator op: Bool = false) {
        rule = FolderDialogs.insert(text, into: rule, operator: op)
    }
}

private struct FolderDialogView: View {
    @ObservedObject var model: FolderDialogModel
    let done: (Bool) -> Void
    @FocusState private var focus: Field?
    enum Field { case name, rule }

    static let fieldOptions: [(String, String)] = [
        ("name~", "name ~ regular expression"),
        ("name=", "name = exact, or a glob like web-*"),
        ("name:", "name : contains"),
        ("addr:", "addr : contains"),
        ("cluster=", "cluster ="),
        ("tag:", "tag : anywhere in any label"),
        ("tunnel=true", "tunnel = true"),
    ]

    var body: some View {
        let p = Theme.shared.p
        let note = model.note
        DialogScaffold(title: model.editing == nil ? "New folder" : "Edit folder", subtitle: model.group, width: 620) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Name") {
                    HField(placeholder: "Production web", text: $model.name).focused($focus, equals: .name)
                }
                MiscField(label: "Inside", hint: "Folders nest as deep as you like.") {
                    HSelect(options: model.parentOptions, selection: $model.parent)
                }
                MiscField(label: "Fill it automatically",
                          hint: "A query, re-asked whenever the inventory changes. Tags (`env=prod`), fields "
                          + "(`name=web-*`), a regular expression (`name~^web-\\d+$`), and `and`, `or`, `not` "
                          + "and brackets between them.") {
                    HField(placeholder: "env=prod and (role:web or role:api) and not name=web-canary", text: $model.rule, mono: true)
                        .focused($focus, equals: .rule)
                }
                .padding(.bottom, -10)
                // The rule, built rather than recalled.
                HFlow(spacing: 5) {
                    Menu("Insert a tag…") {
                        ForEach(model.tags, id: \.key) { t in
                            Section(t.key) {
                                Button("\(t.key): (has the tag at all)") { model.insert("\(t.key):"); focus = .rule }
                                ForEach(t.values.sorted { $0.count > $1.count }, id: \.value) { v in
                                    Button("\(t.key) = \(v.value.isEmpty ? "(empty)" : v.value)  · \(v.count)") {
                                        model.insert(Tags.termFor(t.key, v.value)); focus = .rule
                                    }
                                }
                            }
                        }
                    }
                    .font(.system(size: 11.5)).fixedSize()
                    Menu("Insert a field…") {
                        ForEach(Self.fieldOptions, id: \.0) { o in Button(o.1) { model.insert(o.0); focus = .rule } }
                    }
                    .font(.system(size: 11.5)).fixedSize()
                    ForEach([("and", "and"), ("or", "or"), ("not", "not"), ("( )", "("), (")", ")")], id: \.0) { b in
                        Button(b.0) { model.insert(b.1, operator: true); focus = .rule }.buttonStyle(.ghostSmall)
                    }
                    Button("Clear") { model.rule = ""; focus = .rule }.buttonStyle(.ghostSmall)
                }
                .padding(.top, 7)
                Text(note.text).font(.system(size: 11.5)).foregroundStyle(note.warn ? p.amber : p.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 7)
                if !note.hits.isEmpty {
                    ScrollView {
                        HFlow(spacing: 3, lineSpacing: 3) {
                            ForEach(Array(note.hits.enumerated()), id: \.offset) { _, h in
                                Text(h).font(.system(size: 10.5)).foregroundStyle(p.textDim).lineLimit(1)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(p.panel3))
                            }
                        }
                    }
                    .frame(maxHeight: 96).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                MiscRule().padding(.top, 14)
                MiscField(label: "Icon") { EmojiPicker(selection: $model.icon) }
                MiscField(label: "Colour", hint: "Drawn down the row, the same eight a host can be marked with.") {
                    ColorSwatchPicker(selection: $model.color)
                }
            }
        } footer: {
            Button("Cancel") { done(false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(model.editing == nil ? "Create" : "Save") { done(true) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .frame(maxHeight: 780)
        .onAppear { after(0.05) { focus = .name } }
    }
}

private struct ImportFoldersView: View {
    let subtitle: String
    let unknown: [String]
    let allUnknown: Bool
    let groups: [FolderGroup]
    @ObservedObject var mode: Local<String>
    @ObservedObject var remap: Local<String>
    let done: (Bool) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Import folders", subtitle: subtitle, width: 620) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "How") {
                    HSelect(options: [("merge", "Add them to what is here"), ("replace", "Replace the folders of the groups in the file")],
                            selection: $mode.value)
                }
                if !unknown.isEmpty {
                    MiscHint(text: "\(allUnknown ? "None" : "Some") of the groups in this file are here: "
                             + "\(unknown.joined(separator: ", ")). Folders for a cluster you are not logged in to stay out of sight until you are.",
                             color: p.amber).padding(.top, 8).padding(.bottom, 10)
                    MiscField(label: "Put them in", hint: "Rules travel between clusters; hosts filed by hand do not — they are held by node UUID, "
                              + "which only means something on the cluster they came from.") {
                        HSelect(options: [("", "Leave them where the file says")] + groups.map { ($0.key, $0.label) }, selection: $remap.value)
                    }
                }
                MiscHint(text: "Imported folders are given new ids, so importing twice makes a second copy rather than "
                         + "overwriting the one you have since edited.").padding(.top, 8)
            }
        } footer: {
            Button("Cancel") { done(false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Import") { done(true) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
