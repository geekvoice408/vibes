import AppKit
import SwiftUI

// Small building blocks shared by the network tools and the keys dialog —
// the nt-* and req-* classes of styles.css.

/// Wrapping row of chips (`display:flex; flex-wrap:wrap`).
struct NTFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, width)
            if x > 0 && x + w > width { y += line + lineSpacing; x = 0; line = 0 }
            x += w + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: s.height))
            x += w + spacing
            line = max(line, s.height)
        }
    }
}

/// `.nt-badge` (`name`, `ok`, `warn`, `ver`, `ed`).
struct NTBadge: View {
    let text: String
    var kind = ""
    var body: some View {
        let p = Theme.shared.p
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(kind == "name" ? Color.white : kind == "ok" ? p.green : kind == "warn" ? p.amber : p.textDim)
            .background(RoundedRectangle(cornerRadius: 3).fill(kind == "name" ? p.accentDim : p.panel3))
            .textSelection(.enabled)
    }
}

/// `.nt-group-head` / `.nt-sub`.
struct NTHead: View {
    let text: String
    var top: CGFloat = 0
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).kerning(0.5)
            .foregroundStyle(Theme.shared.p.muted)
            .padding(.top, top).padding(.bottom, 5)
    }
}

/// `.nt-cmd`: the command, small and muted.
struct NTCmd: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.shared.p.muted)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
    }
}

/// `.nt-pre`: output as printed.
struct NTPre: View {
    let text: String
    var color: Color? = nil
    var boxed = false
    var mono = true
    var body: some View {
        let p = Theme.shared.p
        Text(text.isEmpty ? " " : text)
            .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
            .foregroundStyle(color ?? p.textDim)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(boxed ? 8 : 0)
            .background(boxed ? RoundedRectangle(cornerRadius: 5).fill(p.panel2) : nil)
            .overlay(boxed ? RoundedRectangle(cornerRadius: 5).stroke(p.border) : nil)
    }
}

/// `.hint`.
struct NTHint: View {
    let text: String
    var color: Color? = nil
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color ?? Theme.shared.p.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// `.sb-empty`: a centred quiet message.
struct NTEmpty: View {
    let text: String
    var color: Color? = nil
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color ?? Theme.shared.p.muted)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 18)
            .textSelection(.enabled)
    }
}

/// `.nt-kv`: label/value grid; empty values are left out.
struct NTKV: View {
    let rows: [(String, String?)]
    var keyWidth: CGFloat = 168
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                if let v = r.1, !v.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(r.0).font(.system(size: 12)).foregroundStyle(p.muted).frame(width: keyWidth, alignment: .leading)
                        Text(v).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// The same as text, for Copy output.
    static func text(_ rows: [(String, String?)]) -> String {
        rows.compactMap { r in r.1.flatMap { $0.isEmpty ? nil : "\(r.0)\t\($0)" } }.joined(separator: "\n")
    }
}

/// `section(title, rows)`: a titled KV block, absent when nothing is set.
struct NTSection: View {
    let title: String
    let rows: [(String, String?)]
    var body: some View {
        if rows.contains(where: { !($0.1 ?? "").isEmpty }) {
            VStack(alignment: .leading, spacing: 0) {
                NTHead(text: title)
                NTKV(rows: rows)
            }
            .padding(.bottom, 13)
        }
    }
}

/// A `<details>`: a disclosure with its body boxed.
struct NTDetails<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @StateObject private var open = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 5) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open.on ? 90 : 0))
                    Text(title).font(.system(size: 11))
                }
                .foregroundStyle(p.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.on { content() }
        }
        .padding(.top, 6)
    }
}

/// A labelled option (`smallField`).
struct NTField<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(p.muted)
            content()
            if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(p.muted.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A bordered text box in the app's style.
struct NTTextBox: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    var secure = false
    var mono = false
    var onSubmit: () -> Void = {}
    var focus: FocusState<Bool>.Binding? = nil
    @ViewBuilder private var field: some View {
        if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
    }
    var body: some View {
        let p = Theme.shared.p
        Group {
            if let focus { field.focused(focus) } else { field }
        }
        .textFieldStyle(.plain)
        .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
        .onSubmit(onSubmit)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
        .frame(width: width)
    }
}

/// A multi-line monospaced editor (`.nt-ta`) with a placeholder.
struct NTTextArea: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 54
    var body: some View {
        let p = Theme.shared.p
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled(true)
                .padding(4)
            if text.isEmpty {
                Text(placeholder).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.muted)
                    .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}

/// A select box: a menu of labelled values.
struct NTSelect: View {
    let options: [(value: String, label: String)]
    @Binding var value: String
    var width: CGFloat? = nil
    var body: some View {
        Picker("", selection: $value) {
            ForEach(options, id: \.value) { o in Text(o.label).tag(o.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: width)
    }
}

/// Questions asked over a particular window (a panel rather than the main
/// window, which `Modal.prompt` would attach to).
@MainActor
enum NTAsk {
    static func prompt(_ win: NSWindow?, title: String, label: String = "", value: String = "", ok: String = "OK",
                       secure: Bool = false, placeholder: String = "") async -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = label
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let field: NSTextField = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                                        : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        a.accessoryView = field
        a.window.initialFirstResponder = field
        return await run(a, win) == 0 ? field.stringValue : nil
    }

    static func confirm(_ win: NSWindow?, title: String, message: String, ok: String, danger: Bool = false) async -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = danger ? .critical : .informational
        let b = a.addButton(withTitle: ok)
        if danger { b.hasDestructiveAction = true }
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return await run(a, win) == 0
    }

    static func run(_ a: NSAlert, _ win: NSWindow?) async -> Int {
        let base = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if let win, win.isVisible {
            var w = win
            while let s = w.attachedSheet { w = s }
            return await withCheckedContinuation { c in a.beginSheetModal(for: w) { c.resume(returning: $0.rawValue - base) } }
        }
        return a.runModal().rawValue - base
    }

    /// Ask where, then write. Returns the path written.
    static func saveText(_ win: NSWindow?, _ text: String, defaultName: String) async -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = defaultName
        p.canCreateDirectories = true
        p.showsHiddenFiles = true
        p.title = "Save output"
        let ok: Bool
        if let win, win.isVisible {
            ok = await withCheckedContinuation { c in p.beginSheetModal(for: win) { c.resume(returning: $0 == .OK) } }
        } else {
            ok = p.runModal() == .OK
        }
        guard ok, let url = p.url else { return nil }
        do {
            try Data(text.utf8).write(to: url)
            return url
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
            return nil
        }
    }
}
