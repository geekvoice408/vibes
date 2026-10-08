import AppKit
import SwiftUI

/**
 * The Tunnels panel: favourites — the tunnels that are the same three or four
 * every day — above the forwards open now.
 *
 * A forward dies with its session, and re-typing `5432 → 10.0.4.12:5432` from
 * memory is how you end up pointing a client at the wrong replica. A favourite
 * keeps the whole shape, including which host to dial it on, and opens it in
 * one click — dialling the host first if it is not already up.
 */
struct DockTunnelsPanel: View {
    let window: WindowModel

    static func kindLabel(_ k: String) -> String { ["L": "Local", "R": "Remote", "D": "Dynamic"][k] ?? k }

    static func describeForward(_ f: Forward) -> String {
        if f.kind == "D" { return "SOCKS5 proxy on \(f.bindAddr.nilIfEmpty ?? "localhost"):\(f.bindPort)" }
        if f.kind == "L" { return "\(f.bindAddr.nilIfEmpty ?? "localhost"):\(f.bindPort)  \u{2192}  \(f.destHost ?? ""):\(f.destPort.map(String.init) ?? "")" }
        return "server:\(f.bindPort)  \u{2192}  \(f.destHost ?? ""):\(f.destPort.map(String.init) ?? "")"
    }

    static func describeFav(_ f: JSON) -> String {
        let addr = f["bindAddr"].stringish?.nilIfEmpty ?? "localhost"
        let port = f["bindPort"].int ?? 0
        let dest = "\(f["destHost"].stringish ?? ""):\(f["destPort"].int ?? 0)"
        switch f["kind"].string {
        case "D": return "SOCKS5 on \(addr):\(port)"
        case "L": return "\(addr):\(port)  \u{2192}  \(dest)"
        default: return "server:\(port)  \u{2192}  \(dest)"
        }
    }

    var body: some View {
        let p = Theme.shared.p
        let cm = ConnectionManager.shared
        let all = cm.allForwards()
        let favs = FleetStore.forwardFavorites()
        VStack(alignment: .leading, spacing: 0) {
            FleetSubhead(title: "favourites", count: favs.count) {
                Button("+ New\u{2026}") { Task { @MainActor in await FavoriteEditor.open(nil, window: window) } }
                    .buttonStyle(.ghostSmall).help("Keep a tunnel shape without opening it now")
            }
            if favs.isEmpty {
                FleetEmpty(text: "No favourites yet.",
                           detail: "Star an open tunnel below, tick \u{201C}Keep this as a favourite\u{201D} when you create one, or add one here.")
            }
            ForEach(favs.indices, id: \.self) { i in
                let f = favs[i]
                let openHere = all.contains { x in
                    x.kind == f["kind"].string && x.bindPort == f["bindPort"].int
                        && cm.connection(x.connId)?.hostId == f["host"]["id"].string
                }
                let name = f["name"].stringish ?? ""
                FleetRow {
                    FleetTag(text: Self.kindLabel(f["kind"].string ?? "L"))
                    FleetLabel(main: name.nilIfEmpty ?? Self.describeFav(f),
                               sub: (name.isEmpty ? "" : Self.describeFav(f) + "  \u{00B7}  ") + (f["host"]["name"].stringish ?? "")
                                   + (f["login"].truthy ? "  as " + (f["login"].stringish ?? "") : ""))
                    if openHere {
                        FleetTag(text: "open").help("This tunnel is already up")
                    } else {
                        Button("Open") { FavoriteEditor.openFavorite(f, window: window) }.buttonStyle(GhostButtonStyle(small: true, prominent: true))
                    }
                    Button("Edit") { Task { @MainActor in await FavoriteEditor.open(f, window: window) } }.buttonStyle(.ghostSmall)
                    Button("\u{00D7}") { if let id = f["id"].string { FleetStore.deleteForwardFavorite(id) } }
                        .buttonStyle(.icon).help("Remove this favourite")
                }
            }

            FleetSubhead(title: "open now", count: all.count).padding(.top, 10)
            if all.isEmpty {
                FleetEmpty(text: "No tunnels open.", detail: "Right-click a host in the sidebar and choose \u{201C}Port forward\u{2026}\u{201D}.")
            }
            ForEach(all, id: \.id) { f in
                let conn = cm.connection(f.connId)
                let starred = favs.contains { x in
                    x["kind"].string == f.kind && x["bindPort"].int == f.bindPort && x["host"]["id"].string == conn?.hostId
                }
                FleetRow {
                    FleetTag(text: Self.kindLabel(f.kind))
                    FleetLabel(main: Self.describeForward(f), sub: FleetDock.connLabel(f.connId) ?? f.connLabel, mainMono: true)
                        .foregroundStyle(p.text)
                    /*
                     * Star it from here: the moment you know a tunnel is worth
                     * keeping is usually after it is up and something has actually
                     * connected through it, not while typing the ports in.
                     */
                    Button(starred ? "\u{2605}" : "\u{2606}") { star(f, conn) }
                        .buttonStyle(.ghostSmall).help("Keep this as a favourite")
                    if f.kind != "R" {
                        Button("Copy") {
                            let addr = "\(f.bindAddr.nilIfEmpty ?? "localhost"):\(f.bindPort)"
                            Clipboard.write(addr)
                            StatusBus.shared.show("Copied " + addr)
                        }
                        .buttonStyle(.ghostSmall).help("Copy the local address")
                    }
                    Button("Close") {
                        Task { @MainActor in
                            do {
                                try await cm.removeForward(f.connId, f.id)
                                StatusBus.shared.show("Tunnel closed")
                            } catch { StatusBus.shared.toast((error as? AppError)?.message ?? error.localizedDescription, kind: .error) }
                        }
                    }
                    .buttonStyle(GhostButtonStyle(small: true, destructive: true))
                }
            }
        }
    }

