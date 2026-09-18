import SwiftUI
import AppKit

/// Color tokens ported 1:1 from @gravitational/design-system's Teleport theme
/// (third_party/design-system/colors.ts, fetched from
/// github.com/gravitational/design-system — the canonical source Teleport Connect's
/// Electron UI itself uses), so the native app matches it exactly in both
/// light and dark mode rather than approximating it.
enum Theme {
    // MARK: - levels (window/panel elevation)
    //
    // Originally ported 1:1 from Teleport's own blue-tinted dark theme (navy #0C143D/#222C59/
    // etc.) for strict Electron parity. Swapped to real AppKit system colors instead — the user
    // wanted this to read as a native Mac app rather than carry Teleport's brand tint, and these
    // adapt to Dark Mode (and the light/dark override below) the same way Finder/Mail/Notes do.

    static let levelDeep = Color(nsColor: .underPageBackgroundColor)
    static let levelSunken = Color(nsColor: .underPageBackgroundColor)
    static let levelSurface = Color(nsColor: .windowBackgroundColor)
    static let levelElevated = Color(nsColor: .controlBackgroundColor)
    static let levelPopout = Color(nsColor: .controlBackgroundColor)

    // MARK: - brand / accent

    static let brand = dynamic(light: "#512FC9", dark: "#9F85FF")

    // MARK: - text

    static let textMain = dynamic(light: "#000000", dark: "#FFFFFF")
    static let textSlightlyMuted = dynamicAlpha(base: .black, lightAlpha: 0.72, darkBase: .white, darkAlpha: 0.72)
    static let textMuted = dynamicAlpha(base: .black, lightAlpha: 0.54, darkBase: .white, darkAlpha: 0.54)
    static let textDisabled = dynamicAlpha(base: .black, lightAlpha: 0.36, darkBase: .white, darkAlpha: 0.36)

    // MARK: - interactive.solid

    static let interactivePrimary = dynamic(light: "#512FC9", dark: "#9F85FF")
    static let interactiveSuccess = dynamic(light: "#007D6B", dark: "#00BFA6")
    static let interactiveAccent = dynamic(light: "#0073BA", dark: "#009EFF")
    static let interactiveDanger = dynamic(light: "#CC372D", dark: "#FF6257")
    static let interactiveAlert = dynamic(light: "#FFAB00", dark: "#FFAB00")

    // MARK: - spotBackground (hover/divider tints, aka interactive.tonal.neutral)

    static let spotBackground0 = dynamicAlpha(base: .black, lightAlpha: 0.06, darkBase: .white, darkAlpha: 0.07)
    static let spotBackground1 = dynamicAlpha(base: .black, lightAlpha: 0.13, darkBase: .white, darkAlpha: 0.13)
    static let spotBackground2 = dynamicAlpha(base: .black, lightAlpha: 0.18, darkBase: .white, darkAlpha: 0.18)

    // MARK: - interactive.tonal.primary (pinned/selected card backgrounds)

    static let tonalPrimary0 = dynamicRGBAlpha(lightRGB: (81, 47, 201), lightAlpha: 0.1, darkRGB: (159, 133, 255), darkAlpha: 0.1)
    static let tonalPrimary1 = dynamicRGBAlpha(lightRGB: (81, 47, 201), lightAlpha: 0.18, darkRGB: (159, 133, 255), darkAlpha: 0.18)
    static let tonalPrimary2 = dynamicRGBAlpha(lightRGB: (81, 47, 201), lightAlpha: 0.25, darkRGB: (159, 133, 255), darkAlpha: 0.25)

    // MARK: - buttons.border

    static let buttonBorder = dynamicAlpha(base: .black, lightAlpha: 0.36, darkBase: .white, darkAlpha: 0.36)

    // MARK: - layout constants (web/packages/design/src/theme/themes/sharedStyles.ts)

    /// topBarHeight[1] — the breakpoint TopBar.tsx actually renders at.
    static let topBarHeight: CGFloat = 56
    static let tabHeight: CGFloat = 32
    static let statusBarHeight: CGFloat = 36
    static let space: [CGFloat] = [0, 4, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80]
    static let radiiSmall: CGFloat = 4
    static let radiiMedium: CGFloat = 8

    // MARK: - fonts (web/packages/design/src/theme/fonts.ts)

    /// Electron loads a bundled "Ubuntu2" webfont first; that's not available as a
    /// system font here, so we fall back to San Francisco (-apple-system's actual
    /// resolution), which is what every other font in that stack falls back to anyway.
    static let uiFont = Font.system(size: 13)
    static let uiFontMedium = Font.system(size: 13, weight: .medium)
    static let uiFontSmall = Font.system(size: 12)

    /// getMonoFont() on macOS: Menlo, Monaco, "Courier New", monospace.
    static func monoFont(size: CGFloat = 13) -> Font {
        .custom("Menlo", size: size)
    }

    // MARK: - helpers

    private static func dynamic(light: String, dark: String) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light) ?? .black
        })
    }

    private static func dynamicRGBAlpha(
        lightRGB: (Int, Int, Int), lightAlpha: Double,
        darkRGB: (Int, Int, Int), darkAlpha: Double
    ) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? darkRGB : lightRGB
            let alpha = isDark ? darkAlpha : lightAlpha
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
        })
    }

    private static func dynamicAlpha(base: NSColor, lightAlpha: Double, darkBase: NSColor, darkAlpha: Double) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? darkBase.withAlphaComponent(darkAlpha)
                : base.withAlphaComponent(lightAlpha)
        })
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        guard hexString.count == 6, let rgb = UInt32(hexString, radix: 16) else { return nil }
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
