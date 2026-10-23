#if os(macOS)
import SwiftUI
import EeroCore

// Shared building blocks for every page (ports of the small helpers in App.cs / NativeLayout.cs /
// FeatureUi.cs: `Card`, `Text`, `Sub`, `Detail`, `Section`, `RouteRow`, `StatusBadge`, and the
// `AccentButton` / `QuietButton` styles). Views that use `SectionLink` or `RouteRow` need
// `AppModel` in the environment; `RootView` injects it with `.environmentObject(model)`.

/// A rounded surface with a hairline border (port of `Card`).
/// `Card { Text("Hello") }` or `Card(padding: 18) { … }`.
struct Card<Content: View>: View {
    var padding: CGFloat = 24
    @ViewBuilder var content: () -> Content

    init(padding: CGFloat = 24, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.edge, lineWidth: 1))
            .padding(.bottom, 16)
    }
}

/// Large page heading (the 30 pt title written by `PageHeading`).
struct PageTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.text)
            .padding(.bottom, 6)
    }
}

/// Card or section heading (`Text(s, 20, …, true)`).
struct SectionHeader: View {
    let text: String
    var size: CGFloat = 20
    init(_ text: String, size: CGFloat = 20) { self.text = text; self.size = size }
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(Palette.text)
    }
}

/// Muted explanatory line under the page title (port of `Sub`). It is hidden when it merely
/// repeats the last part of the current route, matching the Windows client.
struct Subtitle: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        let last = model.currentPage.split(separator: "/").last.map(String.init) ?? model.currentPage
        VStack(alignment: .leading, spacing: 0) {
            if text.caseInsensitiveCompare(last) != .orderedSame {
                Text(text).font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.bottom, 10)
    }
}

/// Small muted caption text (`Text(s, 12, "#64738A")`).
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// A labelled value (port of `Detail`): muted name, value or "Unavailable".
struct DetailRow: View {
    let name: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(value.isEmpty ? "Unavailable" : value).font(.system(size: 15)).foregroundStyle(Palette.text)
                .textSelection(.enabled)
        }
        .padding(.bottom, 8)
    }
}

/// "Title  ›" button that navigates to a route (port of `Section`).
/// `SectionLink(title:route:)` uses the environment's `AppModel`; pass `model:` to use a specific one.
struct SectionLink: View {
    @EnvironmentObject private var environmentModel: AppModel
    let title: String
    let route: String
    private let explicitModel: AppModel?

    init(title: String, route: String) { self.title = title; self.route = route; explicitModel = nil }
    init(title: String, route: String, model: AppModel) { self.title = title; self.route = route; explicitModel = model }

    var body: some View {
        Button(title + "  ›") {
            let model = explicitModel ?? environmentModel
            if !model.busy { model.navigate(route) }
        }
    }
}

/// Full-width settings row with icon, title, optional subtitle and chevron (port of `RouteRow`).
/// When `action` is nil the row navigates to `route`.
struct RouteRow: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    var subtitle: String = ""
    let route: String
    var action: (() -> Void)?

    init(title: String, subtitle: String = "", route: String, action: (() -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.route = route; self.action = action
    }

    var body: some View {
        Button {
            if model.busy { return }
            if let action { action() } else { model.navigate(route) }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: RouteIcon.symbol(for: route)).font(.system(size: 18))
                    .foregroundStyle(Palette.accent).frame(width: 38, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.leading).padding(.trailing, 12)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 20)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.edge, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// "● Online" / "○ Offline" pill (port of `StatusBadge`).
struct StatusBadge: View {
    let text: String
    let online: Bool
    var body: some View {
        Text((online ? "●  " : "○  ") + text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(online ? Palette.success : Palette.muted)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(online ? Palette.successSoft : Palette.rail, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Red error text inside a card (used by `Availability` and failed feature loads).
struct ErrorCard: View {
    let message: String
    var body: some View {
        Card { Text(message).font(.system(size: 14)).foregroundStyle(Palette.error) }
    }
}

/// Primary filled button (`AccentButton`). Apply with `.buttonStyle(.accent)`.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(minHeight: 34)
            .foregroundStyle(Palette.accentText)
            .background(enabled ? Palette.accent : Palette.disabled, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// Borderless accent-coloured text button (`QuietButton`). Apply with `.buttonStyle(.quiet)`.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(enabled ? Palette.accent : Palette.disabled)
            .background(configuration.isPressed ? Palette.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == AccentButtonStyle { static var accent: AccentButtonStyle { AccentButtonStyle() } }
extension ButtonStyle where Self == QuietButtonStyle { static var quiet: QuietButtonStyle { QuietButtonStyle() } }

/// SF Symbol for a route (port of `RouteIcon`, which picked Segoe Fluent glyphs).
enum RouteIcon {
    static func symbol(for route: String) -> String {
        let title = (route.split(separator: "/").last.map(String.init) ?? route).lowercased()
        func has(_ words: String...) -> Bool { words.contains { title.contains($0) } }
        if has("password", "wifi", "wireless") { return "wifi" }
        if has("profile", "permissions", "account") { return "person" }
        if has("security", "filter", "protection", "vpn") { return "lock.shield" }
        if has("internet", "wan") { return "globe" }
        if has("activity", "usage", "analytics") { return "chart.bar" }
        if has("eero", "device", "setup") { return "wifi.router" }
        if has("notification") { return "bell" }
        if has("appearance") { return "paintpalette" }
        if has("update") { return "arrow.down.circle" }
        if has("help", "support", "troubleshoot") { return "questionmark.circle" }
        if has("about") { return "info.circle" }
        if has("chat") { return "bubble.left.and.bubble.right" }
        if has("dns", "dhcp", "network") { return "network" }
        return "gearshape"
    }
}

/// Two equal-width top-aligned columns, like `Columns()` + `Column()` in NativeLayout.cs.
struct TwoColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0, content: left).frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 0, content: right).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
#endif
