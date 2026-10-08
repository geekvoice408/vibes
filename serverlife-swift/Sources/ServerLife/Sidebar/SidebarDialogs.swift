import AppKit
import SwiftUI

/// A sheet that answers: `ask` resolves with what the content passed to
/// `finish`, or nil when the sheet was closed any other way.
@MainActor
enum SBModal {
    static func ask<T>(_ window: WindowModel?, width: CGFloat = 520, title: String = "",
                       @ViewBuilder content: @escaping (_ finish: @escaping (T?) -> Void) -> some View) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            var answered = false
            var handle: ModalHandle?
            let finish: (T?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
                handle?.close()
            }
            handle = Modal.sheet(window, title: title, width: width) { _ in content(finish) }
            handle?.onClose.append { finish(nil) }
        }
    }
}

/// `.picker-item` rows.
struct SBPickerRow<Trailing: View>: View {
    let title: String
    var active = false
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? p.accentDim.opacity(0.5) : (hover.on ? p.panel3 : p.panel2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

@MainActor
enum SBDialogs {
    // MARK: Open as user

    /// `pickLogin`: one of the cluster's logins, or any name typed in.
    static func pickLogin(_ logins: [String], host: Host, title: String = "Open as user", subtitle: String? = nil,
                          note: String? = nil, window: WindowModel?) async -> String? {
        let current = HostPrefs.preferredLogin(host)
        return await SBModal.ask(window, width: 440) { finish in
            PickLoginView(logins: logins, current: current, title: title,
                          subtitle: subtitle ?? HostPrefs.label(host), note: note, finish: finish)
        }
    }

    // MARK: Preferred username

    static func preferredUser(_ host: Host, window: WindowModel?) {
        let options = HostPrefs.loginOptions(host)
        let current = HostPrefs.preferredUser(host)
        Task {
            guard let res: String = await SBModal.ask(window, width: 480, content: { finish in
                PreferredUserView(host: host, options: options, current: current, finish: finish)
            }) else { return }
            HostPrefs.setPreferredUser(host, res)
        }
    }

    // MARK: SSH config files

    static func sshConfigFiles(window: WindowModel?) {
        Modal.sheet(window, title: "SSH config files", width: 540) { handle in
            SSHConfigFilesView(window: window) { handle.close() }
        }
    }
}

private struct PickLoginView: View {
    let logins: [String]
    let current: String?
    let title: String
    let subtitle: String
    let note: String?
    let finish: (String?) -> Void
    @StateObject private var other = Local("")
    @FocusState private var focused: Bool

    var body: some View {
        DialogScaffold(title: title, subtitle: subtitle, width: 440) {
            VStack(alignment: .leading, spacing: 6) {
                if let note { MiscHint(text: note, size: 11.5).padding(.bottom, 3) }
                ForEach(logins, id: \.self) { l in
                    SBPickerRow(title: l, active: l == current) {
                        if l == current { SBTag(text: "default") }
                    } action: { finish(l) }
                }
                MiscField(label: logins.isEmpty ? "User name" : "Or a name that is not listed") {
                    TextField("another user name", text: $other.value)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { let v = other.value.trimmed; if !v.isEmpty { finish(v) } }
                        .focused($focused)
                        .onAppear { if logins.isEmpty { DispatchQueue.main.async { focused = true } } }
                }
                .padding(.top, 4)
                MiscHint(text: "The one that connects is remembered for this host.")
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Use this name") { let v = other.value.trimmed; if !v.isEmpty { finish(v) } }.buttonStyle(.primary)
        }
    }
}

private struct PreferredUserView: View {
    let host: Host
    let options: [String]
    let current: String
    let finish: (String?) -> Void
    @StateObject private var value: Local<String>

    init(host: Host, options: [String], current: String, finish: @escaping (String?) -> Void) {
        self.host = host; self.options = options; self.current = current; self.finish = finish
        _value = StateObject(wrappedValue: Local(current))
    }

    private var note: String {
        let v = value.value.trimmed
        if v.isEmpty { return "Nothing set: sessions use the last login that worked, or \(options.first ?? "the cluster default")." }
        if !options.isEmpty && !options.contains(v) {
            return "\(v) is not one of the logins this cluster grants (\(options.joined(separator: ", "))). It will still be used — "
                + "the cluster decides whether it is allowed."
        }
        return "Every session on this host will connect as \(v)."
    }

    var body: some View {
        DialogScaffold(title: "Preferred username", subtitle: HostPrefs.label(host), width: 480) {
            VStack(alignment: .leading, spacing: 8) {
                MiscField(label: "Connect as") {
                    TextField(options.first ?? "ubuntu", text: $value.value)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { finish(value.value.trimmed) }
                    if !options.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(options, id: \.self) { o in
                                SBChip(key: nil, value: o, on: value.value.trimmed == o, size: 11) { value.value = o }
                            }
                        }
                    }
                }
                MiscHint(text: note, size: 11.5)
                MiscHint(text: host.type == Host.teleport
                         ? "Stored against this node's uuid (\(String((host.uuid ?? "").prefix(8)))…), so renaming the host keeps it."
                         : "Stored against this ssh_config entry.", size: 11.5)
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            if !current.isEmpty { Button("Clear") { finish("") }.buttonStyle(GhostButtonStyle(destructive: true)) }
            Button("Save") { finish(value.value.trimmed) }.buttonStyle(.primary)
        }
    }
}

private struct SSHConfigFilesView: View {
    let window: WindowModel?
    let close: () -> Void

    var body: some View {
        let p = Theme.shared.p
        let inv = Inventory.shared
        DialogScaffold(title: "SSH config files", subtitle: "Extra files to read hosts from", width: 540) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SB2.configRoots(), id: \.self) { r in
                    let count = SB2.sshHosts(of: r, inv.sshHosts).count
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.label).font(.system(size: 12.5))
                            Text(r.file).font(.system(size: 11, design: .monospaced)).opacity(0.7).textSelection(.enabled)
                            Text(!r.exists ? "not there" : "\(count) host\(count == 1 ? "" : "s")").font(.system(size: 11)).opacity(0.75)
                        }
                        Spacer()
                        if r.primary {
                            SBTag(text: "primary", help: "Always read; this is what plain ssh reads too")
                        } else {
                            Button("Remove") {
                                let keep = SB.store.settingJSON("sshConfigFiles").stringArray.filter { $0 != r.file }
                                SB.store.updateSettings(["sshConfigFiles": JSON(keep)])
                                SBActions.refreshSshConfigs()
                            }
                            .buttonStyle(GhostButtonStyle(small: true, destructive: true))
                            .help("Stop reading this file. The file itself is not touched.")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                }
                (Text("Hosts from an extra file are opened with ") + Text("ssh -F <file>").font(.system(size: 11, design: .monospaced))
                    + Text(" — that file\u{2019}s options and defaults are what apply, and ~/.ssh/config is not read for them."))
                    .font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 5)
                HStack(spacing: 6) {
                    Button("Add a file…") {
                        Task {
                            guard let picked = await SSHConfig.pickConfigFile(window: window) else { return }
                            let have = SB.store.settingJSON("sshConfigFiles").stringArray
                            if have.contains(picked) { SBActions.toast("That file is already listed", .error); return }
                            SB.store.updateSettings(["sshConfigFiles": JSON(have + [picked])])
                            SBActions.refreshSshConfigs()
                        }
                    }
                    .buttonStyle(GhostButtonStyle(small: true, prominent: true))
                    Button("Refresh") { SBActions.refreshSshConfigs() }.buttonStyle(.ghostSmall)
                }
                .padding(.top, 6)
            }
        } footer: {
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }
}
