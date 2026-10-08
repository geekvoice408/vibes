import Testing
import Foundation
@testable import ServerLife

/// tests/themes.test.mjs: dozens of palettes typed in by hand, where a typo
/// does not fail loudly. These check what a glance at one theme would not.
@Suite struct MiscThemesTests {
    typealias T = MiscThemes
    static let hexRE = try! NSRegularExpression(pattern: "^#[0-9a-f]{6}$", options: .caseInsensitive)
    func isHex(_ s: String?) -> Bool { s.map { Self.hexRE.matches($0) } ?? false }

    @Test func thereAreALotOfThemLightAndDarkBoth() {
        #expect(T.appThemes.count >= 30)
        #expect(T.appThemes.filter { $0.tone == "light" }.count >= 10)
        #expect(T.appThemes.filter { $0.tone == "dark" }.count >= 20)
    }

    @Test func everyIdIsUniqueAndNoneShadowsABuiltInSetting() {
        let ids = T.appThemes.map(\.id)
        #expect(Set(ids).count == ids.count)
        for reserved in ["auto", "dark", "light"] { #expect(!ids.contains(reserved)) }
    }

    @Test func eachThemeSaysWhetherItIsLightOrDarkAndToneOfAgrees() {
        for t in T.appThemes {
            #expect(t.tone == "light" || t.tone == "dark", "\(t.id)")
            #expect(T.toneOf(t.id) == t.tone)
        }
        #expect(T.toneOf("light") == "light")
        #expect(T.toneOf("dark") == "dark")
        #expect(T.toneOf("auto") == nil)
        #expect(T.toneOf("no-such-theme") == nil)
    }

    @Test func everyThemeResolvesToSixteenRealColours() {
        for t in T.appThemes {
            let a = T.appThemeAnsi(t)
            #expect(a != nil, "\(t.id): palette not found")
            for k in T.ansiKeys { #expect(isHex(a?[k]), "\(t.id).\(k)") }
            for c in [t.bg, t.fg, t.accent] { #expect(isHex(c), "\(t.id)") }
        }
    }

    @Test func everyDerivedUITokenIsAColour() {
        for t in T.appThemes {
            for (k, v) in T.themeTokens(t, T.appThemeAnsi(t)!) { #expect(isHex(v), "\(t.id) \(k)") }
        }
    }

    @Test func textIsReadableOnEveryBackground() {
        for t in T.appThemes {
            let tok = T.themeTokens(t, T.appThemeAnsi(t)!)
            #expect(T.contrast(tok["--text"]!, tok["--bg"]!) >= 4.5, "\(t.id) text")
            #expect(T.contrast(tok["--text"]!, tok["--panel-3"]!) >= 4.5, "\(t.id) text on panel-3")
            #expect(T.contrast(tok["--text-dim"]!, tok["--bg"]!) >= 4.5, "\(t.id) text-dim")
            #expect(T.contrast(tok["--muted"]!, tok["--bg"]!) >= 3, "\(t.id) muted")
            #expect(T.contrast(tok["--accent"]!, tok["--bg"]!) >= 3, "\(t.id) accent")
        }
    }

    @Test func surfacesStepAwayFromTheBackgroundInOrder() {
        for t in T.appThemes {
            let tok = T.themeTokens(t, T.appThemeAnsi(t)!)
            func d(_ k: String) -> Double { T.contrast(tok[k]!, tok["--bg"]!) }
            #expect(d("--panel") <= d("--panel-2") && d("--panel-2") <= d("--panel-3"), "\(t.id)")
            #expect(d("--border") > d("--panel"), "\(t.id) border lost against the panel")
        }
    }

    @Test func everyThemeResolvesForTheWindowWithNothingMissing() {
        for t in T.appThemes {
            let r = T.resolveTokens(theme: t.id, accent: "blue", skin: "none", systemDark: true)
            #expect(r.tone == t.tone)
            for k in ["--bg", "--panel", "--panel-2", "--panel-3", "--border", "--border-soft", "--text", "--text-dim",
                      "--muted", "--accent", "--accent-dim", "--green", "--red", "--amber", "--purple"] {
                #expect(isHex(r.tokens[k]), "\(t.id) \(k)")
            }
        }
    }

    @Test func themesWithColoursOfTheirOwnCanBePickedForTheTerminalAlone() {
        let values = T.terminalPalettes.map(\.value)
        #expect(Set(values).count == values.count, "a palette is listed twice")
        for t in T.appThemes {
            if case .palette(let p) = t.term { #expect(values.contains(p), "\(t.id)") } else { #expect(values.contains(t.id)) }
        }
    }

    @Test func mixGoesFromOneColourToTheOther() {
        #expect(T.mix("#000000", "#ffffff", 0) == "#000000")
        #expect(T.mix("#000000", "#ffffff", 1) == "#ffffff")
        #expect(T.mix("#000000", "#ffffff", 0.5) == "#808080")
    }

    // The cascade and activeTheme().

    @Test func aSkinRepaintsEverythingAndIgnoresThemeAndAccent() {
        let r = T.resolveTokens(theme: "nord", accent: "rose", skin: "winter", systemDark: true)
        #expect(r.tone == "light")
        #expect(r.tokens["--bg"] == "#f7fafc")
        #expect(r.tokens["--accent"] == "#2e86c1")
    }

    @Test func anAccentOverridesANamedThemeAndBlueKeepsItsOwn() {
        #expect(T.resolveTokens(theme: "dracula", accent: "blue", skin: "none", systemDark: true).tokens["--accent"]
                == T.themeTokens(T.themeById("dracula")!, T.appThemeAnsi(T.themeById("dracula")!)!)["--accent"])
        #expect(T.resolveTokens(theme: "dracula", accent: "teal", skin: "none", systemDark: true).tokens["--accent"] == "#2bb5a8")
        #expect(T.resolveTokens(theme: "solarized-light", accent: "teal", skin: "none", systemDark: true).tokens["--accent"] == "#1b7f74")
        #expect(T.resolveTokens(theme: "light", accent: "violet", skin: "none", systemDark: true).tokens["--accent"] == "#8250df")
    }

    @Test func autoFollowsTheSystem() {
        #expect(T.resolveTokens(theme: "auto", accent: "blue", skin: "none", systemDark: false).tokens["--bg"] == "#ffffff")
        #expect(T.resolveTokens(theme: "auto", accent: "blue", skin: "none", systemDark: true).tokens["--bg"] == "#0f1117")
    }

    @Test func terminalColoursFollowThePrecedenceOfActiveTheme() {
        func term(_ theme: String, _ skin: String, _ pal: String) -> [String: String] {
            let r = T.resolveTokens(theme: theme, accent: "blue", skin: skin, systemDark: true)
            return T.terminalColours(theme: theme, skin: skin, palette: pal, systemDark: true, tokens: r.tokens)
        }
        // A named palette wins over the theme and any skin.
        #expect(term("nord", "matrix", "dracula")["background"] == "#282a36")
        // A named theme brings its own sixteen colours…
        #expect(term("nord", "none", "app")["background"] == "#2e3440")
        #expect(term("tokyo-night", "none", "app")["red"] == "#f7768e")
        // …unless a skin is repainting everything.
        let skinned = term("nord", "matrix", "app")
        #expect(skinned["background"] == "#000700")
        #expect(skinned["blue"] == "#00ff41")
        #expect(skinned["selectionBackground"] == "#00ff4147")
        // Plain dark and light.
        #expect(term("dark", "none", "app")["background"] == "#0f1117")
        #expect(term("light", "none", "app")["background"] == "#ffffff")
        for k in T.ansiKeys + ["background", "foreground", "cursor", "cursorAccent", "selectionBackground"] {
            #expect(term("gruvbox-light", "none", "app")[k] != nil, "\(k)")
        }
    }
}
