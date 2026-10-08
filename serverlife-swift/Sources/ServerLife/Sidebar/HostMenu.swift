import AppKit
import SwiftUI

/// The host list's right-click menus (sidebar.js `onHostContextMenu`,
/// `openGroupMenu`, `openFolderMenu`, `folderMenuFor`, the three-level
/// submenus, the local shell's, the tab strip's requests menu).
@MainActor
enum SBMenus {
    static let check = "\u{2713}"

    // MARK: Host

    /// A host's own menu, wherever it is drawn. `groupKey` is the group it was
    /// clicked in; `folder` the folder, when it was clicked inside one.
    static func hostMenu(_ host: Host, groupKey: String? = nil, folder: HostFolder? = nil, window: WindowModel?) -> [CtxItem] {
        let w = window
        if host.isRequestableRow {
            var items: [CtxItem] = [
                .heading(host.name),
                CtxItem("Requestable since \(HostWatch.goneFor(host.requestableSince ?? nowMs())) ago", disabled: true),
                CtxItem("Request access to it…", icon: "\u{2691}", title: "Starts a request with this node already chosen") {
                    SBActions.requestAccessFor(host, window: w)
                },
            ]
            if let uuid = host.uuid {
                items.append(CtxItem("Copy its node id") { Clipboard.write(uuid); SBActions.status("Copied " + uuid) })
            }
            if let wk = host.watchKey {
                items += [.sep, CtxItem("Stop watching it", icon: "\u{2326}") {
                    HostWatch.forget(wk); SBActions.status("Forgot \(host.name)")
                }]
            }
            return items
        }
        if host.watchMissing || host.watchUnconfirmed {
            var items: [CtxItem] = [
                .heading(host.name),
                CtxItem(host.watchMissing
                        ? "Gone \(HostWatch.goneFor(host.watchMissingSince ?? 0)) — last seen \(HostWatch.goneFor(host.watchLastSeen ?? 0)) ago"
                        : "Not checked — last confirmed \(HostWatch.goneFor(host.watchLastSeen ?? 0)) ago", disabled: true),
            ]
            if let uuid = host.uuid {
                items.append(CtxItem("Copy its node id") { Clipboard.write(uuid); SBActions.status("Copied " + uuid) })
            }
            items += [.sep, CtxItem("Stop watching and forget it", icon: "\u{2326}", title: "Removes the row and the record kept of it") {
                HostWatch.forget(host.watchKey ?? FolderModel.hostKey(host))
                SBActions.status("Forgot \(host.name)")
            }]
            return items
        }

        let logins = HostPrefs.loginOptions(host)
        let preferred = HostPrefs.preferredLogin(host)
        let inTmux = HostPrefs.opensInTmux(host)
        let mfa = HostPrefs.isMfaHost(host.id)
        let canSplit = w.map { $0.feature(SessionsWindow.self).activePane != nil } ?? false
        let sw = w?.feature(SidebarWindow.self)
        let isTp = host.type == Host.teleport

        var items: [CtxItem] = [
            CtxItem(preferred.map { "Open session as \($0)" } ?? "Open session", icon: "\u{25B8}", sub: inTmux ? "in tmux" : nil) {
                SBActions.open(host, window: w)
            },
            CtxItem(inTmux ? "Open without tmux" : "Open in tmux\u{2026}", icon: inTmux ? "\u{25B8}" : "\u{267B}",
                    disabled: !inTmux && mfa,
                    title: mfa && !inTmux ? "Not on a host that asks for MFA per session"
                        : inTmux ? "A plain session on this host, just this once" : "Keeps running on the server when this window goes away") {
                let who = preferred ?? logins.first
                if inTmux {
                    if mfa && isTp { SBActions.openMfa(host, login: who, window: w); return }
                    SBActions.status("Connecting to \(SBActions.label(host))…")
                    var args: [String: Any] = ["noTmux": true]
                    if let who { args["login"] = who }
                    Actions.shared.perform("open-host", window: w, host: host, args: args)
                    return
                }
                var args: [String: Any] = [:]
                if let who { args["login"] = who }
                Actions.shared.perform("tmux-open", window: w, host: host, args: args)
            },
        ]
        if canSplit {
            items += [
                CtxItem("Open beside current (split right)", icon: "\u{216E}") { SBActions.splitWith(host, login: logins.first, dir: "right", window: w) },
                CtxItem("Open below current (split down)", icon: "\u{2017}") { SBActions.splitWith(host, login: logins.first, dir: "down", window: w) },
            ]
        }
        var other: [CtxItem] = []
        if logins.count > 1 {
            other += [CtxItem("As another user…") {
                Task { if let who = await SBDialogs.pickLogin(logins, host: host, window: w) { SBActions.open(host, login: who, window: w) } }
            }, .sep]
        }
        other += [.heading("Files without a terminal"),
                  CtxItem("In a new tab") { SBActions.openFilesOnly(host, login: preferred, window: w) }]
        if canSplit {
            other += [CtxItem("Split right") { SBActions.openFilesOnly(host, login: preferred, dir: "right", window: w) },
                      CtxItem("Split down") { SBActions.openFilesOnly(host, login: preferred, dir: "down", window: w) }]
        }
        items.append(CtxItem("Other ways to open", icon: "\u{22EF}", submenu: other))
        items.append(.sep)

        let pu = HostPrefs.preferredUser(host)
        items.append(CtxItem(pu.isEmpty ? "Preferred username…" : "Preferred username: \(pu)…", icon: "\u{263A}",
                             title: "Always connect to this host as one account, whatever last worked") {
            SBDialogs.preferredUser(host, window: w)
        })
        items.append(openFilesMenu(host))
        items.append(tmuxMenu(host, window: w))
        if let fm = folderMenu(host, groupKey: groupKey, window: w) { items.append(fm) }
        items.append(.sep)

        // How the row looks, in one place.
        let icon = HostPrefs.hostIcon(host)
        let starred = HostPrefs.isStarred(host)
        let colorVal = HostPrefs.hostColorValue(host)
        var mark: [CtxItem] = [
            CtxItem(starred ? "Unstar" : "Star \u{2014} keep at the top", key: starred ? "\u{2605}" : nil) { HostPrefs.setStarred(host, !starred) },
            CtxItem(icon.isEmpty ? "Give it an icon\u{2026}" : "Icon: \(icon)") {
                Task {
                    guard let v = await MiscUI.pickIcon(w, title: "Icon for this host", subtitle: SBActions.label(host), value: icon) else { return }
                    HostPrefs.setHostIcon(host, v)
                }
            },
            .sep, .heading("Colour"),
        ]
        mark += HostColor.all.map { c in
            CtxItem(c.label, key: colorVal == c.value || (c.value.isEmpty && HostPrefs.hostColorHex(host).isEmpty) ? check : nil) {
                HostPrefs.setHostColor(host, c.value)
            }
        }
        mark += [
            .sep, .heading("Where starred hosts go"),
            CtxItem("Top of their own group", key: HostPrefs.starredMode == "inline" ? check : nil) { HostPrefs.setStarredMode("inline") },
            CtxItem("A Starred group above everything", key: HostPrefs.starredMode == "group" ? check : nil) { HostPrefs.setStarredMode("group") },
            .sep,
            CtxItem(HostPrefs.isCareful(host) ? "Stop asking before multi-exec" : "Ask before multi-exec on this host",
                    title: "A host worth a second look before a command fans out to it") { HostPrefs.setCareful(host, !HostPrefs.isCareful(host)) },
        ]
        items.append(CtxItem("Mark this host", icon: icon.nilIfEmpty ?? (starred ? "\u{2605}" : "\u{25C9}"),
                             title: "Star it, colour it, give it an icon", submenu: mark))
        let watched = HostWatch.isWatched(host)
        items.append(CtxItem(watched ? "Stop watching for its disappearance" : "Tell me if this host disappears",
                             icon: watched ? "\u{25C9}" : "\u{25CB}",
                             title: watched ? "Its last known details are kept; the row stays if it leaves the inventory"
                                : "Keeps its node id and last known details, and says so if it stops being listed") {
            HostWatch.toggleWatch(host, SB2.realGroupKey(groupKey, for: host))
        })
        items.append(.sep)
        let ticked = sw?.checkedHosts.contains(host.id) ?? false
        items.append(CtxItem(ticked ? "Unselect for multi-exec" : "Select for multi-exec", icon: ticked ? "\u{2611}" : "\u{2610}") {
            sw?.toggleChecked(host.id)
        })
        items.append(.sep)
        if isTp {
            items += [
                CtxItem("Open with MFA (tsh ssh)", icon: "\u{26BF}") { SBActions.openMfa(host, login: logins.first, window: w) },
                CtxItem(mfa ? "Forget that this needs MFA" : "Remember as an MFA server", icon: "\u{26BF}") { HostPrefs.setMfaHost(host, !mfa) },
            ]
        }
        items.append(CtxItem("Open with X11 forwarding", icon: "\u{2317}") { Task { await SBActions.openX11(host, login: logins.first, window: w) } })
        items.append(agentForwardMenu(host))
        items.append(.sep)
        items.append(CtxItem("Run a command…", icon: "\u{25B8}") { SBHostActions.openRunCommand(host, login: logins.first, window: w) })
        if isTp {
            items.append(CtxItem("Latency to this node…", icon: "\u{21C4}",
                                 title: "tsh latency ssh — round trip to the proxy and from the proxy to the node, live") {
                SBActions.openLatency(host, login: preferred, window: w)
            })
        }
        items.append(CtxItem("Port forward…", icon: "\u{21C6}") { SBHostActions.openPortForward(host, login: preferred, window: w) })
        items.append(CtxItem("Server profile…", icon: "\u{2139}") { SBHostActions.openServerInfo(host, login: preferred, window: w) })
        if isTp {
            let quietName = ["all": "shown in place", "hide": "hidden", "only": "only these"][Heartbeat.quietFilter] ?? "shown in place"
            items += [
                CtxItem("Tags (\(Tags.labelEntries(host).count))…", icon: "\u{2691}") { SBTagBrowser.openHostTags(host, window: w) },
                CtxItem(HostPrefs.showTags ? "Stop showing tags in the list" : "Show tags in the list", icon: "\u{2691}") { HostPrefs.toggleShowTags() },
                CtxItem(Heartbeat.showHeartbeats ? "Stop showing last heartbeats" : "Show last heartbeats", icon: "\u{2665}") { HostPrefs.toggleShowHeartbeats() },
                CtxItem("Quiet nodes: \(quietName)", icon: "\u{266A}", title: "Nodes that have stopped heartbeating but are still listed", submenu: [
                    CtxItem("Show them in place", key: Heartbeat.quietFilter == "all" ? check : nil) { HostPrefs.setQuietFilter("all") },
                    CtxItem("Hide them", key: Heartbeat.quietFilter == "hide" ? check : nil) { HostPrefs.setQuietFilter("hide") },
                    CtxItem("Show only these", key: Heartbeat.quietFilter == "only" ? check : nil) { HostPrefs.setQuietFilter("only") },
                ]),
                .sep,
                CtxItem("Active sessions on this host…", icon: "\u{21C4}", title: "Watch, join or moderate a session that is going on here now") {
                    Actions.shared.perform("live-sessions", window: w, args: [
                        "proxy": host.proxy ?? "", "home": host.home ?? "",
                        "match": [host.name, host.hostname ?? "", host.uuid ?? ""],
                        "title": "Active sessions on \(host.name)", "subtitle": host.cluster?.nilIfEmpty ?? host.proxy ?? "",
                    ])
                },
                CtxItem("Recorded sessions for this host…", icon: "\u{25CE}") {
                    Actions.shared.perform("recordings", window: w, host: host, args: ["filter": host.name, "proxy": host.proxy ?? ""])
                },
            ]
        }
        items.append(CtxItem("Forget host key…", icon: "\u{26BF}") {
            let name = isTp ? "\(host.name).\(host.cluster ?? "")" : (host.hostname?.nilIfEmpty ?? host.alias ?? "")
            Actions.shared.perform("forget-host-key", window: w, host: host, args: ["hostname": name])
        })
        items.append(.sep)
        let hidden = HostPrefs.isHidden(host)
        items.append(CtxItem(hidden ? "Show in list" : "Hide from list") { HostPrefs.setHidden(host, !hidden) })
        items.append(CtxItem(HostPrefs.showHiddenHosts ? "Stop showing hidden hosts" : "Show hidden hosts") { HostPrefs.toggleShowHidden() })
        items.append(.sep)
        items.append(CtxItem("Save as profile…") {
            Actions.shared.perform("new-profile", window: w, args: ["profile": SBActions.profileFromHost(host)])
        })
        if host.type == Host.ssh, let alias = host.alias, Inventory.shared.managedSshHosts.contains(alias) {
            items.append(CtxItem("Remove from ~/.ssh/config") {
                Actions.shared.perform("remove-managed-host", window: w, args: ["alias": alias])
            })
        }
        items.append(CtxItem("Copy ssh command") {
            let cmd = isTp ? "tsh ssh \(logins.first.map { $0 + "@" } ?? "")\(host.name)" : "ssh \(host.alias ?? host.name)"
            Clipboard.write(cmd)
            SBActions.status("Copied: " + cmd)
        })
        return items
    }

