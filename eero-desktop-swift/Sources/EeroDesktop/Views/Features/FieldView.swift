#if os(macOS)
import SwiftUI
import EeroCore

/// Port of the `Field` class used by the Windows `Edit` dialog.
struct Field: Identifiable {
    enum Kind: String { case text, password, bool, choice, multiline, long, link }

    let key: String
    let label: String
    let value: JSON
    let kind: Kind
    let choices: [String]
    /// Optional inline validation, run before the dialog's save action.
    var validate: ((String) throws -> Void)?

    var id: String { key + "\u{1F}" + label }

    init(_ key: String, _ label: String, _ value: JSONConvertible? = nil, _ kind: Kind = .text, _ choices: String...) {
        self.init(key, label, value, kind, choices: choices)
    }

    init(_ key: String, _ label: String, _ value: JSONConvertible?, _ kind: Kind, choices: [String]) {
        self.key = key; self.label = label; self.value = value?.json ?? .null; self.kind = kind; self.choices = choices
    }

    /// Adds inline validation; the thrown error's message is shown under the field.
    func validated(_ check: @escaping (String) throws -> Void) -> Field {
        var f = self; f.validate = check; return f
    }

    /// Maximum input length used by the WPF text boxes.
    var maxLength: Int {
        switch kind {
        case .multiline, .long: return 4096
        case .password: return 512
        default: return 254
        }
    }

    /// The initial selection for a choice field (the value when it is a choice, otherwise the first choice).
    var initialChoice: String {
        let v = value.string
        return choices.contains(v) ? v : (choices.first ?? "")
    }
}

/// Values entered in an `Edit` dialog (`V` / `Flag` in the Windows client).
struct FieldValues {
    let values: [String: JSON]
    /// Asks for confirmation inside the dialog (the WPF `Confirm` message box).
    let confirm: @MainActor (String) async -> Bool

    /// Port of `V`.
    func v(_ key: String) -> String { values[key]?.string ?? "" }
    subscript(_ key: String) -> String { v(key) }
    /// Port of `Flag`.
    func flag(_ key: String) -> Bool { v(key).caseInsensitiveCompare("True") == .orderedSame }
}

/// An `Edit` dialog request.
struct EditForm: Identifiable {
    let id = UUID()
    let title: String
    let fields: [Field]
    var submit = "Save"
    var description: String?
    let save: @MainActor (FieldValues) async throws -> Void
}

extension AppModel {
    /// Port of `Edit(title, fields, save, submit, description)`: shows a form dialog that stays open until `save` succeeds.
    func edit(_ title: String, _ fields: [Field], submit: String = "Save", description: String? = nil,
              save: @escaping @MainActor (FieldValues) async throws -> Void) {
        FeatureDialogs.shared.show(.edit(EditForm(title: title, fields: fields, submit: submit, description: description, save: save)))
    }
}

/// A single form field (text, secure, toggle, picker, multi-line or link) with its validation message.
struct FieldView: View {
    let field: Field
    @Binding var text: String
    @Binding var flag: Bool
    var error: String? = nil
    var openLink: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.kind {
            case .link:
                Button(field.label) { openLink(field.value.string) }
            case .bool:
                Toggle(isOn: $flag) { Text(field.label).fixedSize(horizontal: false, vertical: true) }
                    .toggleStyle(.checkbox)
            case .choice:
                Text(field.label).font(.system(size: 13, weight: .semibold))
                Picker(field.label, selection: $text) {
                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            case .password:
                Text(field.label).font(.system(size: 13, weight: .semibold))
                SecureField("", text: $text).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(field.label)
            case .multiline:
                Text(field.label).font(.system(size: 13, weight: .semibold))
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)))
                    .accessibilityLabel(field.label)
            case .text, .long:
                Text(field.label).font(.system(size: 13, weight: .semibold))
                TextField("", text: $text).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(field.label)
            }
            if let error, !error.isEmpty {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
        .onChange(of: text) { _, new in
            if field.kind != .choice && new.count > field.maxLength { text = String(new.prefix(field.maxLength)) }
        }
    }
}

