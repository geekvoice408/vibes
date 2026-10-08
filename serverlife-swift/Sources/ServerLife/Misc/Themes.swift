import AppKit
import SwiftUI

/// Named themes, skins and terminal palettes: the port of themes.js, the
/// `[data-skin]` / `[data-accent]` blocks of styles.css and term.js's
/// `activeTheme()`.
///
/// Each named theme gives only what defines it — a background, a foreground,
/// an accent and the sixteen terminal colours — and the panels, borders and
/// dimmed text are mixed from the first two (`themeTokens`), so every theme
/// steps between surfaces the same way the built-in dark and light do.
///
/// Plain data and pure functions, so it can be tested as such. `resolve`
/// is what `Theme.shared.resolvers` calls (installed by `MiscFeature`).
enum MiscThemes {
    // MARK: - Data

    enum Term: Equatable {
        /// The id of a palette in `terminalPalettes`.
        case palette(String)
        /// The sixteen colours, space-separated in ANSI order.
        case own(String)
    }

    struct AppTheme: Equatable {
        let id: String
        let label: String
        let tone: String
        let bg: String
        let fg: String
        let accent: String
        let term: Term
    }

    /// ANSI colour names in order, as xterm (and `Theme.shared.terminal`) name them.
    static let ansiKeys = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                           "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
                           "brightMagenta", "brightCyan", "brightWhite"]

    static func ansi(_ s: String) -> [String: String] {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var d: [String: String] = [:]
        for (i, k) in ansiKeys.enumerated() where i < parts.count { d[k] = parts[i] }
        return d
    }

    static let appThemes: [AppTheme] = [
        AppTheme(id: "midnight", label: "Midnight (true black)", tone: "dark", bg: "#000000", fg: "#d0d4dc", accent: "#4c8dff",
                 term: .own("#1c202b #f85149 #3fb950 #d29922 #4c8dff #a371f7 #39c5cf #b1bac4 #4a5266 #ff7b72 #56d364 #e3b341 #79b8ff #bc8cff #56d4dd #f0f6fc")),
        AppTheme(id: "github-dark", label: "GitHub dark", tone: "dark", bg: "#0d1117", fg: "#c9d1d9", accent: "#58a6ff",
                 term: .own("#484f58 #ff7b72 #3fb950 #d29922 #58a6ff #bc8cff #39c5cf #b1bac4 #6e7681 #ffa198 #56d364 #e3b341 #79c0ff #d2a8ff #56d4dd #f0f6fc")),
        AppTheme(id: "nord", label: "Nord", tone: "dark", bg: "#2e3440", fg: "#d8dee9", accent: "#88c0d0",
                 term: .palette("nord")),
        AppTheme(id: "dracula", label: "Dracula", tone: "dark", bg: "#282a36", fg: "#f8f8f2", accent: "#bd93f9",
                 term: .palette("dracula")),
        AppTheme(id: "solarized-dark", label: "Solarized dark", tone: "dark", bg: "#002b36", fg: "#93a1a1", accent: "#268bd2",
                 term: .palette("solarized-dark")),
        AppTheme(id: "gruvbox", label: "Gruvbox dark", tone: "dark", bg: "#282828", fg: "#ebdbb2", accent: "#fe8019",
                 term: .palette("gruvbox")),
        AppTheme(id: "tokyo-night", label: "Tokyo Night", tone: "dark", bg: "#1a1b26", fg: "#c0caf5", accent: "#7aa2f7",
                 term: .own("#15161e #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #a9b1d6 #414868 #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #c0caf5")),
        AppTheme(id: "catppuccin-mocha", label: "Catppuccin Mocha", tone: "dark", bg: "#1e1e2e", fg: "#cdd6f4", accent: "#cba6f7",
                 term: .own("#45475a #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #bac2de #585b70 #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #a6adc8")),
        AppTheme(id: "catppuccin-macchiato", label: "Catppuccin Macchiato", tone: "dark", bg: "#24273a", fg: "#cad3f5", accent: "#8aadf4",
                 term: .own("#494d64 #ed8796 #a6da95 #eed49f #8aadf4 #f5bde6 #8bd5ca #b8c0e0 #5b6078 #ed8796 #a6da95 #eed49f #8aadf4 #f5bde6 #8bd5ca #a5adcb")),
        AppTheme(id: "one-dark", label: "One Dark", tone: "dark", bg: "#282c34", fg: "#abb2bf", accent: "#61afef",
                 term: .own("#3f4451 #e06c75 #98c379 #e5c07b #61afef #c678dd #56b6c2 #abb2bf #5c6370 #e06c75 #98c379 #e5c07b #61afef #c678dd #56b6c2 #ffffff")),
        AppTheme(id: "monokai", label: "Monokai", tone: "dark", bg: "#272822", fg: "#f8f8f2", accent: "#a6e22e",
                 term: .own("#3e3d32 #f92672 #a6e22e #f4bf75 #66d9ef #ae81ff #a1efe4 #f8f8f2 #75715e #f92672 #a6e22e #f4bf75 #66d9ef #ae81ff #a1efe4 #f9f8f5")),
        AppTheme(id: "rose-pine", label: "Rosé Pine", tone: "dark", bg: "#191724", fg: "#e0def4", accent: "#c4a7e7",
                 term: .own("#26233a #eb6f92 #31748f #f6c177 #9ccfd8 #c4a7e7 #ebbcba #e0def4 #6e6a86 #eb6f92 #31748f #f6c177 #9ccfd8 #c4a7e7 #ebbcba #e0def4")),
        AppTheme(id: "everforest-dark", label: "Everforest dark", tone: "dark", bg: "#2d353b", fg: "#d3c6aa", accent: "#a7c080",
                 term: .own("#475258 #e67e80 #a7c080 #dbbc7f #7fbbb3 #d699b6 #83c092 #d3c6aa #859289 #e67e80 #a7c080 #dbbc7f #7fbbb3 #d699b6 #83c092 #d3c6aa")),
        AppTheme(id: "kanagawa", label: "Kanagawa", tone: "dark", bg: "#1f1f28", fg: "#dcd7ba", accent: "#7e9cd8",
                 term: .own("#16161d #c34043 #76946a #c0a36e #7e9cd8 #957fb8 #6a9589 #c8c093 #727169 #e82424 #98bb6c #e6c384 #7fb4ca #938aa9 #7aa89f #dcd7ba")),
        AppTheme(id: "ayu-mirage", label: "Ayu Mirage", tone: "dark", bg: "#1f2430", fg: "#cbccc6", accent: "#ffcc66",
                 term: .own("#191e2a #ed8274 #a6cc70 #fad07b #6dcbfa #cfbafa #90e1c6 #c7c7c7 #686868 #f28779 #bae67e #ffd580 #73d0ff #d4bfff #95e6cb #ffffff")),
        AppTheme(id: "night-owl", label: "Night Owl", tone: "dark", bg: "#011627", fg: "#d6deeb", accent: "#82aaff",
                 term: .own("#1d3b53 #ef5350 #22da6e #addb67 #82aaff #c792ea #21c7a8 #d6deeb #575656 #ef5350 #22da6e #ffeb95 #82aaff #c792ea #7fdbca #ffffff")),
        AppTheme(id: "material-ocean", label: "Material Ocean", tone: "dark", bg: "#0f111a", fg: "#a6accd", accent: "#84ffff",
                 term: .own("#546e7a #ff5370 #c3e88d #ffcb6b #82aaff #c792ea #89ddff #a6accd #717cb4 #ff5370 #c3e88d #ffcb6b #82aaff #c792ea #89ddff #ffffff")),
        AppTheme(id: "horizon", label: "Horizon", tone: "dark", bg: "#1c1e26", fg: "#e0e0e0", accent: "#e95678",
                 term: .own("#16161c #e95678 #29d398 #fab795 #26bbd9 #ee64ac #59e1e3 #e5e5e5 #6c6f93 #ec6a88 #3fdaa4 #fbc3a7 #3fc4de #f075b5 #6be4e6 #e6e6e6")),
        AppTheme(id: "cobalt2", label: "Cobalt2", tone: "dark", bg: "#193549", fg: "#ffffff", accent: "#ffc600",
                 term: .own("#000000 #ff0000 #38de21 #ffe50a #1460d2 #ff005d #00bbbb #bbbbbb #555555 #f40e17 #3bd01d #edc809 #5555ff #ff55ff #6ae3fa #ffffff")),
        AppTheme(id: "catppuccin-frappe", label: "Catppuccin Frappé", tone: "dark", bg: "#303446", fg: "#c6d0f5", accent: "#ca9ee6",
                 term: .own("#51576d #e78284 #a6d189 #e5c890 #8caaee #f4b8e4 #81c8be #b5bfe2 #626880 #e78284 #a6d189 #e5c890 #8caaee #f4b8e4 #81c8be #a5adce")),
        AppTheme(id: "palenight", label: "Palenight", tone: "dark", bg: "#292d3e", fg: "#a6accd", accent: "#c792ea",
                 term: .own("#676e95 #ff5370 #c3e88d #ffcb6b #82aaff #c792ea #89ddff #a6accd #676e95 #ff5370 #c3e88d #ffcb6b #82aaff #c792ea #89ddff #ffffff")),
        AppTheme(id: "oceanic-next", label: "Oceanic Next", tone: "dark", bg: "#1b2b34", fg: "#cdd3de", accent: "#6699cc",
                 term: .own("#343d46 #ec5f67 #99c794 #fac863 #6699cc #c594c5 #5fb3b3 #cdd3de #65737e #ec5f67 #99c794 #fac863 #6699cc #c594c5 #5fb3b3 #d8dee9")),
        AppTheme(id: "iceberg", label: "Iceberg", tone: "dark", bg: "#161821", fg: "#c6c8d1", accent: "#84a0c6",
                 term: .own("#1e2132 #e27878 #b4be82 #e2a478 #84a0c6 #a093c7 #89b8c2 #c6c8d1 #6b7089 #e98989 #c0ca8e #e9b189 #91acd1 #ada0d3 #95c4ce #d2d4de")),
        AppTheme(id: "high-contrast", label: "High contrast", tone: "dark", bg: "#000000", fg: "#ffffff", accent: "#409cff",
                 term: .palette("high-contrast")),
        AppTheme(id: "solarized-light", label: "Solarized light", tone: "light", bg: "#fdf6e3", fg: "#586e75", accent: "#268bd2",
                 term: .palette("solarized-light")),
        AppTheme(id: "gruvbox-light", label: "Gruvbox light", tone: "light", bg: "#fbf1c7", fg: "#3c3836", accent: "#af3a03",
                 term: .own("#3c3836 #cc241d #98971a #d79921 #458588 #b16286 #689d6a #7c6f64 #928374 #9d0006 #79740e #b57614 #076678 #8f3f71 #427b58 #3c3836")),
        AppTheme(id: "catppuccin-latte", label: "Catppuccin Latte", tone: "light", bg: "#eff1f5", fg: "#4c4f69", accent: "#8839ef",
                 term: .own("#5c5f77 #d20f39 #40a02b #df8e1d #1e66f5 #ea76cb #179299 #acb0be #6c6f85 #d20f39 #40a02b #df8e1d #1e66f5 #ea76cb #179299 #bcc0cc")),
        AppTheme(id: "one-light", label: "One Light", tone: "light", bg: "#fafafa", fg: "#383a42", accent: "#4078f2",
                 term: .own("#383a42 #e45649 #50a14f #c18401 #4078f2 #a626a4 #0184bc #a0a1a7 #696c77 #e45649 #50a14f #c18401 #4078f2 #a626a4 #0184bc #383a42")),
        AppTheme(id: "rose-pine-dawn", label: "Rosé Pine Dawn", tone: "light", bg: "#faf4ed", fg: "#575279", accent: "#907aa9",
                 term: .own("#575279 #b4637a #286983 #ea9d34 #56949f #907aa9 #d7827e #9893a5 #797593 #b4637a #286983 #ea9d34 #56949f #907aa9 #d7827e #575279")),
        AppTheme(id: "everforest-light", label: "Everforest light", tone: "light", bg: "#fdf6e3", fg: "#5c6a72", accent: "#8da101",
                 term: .own("#5c6a72 #f85552 #8da101 #dfa000 #3a94c5 #df69ba #35a77c #a6b0a0 #829181 #f85552 #8da101 #dfa000 #3a94c5 #df69ba #35a77c #5c6a72")),
        AppTheme(id: "ayu-light", label: "Ayu light", tone: "light", bg: "#fafafa", fg: "#5c6166", accent: "#fa8d3e",
                 term: .own("#5c6166 #f07171 #86b300 #eba400 #399ee6 #a37acc #4cbf99 #abb0b6 #828c99 #f07171 #86b300 #eba400 #399ee6 #a37acc #4cbf99 #5c6166")),
        AppTheme(id: "tokyo-night-day", label: "Tokyo Night Day", tone: "light", bg: "#e1e2e7", fg: "#3760bf", accent: "#2e7de9",
                 term: .own("#3760bf #f52a65 #587539 #8c6c3e #2e7de9 #9854f1 #007197 #6172b0 #a1a6c5 #f52a65 #587539 #8c6c3e #2e7de9 #9854f1 #007197 #3760bf")),
        AppTheme(id: "github-light-hc", label: "GitHub light high contrast", tone: "light", bg: "#ffffff", fg: "#0e1116", accent: "#0349b4",
                 term: .own("#0e1116 #a0111f #024c1a #3f2200 #0349b4 #622cbc #1b4b91 #66707b #4b535d #86061d #055d20 #4e2c00 #1168e3 #844ae7 #3192aa #0e1116")),
        AppTheme(id: "nord-light", label: "Nord light", tone: "light", bg: "#eceff4", fg: "#2e3440", accent: "#5e81ac",
                 term: .own("#3b4252 #bf616a #5f7f4f #b0862f #5e81ac #b48ead #4f8a96 #4c566a #4c566a #bf616a #6b8f5a #c0963a #81a1c1 #b48ead #5e9aa6 #2e3440")),
        AppTheme(id: "quiet-light", label: "Quiet light", tone: "light", bg: "#f5f5f5", fg: "#333333", accent: "#4b83cd",
                 term: .own("#333333 #aa3731 #448c27 #cb9000 #325cc0 #7a3e9d #0083b2 #777777 #777777 #aa3731 #448c27 #cb9000 #325cc0 #7a3e9d #0083b2 #333333")),
        AppTheme(id: "selenized-light", label: "Selenized light", tone: "light", bg: "#fbf3db", fg: "#53676d", accent: "#0072d4",
                 term: .own("#53676d #d2212d #489100 #ad8900 #0072d4 #ca4898 #009c8f #909995 #909995 #cc1729 #428b00 #a78300 #006dce #c44392 #00978a #3a4d53")),
        AppTheme(id: "paper", label: "Paper (sepia)", tone: "light", bg: "#f4ecd8", fg: "#433422", accent: "#a0522d",
                 term: .own("#433422 #b03a2e #5a7a2e #8a6a10 #2f5d8a #8a4a7a #2e7a72 #8a7a60 #6f6050 #c0483a #6a8a3a #a07a20 #3f6d9a #9a5a8a #3e8a82 #2a2016")),
    ]

    static func themeById(_ id: String?) -> AppTheme? {
        guard let id else { return nil }
        return appThemes.first { $0.id == id }
    }

    struct TerminalPalette {
        let value: String
        let label: String
        /// nil for "app" (follow the app theme).
        let theme: [String: String]?
    }

    private static func pal(_ bg: String, _ fg: String, _ cursor: String, _ cursorAccent: String, _ sel: String,
                            _ colours: String) -> [String: String] {
        var d = ansi(colours)
        d["background"] = bg; d["foreground"] = fg; d["cursor"] = cursor
        d["cursorAccent"] = cursorAccent; d["selectionBackground"] = sel
        return d
    }

    /// The terminal palettes, independent of the app's own theme: a
    /// Solarized user wants Solarized whatever colour the sidebar is. 'app'
    /// keeps the old behaviour of following the theme and any skin. Every app
    /// theme with colours of its own is appended, so it can be picked for the
    /// terminal alone.
    static let terminalPalettes: [TerminalPalette] = {
        var list: [TerminalPalette] = [
            TerminalPalette(value: "app", label: "Follow the app theme", theme: nil),
            TerminalPalette(value: "solarized-dark", label: "Solarized dark", theme: pal(
                "#002b36", "#93a1a1", "#93a1a1", "#002b36", "#073642aa",
                "#073642 #dc322f #859900 #b58900 #268bd2 #d33682 #2aa198 #eee8d5 #586e75 #cb4b16 #586e75 #657b83 #839496 #6c71c4 #93a1a1 #fdf6e3")),
            TerminalPalette(value: "solarized-light", label: "Solarized light", theme: pal(
                "#fdf6e3", "#586e75", "#586e75", "#fdf6e3", "#eee8d5aa",
                "#eee8d5 #dc322f #859900 #b58900 #268bd2 #d33682 #2aa198 #073642 #93a1a1 #cb4b16 #93a1a1 #839496 #657b83 #6c71c4 #586e75 #002b36")),
            TerminalPalette(value: "gruvbox", label: "Gruvbox dark", theme: pal(
                "#282828", "#ebdbb2", "#ebdbb2", "#282828", "#504945aa",
                "#282828 #cc241d #98971a #d79921 #458588 #b16286 #689d6a #a89984 #928374 #fb4934 #b8bb26 #fabd2f #83a598 #d3869b #8ec07c #ebdbb2")),
            TerminalPalette(value: "nord", label: "Nord", theme: pal(
                "#2e3440", "#d8dee9", "#d8dee9", "#2e3440", "#434c5eaa",
                "#3b4252 #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #88c0d0 #e5e9f0 #4c566a #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #8fbcbb #eceff4")),
            TerminalPalette(value: "dracula", label: "Dracula", theme: pal(
                "#282a36", "#f8f8f2", "#f8f8f2", "#282a36", "#44475aaa",
                "#21222c #ff5555 #50fa7b #f1fa8c #bd93f9 #ff79c6 #8be9fd #f8f8f2 #6272a4 #ff6e6e #69ff94 #ffffa5 #d6acff #ff92df #a4ffff #ffffff")),
            TerminalPalette(value: "high-contrast", label: "High contrast", theme: pal(
                "#000000", "#ffffff", "#ffffff", "#000000", "#3355ffaa",
                "#000000 #ff3b30 #28cd41 #ffcc00 #409cff #ff6ff2 #5ac8fa #f2f2f7 #8e8e93 #ff6961 #5ff08a #ffe066 #7cc0ff #ff9df8 #8fe0ff #ffffff")),
        ]
        for t in appThemes {
            if case .own = t.term { list.append(TerminalPalette(value: t.id, label: t.label, theme: fromAppTheme(t))) }
        }
        return list
    }()

    /// A named app theme's own colours as a whole terminal palette.
    static func fromAppTheme(_ t: AppTheme) -> [String: String] {
        var d: [String: String] = ["background": t.bg, "foreground": t.fg, "cursor": t.accent,
                                   "cursorAccent": t.bg, "selectionBackground": t.accent + "44"]
        if case .own(let s) = t.term { d.merge(ansi(s)) { _, n in n } }
        return d
    }

    static func paletteByName(_ name: String?) -> [String: String]? {
        guard let name else { return nil }
        return terminalPalettes.first { $0.value == name && $0.theme != nil }?.theme
    }

    /// The sixteen colours behind an app theme, whichever way it names them.
    static func appThemeAnsi(_ t: AppTheme) -> [String: String]? {
        switch t.term {
        case .palette(let p): return paletteByName(p)
        case .own(let s): return ansi(s)
        }
    }

    /// An app theme as the terminal draws it: background, cursor and all.
    static func appThemePalette(_ t: AppTheme) -> [String: String]? {
        switch t.term {
        case .palette(let p): return paletteByName(p)
        case .own: return fromAppTheme(t)
        }
    }

    /// 'light' or 'dark' for any theme setting, or nil for "follow the system".
    static func toneOf(_ id: String?) -> String? {
        if id == "light" || id == "dark" { return id }
        return themeById(id)?.tone
    }

    // MARK: - macOS system colours

    /// The styles.css tokens filled from AppKit's semantic colours, resolved
    /// for a dark or light appearance. Translucent colours (separators,
    /// secondary labels) are flattened over the background, since the tokens
    /// are opaque hex.
    static func systemTokens(dark: Bool) -> ([String: String], String) {
        var out: [String: String] = [:]
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            func srgb(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }
            let bg = srgb(dark ? NSColor.underPageBackgroundColor : NSColor.textBackgroundColor)
            func hex(_ c: NSColor, over base: NSColor? = nil) -> String {
                var c = srgb(c)
                if let base, c.alphaComponent < 1 {
                    let a = c.alphaComponent, b = srgb(base)
                    c = NSColor(srgbRed: c.redComponent * a + b.redComponent * (1 - a),
                                green: c.greenComponent * a + b.greenComponent * (1 - a),
                                blue: c.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
                }
                return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)),
                              Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
            }
            let panel = srgb(NSColor.windowBackgroundColor)
            out["--bg"] = hex(bg)
            out["--panel"] = hex(panel)
            // panel-2/panel-3 are what buttons are filled with (resting /
            // hover): use the native push-button face, not the near-black
            // control *background* colour, so buttons look like macOS's own.
            // panel-2 is a surface (boxes, chips, inputs) as well as the
            // button fill, so it stays subtle; buttons get the native face
            // through Theme.buttonFace instead.
            out["--panel-2"] = dark ? hex(NSColor.labelColor.withAlphaComponent(0.07), over: panel)
                                    : hex(NSColor.controlBackgroundColor, over: panel)
            // panel-3 is the wash behind tag chips, selected rows and badges:
            // subtle, so the text on it stays readable.
            out["--panel-3"] = dark ? hex(NSColor.labelColor.withAlphaComponent(0.13), over: panel)
                                    : hex(NSColor.unemphasizedSelectedContentBackgroundColor, over: panel)
            out["--border"] = hex(NSColor.separatorColor, over: panel)
            out["--border-soft"] = hex(NSColor.separatorColor.withAlphaComponent(0.5), over: panel)
            out["--text"] = hex(NSColor.labelColor, over: bg)
            // The app uses these for help text and labels, not decoration:
            // macOS's tertiary label (~25%) is far too faint for that.
            out["--text-dim"] = hex(NSColor.labelColor.withAlphaComponent(0.78), over: bg)
            out["--muted"] = hex(NSColor.labelColor.withAlphaComponent(0.55), over: bg)
            out["--accent"] = hex(NSColor.controlAccentColor)
            out["--accent-dim"] = hex(NSColor.controlAccentColor.withAlphaComponent(0.55), over: bg)
            out["--green"] = hex(NSColor.systemGreen)
            out["--red"] = hex(NSColor.systemRed)
            out["--amber"] = hex(NSColor.systemOrange)
            out["--purple"] = hex(NSColor.systemPurple)
            out["--scroll-thumb"] = hex(NSColor.tertiaryLabelColor, over: panel)
            out["--scroll-thumb-hover"] = hex(NSColor.secondaryLabelColor, over: panel)
        }
        return (out, dark ? "dark" : "light")
    }

    // MARK: - Colour arithmetic

    static func rgb(_ c: String) -> [Double] {
        var s = c
        if s.hasPrefix("#") { s.removeFirst() }
        let chars = Array(s)
        return [0, 2, 4].map { i -> Double in
            guard i + 2 <= chars.count else { return 0 }
            return Double(Int(String(chars[i..<i + 2]), radix: 16) ?? 0)
        }
    }

    static func toHex(_ v: [Double]) -> String {
        "#" + v.map { String(format: "%02x", Int(($0).rounded(.toNearestOrAwayFromZero))) }.joined()
    }

    /// `a` moved toward `b` by `t` (0…1).
    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let x = rgb(a), y = rgb(b)
        return toHex((0..<3).map { x[$0] + (y[$0] - x[$0]) * t })
    }

    /// WCAG relative luminance.
    static func luminance(_ c: String) -> Double {
        let v = rgb(c).map { $0 / 255 }.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    }

    /// WCAG contrast ratio.
    static func contrast(_ a: String, _ b: String) -> Double {
        let l = [luminance(a), luminance(b)].sorted(by: >)
        return (l[0] + 0.05) / (l[1] + 0.05)
    }

    /// `c`, pushed toward black on a light theme or white on a dark one just
    /// far enough to reach `min` against `against`. The terminal keeps the
    /// palette exactly; the chrome gets the nearest readable shade.
    static func readable(_ c: String, _ against: String, _ min: Double, _ light: Bool) -> String {
        let toward = light ? "#000000" : "#ffffff"
        var k = 0.0
        while k <= 1 {
            let v = mix(c, toward, k)
            if contrast(v, against) >= min { return v }
            k += 0.02
        }
        return toward
    }

    /// The UI tokens for a theme, mixed from what it defines (keys as the CSS
    /// variables: `--bg`, `--panel` …).
    static func themeTokens(_ t: AppTheme, _ ansiColours: [String: String]) -> [String: String] {
        let light = t.tone == "light"
        func step(_ k: Double) -> String { mix(t.bg, t.fg, k) }
        let panel3 = step(light ? 0.11 : 0.095)
        let text = readable(t.fg, panel3, 4.5, light)
        let accent = readable(t.accent, t.bg, 3, light)
        return [
            "--bg": t.bg,
            "--panel": step(0.035),
            "--panel-2": step(light ? 0.07 : 0.065),
            "--panel-3": panel3,
            "--border": step(light ? 0.17 : 0.13),
            "--border-soft": step(light ? 0.09 : 0.08),
            "--text": text,
            "--text-dim": readable(mix(text, t.bg, 0.25), t.bg, 4.5, light),
            "--muted": readable(mix(text, t.bg, 0.45), t.bg, 3, light),
            "--accent": accent,
            "--accent-dim": mix(accent, t.bg, light ? 0.55 : 0.4),
            "--green": ansiColours["green"] ?? "#3fb950",
            "--red": ansiColours["red"] ?? "#f85149",
            "--amber": ansiColours["yellow"] ?? "#d29922",
            "--purple": ansiColours["magenta"] ?? "#a371f7",
            "--scroll-thumb": step(light ? 0.2 : 0.16),
            "--scroll-thumb-hover": step(light ? 0.3 : 0.24),
        ]
    }

    // MARK: - styles.css

    private static func tokens(_ list: String) -> [String: String] {
        let names = ["--bg", "--panel", "--panel-2", "--panel-3", "--border", "--border-soft", "--text", "--text-dim",
                     "--muted", "--accent", "--accent-dim", "--green", "--red", "--amber", "--purple",
                     "--scroll-thumb", "--scroll-thumb-hover"]
        let v = list.split(separator: " ").map(String.init)
        var d: [String: String] = [:]
        for (i, n) in names.enumerated() where i < v.count { d[n] = v[i] }
        return d
    }

    /// `:root` (dark) and `:root[data-theme="light"]`.
    static let darkTokens = tokens("#0f1117 #161922 #1c202b #232836 #272d3a #1f2430 #d8dee9 #9aa5b8 #6b7689 #4c8dff #2f5db3 #3fb950 #f85149 #d29922 #a371f7 #313846 #424b5d")
    static let lightTokens = tokens("#ffffff #f5f6f8 #eceef2 #e1e4ea #d3d7de #e4e7ec #1c2128 #4a515c #78808d #1f6feb #7fb0ff #1a7f37 #cf222e #9a6700 #8250df #c6cbd3 #adb3bd")

    struct Skin {
        let id: String
        let label: String
        let tone: String
        let tokens: [String: String]
    }

    /// The `[data-skin]` blocks of styles.css. A skin repaints every token at
    /// once and so overrides the theme and the accent both.
    static let skins: [Skin] = [
        Skin(id: "party", label: "\u{1F389} Party", tone: "dark",
             tokens: tokens("#0b0616 #150d26 #1e1235 #2a1a48 #3c2566 #2a1a48 #f4e9ff #c9a8f0 #8f6fb8 #ff3ec8 #a3187c #3dffc0 #ff4d6d #ffd23f #b388ff #452a70 #5d3a94")),
        Skin(id: "halloween", label: "\u{1F383} Halloween", tone: "dark",
             tokens: tokens("#0d0a07 #17110c #201811 #2d2117 #40301f #2a1f14 #f6e7d3 #d3a76a #8a6c47 #ff7518 #a8460a #7fff32 #e03a1f #ffb627 #9d4edd #3b2b1c #55402a")),
        Skin(id: "christmas", label: "\u{1F384} Christmas", tone: "dark",
             tokens: tokens("#07140d #0c1f15 #12291c #1a3626 #245037 #1a3626 #eef7f1 #a8cdb6 #6f9880 #e63946 #9d2531 #57cc99 #ff5a5f #ffd166 #c77dff #21432f #2f5c42")),
        Skin(id: "winter", label: "\u{2744}\u{FE0F} Winter", tone: "light",
             tokens: tokens("#f7fafc #eaf1f6 #dfe9f1 #cfdeea #b6cbdb #d4e2ec #10222f #3d5a6f #6d879b #2e86c1 #90c5e3 #1a7f5a #c0392b #a97400 #6c5ce7 #bccfdd #a3bccf")),
        Skin(id: "valentine", label: "\u{1F495} Valentine", tone: "dark",
             tokens: tokens("#16070f #230d19 #2e1322 #3d1b2d #562740 #3a1a2b #ffeaf3 #f0aac8 #b2738f #ff4d8d #a82558 #4dd4ac #ff6b6b #ffc857 #d291ff #4d2438 #6b3550")),
        Skin(id: "shamrock", label: "\u{1F340} Shamrock", tone: "dark",
             tokens: tokens("#04120a #081d10 #0d2717 #13351f #1d4d2d #133520 #e8f8ec #9ed9ae #67997a #2ecc71 #1a7a43 #7bed9f #ff6b6b #f9ca24 #a29bfe #1b4429 #2a6340")),
        Skin(id: "fireworks", label: "\u{1F386} Fireworks", tone: "dark",
             tokens: tokens("#060b1c #0c1330 #121b41 #1a2655 #263673 #1a2655 #eef2ff #a9b6e8 #6d7bb0 #ff3b3f #a81f22 #4ade80 #ff5c5c #ffd166 #8b9cff #22305e #32447f")),
        Skin(id: "synthwave", label: "\u{1F3B9} Synthwave", tone: "dark",
             tokens: tokens("#120a24 #1b1036 #241547 #311d5e #452a80 #2d1a57 #f2e9ff #b39cf5 #7f6bbf #ff2e97 #a81361 #05ffa1 #ff5470 #ffb800 #b967ff #3d2570 #523397")),
        Skin(id: "matrix", label: "\u{1F7E9} Matrix", tone: "dark",
             tokens: tokens("#000700 #041004 #071807 #0b220b #144014 #0d2b0d #b6ffb6 #52d552 #2f8f2f #00ff41 #00a52a #00ff41 #ff4136 #d7ff2f #6cff9e #113d11 #1a5c1a")),
    ]

    static func skin(_ id: String?) -> Skin? { skins.first { $0.id == id } }

    /// The accent rules: `[data-accent]` and `[data-tone="light"][data-accent]`.
    static func accentPair(_ accent: String, light: Bool) -> (String, String)? {
        guard accent != "blue", let a = Palette.accents.first(where: { $0.id == accent }) else { return nil }
        return light ? a.light : a.dark
    }

    // MARK: - term.js LIGHT_THEME / DARK_THEME

    static let lightTerminal: [String: String] = {
        var d = ansi("#24292f #cf222e #116329 #4d2d00 #0969da #8250df #1b7c83 #6e7781 #57606a #a40e26 #1a7f37 #633c01 #218bff #a475f9 #3192aa #8c959f")
        d["background"] = "#ffffff"; d["foreground"] = "#1c2128"; d["cursor"] = "#1f6feb"
        d["cursorAccent"] = "#ffffff"; d["selectionBackground"] = "#1f6feb38"   // rgba(31,111,235,.22)
        return d
    }()

    static let darkTerminal: [String: String] = {
        var d = ansi("#1c202b #f85149 #3fb950 #d29922 #4c8dff #a371f7 #39c5cf #b1bac4 #4a5266 #ff7b72 #56d364 #e3b341 #79b8ff #bc8cff #56d4dd #f0f6fc")
        d["background"] = "#0f1117"; d["foreground"] = "#d8dee9"; d["cursor"] = "#4c8dff"
        d["cursorAccent"] = "#0f1117"; d["selectionBackground"] = "#4c8dff47"  // rgba(76,141,255,.28)
        return d
    }()

    // MARK: - Resolution

    /// What the window shows for these settings: the CSS cascade of
    /// styles.css (base → named theme → accent → skin) and `activeTheme()`.
    /// `systemDark` answers "auto".
    static func resolveTokens(theme: String, accent: String, skin skinId: String, systemDark: Bool)
        -> (tokens: [String: String], tone: String) {
        let named = themeById(theme)
        var tone: String
        var tok: [String: String]
        if theme == "system" {
            // macOS's own colours, light or dark as the system is set, with
            // the system accent; a skin still repaints on top.
            let (t, tn) = systemTokens(dark: systemDark)
            if let sk = skin(skinId) { return (sk.tokens, sk.tone) }
            return (t, tn)
        }
        if let named {
            tone = named.tone
            tok = themeTokens(named, appThemeAnsi(named) ?? [:])
        } else if theme == "light" || (theme == "auto" && !systemDark) {
            tone = "light"; tok = lightTokens
        } else {
            tone = "dark"; tok = darkTokens
        }
        // data-tone is absent for "auto", so the light accent shades only
        // apply to a theme that is light by name — as in styles.css.
        if let pair = accentPair(accent, light: toneOf(theme) == "light") {
            tok["--accent"] = pair.0; tok["--accent-dim"] = pair.1
        }
        if let s = skin(skinId) {
            tok = s.tokens; tone = s.tone
        }
        return (tok, tone)
    }

    /// term.js `activeTheme()`.
    static func terminalColours(theme: String, skin skinId: String, palette: String, systemDark: Bool,
                                tokens tok: [String: String]) -> [String: String] {
        let tone = toneOf(theme == "auto" || theme == "system" ? nil : theme)
        let light = tone == "light" || (tone == nil && !systemDark)
        var base = light ? lightTerminal : darkTerminal
        if theme == "system" {
            // The terminal sits on the same surface as the window.
            base["background"] = tok["--bg"] ?? base["background"]
            base["foreground"] = tok["--text"] ?? base["foreground"]
            base["cursorAccent"] = tok["--bg"] ?? base["cursorAccent"]
        }
        func over(_ p: [String: String]) -> [String: String] { base.merging(p) { _, n in n } }
        // A named palette wins over both the theme and any skin.
        if let named = paletteByName(palette) { return over(named) }
        let hasSkin = skin(skinId) != nil
        if let t = themeById(theme), !hasSkin, let p = appThemePalette(t) { return over(p) }
        guard hasSkin else { return base }
        // A skin repaints through its tokens; the terminal follows them.
        func v(_ name: String, _ fallback: String?) -> String { tok[name] ?? fallback ?? "" }
        let accent = v("--accent", base["blue"])
        var d = base
        d["background"] = v("--bg", base["background"])
        d["foreground"] = v("--text", base["foreground"])
        d["cursor"] = accent
        d["cursorAccent"] = v("--bg", base["cursorAccent"])
        d["selectionBackground"] = accent.count == 7 ? accent + "47" : base["selectionBackground"]
        d["black"] = v("--panel-2", base["black"])
        d["red"] = v("--red", base["red"])
        d["green"] = v("--green", base["green"])
        d["yellow"] = v("--amber", base["yellow"])
        d["blue"] = accent
        d["magenta"] = v("--purple", base["magenta"])
        d["white"] = v("--text-dim", base["white"])
        d["brightWhite"] = v("--text", base["brightWhite"])
        d["brightBlack"] = v("--muted", base["brightBlack"])
        return d
    }

    static func palette(from tok: [String: String], tone: String) -> Palette {
        func c(_ k: String) -> Color { Color(hex: tok[k] ?? "#ff00ff") }
        return Palette(tone: tone == "light" ? .light : .dark,
                       bg: c("--bg"), panel: c("--panel"), panel2: c("--panel-2"), panel3: c("--panel-3"),
                       border: c("--border"), borderSoft: c("--border-soft"), text: c("--text"),
                       textDim: c("--text-dim"), muted: c("--muted"), accent: c("--accent"),
                       accentDim: c("--accent-dim"), green: c("--green"), red: c("--red"),
                       amber: c("--amber"), purple: c("--purple"))
    }

    /// While the Settings dialog is open, what it is previewing (theme,
    /// accent, skin) instead of what is saved. nil = the saved settings.
    @MainActor static var preview: (theme: String, accent: String, skin: String)?

    /// The resolver plugged into `Theme.shared.resolvers`. Always answers, so
    /// `Theme.shared.terminal` is always the full set of colours.
    @MainActor static func resolve(_ s: JSON, _ base: Palette) -> (Palette, [String: String])? {
        let theme = preview?.theme ?? s["theme"].string ?? "dark"
        let accent = preview?.accent ?? s["accent"].string ?? "blue"
        let skinId = preview?.skin ?? s["skin"].string ?? "none"
        let palette = s["terminalPalette"].string ?? "app"
        let systemDark = Theme.shared.systemIsDark
        let r = resolveTokens(theme: theme, accent: accent, skin: skinId, systemDark: systemDark)
        var term = terminalColours(theme: theme, skin: skinId, palette: palette, systemDark: systemDark, tokens: r.tokens)
        term["selection"] = term["selectionBackground"]
        return (MiscThemes.palette(from: r.tokens, tone: r.tone), term)
    }
}

extension Theme {
    /// A terminal colour (`Theme.shared.terminal[key]`) as an NSColor,
    /// alpha included (`#rrggbbaa`).
    func terminalNSColor(_ key: String) -> NSColor? {
        guard let hex = terminal[key] else { return nil }
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            return NSColor(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                           blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
        }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
