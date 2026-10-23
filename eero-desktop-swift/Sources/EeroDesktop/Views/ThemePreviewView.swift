#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Development-only page with sample controls for visual inspection in both appearances
/// (port of `ThemePreviewPage`, reachable with `--theme-preview`). It makes no network requests.
@MainActor
struct ThemePreviewView: View {
    @ObservedObject var model: AppModel

    private struct SampleRow: Identifiable { let id = UUID(); let name: String; let status: String }
    private let rows = [SampleRow(name: "Selected device", status: "Online"), SampleRow(name: "Alternating row", status: "Offline")]

    @ViewState private var networkName = "Sample network name"
    @ViewState private var password = "sample-password"
    @ViewState private var mode = "Automatic"
    @ViewState private var enabledOption = true
    @ViewState private var selection: UUID?
    @ViewState private var sheet: Sheet?

    private enum Sheet: String, Identifiable { case form, backup, credentials; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Subtitle("Sample controls for visual inspection. This screen does not make network requests.")
            Card {
                SectionHeader("Fields & choices")
                TextField("Network name", text: $networkName).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                Picker("Mode", selection: $mode) {
                    ForEach(["Automatic", "Manual", "Bridge"], id: \.self) { Text($0).tag($0) }
                    Text("Unavailable option").tag("Unavailable option").disabled(true)
                }
                .labelsHidden()
                HStack(spacing: 24) {
                    Toggle("Enabled option", isOn: $enabledOption)
                    Toggle("Disabled option", isOn: .constant(true)).disabled(true)
                }
                .padding(.vertical, 5)
                Table(rows, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Status", value: \.status)
                }
                .frame(height: 144)
                .onAppear { if selection == nil { selection = rows.first?.id } }
            }
            HStack {
                Button("Open sample settings form") { sheet = .form }
                Button("Open sample confirmation") {
                    Task { _ = await model.confirm("This sample confirmation performs no network change.") }
                }
            }
            .padding(.bottom, 8)
            HStack {
                Button("Open sample backup priority") { sheet = .backup }
                Button("Open sample credential display") { sheet = .credentials }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .form: SampleFormSheet()
            case .backup: SampleBackupPrioritySheet()
            case .credentials: SampleCredentialsSheet()
            }
        }
    }
}

/// "Sample settings" editor: every field kind with nothing saved.
private struct SampleFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = "Sample network"
    @ViewState private var secret = ""
    @ViewState private var mode = "Automatic"
    @ViewState private var enabled = true
    @ViewState private var note = "Sample text"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sample settings").font(.system(size: 22, weight: .semibold))
            Text("Network name").font(.system(size: 13, weight: .semibold))
            TextField("", text: $name).textFieldStyle(.roundedBorder)
            Text("Password").font(.system(size: 13, weight: .semibold))
            SecureField("", text: $secret).textFieldStyle(.roundedBorder)
            Text("Connection mode").font(.system(size: 13, weight: .semibold))
            Picker("Connection mode", selection: $mode) {
                ForEach(["Automatic", "Manual", "Bridge"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            Toggle("Enable sample option", isOn: $enabled)
            Text("Notes").font(.system(size: 13, weight: .semibold))
            TextEditor(text: $note).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.edge))
            Caption("Preview controls only; no settings are saved.")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Close sample") { dismiss() }.buttonStyle(.accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

/// Sample backup-network priority list with reordering.
private struct SampleBackupPrioritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var items = ["Sample phone hotspot", "Sample backup wifi"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backup priority").font(.system(size: 22, weight: .semibold))
            Caption("Drag to reorder. The first network is tried first.")
            List {
                ForEach(items, id: \.self) { Text($0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 140)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save order") { dismiss() }.buttonStyle(.accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
    }
}

/// Sample credential display with copy buttons.
private struct SampleCredentialsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let values = [("Sample username", "sample-user"), ("Sample password", "sample-password")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sample credentials").font(.system(size: 22, weight: .semibold))
            ForEach(values.indices, id: \.self) { i in
                let pair = values[i]
                HStack {
                    DetailRow(name: pair.0, value: pair.1)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pair.1, forType: .string)
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(28)
        .frame(width: 460)
    }
}
#endif
