import AppKit
import SwiftUI

/// Choose a host from the whole inventory (hostactions.js `pickHost`, and the
/// sidebar's "Run on which host?"). Searchable, because an inventory is not a
/// list you point at.
@MainActor
enum FleetHostPicker {
    static func pick(_ window: WindowModel?, title: String = "Choose a host", visibleOnly: Bool = false) async -> Host? {
        var all = FleetHooks.allHosts
        if visibleOnly {
            let showHidden = Store.shared.settingJSON("showHiddenHosts").bool == true
            all = all.filter { showHidden || !FleetHooks.hidden($0) }
        }
        if all.isEmpty { StatusBus.shared.toast("No hosts available", kind: .error); return nil }
        let hosts = all
        return await FleetDialog.ask(window, title: title, width: 480) { done in
            PickerView(title: title, all: hosts, done: done)
        }
    }

    private struct PickerView: View {
        let title: String
        let all: [Host]
        let done: (Host?) -> Void
        @StateObject private var q = Local("")

        var body: some View {
            let p = Theme.shared.p
            let query = q.value.trimmed.lowercased()
            let matched = query.isEmpty ? all : all.filter {
                "\($0.name) \($0.alias ?? "") \($0.hostname ?? "") \($0.cluster ?? "")".lowercased().contains(query)
            }
            let shown = Array(matched.prefix(300))
            DialogScaffold(title: title, subtitle: "\(all.count) host\(all.count == 1 ? "" : "s") in the list", scroll: false) {
                VStack(alignment: .leading, spacing: 8) {
                    MiscField(label: "Host") {
                        FleetField(placeholder: "Search hosts\u{2026}", text: $q.value) { if let f = shown.first { done(f) } }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if shown.isEmpty { FleetEmpty(text: "No matches.") }
                            ForEach(shown, id: \.id) { h in
                                Button { done(h) } label: {
                                    HStack {
                                        Text(h.name.nilIfEmpty ?? h.alias ?? h.id).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        FleetTag(text: h.isTeleport ? (h.cluster?.nilIfEmpty ?? "tsh") : "ssh")
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(FleetHoverRowStyle())
                            }
                        }
                    }
                    .frame(height: 300)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    MiscHint(text: "\(shown.count) shown\(shown.count < all.count ? " of \(all.count)" : "")")
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            }
            .frame(height: 470)
        }
    }
}

/// A list row that lights up under the pointer.
struct FleetHoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }
    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @StateObject private var hover = LocalFlag()
        var body: some View {
            let p = Theme.shared.p
            configuration.label
                .foregroundStyle(p.text)
                .background(hover.on ? p.panel3 : Color.clear)
                .onHover { hover.on = $0 }
        }
    }
}
