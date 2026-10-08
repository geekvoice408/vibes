import AppKit
import Foundation
import Observation

/// One target of a multi-exec: a host (ticked or matched by tag), or an open
/// session when nothing is ticked.
struct MXTarget: Equatable {
    var hostId: String?
    var host: Host?
    var connId: String?
    var label: String
}

/// The tag selector: a cluster (proxy, "" for every logged-in one) and a query.
struct MXSelector: Equatable {
    var on = false
    var proxy = ""
    var query = ""
}

/// The hosts the last fan-out could not dial, and what it tried them as.
struct MXFailed {
    struct Host { var target: MXTarget; var login: String?; var error: String }
    var command: String
    var runAs: String?
    var label: String
    var hosts: [Host]
}

/// Per-window dock state and the multi-exec workflow of dock.js: what to run,
/// on which hosts, as whom, and what to remember.
@MainActor
@Observable
final class FleetWindow: WindowFeature {
    @ObservationIgnored weak var window: WindowModel?

    var lastCommand = ""
    var lastRunAs = ""
    /// Kept until the next run replaces it: a connection failure is the most
    /// re-triable thing in a fan-out — an expired certificate, an MFA prompt
    /// that timed out, a proxy that blinked.
    var lastFailed: MXFailed?
    /// command | macros | history
    var mxView = "command"
    var mxMacroFilter = ""
    /**
     * A target set expressed as a question rather than a list: a cluster and a
     * tag query, resolved when the command runs. Kept in the dock's own state
     * and saved with a run, so a YAML saved today runs against whatever
     * matches next month.
     */
    var tagSelector = MXSelector()
    /// Result cards opened or closed by hand: runId/connId → expanded.
    var expanded: [String: Bool] = [:]
    /// Bumped to make the history list re-read the store.
    var historyRevision = 0

    init(window: WindowModel) { self.window = window }

    private var w: WindowModel { window ?? WindowManager.shared.current() }

    // MARK: Targets

    /// The hosts a tag selector matches right now.
    func hostsForSelector(_ sel: MXSelector? = nil) -> [Host] {
        let sel = sel ?? tagSelector
        guard sel.on else { return [] }
        let match = FleetHooks.query(sel.query)
        let showHidden = Store.shared.settingJSON("showHiddenHosts").bool == true
        var out: [Host] = []
        for p in Inventory.shared.profiles {
            if !sel.proxy.isEmpty && p.proxy != sel.proxy { continue }
            for n in Inventory.shared.nodesByKey[p.key] ?? [] {
                if !match(n) { continue }
                if FleetHooks.hidden(n) && !showHidden { continue }
                out.append(n)
            }
        }
        // An ssh_config host has no labels, so a tag query cannot name one; when
        // the query is empty and no cluster is chosen this would otherwise be
        // "every host in the window", which is not something to run a command
        // on by accident.
        return !sel.query.trimmed.isEmpty || !sel.proxy.isEmpty ? out : []
    }

    /**
     * The account a target will be reached as: an explicit *run as* wins, then
     * whatever last worked for this host, then the cluster's first login or
     * the config's user.
     */
    func loginForTarget(_ t: MXTarget, _ runAs: String?) -> String? {
        if let runAs, !runAs.isEmpty { return runAs }
        guard let host = t.host ?? t.hostId.flatMap(FleetHooks.hostById) else {
            // Nothing but a live session to go on: it already knows who it is.
            return t.connId.flatMap { ConnectionManager.shared.connection($0)?.login }
        }
        if let l = Store.shared.settingJSON("hostLogins")[host.id].string, !l.isEmpty { return l }
        if host.isTeleport {
            return Inventory.shared.profiles.first { $0.cluster == host.cluster }?.logins.first
        }
        return host.user?.nilIfEmpty
    }

    /// `name` or `name (as ubuntu)`, for the places that list targets.
    func targetLabel(_ t: MXTarget, _ runAs: String?) -> String {
        guard let who = loginForTarget(t, runAs) else { return t.label }
        // An open session's label already says who it is — "ent (ubuntu)".
        if t.label.hasSuffix("(\(who))") { return t.label }
        return "\(t.label) (\(who))"
    }

    private func connFor(hostId: String) -> Connection? {
        ConnectionManager.shared.connections.first { $0.hostId == hostId }
    }