    // MARK: Three-level submenus

    static func agentForwardMenu(_ host: Host) -> CtxItem {
        let st = HostPrefs.agentForward(host)
        let ck = host.clusterPrefKey
        let clusterSet = HostPrefs.clusterAgentForward(ck)
        let ssh = ck == "ssh"
        return CtxItem("Agent forwarding: \(st.on ? "on" : "off")\(st.from == "host" ? "" : " (from the \(st.from))")",
                       title: "Forwarding the agent lets processes on that host use your keys while the session is open", submenu: [
            .heading("This host"),
            CtxItem("On", key: st.from == "host" && st.on ? check : nil) { HostPrefs.setAgentForward(host, true) },
            CtxItem("Off", key: st.from == "host" && !st.on ? check : nil) { HostPrefs.setAgentForward(host, false) },
            CtxItem("Follow the \(ssh ? "SSH config" : "cluster") setting", key: st.from != "host" ? check : nil) { HostPrefs.setAgentForward(host, nil) },
            .sep,
            .heading(ssh ? "Every ssh_config host" : "Every host on \(ck)"),
            CtxItem("On", key: clusterSet == true ? check : nil) { HostPrefs.setAgentForwardForCluster(ck, true) },
            CtxItem("Off", key: clusterSet == false ? check : nil) { HostPrefs.setAgentForwardForCluster(ck, false) },
            CtxItem("Follow the global preference (\(HostPrefs.globalAgentForward ? "on" : "off"))", key: clusterSet == nil ? check : nil) {
                HostPrefs.setAgentForwardForCluster(ck, nil)
            },
        ])
    }

