import AppKit
import SwiftUI

/// Access requests (teleportpanel.js): the list for one cluster, a new
/// request, saved (reusable) requests, assume and drop.
@MainActor
enum AccessRequestsUI {
    // MARK: - The list

    /// `openRequestsDialog(profile)`.
    static func openRequestsDialog(_ profile: TeleportProfile?, window: WindowModel? = nil) {
        guard let p = profile ?? TUI.activeProfile() else { TUIStatus.toast("No Teleport profile", "error"); return }
        let m = RequestsListModel(p: p, window: window)
        m.load()
        TUIModal.show(window, title: "Access requests", width: 740, height: 600, autosave: "accessrequests") { handle in
            RequestsListView(m: m, handle: handle)
        }
    }

    /// Whatever profile is current for this key now (the inventory replaces
    /// profile values on every refresh).
    static func current(_ p: TeleportProfile) -> TeleportProfile { Inventory.shared.profile(forKey: p.key) ?? p }

    // MARK: - New request

    struct Prefill {
        var id: String?
        var name = ""
        var roles: [String] = []
        var resources: [ReqResource] = []
        var reason = ""
        var reviewers: [String] = []
        var requestTtl = "", maxDuration = "", sessionTtl = ""
        var assumeStartTime: String?

        init(roles: [String] = [], resources: [ReqResource] = [], reason: String = "") {
            self.roles = roles; self.resources = resources; self.reason = reason
        }

        /// A saved template as form input.
        init(template t: JSON) {
            id = t["id"].string; name = t["name"].stringish ?? ""
            roles = t["roles"].stringArray
            resources = t["resources"].items.compactMap { ReqResource(json: $0) }
            reason = t["reason"].stringish ?? ""; reviewers = t["reviewers"].stringArray
            requestTtl = t["requestTtl"].stringish ?? ""; maxDuration = t["maxDuration"].stringish ?? ""
            sessionTtl = t["sessionTtl"].stringish ?? ""
            assumeStartTime = t["assumeStartTime"].stringish?.nilIfEmpty
        }
    }

    /// `requestAccessTo(profile, resource)`: a request with something chosen.
    static func requestAccessTo(_ p: TeleportProfile, resource: ReqResource?, window: WindowModel? = nil) {
        Task { await openCreateRequest(p, prefill: Prefill(resources: [resource].compactMap { $0 }), window: window) }
    }

    /// `openCreateRequest`: build and raise an access request. Returns when
    /// the dialog has closed.
    static func openCreateRequest(_ p: TeleportProfile, prefill: Prefill = Prefill(), window: WindowModel? = nil) async {
        let m = CreateRequestModel(p: p, prefill: prefill, window: window)
        m.loadOfferedRoles()
        let _: Bool? = await TUIModal.ask(window, title: "New access request", width: 680, height: 720,
                                          autosave: "newrequest") { finish, _ in
            CreateRequestView(m: m, finish: finish)
        }
    }

    // MARK: - Settings the dialog remembers

    /// `reasonNeeded(p)`: this cluster has refused a request for want of one.
    static func reasonNeeded(_ p: TeleportProfile) -> Bool {
        Store.shared.settingJSON("reasonRequired")[p.proxy.nilIfEmpty ?? p.cluster].truthy
    }

    static func rememberReasonRequired(_ p: TeleportProfile) {
        Store.shared.mutateSetting("reasonRequired") { $0[p.proxy.nilIfEmpty ?? p.cluster] = true }
    }

    // MARK: - Prefill from an existing request

    /// `asPrefill`: absolute instants turned back into the durations they
    /// were presumably asked for, measured from creation.
    static func asPrefill(_ r: AccessRequest, _ p: TeleportProfile) -> Prefill {
        var out = Prefill(roles: r.roles, resources: requestResources(r, p), reason: r.reason)
        out.reviewers = r.reviewers
        let from = TPText.parseDate(r.created)
        out.requestTtl = span(from, r.expires)
        out.maxDuration = span(from, r.maxDuration)
        out.sessionTtl = span(from, r.sessionTtl)
        return out
    }