    /// Selected sidebar hosts take priority; otherwise every open session. A
    /// tag selector, when on, replaces the ticked list.
    func resolveTargets() -> [MXTarget] {
        if tagSelector.on {
            return hostsForSelector().map { h in
                MXTarget(hostId: h.id, host: h, connId: connFor(hostId: h.id)?.id, label: h.name.nilIfEmpty ?? h.alias ?? h.id)
            }
        }
        let checked = FleetHooks.checked(w)
        if !checked.isEmpty {
            return checked.compactMap { id in
                guard let h = FleetHooks.hostById(id) else { return nil }
                return MXTarget(hostId: id, host: h, connId: connFor(hostId: id)?.id, label: h.name.nilIfEmpty ?? h.alias ?? id)
            }
        }
        return ConnectionManager.shared.connections.filter { $0.state == .connected }.map {
            MXTarget(hostId: $0.hostId, host: nil, connId: $0.id, label: $0.label)
        }
    }

    /// Every login the logged-in clusters grant, for the run-as suggestions.
    func knownLogins() -> [String] {
        var out = Set<String>()
        for p in Inventory.shared.profiles { p.logins.forEach { out.insert($0) } }
        for h in Inventory.shared.sshHosts { if let u = h.user, !u.isEmpty { out.insert(u) } }
        return out.sorted()
    }

    /// The line under the form: who it will run on, as whom.
    func targetsLine(runAs: String) -> String {
        let targets = resolveTargets()
        let who = runAs.trimmed.nilIfEmpty
        let named = targets.map { targetLabel($0, who) }.joined(separator: ", ")
        let n = targets.count
        if tagSelector.on {
            return n > 0
                ? "Matches now: \(n) host\(n == 1 ? "" : "s") \u{2014} \(named)"
                : "Nothing matches that query yet. It is resolved again every time you run, so this can be written before the hosts exist."
        }
        if n > 0 {
            // With nothing ticked the run goes to the open sessions, which is
            // easy to forget once the ticks are gone — so it says so.
            return FleetHooks.checked(w).isEmpty ? "Targets (open sessions \u{2014} nothing ticked): \(named)" : "Targets: \(named)"
        }
        return "No hosts selected. Tick hosts in the sidebar, or open sessions \u{2014} open sessions are used when nothing is ticked."
    }

    // MARK: Running