    static func tmuxMenu(_ host: Host, window: WindowModel?) -> CtxItem {
        let st = HostPrefs.tmux(host)
        if st.from == "mfa" {
            return CtxItem("Open in tmux: not on an MFA host", icon: "\u{267B}", disabled: true,
                           title: "A node that asks for MFA per session needs tsh ssh and an approval "
                            + "each time; a session you attach to and detach from cannot work that way")
        }
        let ck = host.clusterPrefKey
        let clusterSet = HostPrefs.clusterTmux(ck)
        return CtxItem("Open in tmux: \(st.on ? "always" : "when asked")", icon: "\u{267B}",
                       title: "What runs in tmux keeps running when this window goes away", submenu: [
            .heading("This host"),
            CtxItem("Always", key: st.from == "host" && st.on ? check : nil) { HostPrefs.setTmux(host, true) },
            CtxItem("Never", key: st.from == "host" && !st.on ? check : nil) { HostPrefs.setTmux(host, false) },
            CtxItem("Follow the setting below", key: st.from != "host" ? check : nil) { HostPrefs.setTmux(host, nil) },
            .sep,
            .heading(ck == "ssh" ? "Every ssh_config host" : "Every host on \(ck)"),
            CtxItem("Always", key: clusterSet == true ? check : nil) { HostPrefs.setTmuxForCluster(ck, true) },
            CtxItem("Never", key: clusterSet == false ? check : nil) { HostPrefs.setTmuxForCluster(ck, false) },
            CtxItem("Follow the global setting (\(HostPrefs.tmuxDefault ? "always" : "when asked"))", key: clusterSet == nil ? check : nil) {
                HostPrefs.setTmuxForCluster(ck, nil)
            },
            .sep,
            .heading("Everywhere"),
            CtxItem("Open every new session in tmux", key: HostPrefs.tmuxDefault ? check : nil) { HostPrefs.setTmuxEverywhere(!HostPrefs.tmuxDefault) },
            .sep,
            CtxItem("Session name…", title: "Which tmux session to attach to on this host") {
                Task {
                    guard let name = await MiscUI.prompt(window, title: "tmux session name",
                                                         label: "What to attach to on \(SBActions.label(host))",
                                                         value: HostPrefs.tmuxName(host)) else { return }
                    HostPrefs.setTmuxName(host, name)
                }
            },
        ])
    }