    /// Go durations, readable ones: "7h56m" rather than "476m".
    static func span(_ from: Double?, _ iso: String?) -> String {
        guard let from, let iso, let t = TPText.parseDate(iso) else { return "" }
        let mins = Int(((t - from) / 60000).rounded())
        if mins <= 0 { return "" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        return mins % 60 != 0 ? "\(h)h\(mins % 60)m" : "\(h)h"
    }

    static func requestResources(_ r: AccessRequest, _ p: TeleportProfile) -> [ReqResource] {
        r.resources.map { ReqResource(id: $0.id, kind: $0.kind, name: $0.label ?? $0.name, cluster: $0.cluster.nilIfEmpty ?? p.cluster) }
    }

    /// `suggestedName`: the reason if there was one, else what it asked for.
    static func suggestedName(_ r: AccessRequest, _ resources: [ReqResource]) -> String {
        let reason = r.reason.trimmed
        if !reason.isEmpty { return reason.count > 48 ? String(reason.prefix(47)) + "…" : reason }
        if resources.count == 1 { return resources[0].name }
        if !resources.isEmpty { return "\(resources.count) resources" }
        return r.roles.joined(separator: ", ")
    }

    /// `saveExistingRequest`: copy a request that exists into a saved one.
    static func saveExistingRequest(_ p: TeleportProfile, _ r: AccessRequest, window: WindowModel?) async {
        let resources = requestResources(r, p)
        if r.roles.isEmpty && resources.isEmpty {
            TUIStatus.toast("This request names neither roles nor resources", "error"); return
        }
        guard let name = await MiscUI.prompt(window, title: "Save as a reusable request",
                                             label: "Listed under \(TUI.name(p)), ready to raise again.",
                                             value: suggestedName(r, resources),
                                             placeholder: "e.g. prod database incident access", confirmLabel: "Save"),
              !name.isEmpty else { return }
        let timing = asPrefill(r, p)
        TUIData.upsertRequestTemplate([
            "name": .string(name), "proxy": .string(p.proxy), "cluster": .string(p.cluster),
            "roles": JSON(r.roles), "resources": .array(resources.map(\.json)), "reason": .string(r.reason),
            "reviewers": JSON(r.reviewers), "requestTtl": .string(timing.requestTtl),
            "maxDuration": .string(timing.maxDuration), "sessionTtl": .string(timing.sessionTtl),
        ])
        TUIStatus.toast("Saved \u{201C}\(name)\u{201D}", "success")
    }

    // MARK: - Saved requests

    /// `openSavedRequests`: load one back (returned), or delete.
    static func openSavedRequests(_ p: TeleportProfile, window: WindowModel?) async -> JSON? {
        await TUIModal.ask(window, title: "Saved requests", width: 680, height: 520) { finish, _ in
            SavedRequestsView(p: p, window: window, finish: finish)
        }
    }

    /// `timingSummary`.
    static func timingSummary(_ t: JSON) -> String? {
        let parts = [t["requestTtl"].stringish?.nilIfEmpty.map { "expires after \($0)" },
                     t["maxDuration"].stringish?.nilIfEmpty.map { "access for \($0)" },
                     t["sessionTtl"].stringish?.nilIfEmpty.map { "session \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : "timing: " + parts.joined(separator: " · ")
    }

    /// `resourceLine`'s text, by the name a human would use.
    static func resourceText(_ r: RequestResource) -> String {
        "\(r.kind)/\(r.label ?? r.name)" + (r.sub.isEmpty ? "" : "/" + r.sub)
    }
}

// MARK: - Requests list

@MainActor
final class RequestsListModel: ObservableObject {
    let p: TeleportProfile
    let window: WindowModel?
    @Published var loading = true
    @Published var result: TshList<AccessRequest>?

    init(p: TeleportProfile, window: WindowModel?) { self.p = p; self.window = window }

    var profile: TeleportProfile { AccessRequestsUI.current(p) }

    func load() {
        loading = true
        let p = self.p
        Task { @MainActor in
            let r = await Teleport.listRequests(proxy: p.proxy, home: p.homeDir)
            self.result = r
            self.loading = false
        }
    }

    func dropAll(_ ids: [String]) async {
        guard await MiscUI.confirm(window, title: "Drop assumed roles", message: "Drop all assumed access requests?",
                                   detail: "Your certificate is reissued without the extra roles.",
                                   confirmLabel: "Drop", danger: true) else { return }
        await drop(ids)
    }

    func drop(_ ids: [String]) async {
        TUIStatus.show("Dropping…", ms: 0)
        let r = await Teleport.dropRequest(ids, proxy: p.proxy, home: p.homeDir)
        TUIStatus.clear()
        if r.ok { TUIStatus.toast("Dropped", "success") } else { TUIStatus.toast(r.output.nilIfEmpty ?? "Drop failed", "error") }
        await TUI.refreshInventory()
        load()
    }

    func assume(_ id: String) async {
        TUIStatus.show("Assuming request…", ms: 0)
        let out = await Teleport.assumeRequest(id, proxy: p.proxy, home: p.homeDir)
        TUIStatus.clear()
        if out.ok {
            TUIStatus.toast("Roles assumed", "success")
            await TUI.refreshInventory()
            load()
        } else {
            TUIStatus.toast(out.output.nilIfEmpty ?? "Assume failed", "error")
        }
    }

    func details(_ id: String) async {
        let d = await Teleport.showRequest(id, proxy: p.proxy, home: p.homeDir)
        TUIModal.show(window, title: "Request " + id, width: 760, height: 520) { handle in
            DialogScaffold(title: "Request " + id, scroll: false) {
                TUIPre(text: d.text.nilIfEmpty ?? "(no details)").frame(maxHeight: .infinity)
            } footer: {
                Button("Close") { handle.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The `.req-state` pill.
struct RequestStateTag: View {
    let state: String
    var body: some View {
        let kind: TUITag.Kind = {
            switch state {
            case "PENDING": return .warn
            case "APPROVED", "PROMOTED": return .ok
            case "DENIED": return .expired
            case "ASSUMED": return .accent
            default: return .plain
            }
        }()
        TUITag(text: state, kind: kind)
    }
}

private struct RequestsListView: View {
    @ObservedObject var m: RequestsListModel
    let handle: ModalHandle

    var body: some View {
        let p = m.profile
        DialogScaffold(title: "Access requests", subtitle: TUI.name(p)) {
            content(p)
        } footer: {
            Button("New request…") {
                Task { await AccessRequestsUI.openCreateRequest(p, window: m.window); m.load() }
            }.buttonStyle(.ghost)
            Button("Saved…") {
                Task {
                    if let t = await AccessRequestsUI.openSavedRequests(p, window: m.window) {
                        await AccessRequestsUI.openCreateRequest(p, prefill: .init(template: t), window: m.window)
                        m.load()
                    }
                }
            }.buttonStyle(.ghost)
            Button("Refresh") { m.load() }.buttonStyle(.ghost)
            Button("Close") { handle.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func content(_ p: TeleportProfile) -> some View {
        let pal = Theme.shared.p
        if m.loading {
            TUIEmpty(lines: ["Loading requests…"])
        } else if let res = m.result, !res.ok {
            TUIEmpty(lines: [res.error?.nilIfEmpty ?? "Could not list requests"], error: true)
        } else if let res = m.result {
            let assumed = p.activeRequests
            VStack(alignment: .leading, spacing: 10) {
                if !assumed.isEmpty {
                    HStack(spacing: 9) {
                        Text("Currently assumed: \(assumed.joined(separator: ", "))")
                            .font(.system(size: 11.5)).foregroundStyle(pal.accent).textSelection(.enabled)
                        Button("Drop all") { Task { await m.dropAll(assumed) } }.buttonStyle(.ghostSmall)
                    }
                }
                if res.items.isEmpty {
                    TUIEmpty(lines: ["No access requests on this cluster.", "Create one below to request extra roles."])
                }
                ForEach(res.items, id: \.id) { r in card(r, p: p, assumed: assumed.contains(r.id)) }
            }
        }
    }

    private func card(_ r: AccessRequest, p: TeleportProfile, assumed: Bool) -> some View {
        let pal = Theme.shared.p
        let lines: [String] = [
            r.reason.isEmpty ? nil : "reason: " + r.reason,
            r.reviewers.isEmpty ? nil : "suggested reviewers: " + r.reviewers.joined(separator: ", "),
            TUI.formatWhen(r.assumeStartTime).map { "takes effect: " + $0 },
            TUI.formatWhen(r.expires).map { "request expires: " + $0 },
            TUI.formatWhen(r.maxDuration).map { "access until: " + $0 },
            TUI.formatWhen(r.sessionTtl).map { "session expires: " + $0 },
        ].compactMap { $0 }
        return TUICard {
            HStack(spacing: 8) {
                RequestStateTag(state: assumed ? "ASSUMED" : r.state)
                Text(r.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.muted).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                if !r.roles.isEmpty { Text("roles: " + r.roles.joined(separator: ", ")) }
                if !r.resources.isEmpty { resourceLine(r.resources) }
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.system(size: 11.5)).foregroundStyle(pal.textDim).textSelection(.enabled)
            TUIFlow(spacing: 6) {
                if r.state == "APPROVED" && !assumed {
                    Button("Assume roles") { Task { await m.assume(r.id) } }.buttonStyle(.primary)
                }
                if assumed {
                    Button("Drop") { Task { await m.drop([r.id]) } }.buttonStyle(GhostButtonStyle(destructive: true))
                }
                Button("Copy to new request") {
                    Task {
                        await AccessRequestsUI.openCreateRequest(p, prefill: AccessRequestsUI.asPrefill(r, p), window: m.window)
                        m.load()
                    }
                }.buttonStyle(.ghost).help("Open a new request with the same resources, roles and reason")
                Button("Save as reusable…") { Task { await AccessRequestsUI.saveExistingRequest(p, r, window: m.window) } }
                    .buttonStyle(.ghost).help("Keep these resources, roles and reason to raise again later")
                Button("Details") { Task { await m.details(r.id) } }.buttonStyle(.ghost)
            }
            .padding(.top, 2)
        }
    }

    /// `resourceLine`: up to six, by their resolved names; the raw id in the tooltip.
    private func resourceLine(_ resources: [RequestResource]) -> some View {
        let shown = Array(resources.prefix(6))
        return HStack(spacing: 0) {
            Text("resources: ")
            ForEach(Array(shown.enumerated()), id: \.offset) { i, r in
                Text(AccessRequestsUI.resourceText(r))
                    .underline(r.label != nil, pattern: .dot)
                    .help(r.label != nil ? "\(r.kind)/\(r.name)" : r.id)
                if i < shown.count - 1 { Text(", ") }
            }
            if resources.count > shown.count { Text(" +\(resources.count - shown.count)") }
        }
        .lineLimit(1)
    }
}

// MARK: - New request

@MainActor
final class CreateRequestModel: ObservableObject {
    let p: TeleportProfile
    let window: WindowModel?
    let prefillName: String
    var templateId: String?

    @Published var roles: [String]
    @Published var resources: [ReqResource]
    /// nil until the cluster has answered.
    @Published var offered: [String]?
    @Published var reason: String
    @Published var reviewers: String
    @Published var start: Date
    @Published var requestTtl: String
    @Published var maxDuration: String
    @Published var sessionTtl: String
    @Published var reasonMarked: Bool
    @Published var reasonPlaceholder: String
    /// The cluster's own `request_prompt`.
    @Published var clusterPrompt = ""
    @Published var showCommand = false
    @Published var focusReason = 0

    static let ttlSuggestions = ["30m", "1h", "2h", "4h", "8h", "12h", "24h", "48h"]

    init(p: TeleportProfile, prefill f: AccessRequestsUI.Prefill, window: WindowModel?) {
        self.p = p; self.window = window
        prefillName = f.name; templateId = f.id
        roles = f.roles; resources = f.resources; reason = f.reason
        reviewers = f.reviewers.joined(separator: ",")
        start = TUI.toMinute(f.assumeStartTime.flatMap { TPText.parseDate($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date())
        requestTtl = f.requestTtl; maxDuration = f.maxDuration; sessionTtl = f.sessionTtl
        let needed = AccessRequestsUI.reasonNeeded(p)
        reasonMarked = needed
        reasonPlaceholder = needed ? "Required by this cluster" : "Why you need access"
    }

    var reasonNeeded: Bool { AccessRequestsUI.reasonNeeded(p) }

    /// `collect()`.
    var spec: Teleport.RequestSpec {
        Teleport.RequestSpec(
            proxy: p.proxy, roles: roles, resources: resources.map(\.id), reason: reason.trimmed,
            requestTtl: requestTtl.trimmed, sessionTtl: sessionTtl.trimmed, maxDuration: maxDuration.trimmed,
            // Anything at or before now is the default anyway, so leave the flag off.
            assumeStartTime: TUI.futureIso(start),
            // Suggested, not required: Teleport still routes by its own review rules.
            reviewers: reviewers.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty },
            home: p.homeDir)
    }

    /// The exact command about to run.
    var commandLine: String { Teleport.requestPreview(spec).map(TUI.shellQuote).joined(separator: " ") }

    /// The roles shown as chips.
    var roleList: [String] {
        guard let offered else { return roles }
        return Array(Set(offered + roles)).sorted()
    }

    // MARK: Roles

    func loadOfferedRoles() {
        Task { @MainActor in
            let r = await Teleport.searchRequestableRoles(proxy: p.proxy, home: p.homeDir)
            var off = r.ok ? r.items.map(\.name) : []
            let history = await rolesFromHistory()
            let mine = rolesRemembered()
            off = unique(off + history + mine)
            self.offered = off
            // What you used last time for these resources starts ticked.
            if roles.isEmpty { roles = unique(history + mine) }
            await askTheCluster()
        }
    }

    private func unique(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }

    /// Which roles these resources were granted through before, from your own history.
    func rolesFromHistory() async -> [String] {
        let ids = resources.map(\.id)
        if ids.isEmpty { return [] }
        let r = await Teleport.listRequests(proxy: p.proxy, home: p.homeDir, resolveNames: false)
        return Teleport.rolesForResources(r.items, ids)
    }

    /// Roles tied to one of these resources by hand, before.
    func rolesRemembered() -> [String] {
        let map = Store.shared.settingJSON("resourceRoles")
        var out: [String] = []
        for r in resources { for role in map[r.id].stringArray where !out.contains(role) { out.append(role) } }
        return out
    }

    func rememberRolesForResources(_ list: [String]) {
        Store.shared.mutateSetting("resourceRoles") { m in
            if m.object == nil { m = .object([:]) }
            for r in resources { if list.isEmpty { m.removeKey(r.id) } else { m[r.id] = JSON(list) } }
        }
    }

    func toggleRole(_ role: String) {
        if let i = roles.firstIndex(of: role) { roles.remove(at: i) } else { roles.append(role) }
        rememberRolesForResources(roles)
    }

    /// `askTheCluster`: put an impossible request to it, and read what a real one would need.
    func askTheCluster() async {
        if resources.isEmpty { return }
        let r = await Teleport.probeRequest(proxy: p.proxy, home: p.homeDir, resources: resources.map(\.id))
        guard r.ok else { return }
        if !r.roles.isEmpty {
            offered = unique((offered ?? []) + r.roles)
            roles = unique(roles + r.roles)
        }
        if r.reasonRequired {
            AccessRequestsUI.rememberReasonRequired(p)
            reasonMarked = true
            reasonPlaceholder = "Required by this cluster"
        }
        if !r.prompt.isEmpty { clusterPrompt = r.prompt }
    }

    /// `roleCandidates`: every role name worth offering, and where it came from.
    func roleCandidates() async -> [(name: String, from: String, description: String)] {
        var order: [String] = []
        var from: [String: String] = [:]
        func add(_ n: String, _ f: String) { if !n.isEmpty && from[n] == nil { from[n] = f; order.append(n) } }
        for r in await rolesFromHistory() { add(r, "used before") }
        for r in rolesRemembered() { add(r, "you chose it") }
        for r in offered ?? [] { add(r, "offered") }
        let prof = Inventory.shared.profiles.first { $0.proxy == p.proxy && $0.homeDir == p.homeDir }
        for r in prof?.roles ?? [] { add(r, "you hold it") }
        var described: [String: String] = [:]
        let rr = await Teleport.searchRequestableRoles(proxy: p.proxy, home: p.homeDir)
        for r in rr.items {
            add(r.name, "requestable")
            if !r.description.isEmpty { described[r.name] = r.description }
        }
        return order.map { ($0, from[$0]!, described[$0] ?? "") }
    }

    /// `openRolePicker`: a menu of candidates, and "Another name…".
    func openRolePicker() async {
        let list = await roleCandidates()
        let chosen = Set(roles)
        var items: [CtxItem] = [.heading("Roles for this request")]
        for r in list {
            items.append(CtxItem(r.name, key: chosen.contains(r.name) ? "\u{2713}" : r.from,
                                 title: r.description.nilIfEmpty ?? "Add \(r.name) to this request") { [weak self] in
                guard let self else { return }
                if chosen.contains(r.name) { self.roles.removeAll { $0 == r.name } } else { self.roles.append(r.name) }
                self.offered = self.unique((self.offered ?? []) + [r.name])
                self.rememberRolesForResources(self.roles)
            })
        }
        if !list.isEmpty { items.append(.sep) }
        items.append(CtxItem("Another name\u{2026}", title: "For a role none of the lists above knows about") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard let v = await MiscUI.prompt(self.window, title: "Role to request",
                                                  label: "Its name, exactly as the cluster spells it", confirmLabel: "Add"),
                      !v.isEmpty else { return }
                self.offered = self.unique((self.offered ?? []) + [v.trimmed])
                self.roles = self.unique(self.roles + [v.trimmed])
                self.rememberRolesForResources(self.roles)
            }
        })
        CtxMenu.show(items)
    }

    // MARK: Buttons

    func loadSaved() async {
        guard let t = await AccessRequestsUI.openSavedRequests(p, window: window) else { return }
        let f = AccessRequestsUI.Prefill(template: t)
        roles = f.roles; resources = f.resources; reason = f.reason
        reviewers = f.reviewers.joined(separator: ",")
        requestTtl = f.requestTtl; maxDuration = f.maxDuration; sessionTtl = f.sessionTtl
        // A saved start time has long since passed; replaying means "now".
        start = TUI.toMinute(Date())
        templateId = f.id
        TUIStatus.show("Loaded \u{201C}\(f.name)\u{201D}")
    }

    func save() async {
        let cur = spec
        if cur.roles.isEmpty && cur.resources.isEmpty {
            TUIStatus.toast("Choose roles or resources before saving", "error"); return
        }
        guard let name = await MiscUI.prompt(window, title: "Save this request",
                                             label: "Listed under \(TUI.name(p)), ready to raise again.",
                                             value: prefillName, placeholder: "e.g. prod database incident access",
                                             confirmLabel: "Save"), !name.isEmpty else { return }
        var rec: JSON = [
            "name": .string(name), "proxy": .string(p.proxy), "cluster": .string(p.cluster),
            "roles": JSON(cur.roles), "resources": .array(resources.map(\.json)), "reason": .string(cur.reason ?? ""),
            "reviewers": JSON(cur.reviewers), "requestTtl": .string(cur.requestTtl ?? ""),
            "maxDuration": .string(cur.maxDuration ?? ""), "sessionTtl": .string(cur.sessionTtl ?? ""),
            "assumeStartTime": .string(cur.assumeStartTime ?? ""),
        ]
        if let id = templateId { rec["id"] = .string(id) }
        TUIData.upsertRequestTemplate(rec)
        TUIStatus.toast("Request saved", "success")
    }

    /// Sent from inside the dialog, so a refusal lands where it can be fixed.
    func submit(_ finish: @escaping (Bool?) -> Void) async {
        let cur = spec
        if cur.roles.isEmpty && cur.resources.isEmpty {
            TUIStatus.toast("Give at least one role or resource", "error"); return
        }
        if reasonNeeded && (cur.reason ?? "").trimmed.isEmpty {
            reasonMarked = true
            focusReason += 1
            TUIStatus.toast("\(TUI.name(p)) requires a reason for access requests", "error", ms: 7000)
            return
        }
        TUIStatus.show("Creating request…", ms: 0)
        let out = await Teleport.createRequest(cur)
        TUIStatus.clear()
        if out.ok {
            if let id = templateId { TUIData.markRequestTemplateUsed(id) }
            TUIStatus.toast("Request created", "success")
            finish(true)
            return
        }
        let why = TUI.firstLine(out.output) ?? "Create failed"
        // tsh stopped to ask which roles; the names it was about to offer
        // become the chips and the person answers instead.
        if !out.roleChoices.isEmpty {
            offered = unique((offered ?? []) + out.roleChoices)
            TUIStatus.toast("\(TUI.name(p)) needs you to say which roles to request — choose them above and submit again",
                            "error", ms: 12000)
            return
        }
        if out.needsReason || TPText.test("reason", why, .caseInsensitive) {
            AccessRequestsUI.rememberReasonRequired(p)
            reasonMarked = true
            focusReason += 1
        }
        TUIStatus.toast(why, "error", ms: 10000)
    }
}

private struct CreateRequestView: View {
    @ObservedObject var m: CreateRequestModel
    let finish: (Bool?) -> Void
    @FocusState private var reasonFocused: Bool

    var body: some View {
        let pal = Theme.shared.p
        DialogScaffold(title: "New access request", subtitle: TUI.name(m.p)) {
            VStack(alignment: .leading, spacing: 0) {
                fieldHead("Roles") {
                    Button("Choose…") {
                        Task { if let picked = await RequestPicker.pickRoles(m.p, preselected: m.roles, window: m.window) { m.roles = picked } }
                    }.buttonStyle(.ghostSmall)
                }
                rolesBox.padding(.bottom, 12)
                fieldHead("Resources") {
                    Button("Browse…") {
                        Task {
                            if let picked = await RequestPicker.pickResources(m.p, preselected: m.resources, window: m.window) {
                                m.resources = picked
                            }
                        }
                    }.buttonStyle(.ghostSmall)
                }
                resourcesBox.padding(.bottom, 12)
                TUIField(label: "Reason") {
                    TextField(m.reasonPlaceholder, text: $m.reason).textFieldStyle(.roundedBorder)
                        .focused($reasonFocused)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(m.reasonMarked ? pal.red : .clear, lineWidth: 1.5))
                        // The mark clears once something is typed, and comes
                        // back on an emptied field where the cluster wants one.
                        .onChange(of: m.reason) { _, v in
                            if !v.trimmed.isEmpty { m.reasonMarked = false } else if m.reasonNeeded { m.reasonMarked = true }
                        }
                }
                if !m.clusterPrompt.isEmpty { MiscHint(text: m.clusterPrompt, size: 11).padding(.top, -6).padding(.bottom, 10) }
                TUIField(label: "Suggested reviewers", hint: "Optional. Comma separated — the cluster still applies its own review rules.") {
                    TextField("optional — alice,bob", text: $m.reviewers).textFieldStyle(.roundedBorder)
                }
                fieldHead("Timing") {
                    Button("Start now") { m.start = TUI.toMinute(Date()) }.buttonStyle(.ghostSmall)
                        .help("Reset the start time to immediately")
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    timeField("Takes effect", "Defaults to now") {
                        DatePicker("", selection: $m.start, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden().datePickerStyle(.field)
                    }
                    timeField("Request expires", "Unreviewed after this") { durationInput($m.requestTtl) }
                    timeField("Access lasts", "Once approved") { durationInput($m.maxDuration) }
                    timeField("Session expires", "Elevated certificate") { durationInput($m.sessionTtl) }
                }
                .padding(.bottom, 12)
                commandDisclosure
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Load saved…") { Task { await m.loadSaved() } }.buttonStyle(.ghost)
            Button("Save…") { Task { await m.save() } }.buttonStyle(.ghost)
            Button("Submit request") { Task { await m.submit(finish) } }.buttonStyle(.primary)
        }
        .onChange(of: m.focusReason) { _, _ in reasonFocused = true }
    }

    private func fieldHead<B: View>(_ label: String, @ViewBuilder button: () -> B) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.shared.p.textDim)
            Spacer()
            button()
        }
        .padding(.bottom, 5)
    }

    private func timeField<C: View>(_ label: String, _ hint: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.shared.p.textDim)
            content()
            Text(hint).font(.system(size: 10)).foregroundStyle(Theme.shared.p.muted)
        }
    }

    private func durationInput(_ value: Binding<String>) -> some View {
        HStack(spacing: 3) {
            TextField("e.g. 4h", text: value).textFieldStyle(.roundedBorder)
            Menu {
                ForEach(CreateRequestModel.ttlSuggestions, id: \.self) { s in Button(s) { value.wrappedValue = s } }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
        }
    }

    /// Every role this cluster would let you ask for, as chips to switch on and off.
    @ViewBuilder private var rolesBox: some View {
        let list = m.roleList
        let chosen = Set(m.roles)
        if list.isEmpty {
            MiscHint(text: m.offered == nil ? "Asking the cluster which roles you may request…"
                     : "No roles to request here — resources only.", size: 11)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                TUIFlow(spacing: 5, lineSpacing: 5) {
                    ForEach(list, id: \.self) { role in
                        let on = chosen.contains(role)
                        Button { m.toggleRole(role) } label: { roleChip(role, on: on) }
                            .buttonStyle(.plain)
                            .help(on ? "Included — click to leave it out" : "Click to include this role")
                    }
                    Button("+ role") { Task { await m.openRolePicker() } }.buttonStyle(.ghostSmall)
                        .help("Add a role to this request from the ones this cluster knows about")
                }
                MiscHint(text: m.roles.isEmpty
                         ? "None included: this asks for the resources alone, which is what most requests want."
                         : "\(m.roles.count) of \(list.count) included — the rest are left out of this request.", size: 10.5)
            }
        }
    }

    private func roleChip(_ role: String, on: Bool) -> some View {
        let p = Theme.shared.p
        return HStack(spacing: 4) {
            Image(systemName: on ? "checkmark" : "plus").font(.system(size: 8, weight: .bold))
            Text(role).font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(on ? p.accent : p.textDim)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(on ? p.accent.opacity(0.16) : p.panel3))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? p.accent.opacity(0.5) : p.border, lineWidth: 0.5))
    }

    @ViewBuilder private var resourcesBox: some View {
        let p = Theme.shared.p
        if m.resources.isEmpty {
            MiscHint(text: "Nothing selected — use Browse…", size: 11)
        } else {
            TUIFlow(spacing: 5, lineSpacing: 5) {
                ForEach(m.resources) { r in
                    HStack(spacing: 4) {
                        Text(r.kind).foregroundStyle(p.muted)
                        Text(r.name.nilIfEmpty ?? r.id).foregroundStyle(p.accent)
                        Button { m.resources.removeAll { $0.id == r.id } } label: { Text("\u{00D7}") }
                            .buttonStyle(.plain).foregroundStyle(p.muted).help("Remove")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(p.accent.opacity(0.12)))
                    .help(r.id)
                }
            }
        }
    }

    /// The exact command, folded away; Copy works without opening it.
    private var commandDisclosure: some View {
        let p = Theme.shared.p
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { m.showCommand.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: m.showCommand ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Text("tsh command").font(.system(size: 11.5))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(p.textDim)
                Spacer()
                Button("Copy") { Clipboard.write(m.commandLine); TUIStatus.show("Command copied") }.buttonStyle(.ghostSmall)
            }
            if m.showCommand {
                Text(m.commandLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textDim)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
            }
        }
    }
}

// MARK: - Saved requests

private struct SavedRequestsView: View {
    let p: TeleportProfile
    let window: WindowModel?
    let finish: (JSON?) -> Void

    var body: some View {
        let pal = Theme.shared.p
        let list = TUIData.listRequestTemplates(proxy: p.proxy)
        DialogScaffold(title: "Saved requests", subtitle: TUI.name(p)) {
            if list.isEmpty {
                TUIEmpty(lines: ["Nothing saved for this cluster yet.", "Build a request, then use Save… to keep it."])
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, t in
                        let res = t["resources"].items
                        let resText = res.prefix(5).map { $0["name"].stringish?.nilIfEmpty ?? $0["id"].stringish ?? "" }
                            .joined(separator: ", ") + (res.count > 5 ? " +\(res.count - 5)" : "")
                        let lines: [String] = [
                            t["roles"].stringArray.isEmpty ? nil : "roles: " + t["roles"].stringArray.joined(separator: ", "),
                            res.isEmpty ? nil : "\(res.count) resource(s): " + resText,
                            t["reason"].stringish?.nilIfEmpty.map { "reason: " + $0 },
                            t["reviewers"].stringArray.isEmpty ? nil : "reviewers: " + t["reviewers"].stringArray.joined(separator: ", "),
                            AccessRequestsUI.timingSummary(t),
                        ].compactMap { $0 }
                        TUICard {
                            HStack {
                                Text(t["name"].stringish ?? "").fontWeight(.semibold)
                                Spacer()
                                Text(t["lastUsed"].double.flatMap { $0 > 0 ? "raised " + TUI.localeDateString(ms: $0) : nil } ?? "never raised")
                                    .font(.system(size: 11)).foregroundStyle(pal.muted)
                            }
                            VStack(alignment: .leading, spacing: 2) { ForEach(lines, id: \.self) { Text($0) } }
                                .font(.system(size: 11.5)).foregroundStyle(pal.textDim)
                            HStack(spacing: 6) {
                                Button("Load") { finish(t) }.buttonStyle(.primary)
                                Button("Delete") {
                                    Task { @MainActor in
                                        guard await MiscUI.confirm(window, title: "Delete saved request",
                                                                   message: "Delete \u{201C}\(t["name"].stringish ?? "")\u{201D}?",
                                                                   confirmLabel: "Delete", danger: true) else { return }
                                        if let id = t["id"].string { TUIData.deleteRequestTemplate(id) }
                                    }
                                }.buttonStyle(GhostButtonStyle(destructive: true))
                            }
                        }
                    }
                }
            }
        } footer: {
            Button("Close") { finish(nil) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