    func runMulti(_ command: String, runAs: String?, label: String? = nil, only: [MXTarget]? = nil) async {
        let cmd = command.trimmed
        guard !cmd.isEmpty else { StatusBus.shared.toast("Enter a command", kind: .error); return }
        // `only` is a retry over the hosts that failed last time, which must not
        // be re-derived from the selection: ticks and tag queries move on.
        var targets = (only?.isEmpty == false) ? only! : resolveTargets()
        guard !targets.isEmpty else { StatusBus.shared.toast("Select hosts in the sidebar first", kind: .error); return }
        let runAs = runAs?.nilIfEmpty
        var failed: [MXFailed.Host] = []

        /*
         * A host marked careful gets a second look before a command fans out to
         * it. Marked by hand, on the host's own menu, for the boxes where "run
         * this everywhere" is how an outage starts.
         */
        let careful = targets.compactMap { $0.host ?? $0.hostId.flatMap(FleetHooks.hostById) }.filter(FleetHooks.careful)
        if !careful.isEmpty {
            let names = careful.map { $0.name.nilIfEmpty ?? $0.alias ?? $0.id }.joined(separator: ", ")
            let n = targets.count
            let ok = await MiscUI.confirm(w, title: "Run on a host marked careful?",
                                          message: "\(names) \(careful.count == 1 ? "is" : "are") marked careful.",
                                          detail: "The command is:\n\n\(cmd)\n\nIt would run on \(n) host\(n == 1 ? "" : "s").",
                                          confirmLabel: "Run it", danger: true)
            if !ok { return }
        }

        lastCommand = cmd
        lastRunAs = runAs ?? ""
        w.showDock("multiexec")
        StatusBus.shared.show("\(label.map { $0 + " \u{2014} running" } ?? "Running") on \(targets.count) host(s)\(runAs.map { " as " + $0 } ?? "")\u{2026}", seconds: 0)

        // Hosts without a live connection need one created first.
        var connIds: [String] = []
        for i in targets.indices {
            var t = targets[i]
            if let cid = t.connId {
                let existing = ConnectionManager.shared.connection(cid)
                // Reusing a session opened as someone else would silently ignore "run as".
                if runAs == nil || existing?.login == runAs { connIds.append(cid); continue }
                t.host = t.host ?? t.hostId.flatMap(FleetHooks.hostById)
                targets[i] = t
                if t.host == nil { connIds.append(cid); continue }
            }
            guard let host = t.host ?? t.hostId.flatMap(FleetHooks.hostById) else {
                failed.append(.init(target: t, login: loginForTarget(t, runAs), error: "That host is no longer in the list"))
                continue
            }
            do {
                // Explicit "run as" wins; otherwise reuse whatever worked for this host.
                let login = loginForTarget(t, runAs)
                let c = try await ConnectionManager.shared.create(host: host, options: ConnectOptions(login: login))
                connIds.append(c.id)
            } catch {
                /*
                 * A host that could not be dialled is kept, not just announced:
                 * the failures are held with what they were tried as, and offered
                 * back as a retry over just those hosts.
                 */
                failed.append(.init(target: t, login: loginForTarget(t, runAs),
                                    error: (error as? AppError)?.message ?? error.localizedDescription))
            }
        }
        // Set before the run so the panel can show it even if the run itself throws.
        lastFailed = failed.isEmpty ? nil : MXFailed(command: cmd, runAs: runAs, label: label ?? "", hosts: failed)

        guard !connIds.isEmpty else {
            StatusBus.shared.clear()
            StatusBus.shared.toast(failed.isEmpty ? "Nothing to run on" : "None of the \(failed.count) host(s) could be connected", kind: .error)
            return
        }
        let view = await MultiExecService.shared.run(connIds, command: cmd,
                                                     options: .init(concurrency: 10, timeout: 120_000))
        /*
         * Keep the question, not the answers. "Run that again" is the common
         * follow-up — after a fix, after a deploy, an hour later — and rebuilding
         * the host selection by hand is the tedious part.
         */
        var rec: JSON = [
            "command": .string(cmd),
            "label": .string(label ?? ""),
            "runAs": JSON(runAs),
            "hosts": JSON(targets.map(\.label)),
            "hostIds": JSON(targets.compactMap(\.hostId)),
            // A tag run is remembered as its query: running it again should ask
            // the same question, not repeat the answer it got last time.
            "selector": tagSelector.on ? ["proxy": .string(tagSelector.proxy), "query": .string(tagSelector.query)] : .null,
        ]
        // Hosts that never connected are not in the run's results, but count.
        rec["unreachable"] = .number(Double(failed.count))
        FleetHistory.shared.remember(view, rec, window: self)
        StatusBus.shared.clear()
    }

    /// Dial the hosts that failed last time, and run the same command on them.
    func retryFailed() async {
        guard let f = lastFailed, !f.hosts.isEmpty else { return }
        await runMulti(f.command, runAs: f.runAs, label: f.label.nilIfEmpty, only: f.hosts.map(\.target))
    }

    /// A macro across the selection: blanks filled in once, the same values
    /// to every host.
    func runMacroMulti(_ macroIn: Macro, login: String?) async {
        guard let macro = await Macros.shared.resolve(macroIn, window: w) else { return }
        if macro.confirm {
            let n = resolveTargets().count
            let ok = await MiscUI.confirm(w, title: macro.name, message: "Run on \(n) host\(n == 1 ? "" : "s")?",
                                          detail: macro.command, confirmLabel: "Run", danger: true)
            if !ok { return }
        }
        lastCommand = macro.command
        Macros.shared.markUsed(macro)
        await runMulti(macro.command, runAs: login, label: macro.name)
    }

    // MARK: Recent runs

    /// A remembered run's hosts, split into the ones still listed and the rest.
    func runHosts(_ run: JSON) -> (found: [Host], missing: [String]) {
        var found: [Host] = [], missing: [String] = []
        for id in run["hostIds"].items.compactMap(\.stringish) {
            if let h = FleetHooks.hostById(id) { found.append(h) } else { missing.append(id) }
        }
        return (found, missing)
    }

    /// Tick exactly these hosts, as the sidebar would.
    func tickHosts(_ hosts: [Host]) {
        tagSelector = MXSelector()
        FleetHooks.setChecked(w, hosts.map(\.id))
    }

    private func selectorOf(_ run: JSON) -> MXSelector? {
        let q = run["selector"]["query"]
        guard run["selector"].object != nil, !q.isNull else { return nil }
        return MXSelector(on: true, proxy: run["selector"]["proxy"].stringish ?? "", query: q.stringish ?? "")
    }