    static func openFilesMenu(_ host: Host) -> CtxItem {
        let st = HostPrefs.openFiles(host)
        let ck = host.clusterPrefKey
        let clusterSet = HostPrefs.clusterOpenFiles(ck)
        let ssh = ck == "ssh"
        return CtxItem("Opens with the file browser: \(st.on ? "yes" : "no")\(st.from == "host" ? "" : " (from the \(st.from))")",
                       icon: "\u{2630}",
                       title: "Whether a new session on this host shows its files beside the terminal. ⌘E still opens it either way.", submenu: [
            .heading("This host"),
            CtxItem("Open with files", key: st.from == "host" && st.on ? check : nil) { HostPrefs.setOpenFiles(host, true) },
            CtxItem("Do not open with files", key: st.from == "host" && !st.on ? check : nil) { HostPrefs.setOpenFiles(host, false) },
            CtxItem("Follow the \(ssh ? "SSH config" : "cluster") setting", key: st.from != "host" ? check : nil) { HostPrefs.setOpenFiles(host, nil) },
            .sep,
            .heading(ssh ? "Every ssh_config host" : "Every host on \(ck)"),
            CtxItem("Open with files", key: clusterSet == true ? check : nil) { HostPrefs.setOpenFilesForCluster(ck, true) },
            CtxItem("Do not open with files", key: clusterSet == false ? check : nil) { HostPrefs.setOpenFilesForCluster(ck, false) },
            CtxItem("Follow the global preference (\(HostPrefs.globalOpenFiles ? "with" : "without"))", key: clusterSet == nil ? check : nil) {
                HostPrefs.setOpenFilesForCluster(ck, nil)
            },
        ])
    }

    // MARK: Folders

    /// Ask the hosts owner's folder dialog to make or edit a folder; `done`
    /// gets the folder (nil when cancelled).
    static func folderDialog(group: String, parent: String? = nil, folder: HostFolder? = nil, hosts: [Host],
                             window: WindowModel?, done: ((HostFolder?) -> Void)? = nil) {
        var args: [String: Any] = ["groupKey": group, "hosts": hosts]
        if let parent { args["parentId"] = parent }
        if let folder { args["folderId"] = folder.id }
        if let done { args["completion"] = done }
        Actions.shared.perform("folder-dialog", window: window, args: args)
    }