    private func star(_ f: Forward, _ conn: Connection?) {
        guard let hid = conn?.hostId, let host = FleetHooks.hostById(hid) else {
            StatusBus.shared.toast("That host is no longer in the list, so there is nothing to reopen it on", kind: .error)
            return
        }
        do {
            try FavoriteEditor.save(host: host, kind: f.kind, bindPort: f.bindPort, bindAddr: f.bindAddr,
                                    destHost: f.destHost ?? "", destPort: f.destPort ?? 0, login: conn?.login, name: "")
            StatusBus.shared.show("Kept as a favourite")
        } catch {
            StatusBus.shared.toast((error as? AppError)?.message ?? error.localizedDescription, kind: .error)
        }
    }
}

@MainActor
enum FavoriteEditor {
    /**
     * What a favourite has to remember about its host. Kept whole rather than
     * as an id, because a favourite outlives the inventory it was made from.
     * Only the fields a connection needs (hostactions.js `favoriteHostRef`).
     */
    static func hostRef(_ h: Host) -> JSON {
        [
            "id": .string(h.id), "type": .string(h.type.nilIfEmpty ?? "ssh"),
            "name": .string(h.name.nilIfEmpty ?? h.alias ?? ""), "alias": JSON(h.alias), "hostname": JSON(h.hostname),
            "uuid": JSON(h.uuid), "cluster": JSON(h.cluster), "proxy": JSON(h.proxy), "home": JSON(h.home),
            "direct": h.direct.map { JSON.encode($0) } ?? .null, "configFile": JSON(h.configFile),
        ]
    }

    /// Star a forward: this shape, on this host, worth having again tomorrow.
    static func save(host: Host, kind: String, bindPort: Int, bindAddr: String, destHost: String, destPort: Int,
                     login: String?, name: String) throws {
        try FleetStore.addForwardFavorite([
            "name": .string(name), "kind": .string(kind), "bindPort": .number(Double(bindPort)),
            "bindAddr": .string(bindAddr), "destHost": .string(destHost), "destPort": .number(Double(destPort)),
            "host": hostRef(host), "login": JSON(login?.nilIfEmpty),
        ])
    }