/// Confirmation request shown inside an `EditSheet`; resolves exactly once.
@MainActor
final class SheetConfirmation: Identifiable {
    let id = UUID()
    let message: String
    private var resume: ((Bool) -> Void)?
    init(_ message: String, _ resume: @escaping (Bool) -> Void) { self.message = message; self.resume = resume }
    func resolve(_ value: Bool) { let r = resume; resume = nil; r?(value) }
}

/// Port of the `Edit` dialog window.
struct EditSheet: View {
    let form: EditForm
    @ObservedObject var model: AppModel
    let close: () -> Void

    @ViewState private var text: [String: String]
    @ViewState private var flags: [String: Bool]
    @ViewState private var errors: [String: String] = [:]
    @ViewState private var status = ""
    @ViewState private var working = false
    @ViewState private var confirmation: SheetConfirmation?

    init(form: EditForm, model: AppModel, close: @escaping () -> Void) {
        self.form = form; self.model = model; self.close = close
        var t: [String: String] = [:], f: [String: Bool] = [:]
        for field in form.fields {
            switch field.kind {
            case .bool: if case .bool(let b) = field.value { f[field.key] = b } else { f[field.key] = false }
            case .choice: t[field.key] = field.initialChoice
            case .password: t[field.key] = ""
            case .link: break
            default: t[field.key] = field.value.string
            }
        }
        _text = ViewState(wrappedValue: t); _flags = ViewState(wrappedValue: f)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(form.title).font(.system(size: 24, weight: .semibold))
                    if let d = form.description { Text(d).font(.system(size: 13)).foregroundStyle(.secondary) }
                    ForEach(form.fields) { field in
                        FieldView(field: field, text: textBinding(field.key), flag: flagBinding(field.key), error: errors[field.key]) { url in
                            model.runLocal { try model.official(url) }
                        }
                        .disabled(working)
                    }
                    if !status.isEmpty {
                        Text(status).font(.system(size: 13)).foregroundStyle(working ? Color.secondary : Color.red)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { if !working { clear(); close() } }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(form.submit) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
            .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 300, idealHeight: 560)
        .interactiveDismissDisabled(working)
        .alert("Confirm", isPresented: Binding(
            get: { confirmation != nil },
            set: { shown in if !shown, let c = confirmation { confirmation = nil; c.resolve(false) } }
        ), presenting: confirmation) { c in
            Button("Yes") { confirmation = nil; c.resolve(true) }
            Button("No", role: .cancel) { confirmation = nil; c.resolve(false) }
        } message: { c in
            Text(c.message)
        }
        .onDisappear { clear(); confirmation?.resolve(false) }
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { text[key] ?? "" }, set: { text[key] = $0 })
    }
    private func flagBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { flags[key] ?? false }, set: { flags[key] = $0 })
    }

    /// Secrets are cleared when the dialog closes (WPF `PasswordBox.Clear`).
    private func clear() {
        for f in form.fields where f.kind == .password { text[f.key] = "" }
    }

    private func values() -> [String: JSON] {
        var out: [String: JSON] = [:]
        for f in form.fields {
            switch f.kind {
            case .link: continue
            case .bool: out[f.key] = .bool(flags[f.key] ?? false)
            default: out[f.key] = .string(text[f.key] ?? "")
            }
        }
        return out
    }

    private func ask(_ message: String) async -> Bool {
        await withCheckedContinuation { c in
            confirmation = SheetConfirmation(message) { c.resume(returning: $0) }
        }
    }

    private func commit() {
        if working { return }
        var found: [String: String] = [:]
        for f in form.fields {
            guard let check = f.validate else { continue }
            do { try check(text[f.key] ?? "") } catch { found[f.key] = userMessage(error) }
        }
        errors = found
        if !found.isEmpty { status = "Check the highlighted fields."; return }
        working = true
        status = "Saving…"
        let input = FieldValues(values: values(), confirm: { message in await ask(message) })
        Task { @MainActor in
            do {
                try await form.save(input)
                working = false
                status = ""
                clear()
                close()
            } catch let e as ApiError where e.sessionExpired {
                status = e.message
                working = false
                close()
                await model.api.forget()
                model.clearData()
                model.screen = .login(verify: false)
                model.setNotice("Your session expired. Sign in again.", error: true)
            } catch {
                status = userMessage(error)
                working = false
            }
        }
    }
}
#endif