    /// "Folders: …" on a host's menu: file it, take it out, or make a folder for it.
    static func folderMenu(_ host: Host, groupKey: String?, window: WindowModel?) -> CtxItem? {
        let gk = SB2.realGroupKey(groupKey, for: host)
        if gk.isEmpty { return nil }
        let hosts = SB2.hostsInGroup(gk)
        let mine = FolderModel.foldersForHost(host, gk)
        let mineIds = Set(mine.map(\.id))
        let all = FolderModel.allFolders().filter { $0.group == gk }
        var items: [CtxItem] = [
            CtxItem("New folder with this host…", icon: "\u{1F4C1}") {
                folderDialog(group: gk, hosts: hosts, window: window) { made in
                    guard let made else { return }
                    Task { await dropHostIntoFolder(host, made, gk) }
                }
            },
        ]
        if !all.isEmpty {
            items += [.sep, .heading("File it in")]
            for f in all {
                items.append(CtxItem(FolderModel.pathLabel(f), key: mineIds.contains(f.id) ? check : nil,
                                     title: !f.rule.isEmpty && !FolderModel.isManualMember(host, f.id) ? "Matched by this folder's rule: \(f.rule)" : nil) {
                    if mineIds.contains(f.id) { FolderModel.unfileHost(host, f.id) } else { Task { await dropHostIntoFolder(host, f, gk) } }
                })
            }
        }
        if !mine.isEmpty {
            items += [.sep, CtxItem(mine.count == 1 ? "Take it out of \(mine[0].name)" : "Take it out of every folder") {
                for f in mine { FolderModel.unfileHost(host, f.id) }
                SBActions.status("\(SBActions.label(host)) is loose again")
            }]
        }
        return CtxItem(mine.isEmpty ? "Folders: not filed" : "Folders: \(mine.map(\.name).joined(separator: ", "))", icon: "\u{1F4C2}",
                       title: "A filed host is listed inside its folder instead of loose in the group", submenu: items)
    }

    static func dropHostIntoFolder(_ host: Host, _ folder: HostFolder, _ groupKey: String) async {
        guard let r = await FolderModel.fileHostsInto([host], folder, groupKey) else { return }
        SBActions.status("\(SBActions.label(host)) \(r.mode == "move" ? "moved to" : "added to") \(folder.name)")
    }

    /// A folder row's menu.
    static func folderRowMenu(_ folder: HostFolder, groupKey: String, window: WindowModel?) -> [CtxItem] {
        let hosts = SB2.hostsInGroup(groupKey)
        let sw = window?.feature(SidebarWindow.self)
        return [
            .heading(FolderModel.pathLabel(folder)),
            CtxItem("Open this folder…", icon: "\u{229E}", title: "The big view, with everything in it") {
                Actions.shared.perform("folders-browser", window: window, args: ["groupKey": groupKey, "folderId": folder.id])
            },
            .sep,
            CtxItem("New folder inside…", icon: "\u{1F4C1}") { folderDialog(group: groupKey, parent: folder.id, hosts: hosts, window: window) },
            CtxItem(folder.rule.isEmpty ? "Edit folder…" : "Edit folder and its rule…", icon: "\u{270E}") {
                folderDialog(group: groupKey, folder: folder, hosts: hosts, window: window)
            },
            CtxItem("Open every host in it", title: "\(FolderModel.hostsInTree(folder, hosts).count) session(s)") {
                Task { await SBActions.openEveryHostIn(folder, hosts, window: window) }
            },
            .sep,
            CtxItem("Select these for multi-exec", icon: "\u{2611}") {
                for h in FolderModel.hostsInTree(folder, hosts) { sw?.checkedHosts.insert(h.id) }
            },
            .sep,
            CtxItem("Export these folders…") { Actions.shared.perform("folders-export", window: window, args: ["groupKey": groupKey]) },
            CtxItem("Delete this folder…", icon: "\u{2326}") {
                Task {
                    let kids = FolderModel.allFolders().filter { $0.parent == folder.id }.count
                    let go = await MiscUI.confirm(window, title: "Delete “\(folder.name)”?",
                        message: kids > 0 ? "The folder and the \(kids) inside it go." : "The folder goes.",
                        detail: "The hosts stay exactly where they were — they live in the cluster, not in here. They go back to being listed loose.",
                        confirmLabel: "Delete")
                    if go { FolderModel.deleteFolder(folder.id); SBActions.status("Deleted “\(folder.name)”") }
                }
            },
        ]
    }

    // MARK: Group headings

    static func monitorSummary(_ p: TeleportProfile) -> (total: Int, missing: Int) {
        let mine = SB.store.settingJSON("requestMonitor").items.filter {
            ($0["proxy"].string ?? "") == p.proxy && ($0["home"].string?.nilIfEmpty) == (p.homeDir.nilIfEmpty)
        }
        return (mine.count, mine.filter { $0["missingSince"].truthy }.count)
    }