    /// Put a remembered run back in the form — command, login and its hosts —
    /// without running it.
    func editRun(_ run: JSON) {
        lastCommand = run["command"].stringish ?? ""
        lastRunAs = run["runAs"].stringish ?? ""
        mxView = "command"
        if let sel = selectorOf(run) {
            tagSelector = sel
            FleetHooks.setChecked(w, [])
            StatusBus.shared.show("Editing \u{2014} hosts chosen by tag: \(sel.query)")
            return
        }
        let (found, missing) = runHosts(run)
        tickHosts(found)
        if !missing.isEmpty {
            StatusBus.shared.toast("\(found.count) of \(run["hostIds"].items.count) hosts re-selected \u{2014} \(missing.count) are no longer in the list",
                                   kind: .error, seconds: 7)
        } else {
            StatusBus.shared.show("Editing \u{2014} \(found.count) host\(found.count == 1 ? "" : "s") re-selected")
        }
    }

    /**
     * Run a remembered run again, on the hosts it named. The selection is
     * rebuilt from host ids rather than names, so a renamed Teleport node still
     * matches. A host that has genuinely gone is reported rather than silently
     * skipped, because "it ran on four of six" is a different result from "it ran".
     */
    func rerun(_ run: JSON) async {
        let command = run["command"].stringish ?? ""
        let runAs = run["runAs"].stringish
        let label = run["label"].stringish?.nilIfEmpty
        // A remembered tag run re-asks its question rather than repeating its answer.
        if let sel = selectorOf(run) {
            tagSelector = sel
            FleetHooks.setChecked(w, [])
            mxView = "command"
            if resolveTargets().isEmpty { StatusBus.shared.toast("Nothing matches that query now", kind: .error); return }
            await runMulti(command, runAs: runAs, label: label)
            return
        }
        let (found, missing) = runHosts(run)
        if found.isEmpty { StatusBus.shared.toast("None of those hosts are in the list any more", kind: .error); return }
        if !missing.isEmpty {
            let ok = await MiscUI.confirm(w, title: "Some hosts are missing",
                                          message: "\(found.count) of \(run["hostIds"].items.count) hosts are still in the list.",
                                          detail: "The missing ones may have been logged out of, hidden or removed from the config. "
                                              + "Running now would run on the ones that are left.",
                                          confirmLabel: "Run on \(found.count)")
            if !ok { return }
        }
        // The selection is what runMulti reads, so it is set rather than passed.
        tickHosts(found)
        await runMulti(command, runAs: runAs, label: label)
    }

    // MARK: Files

    private func teleportLogin(_ host: Host, _ conn: Connection?) -> String? {
        conn?.login ?? Inventory.shared.profiles.first { $0.cluster == host.cluster }?.logins.first
    }

    /// Describe the current selection in the shape the YAML file stores.
    func currentRunDefinition() -> [MultiExecFile.Target] {
        resolveTargets().map { t in
            let host = t.host ?? t.hostId.flatMap(FleetHooks.hostById)
            let conn = t.connId.flatMap { ConnectionManager.shared.connection($0) }
            if let host, host.isTeleport {
                return MultiExecFile.Target(type: "teleport", name: host.name, cluster: host.cluster, proxy: host.proxy,
                                            login: teleportLogin(host, conn), home: host.home)
            }
            return MultiExecFile.Target(type: "ssh", alias: host?.alias ?? t.label, user: conn?.login ?? host?.user, port: host?.port)
        }
    }

    func saveRunYaml(_ command: String) async {
        let cmd = command.trimmed
        guard !cmd.isEmpty else { StatusBus.shared.toast("Enter a command to save", kind: .error); return }
        let targets = currentRunDefinition()
        let sel = tagSelector.on ? tagSelector : nil
        if targets.isEmpty && sel == nil { StatusBus.shared.toast("Select hosts in the sidebar first", kind: .error); return }
        let name = FleetStore.firstLine(cmd, max: 50)
        /*
         * A tag run saves the *question*. The hosts it matches today go in as
         * well, commented as a snapshot, so the file still says what it meant
         * when someone reads it in six months — but the query is what runs.
         */
        let text = MultiExecFile.toYaml(name: name, command: cmd, targets: targets,
                                        options: .init(concurrency: 10, timeout: 120_000),
                                        selector: sel.map { .init(cluster: $0.proxy.nilIfEmpty, query: $0.query) })
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
        guard let url = await Modal.saveFile(w, defaultName: MultiExecFile.safeFileName(name) + ".yaml", directory: docs,
                                             types: FleetFiles.yamlTypes) else { return }
        do {
            try Data(text.utf8).write(to: url)
            StatusBus.shared.show("Saved " + url.path)
            StatusBus.shared.toast("Run saved as YAML", kind: .ok)
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
        }
    }

