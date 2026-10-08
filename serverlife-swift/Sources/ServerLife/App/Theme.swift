import AppKit
import SwiftUI

/// The colour tokens of styles.css (`--bg`, `--panel` …), resolved for the
/// current theme, accent and skin.
struct Palette: Equatable {
    var tone: Tone
    var bg, panel, panel2, panel3, border, borderSoft, text, textDim, muted: Color
    var accent, accentDim, green, red, amber, purple: Color

    enum Tone: String { case dark, light }

    static let dark = Palette(
        tone: .dark,
        bg: Color(hex: "#0f1117"), panel: Color(hex: "#161922"), panel2: Color(hex: "#1c202b"),
        panel3: Color(hex: "#232836"), border: Color(hex: "#272d3a"), borderSoft: Color(hex: "#1f2430"),
        text: Color(hex: "#d8dee9"), textDim: Color(hex: "#9aa5b8"), muted: Color(hex: "#6b7689"),
        accent: Color(hex: "#4c8dff"), accentDim: Color(hex: "#2f5db3"), green: Color(hex: "#3fb950"),
        red: Color(hex: "#f85149"), amber: Color(hex: "#d29922"), purple: Color(hex: "#a371f7"))

    static let light = Palette(
        tone: .light,
        bg: Color(hex: "#ffffff"), panel: Color(hex: "#f5f6f8"), panel2: Color(hex: "#eceef2"),
        panel3: Color(hex: "#e1e4ea"), border: Color(hex: "#d3d7de"), borderSoft: Color(hex: "#e4e7ec"),
        text: Color(hex: "#1c2128"), textDim: Color(hex: "#4a515c"), muted: Color(hex: "#78808d"),
        accent: Color(hex: "#1f6feb"), accentDim: Color(hex: "#7fb0ff"), green: Color(hex: "#1a7f37"),
        red: Color(hex: "#cf222e"), amber: Color(hex: "#9a6700"), purple: Color(hex: "#8250df"))

    /// The seven accent choices (`data-accent`), dark and light variants.
    static let accents: [(id: String, label: String, dark: (String, String), light: (String, String))] = [
        ("blue", "Blue", ("#4c8dff", "#2f5db3"), ("#1f6feb", "#7fb0ff")),
        ("violet", "Violet", ("#a371f7", "#6b42ad"), ("#8250df", "#c4a7f5")),
        ("teal", "Teal", ("#2bb5a8", "#1c7a71"), ("#1b7f74", "#8fd4cc")),
        ("green", "Green", ("#3fb950", "#2a7d36"), ("#1a7f37", "#93d3a2")),
        ("amber", "Amber", ("#d29922", "#8f6816"), ("#9a6700", "#e0c07a")),
        ("rose", "Rose", ("#f778ba", "#a84b7d"), ("#bf3989", "#f0a8cd")),
        ("slate", "Slate", ("#8b98ad", "#5a6576"), ("#57606a", "#b6bec7")),
    ]
}

/// The current look. Recomputed from settings (`theme`, `accent`, `skin`)
/// and the system appearance; views read `Theme.shared.p`.
///
/// Named themes, skins and terminal palettes (themes.js) plug in through
/// `resolvers`: each gets the settings and the base palette and may return a
/// replacement. The first non-nil answer wins.
@MainActor
@Observable
final class Theme {
    static let shared = Theme()

    private(set) var p: Palette = .dark
    /// Terminal colours for the current theme: 16 ANSI colours plus
    /// background/foreground/cursor/selection, as hex strings. Empty = derive
    /// from the palette.
    private(set) var terminal: [String: String] = [:]

    @ObservationIgnored var resolvers: [(_ settings: JSON, _ base: Palette) -> (Palette, [String: String])?] = []

    func start() {
        refresh()
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Theme.shared.refresh() }
        }
        Store.shared.onSettingsChanged.append { Theme.shared.refresh() }
        // The system accent and highlight colours (the "macOS" theme uses them).
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleColorPreferencesChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Theme.shared.refresh() }
        }
    }

    /// The system's own appearance — not NSApp's, which `refresh` forces to
    /// the chosen theme and would then only ever report itself.
    /// The fill of an ordinary (non-prominent) button: the native push-button
    /// face in the macOS theme, `panel2` everywhere else (as styles.css).
    var buttonFace: Color {
        guard Store.shared.settingJSON("theme").string == "system" else { return p.panel2 }
        let dark = p.tone == .dark
        var out = p.panel2
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let face = NSColor.controlColor.usingColorSpace(.sRGB) ?? .gray
            let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .black
            let a = face.alphaComponent
            out = Color(.sRGB, red: face.redComponent * a + base.redComponent * (1 - a),
                        green: face.greenComponent * a + base.greenComponent * (1 - a),
                        blue: face.blueComponent * a + base.blueComponent * (1 - a))
        }
        return out
    }

    var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    func refresh() {
        let s = Store.shared.settings
        let themeSetting = s["theme"].string ?? "dark"
        let tone: Palette.Tone = themeSetting == "light" ? .light
            : (themeSetting == "auto" || themeSetting == "system") ? (systemIsDark ? .dark : .light) : .dark
        var base = tone == .light ? Palette.light : Palette.dark
        let accent = s["accent"].string ?? "blue"
        if let a = Palette.accents.first(where: { $0.id == accent }) {
            let pair = tone == .light ? a.light : a.dark
            base.accent = Color(hex: pair.0); base.accentDim = Color(hex: pair.1)
        }
        var term: [String: String] = [:]
        for r in resolvers {
            if let (pal, t) = r(s, base) { base = pal; term = t; break }
        }
        if base != p { p = base }
        if term != terminal { terminal = term }
        let appearance = NSAppearance(named: base.tone == .light ? .aqua : .darkAqua)
        if NSApp.appearance != appearance { NSApp.appearance = appearance }
    }
}

extension View {
    /// Apply the app's colour scheme and base font to a root view (windows,
    /// sheets, panels).
    func themed() -> some View {
        modifier(ThemedRoot())
    }
}

private struct ThemedRoot: ViewModifier {
    func body(content: Content) -> some View {
        let t = Theme.shared
        content
            .environment(t)
            .preferredColorScheme(t.p.tone == .light ? .light : .dark)
            .tint(t.p.accent)
            .foregroundStyle(t.p.text)
    }
}