    /// Open a favourite: the sidebar's `forward-favorite-open` when it is
    /// there; else dial its host if needed, then put the tunnel back up.
    static func openFavorite(_ fav: JSON, window: WindowModel?) {
        if Actions.shared.isRegistered("forward-favorite-open") {
            Actions.shared.perform("forward-favorite-open", window: window, args: ["favorite": fav])
            return
        }
        Task { @MainActor in
            StatusBus.shared.show("Opening tunnel\u{2026}", seconds: 0)
            defer { StatusBus.shared.clear() }
            do {
                let host = Host(json: fav["host"])
                let id = try await FleetConn.ensure(host, login: fav["login"].stringish?.nilIfEmpty)
                let kind = fav["kind"].string ?? "L"
                _ = try await ConnectionManager.shared.addForward(id, ForwardSpec(
                    kind: kind, bindAddr: fav["bindAddr"].stringish?.nilIfEmpty, bindPort: fav["bindPort"].int ?? 0,
                    destHost: fav["destHost"].stringish?.nilIfEmpty, destPort: fav["destPort"].int.flatMap { $0 == 0 ? nil : $0 }))
                if let fid = fav["id"].string { FleetStore.markForwardFavoriteUsed(fid) }
                StatusBus.shared.toast("Tunnel open \u{2014} " + DockTunnelsPanel.describeFav(fav).replacingOccurrences(of: "  \u{2192}  ", with: " \u{2192} "), kind: .ok)
                window?.showDock("forwards")
            } catch {
                StatusBus.shared.toast((error as? AppError)?.message ?? error.localizedDescription, kind: .error)
            }
        }
    }

    /// Create or edit a favourite without opening anything.
    static func open(_ existing: JSON?, window: WindowModel?) async {
        let res: JSON? = await FleetDialog.ask(window, title: existing == nil ? "New favourite tunnel" : "Edit favourite", width: 540) { done in
            Form(existing: existing, window: window, done: done)
        }
        guard let res else { return }
        do {
            // Editing keeps the row it was; a new one upserts on host, port and
            // type, so saying the same thing twice does not leave two rows.
            if let id = existing?["id"].string { FleetStore.updateForwardFavorite(id, res) }
            else { try FleetStore.addForwardFavorite(res) }
            let name = res["name"].stringish ?? ""
            StatusBus.shared.show(name.isEmpty ? "Favourite saved" : "Saved \u{201C}\(name)\u{201D}")
        } catch {
            StatusBus.shared.toast((error as? AppError)?.message ?? error.localizedDescription, kind: .error)
        }
    }

    static let kinds: [(value: String, label: String)] = [
        ("L", "Local  (-L)  \u{2014} a port here reaches a remote service"),
        ("R", "Remote (-R)  \u{2014} a port on the server reaches a local service"),
        ("D", "Dynamic (-D) \u{2014} SOCKS5 proxy through the server"),
    ]

    private struct Form: View {
        let existing: JSON?
        let window: WindowModel?
        let done: (JSON?) -> Void
        @StateObject private var host: Local<JSON>
        @StateObject private var name: Local<String>
        @StateObject private var kind: Local<String>
        @StateObject private var bindPort: Local<String>
        @StateObject private var bindAddr: Local<String>
        @StateObject private var destHost: Local<String>
        @StateObject private var destPort: Local<String>
        @StateObject private var login: Local<String>