    /// Load a saved run: restore the command, and re-select the hosts it names
    /// by matching them against the current inventory.
    func loadRunYaml() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
        guard let url = await Modal.openFiles(w, multiple: false, directory: docs, types: FleetFiles.yamlTypes).first else { return }
        let def: MultiExecFile.Definition
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            def = try MultiExecFile.fromYaml(text)
        } catch {
            StatusBus.shared.toast((error as? AppError)?.message ?? error.localizedDescription, kind: .error)
            return
        }
        lastCommand = def.command
        /*
         * A saved tag run restores the query rather than the host list: what it
         * meant was "whatever matches", and resolving it now is the point.
         */
        if let sel = def.selector {
            tagSelector = MXSelector(on: true, proxy: sel.cluster ?? "", query: sel.query)
            FleetHooks.setChecked(w, [])
            let n = resolveTargets().count
            StatusBus.shared.show("Loaded \"\(def.name)\" \u{2014} \(n) host\(n == 1 ? "" : "s") match that query now")
            return
        }
        tagSelector = MXSelector()
        var matched: [String] = [], missing: [String] = [], ids: [String] = []
        for t in def.targets {
            var host: Host?
            if t.type == "teleport" {
                for p in Inventory.shared.profiles {
                    if let c = t.cluster, !c.isEmpty, p.key != c { continue }
                    if let n = (Inventory.shared.nodesByKey[p.key] ?? []).first(where: { $0.name == t.name }) { host = n; break }
                }
            } else {
                host = Inventory.shared.sshHosts.first { $0.alias == t.alias }
            }
            if let host { ids.append(host.id); matched.append(host.name.nilIfEmpty ?? host.alias ?? host.id) }
            else { missing.append(t.name ?? t.alias ?? "") }
        }
        FleetHooks.setChecked(w, ids)
        if !missing.isEmpty {
            StatusBus.shared.toast("Loaded \"\(def.name)\" \u{2014} \(matched.count) hosts matched, \(missing.count) not found: \(missing.joined(separator: ", "))",
                                   kind: .error, seconds: 8)
        } else {
            StatusBus.shared.toast("Loaded \"\(def.name)\" \u{2014} \(matched.count) hosts selected", kind: .ok)
        }
        StatusBus.shared.show("Loaded run from \(url.path)")
    }

    func saveResults(_ view: MultiExecView) async {
        let text = MultiExecFile.resultsToYaml(view, includeOutput: true)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
        guard let url = await Modal.saveFile(w, defaultName: "multiexec-results-\(Int(nowMs())).yaml", directory: docs,
                                             types: FleetFiles.yamlTypes) else { return }
        do {
            try Data(text.utf8).write(to: url)
            StatusBus.shared.show("Results saved: " + url.path)
            StatusBus.shared.toast("Results saved", kind: .ok)
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
        }
    }

    /// Turn the current command + host selection into an Ansible bundle on disk.
    func exportAnsible(_ command: String) async {
        let cmd = command.trimmed
        guard !cmd.isEmpty else { StatusBus.shared.toast("Enter a command to export", kind: .error); return }
        let targets = resolveTargets()
        guard !targets.isEmpty else { StatusBus.shared.toast("Select hosts in the sidebar first", kind: .error); return }
        let payload: [AnsibleExport.Target] = targets.map { t in
            let host = t.host ?? t.hostId.flatMap(FleetHooks.hostById)
            let conn = t.connId.flatMap { ConnectionManager.shared.connection($0) }
            if let host, host.isTeleport {
                return AnsibleExport.Target(type: "teleport", name: host.name, cluster: host.cluster, proxy: host.proxy,
                                            home: host.home, login: teleportLogin(host, conn))
            }
            return AnsibleExport.Target(type: "ssh", name: host?.alias ?? t.label, alias: host?.alias ?? t.label,
                                        user: conn?.login ?? host?.user, port: host?.port)
        }
        /*
         * The folder's name first, before the folder picker: every export used to
         * be called serverlife-ansible, so the second one quietly replaced the
         * first. The suggestion is the command's first word — ansible-df.
         */
        guard let folderName = await MiscUI.prompt(w, title: "Name the export",
                                                   label: "Folder name \u{2014} you choose where it goes next",
                                                   value: AnsibleExport.suggestFolderName(cmd),
                                                   confirmLabel: "Choose where\u{2026}",
                                                   validate: { $0.isEmpty ? "Give the folder a name" : nil }),
              !folderName.isEmpty else { return }
        /*
         * A tag run exports the hosts it matches *now* — an inventory is a list
         * of machines, so the question has to be answered before it is written.
         * The play's name says which query produced it.
         */
        let playName = tagSelector.on && !tagSelector.query.isEmpty
            ? "Run on \(tagSelector.query): \(FleetStore.firstLine(cmd, max: 40))"
            : "Run: \(FleetStore.firstLine(cmd, max: 60))"
        guard let parent = await Modal.chooseDirectory(w, prompt: "Export here") else { return }
        let dir = (parent.path as NSString).appendingPathComponent(AnsibleExport.exportFolderName(folderName))
        /*
         * An earlier export by the same name is not overwritten unasked: its
         * playbook may have been edited since.
         */
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dir), !items.isEmpty {
            let replace = await MiscUI.confirm(w, title: "That folder is already there", message: dir,
                                               detail: "It has files in it \u{2014} perhaps an earlier export, perhaps edited since. "
                                                   + "Replacing writes the new inventory, playbook and scripts over the old ones.",
                                               confirmLabel: "Replace them", danger: true)
            if !replace { return }
        }
        StatusBus.shared.show("Exporting Ansible bundle\u{2026}", seconds: 0)
        do {
            let bundle = AnsibleExport.build(payload, command: cmd, .init(playName: playName))
            let res = try await AnsibleExport.write(dir, bundle)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (res.dir as NSString).appendingPathComponent("playbook.yml"))])
            StatusBus.shared.clear()
            await offerShellIn(res)
        } catch {
            StatusBus.shared.clear()
            StatusBus.shared.toast((error as? AppError)?.message ?? error.localizedDescription, kind: .error)
        }
    }

    /**
     * After an export: offer a local shell already in the bundle's folder. The
     * next thing anyone does with an export is run it, and that starts with
     * `cd` into a folder whose path they have just been shown once.
     */
    private func offerShellIn(_ res: AnsibleExport.Written) async {
        let ok = await MiscUI.confirm(w, title: "Ansible bundle exported", message: "\(res.files.count) files in \(res.dir)",
                                      detail: "Open a local shell in that folder? `./run.sh` runs the playbook; "
                                          + "`./run.sh --list-hosts` shows which hosts it would run on, without running anything.",
                                      confirmLabel: "Open a local shell there")
        guard ok else { return }
        let name = res.dir.split(separator: "/").last.map(String.init) ?? "ansible"
        Actions.shared.perform("open-local", window: w, args: ["cwd": res.dir, "title": "ansible \u{00B7} \(name)"])
    }
}