    static func groupMenu(_ g: SBGroup, sw: SidebarWindow, window: WindowModel?) -> [CtxItem] {
        let key = g.key
        let profile = g.profile
        let keys = SB2.groupKeysOnScreen(sw)
        let i = keys.firstIndex(of: key) ?? -1
        let isSsh = key == "ssh" || key.hasPrefix("ssh:")
        let clusterKey = profile.map { $0.proxy.nilIfEmpty ?? $0.cluster } ?? (isSsh ? "ssh" : "")
        let clusterSet = clusterKey.isEmpty ? nil : HostPrefs.clusterAgentForward(clusterKey)
        let clusterFiles = clusterKey.isEmpty ? nil : HostPrefs.clusterOpenFiles(clusterKey)
        let folderKey = profile != nil || isSsh ? key : ""
        let inv = Inventory.shared
        var items: [CtxItem] = [.heading(g.title)]

        if let p = profile {
            let mine = inv.requestsFor(p)
            let reqLabel: String = {
                if mine.isEmpty { return "Access requests…" }
                let s = inv.requestSummary(mine)
                return "Access requests — " + [s.pending > 0 ? "\(s.pending) waiting" : "", s.approved > 0 ? "\(s.approved) approved" : ""]
                    .filter { !$0.isEmpty }.joined(separator: ", ") + "…"
            }()
            items.append(CtxItem(reqLabel, title: "Raise one, review what is outstanding, or assume an approval") {
                Actions.shared.perform("access-requests", window: window, args: ["profileKey": p.key])
            })
            let n = monitorSummary(p)
            items.append(CtxItem(n.total == 0 ? "Monitor requestable resources…"
                                 : n.missing > 0 ? "Requestable monitor — \(n.missing) of \(n.total) missing…" : "Requestable monitor — \(n.total) watched…",
                                 title: "Confirm on a timer that the resources you expect to be able to request are still offered") {
                Actions.shared.perform("request-monitor-add", window: window, args: ["profileKey": p.key])
            })
            let showing = HostPrefs.showRequestable(key)
            items.append(CtxItem(showing ? "Hide requestable nodes" : "Show requestable nodes too", icon: "\u{2691}",
                                 title: showing ? "List only what you can reach on this cluster"
                                    : "Also list what this cluster would let you ask for, tagged req — double-click one to request it") {
                if !showing { SBRequestableCache.shared.forget(key) }
                HostPrefs.setShowRequestable(key, !showing)
            })
            items += ClusterMarks.menu(p, window: window)
            items.append(CtxItem("Status (tsh status)…", title: "Roles, logins, expiry and the certificate extensions, as tsh prints them") {
                Actions.shared.perform("tsh-status", window: window, args: ["profileKey": p.key])
            })
            items.append(CtxItem("Refresh this cluster", title: "Its nodes, the clusters it trusts and its beams — nothing else") {
                SBActions.refreshProfile(p)
            })
        }
        if isSsh {
            items.append(CtxItem("Re-read the config files", icon: "\u{21BB}") { SBActions.refreshSshConfigs(key) })
            items.append(CtxItem("SSH config files…", icon: "\u{2630}", title: "Read hosts from more than one config file") {
                SBDialogs.sshConfigFiles(window: window)
            })
        }
        if !clusterKey.isEmpty {
            let g = HostPrefs.globalAgentForward ? "on" : "off"
            items.append(CtxItem("Agent forwarding: \(clusterSet == nil ? "follows the global preference (\(g))" : (clusterSet! ? "on" : "off"))",
                                 title: "Applies to every host in this group that has no setting of its own", submenu: [
                CtxItem("On", key: clusterSet == true ? check : nil) { HostPrefs.setAgentForwardForCluster(clusterKey, true) },
                CtxItem("Off", key: clusterSet == false ? check : nil) { HostPrefs.setAgentForwardForCluster(clusterKey, false) },
                CtxItem("Follow the global preference (\(g))", key: clusterSet == nil ? check : nil) { HostPrefs.setAgentForwardForCluster(clusterKey, nil) },
            ]))
            let gf = HostPrefs.globalOpenFiles ? "yes" : "no"
            items.append(CtxItem("Opens with the file browser: \(clusterFiles == nil ? "follows the global preference (\(gf))" : (clusterFiles! ? "yes" : "no"))",
                                 title: "Applies to every host in this group that has no setting of its own", submenu: [
                CtxItem("Open with files", key: clusterFiles == true ? check : nil) { HostPrefs.setOpenFilesForCluster(clusterKey, true) },
                CtxItem("Do not open with files", key: clusterFiles == false ? check : nil) { HostPrefs.setOpenFilesForCluster(clusterKey, false) },
                CtxItem("Follow the global preference (\(gf))", key: clusterFiles == nil ? check : nil) { HostPrefs.setOpenFilesForCluster(clusterKey, nil) },
            ]))
        }
        if !folderKey.isEmpty {
            items.append(.sep)
            items.append(CtxItem("Open this list in a pane", icon: "\u{25A6}",
                                 title: "The hosts of this group, with room: folders on or off, rows or tiles", submenu: [
                CtxItem("In a new tab") { Actions.shared.perform("hosts-pane", window: window, args: ["groupKey": folderKey]) },
                CtxItem("Beside this pane") { Actions.shared.perform("hosts-pane", window: window, args: ["groupKey": folderKey, "split": "right"]) },
                CtxItem("Below this pane") { Actions.shared.perform("hosts-pane", window: window, args: ["groupKey": folderKey, "split": "down"]) },
            ]))
            let n = FolderModel.allFolders().filter { $0.group == folderKey }.count
            items.append(CtxItem(FolderModel.groupHasFolders(folderKey) ? "Folders (\(n))" : "Folders", icon: "\u{1F4C2}", submenu: [
                CtxItem("New folder…", icon: "\u{1F4C1}") { folderDialog(group: folderKey, hosts: SB2.hostsInGroup(folderKey), window: window) },
                CtxItem("Open the folder browser…", icon: "\u{229E}", title: "The big view: a tree on the left, what is in it on the right") {
                    Actions.shared.perform("folders-browser", window: window, args: ["groupKey": folderKey])
                },
                .sep,
                CtxItem(FolderModel.showFiledHosts ? "Stop listing filed hosts at the top" : "Also list filed hosts at the top",
                        title: "A host that has been filed is normally listed inside its folder and nowhere else") {
                    FolderModel.setShowFiledHosts(!FolderModel.showFiledHosts)
                },
                .sep,
                CtxItem("Export these folders…") { Actions.shared.perform("folders-export", window: window, args: ["groupKey": folderKey]) },
                CtxItem("Import folders…") {
                    Actions.shared.perform("folders-import", window: window)
                },
            ]))
        }
        if profile != nil || isSsh { items.append(.sep) }

        if let p = profile {
            if p.expired {
                items.append(CtxItem("Log in…", icon: "\u{2192}") { SBActions.relogin(p, window: window) })
            } else {
                items.append(CtxItem("Log out of this cluster…", icon: "\u{2190}") {
                    Actions.shared.perform("tsh-logout", window: window, args: ["profileKey": p.key])
                })
            }
            items.append(CtxItem("Copy login cmd", icon: "\u{29C9}") { SBActions.copyLoginCommand(p) })
            if !p.expired {
                items.append(CtxItem("Active sessions\u{2026}", icon: "\u{21C4}",
                                     title: "Who is in what right now \u{2014} and watch, join or moderate the SSH and Kubernetes ones") {
                    Actions.shared.perform("live-sessions", window: window, args: [
                        "profileKey": p.key, "proxy": p.proxy, "home": p.homeDir, "subtitle": p.cluster.nilIfEmpty ?? p.proxy,
                    ])
                })
                items.append(CtxItem(p.active ? "Active profile" : "Make this the active profile",
                                     key: p.active ? check : nil, icon: "\u{25C9}", disabled: p.active,
                                     title: p.active ? "Plain tsh commands already use this cluster"
                                        : "Runs this cluster’s login again, which is what makes it the active one. "
                                            + "No re-authentication while the certificate is still valid.") {
                    Actions.shared.perform("tsh-make-active", window: window, args: ["profileKey": p.key])
                })
            }
            if let w = window, let item = SidebarHooks.clusterSwitchMenuItem?(p, w) { items.append(item) }
            let supported = inv.beamsSupported(p.proxy)
            let marked = inv.markedAsBeams(p.proxy)
            items.append(CtxItem(supported ? (marked ? "Stop marking this as a beams cluster" : "Beams: listed") : "Mark this as a beams cluster",
                                 disabled: supported && !marked,
                                 title: supported ? "Beams from this cluster are listed in their own group"
                                    : "The cluster did not answer tsh beams ls — list them anyway") {
                Task { await inv.setMarkedAsBeams(p.proxy, !marked) }
            })
            let hiddenBeams = SB.store.settingJSON("hiddenBeamProxies").stringArray.contains(p.proxy)
            if hiddenBeams {
                items.append(CtxItem("Show beams for this cluster") { Task { await inv.showBeamsFor(p.proxy) } })
            }
            if supported {
                items.append(CtxItem("Start a beam…", icon: "\u{2197}") {
                    Actions.shared.perform("beam-start", window: window, args: ["profileKey": p.key])
                })
                items.append(CtxItem("Refresh the beam list", icon: "\u{21BB}") { Task { await inv.refreshBeams(refresh: true) } })
                if !hiddenBeams { items.append(CtxItem("Hide beams for this cluster") { inv.hideBeamsFor(p.proxy) }) }
            }
            items.append(CtxItem("Add to ~/.ssh/config…", title: "tsh config for this cluster, so ssh, scp, rsync and Ansible reach its nodes") {
                Actions.shared.perform("tsh-config", window: window, args: ["profileKey": p.key])
            })
            items.append(CtxItem("Open in web UI") {
                do { _ = try Teleport.openWebCluster(proxy: p.proxy, cluster: p.cluster) } catch { SBActions.toast(error.localizedDescription, .error) }
            })
            items.append(.sep)
        }
        let mode = HostPrefs.starredMode
        items.append(CtxItem("Starred hosts: \(mode == "group" ? "in their own group" : "at the top of their group")", submenu: [
            CtxItem("At the top of their own group", key: mode == "inline" ? check : nil) { HostPrefs.setStarredMode("inline") },
            CtxItem("Gathered in a Starred group", key: mode == "group" ? check : nil) { HostPrefs.setStarredMode("group") },
        ]))
        if HostPrefs.hasHostOrder(key) {
            items.append(CtxItem("Reset the host order in this group", title: "Back to starred first, then the natural order") {
                HostPrefs.saveHostOrder(key, [])
            })
        }
        items += [
            .sep,
            CtxItem("Move up", disabled: i <= 0) { nudgeGroup(key, -1, sw) },
            CtxItem("Move down", disabled: i < 0 || i >= keys.count - 1) { nudgeGroup(key, 1, sw) },
            CtxItem("Move to top", disabled: i <= 0) { placeGroup(key, before: keys.first { $0 != key }, sw) },
            CtxItem("Move to bottom", disabled: i < 0 || i >= keys.count - 1) { placeGroup(key, before: nil, sw) },
            .sep,
            CtxItem("Reset order", disabled: HostPrefs.groupOrder.isEmpty) { HostPrefs.saveGroupOrder([]) },
        ]
        return items
    }

