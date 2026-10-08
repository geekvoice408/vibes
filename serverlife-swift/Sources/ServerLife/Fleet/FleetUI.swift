import AppKit
import SwiftUI

// Small view pieces the dock and Fleet's dialogs share (the `.tag`,
// `.sb-empty`, `.sb-subhead`, `.xfer-row` looks of styles.css).

@MainActor
enum FleetDialog {
    /// A modal sheet that answers with a value (nil when cancelled or closed).
    static func ask<R, V: View>(_ owner: WindowModel?, title: String = "", width: CGFloat = 520, height: CGFloat? = nil,
                                resizable: Bool = false, autosave: String? = nil,
                                @ViewBuilder content: @escaping (_ done: @escaping (R?) -> Void) -> V) async -> R? {
        await withCheckedContinuation { (cont: CheckedContinuation<R?, Never>) in
            var answered = false
            var handle: ModalHandle?
            let finish: (R?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
                handle?.close()
            }
            let h = Modal.sheet(owner, title: title, width: width, height: height, resizable: resizable, autosave: autosave) { _ in
                content(finish)
            }
            handle = h
            h.onClose.append { finish(nil) }
        }
    }
}

/// `.tag`: a small rounded label.
struct FleetTag: View {
    let text: String
    var color: Color? = nil
    var mono = false
    var body: some View {
        let p = Theme.shared.p
        Text(text)
            .font(.system(size: 10, weight: .medium, design: mono ? .monospaced : .default))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color ?? p.textDim)
            .background(RoundedRectangle(cornerRadius: 3).fill(p.panel3))
    }
}

/// `.sb-empty`: a muted note where a list would be, with an optional second line.
struct FleetEmpty: View {
    let text: String
    var detail: String? = nil
    var detailView: AnyView? = nil
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
            if let detail { Text(detail).opacity(0.75) }
            if let detailView { detailView.opacity(0.75) }
        }
        .font(.system(size: 12))
        .foregroundStyle(p.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.sb-subhead`: a small uppercase heading with a count.
struct FleetSubhead<Trailing: View>: View {
    let title: String
    var count: Int = 0
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).kerning(0.8)
            if count > 0 { Text("\(count)").font(.system(size: 9.5)).opacity(0.65) }
            Spacer()
            trailing()
        }
        .foregroundStyle(p.muted)
        .padding(.top, 6).padding(.bottom, 2)
    }
}

extension FleetSubhead where Trailing == EmptyView {
    init(title: String, count: Int = 0) { self.init(title: title, count: count) { EmptyView() } }
}

/// The row of the transfers / tunnels / runs lists (`.xfer-row`).
struct FleetRow<Content: View>: View {
    var padding: CGFloat = 6
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        HStack(alignment: .center, spacing: 9) { content() }
            .font(.system(size: 12))
            .padding(.vertical, padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
    }
}

/// `.xlabel`: a main line and a dim monospaced second line.
struct FleetLabel: View {
    let main: String
    var sub: String = ""
    var mainMono = false
    var mainColor: Color? = nil
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 1) {
            Text(main)
                .font(mainMono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(mainColor ?? p.text)
                .lineLimit(1).truncationMode(.tail)
            if !sub.isEmpty {
                Text(sub).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A plain text field with the app's input look.
struct FleetField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var onSubmit: () -> Void = {}
    var body: some View {
        let p = Theme.shared.p
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
            .onSubmit(onSubmit)
            .autocorrectionDisabled()
    }
}

/// ui.js `select`: a menu of labelled values.
struct FleetPicker: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { o in
                Text(o.label).tag(o.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .font(.system(size: 12))
    }
}

/// A multi-line monospaced editor with a placeholder.
struct FleetTextArea: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 90
    var body: some View {
        let p = Theme.shared.p
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(4)
            if text.isEmpty {
                Text(placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted)
                    .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}

/// The `.mx-tab` segmented buttons.
struct FleetTabs: View {
    let tabs: [(id: String, label: String)]
    @Binding var selection: String
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 4) {
            ForEach(tabs, id: \.id) { t in
                let on = selection == t.id
                Button { selection = t.id } label: {
                    Text(t.label).font(.system(size: 11.5))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .foregroundStyle(on ? Color.white : p.muted)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? p.accentDim : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? p.accentDim : p.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