        init(existing: JSON?, window: WindowModel?, done: @escaping (JSON?) -> Void) {
            self.existing = existing; self.window = window; self.done = done
            let e = existing ?? [:]
            _host = StateObject(wrappedValue: Local(e["host"]))
            _name = StateObject(wrappedValue: Local(e["name"].stringish ?? ""))
            _kind = StateObject(wrappedValue: Local(e["kind"].string ?? "L"))
            _bindPort = StateObject(wrappedValue: Local(String(e["bindPort"].int.flatMap { $0 == 0 ? nil : $0 } ?? 8080)))
            _bindAddr = StateObject(wrappedValue: Local(e["bindAddr"].stringish ?? ""))
            _destHost = StateObject(wrappedValue: Local(e["destHost"].stringish?.nilIfEmpty ?? "localhost"))
            _destPort = StateObject(wrappedValue: Local(String(e["destPort"].int.flatMap { $0 == 0 ? nil : $0 } ?? 80)))
            _login = StateObject(wrappedValue: Local(e["login"].stringish ?? ""))
        }

        var body: some View {
            let h = host.value
            DialogScaffold(title: existing == nil ? "New favourite tunnel" : "Edit favourite",
                           subtitle: "Kept until you remove it; opens on the host below") {
                VStack(alignment: .leading, spacing: 0) {
                    MiscField(label: "Name (optional)") { FleetField(placeholder: "Database on the replica", text: $name.value) }
                    MiscField(label: "Host") {
                        HStack(spacing: 8) {
                            Button("Choose a host\u{2026}") {
                                // The sidebar's `pickHost` when it is there.
                                if Actions.shared.isRegistered("choose-host") {
                                    let done: (Host?) -> Void = { picked in
                                        if let picked { host.value = FavoriteEditor.hostRef(picked) }
                                    }
                                    Actions.shared.perform("choose-host", window: window, args: ["completion": done])
                                    return
                                }
                                Task { @MainActor in
                                    if let picked = await FleetHostPicker.pick(window) { host.value = FavoriteEditor.hostRef(picked) }
                                }
                            }
                            .buttonStyle(.ghostSmall)
                            MiscHint(text: h.object != nil
                                     ? "\(h["name"].stringish ?? "")\(h["cluster"].truthy ? "  \u{00B7}  " + (h["cluster"].stringish ?? "") : "")"
                                     : "No host chosen yet.")
                        }
                    }
                    MiscField(label: "Type") { FleetPicker(options: FavoriteEditor.kinds, selection: $kind.value) }
                    HStack(alignment: .top, spacing: 10) {
                        MiscField(label: "Listen port") { FleetField(placeholder: "", text: $bindPort.value) }
                        MiscField(label: "Listen address (optional)") { FleetField(placeholder: "localhost (default)", text: $bindAddr.value) }
                    }
                    if kind.value != "D" {
                        HStack(alignment: .top, spacing: 10) {
                            MiscField(label: "Destination host") { FleetField(placeholder: "localhost", text: $destHost.value) }
                            MiscField(label: "Destination port") { FleetField(placeholder: "", text: $destPort.value) }
                        }
                    }
                    MiscField(label: "Connect as (optional)") { FleetField(placeholder: "whatever the host normally uses", text: $login.value) }
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }

        private func save() {
            guard host.value.object != nil else { StatusBus.shared.toast("Choose a host for this tunnel", kind: .error); return }
            guard let port = Int(bindPort.value.trimmed), port >= 1, port <= 65535 else {
                StatusBus.shared.toast("Enter a valid listen port", kind: .error); return
            }
            let dp = Int(destPort.value.trimmed) ?? 0
            if kind.value != "D" && (destHost.value.trimmed.isEmpty || dp == 0) {
                StatusBus.shared.toast("A destination host and port are needed", kind: .error); return
            }
            done([
                "name": .string(name.value.trimmed), "kind": .string(kind.value), "bindPort": .number(Double(port)),
                "bindAddr": .string(bindAddr.value.trimmed), "destHost": .string(destHost.value.trimmed),
                "destPort": .number(Double(dp)), "host": host.value, "login": JSON(login.value.trimmed.nilIfEmpty),
            ])
        }
    }
}