    /// Move a group so it sits where `before` is (or last).
    static func placeGroup(_ key: String, before: String?, _ sw: SidebarWindow) {
        var keys = SB2.groupKeysOnScreen(sw).filter { $0 != key }
        let at = before.flatMap { keys.firstIndex(of: $0) } ?? keys.count
        keys.insert(key, at: at)
        HostPrefs.saveGroupOrder(keys)
    }

    static func nudgeGroup(_ key: String, _ delta: Int, _ sw: SidebarWindow) {
        var keys = SB2.groupKeysOnScreen(sw)
        guard let from = keys.firstIndex(of: key) else { return }
        let to = from + delta
        guard to >= 0, to < keys.count else { return }
        keys.insert(keys.remove(at: from), at: to)
        HostPrefs.saveGroupOrder(keys)
    }

    // MARK: This machine

    static func shellLabel(_ sh: ShellInfo, _ all: [ShellInfo]) -> String {
        all.filter { $0.name == sh.name }.count > 1 ? "\(sh.name)  (\((sh.path as NSString).deletingLastPathComponent))" : sh.name
    }

    static func localShellMenu(window: WindowModel?) -> [CtxItem] {
        let shells = LocalShells.shared.shells()
        let openWith: (ShellInfo, Bool) -> Void = { sh, blank in
            Actions.shared.perform("open-local", window: window, args: ["shell": sh.path, "blank": blank,
                                                                         "title": "\(sh.name)\(blank ? " (blank)" : "")"])
        }
        var items: [CtxItem] = [CtxItem("Open local shell") { Actions.shared.perform("open-local", window: window) }]
        if !shells.isEmpty {
            items.append(CtxItem("Open another shell", title: "The shells installed on this machine", submenu: shells.map { sh in
                CtxItem(shellLabel(sh, shells), sub: sh.note.nilIfEmpty, title: sh.path) { openWith(sh, false) }
            }))
            items.append(CtxItem("Open with a blank configuration",
                                 title: "No profile, no rc file — what a script sees, and a way in when an rc file is broken",
                                 submenu: shells.filter(\.canBlank).map { sh in
                CtxItem(shellLabel(sh, shells), sub: sh.note.nilIfEmpty, title: "\(sh.path) with its startup files skipped") { openWith(sh, true) }
            }))
        }
        items.append(CtxItem("Open in tmux…", icon: "\u{267B}",
                             title: "A tmux session on this machine — what runs in it keeps running when this window closes") {
            Actions.shared.perform("tmux-open", window: window, host: Host.localMachine)
        })
        items += [
            .sep,
            CtxItem("Open beside current (split right)") { Actions.shared.perform("open-local", window: window, args: ["split": "right"]) },
            CtxItem("Open below current (split down)") { Actions.shared.perform("open-local", window: window, args: ["split": "down"]) },
            .sep,
            CtxItem("Show local files in this pane") {
                guard let w = window, w.feature(SessionsWindow.self).activePane != nil else { SBActions.toast("Open a session first", .error); return }
                Actions.shared.perform("local-files", window: w, args: ["show": true])
            },
        ]
        return items
    }
}
