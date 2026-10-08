import SwiftUI

// Small pieces the S3 dialogs share.

@MainActor
enum S3Dialog {
    /// A sheet that answers once: `done(value)` closes it with a value, and
    /// closing it any other way (Escape, Cancel) answers nil.
    static func ask<T, V: View>(_ owner: WindowModel?, title: String, width: CGFloat, height: CGFloat? = nil,
                                resizable: Bool = false,
                                @ViewBuilder content: @escaping (_ done: @escaping (T?) -> Void) -> V) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            var answered = false
            var handle: ModalHandle?
            let finish: (T?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
                handle?.close()
            }
            let h = Modal.sheet(owner, title: title, width: width, height: height, resizable: resizable) { _ in
                content(finish)
            }
            handle = h
            h.onClose.append { finish(nil) }
        }
    }
}

/// A labelled field the way ui.js `field(label, input, hint)` drew it.
struct S3Field<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.textDim)
            content()
            if let hint { S3Hint(text: hint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
    }
}

struct S3Hint: View {
    let text: String
    var color: Color? = nil
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color ?? Theme.shared.p.muted)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `select(options, value)`.
struct S3Select: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in Text(o.label).tag(o.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }
}

/// `.tag`: a small outlined label.
struct S3Tag: View {
    let text: String
    var body: some View {
        let p = Theme.shared.p
        Text(text)
            .font(.system(size: 10.5))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(p.textDim)
            .background(RoundedRectangle(cornerRadius: 4).fill(p.panel3))
    }
}

extension StatusBus {
    /// ui.js `toast(text, 'success')`.
    func s3Ok(_ text: String) { toast(text, kind: .ok) }
    /// ui.js `toast(text, 'error')`.
    func s3Error(_ text: String) { toast(text, kind: .error) }
}

/// The text of any error, the way the original showed `e.message`.
func s3Message(_ error: Error) -> String {
    (error as? AppError)?.message ?? error.localizedDescription
}
