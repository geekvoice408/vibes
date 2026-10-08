import SwiftUI

// Shared building blocks, so every dialog and panel looks like one app.
// The CSS classes they stand in for are noted on each.

/// `.ghost-btn`: the quiet bordered button used everywhere.
struct GhostButtonStyle: ButtonStyle {
    var small = false
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration, small: small, prominent: prominent, destructive: destructive)
    }
    private struct GhostBody: View {
        let configuration: ButtonStyle.Configuration
        let small: Bool, prominent: Bool, destructive: Bool
        @Environment(\.isEnabled) private var enabled
        @StateObject private var hover = LocalFlag()
        var body: some View {
            let p = Theme.shared.p
            let fg: Color = prominent ? .white : destructive ? p.red : p.text
            let bg: Color = prominent ? (destructive ? p.red : p.accent)
                : (hover.on ? p.panel3 : p.panel2)
            configuration.label
                .font(.system(size: small ? 11 : 12))
                .padding(.horizontal, small ? 7 : 10)
                .padding(.vertical, small ? 2 : 4)
                .foregroundStyle(fg)
                .background(RoundedRectangle(cornerRadius: 5).fill(bg.opacity(configuration.isPressed ? 0.8 : 1)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(prominent ? Color.clear : p.border))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover.on = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// `.icon-btn`: a borderless glyph button with a hover wash.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 22
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, active: active)
    }
    private struct IconBody: View {
        let configuration: ButtonStyle.Configuration
        let size: CGFloat, active: Bool
        @Environment(\.isEnabled) private var enabled
        @StateObject private var hover = LocalFlag()
        var body: some View {
            let p = Theme.shared.p
            configuration.label
                .font(.system(size: 12))
                .frame(minWidth: size, minHeight: size)
                .foregroundStyle(active ? p.accent : (hover.on ? p.text : p.textDim))
                .background(RoundedRectangle(cornerRadius: 4).fill(hover.on || active ? p.panel3 : .clear))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover.on = $0 }
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
    static var ghostSmall: GhostButtonStyle { GhostButtonStyle(small: true) }
    static var primary: GhostButtonStyle { GhostButtonStyle(prominent: true) }
    static var danger: GhostButtonStyle { GhostButtonStyle(prominent: true, destructive: true) }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

/// `.badge`: a small rounded count or tag.
struct Badge: View {
    let text: String
    var color: Color? = nil
    var filled = false
    var body: some View {
        let p = Theme.shared.p
        let c = color ?? p.textDim
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(filled ? Color.white : c)
            .background(Capsule().fill(filled ? c : c.opacity(0.14)))
    }
}

/// A `key = value` label chip (tags under a host row).
struct Chip: View {
    let text: String
    var active = false
    var action: (() -> Void)? = nil
    var body: some View {
        let p = Theme.shared.p
        let label = Text(text)
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(active ? p.accent : p.textDim)
            .background(RoundedRectangle(cornerRadius: 3).fill(active ? p.accent.opacity(0.15) : p.panel3))
        if let action { Button(action: action) { label }.buttonStyle(.plain) } else { label }
    }
}

/// A search/filter field with a clear button (`input[type=search]`).
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(p.muted)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}

/// A section heading in a list or dialog (`.section-title`).
struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        let p = Theme.shared.p
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(p.muted)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
    }
}

/// The frame of every dialog: title, scrollable body, button row.
/// (`modal()` in ui.js: `.modal-head`, `.modal-body`, `.modal-foot`.)
struct DialogScaffold<Body: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat? = nil
    var scroll = true
    @ViewBuilder var content: () -> Body
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(p.textDim) }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            p.border.frame(height: 1)
            Group {
                if scroll {
                    ScrollView { content().padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    content().padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            p.border.frame(height: 1)
            HStack(spacing: 8) { footer() }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: width)
        .background(p.panel)
    }
}

/// A labelled form row: label on the left, control on the right.
struct FormRow<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(p.textDim).frame(width: 130, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                content()
                if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A monospaced, selectable block of command output.
struct OutputBlock: View {
    let text: String
    var maxHeight: CGFloat? = 300
    var body: some View {
        let p = Theme.shared.p
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: maxHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}

/// The eight host colours as swatches (`HOST_COLORS`).
struct ColorSwatchPicker: View {
    @Binding var selection: String
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 6) {
            ForEach(HostColor.all) { c in
                Button { selection = c.value } label: {
                    ZStack {
                        Circle().fill(c.color ?? p.panel3).frame(width: 18, height: 18)
                        if c.value.isEmpty { Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(p.muted) }
                    }
                    .overlay(Circle().stroke(selection == c.value ? p.text : .clear, lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .help(c.label)
            }
        }
    }
}

/// The emoji grid (`ICON_CHOICES`) plus a field that takes anything pasted.
struct EmojiPicker: View {
    @Binding var selection: String
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 10), spacing: 4) {
                ForEach(iconChoices, id: \.self) { e in
                    Button { selection = e } label: {
                        Text(e).font(.system(size: 17)).frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 4).fill(selection == e ? p.accent.opacity(0.25) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("or paste one", text: Binding(get: { selection },
                                                        set: { selection = String($0.prefix(8)) }))
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                Button("None") { selection = "" }.buttonStyle(.ghostSmall)
            }
        }
    }
}

extension View {
    /// Pointer feedback for clickable non-button views.
    func pointerHand() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