/// Recent runs are written when a run has finished, not when it starts — the
/// counts are the point. Whichever of "started" and "done" arrives second
/// writes the record, since a run whose hosts all failed to connect can be
/// done before its start has been answered.
@MainActor
final class FleetHistory {
    static let shared = FleetHistory()
    private var waiting: [String: (JSON, FleetWindow?)] = [:]
    private var finished: [String: MultiExecView] = [:]

    func remember(_ view: MultiExecView, _ rec: JSON, window: FleetWindow?) {
        let done = finished.removeValue(forKey: view.id) ?? MultiExecService.shared.view(view.id).flatMap { $0.running ? nil : $0 }
        if let done { write(done, rec, window) } else { waiting[view.id] = (rec, window) }
    }

    func finish(_ view: MultiExecView) {
        guard let (rec, w) = waiting.removeValue(forKey: view.id) else { finished[view.id] = view; return }
        write(view, rec, w)
    }

    private func write(_ view: MultiExecView, _ recIn: JSON, _ w: FleetWindow?) {
        let ok = view.results.filter { $0.status == "done" }.count
        var rec = recIn
        let unreachable = Int(rec["unreachable"].double ?? 0)
        rec.removeKey("unreachable")
        rec["ok"] = .number(Double(ok))
        // The ones that never connected count as failures too — "it ran on four
        // of six" is the honest number, not "four of four".
        rec["failed"] = .number(Double(view.results.count - ok + unreachable))
        FleetStore.addExecRun(rec)
        for win in WindowManager.shared.windows { win.feature(FleetWindow.self).historyRevision += 1 }
        _ = w
    }
}

import UniformTypeIdentifiers

enum FleetFiles {
    static var yamlTypes: [UTType] {
        [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
    }
}
