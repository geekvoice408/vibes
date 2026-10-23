#if os(macOS)
import AppKit
import SwiftUI

/// Semantic colour tokens (port of the `ApplyTheme` palette in Theme.cs and `UiPreferences.Color`).
///
/// Every token resolves against the effective appearance of the view that draws it, so it follows
/// `UiPreferences.theme` (System / Light / Dark), which is applied app-wide through `NSApp.appearance`.
///
/// Usage: `.foregroundStyle(Palette.muted)`, `.background(Palette.surface)`.
enum Palette {
    /// Window/page background (`Page`).
    static let page = dynamic(0xF7F7F7, 0x1C1C1E)
    /// Sidebar / login intro background (`#F3F3F3`).
    static let rail = dynamic(0xF3F3F3, 0x202022)
    /// Card surface (`Surface`).
    static let surface = dynamic(0xFFFFFF, 0x272729)
    /// Text field / input surface (`Input`).
    static let input = dynamic(0xFFFFFF, 0x2D2D30)
    /// Primary text (`Text`).
    static let text = dynamic(0x202445, 0xF3F3F5)
    /// Secondary text and captions (`Muted`).
    static let muted = dynamic(0x646879, 0xB2B3BD)
    /// Borders and separators (`Edge`).
    static let edge = dynamic(0xE1E1E5, 0x3D3D42)
    /// Brand accent (`Accent`).
    static let accent = dynamic(0x0057FF, 0x82AAFF)
    /// Text drawn on top of `accent` (`AccentText`).
    static let accentText = dynamic(0xFFFFFF, 0x111826)
    /// Soft accent background, e.g. selected rows (`Soft`).
    static let soft = dynamic(0xEAF0FF, 0x28364E)
    /// Hover background (`Hover`).
    static let hover = dynamic(0xF0F0F3, 0x323235)
    /// Disabled foreground (`Disabled`).
    static let disabled = dynamic(0x9496A0, 0x777780)
    /// Scroll thumb (`Thumb`).
    static let thumb = dynamic(0xB7B8C2, 0x616169)
    /// Online / success text (`#0D7959`).
    static let success = dynamic(0x007D68, 0x65D3B5)
    /// Online badge background (`#E4F5EE`).
    static let successSoft = dynamic(0xE4F5EE, 0x193D34)
    /// Warning text (`#926410`).
    static let warning = dynamic(0x8B5A0A, 0xF0C079)
    /// Error text (`#B5333D`).
    static let error = dynamic(0xB22D3B, 0xFFA4AC)
    /// Informational banner background (`#EEF3FF`).
    static let info = dynamic(0xEDF2FF, 0x28364E)

    /// The colour a legacy page hex from the Windows client maps to (port of `UiPreferences.Color`).
    /// Unknown colours are used as-is in both appearances.
    static func legacy(_ hex: String) -> Color {
        if let pair = legacyPair(hex) { return dynamic(pair.light, pair.dark) }
        let v = parseHex(hex) ?? 0x000000
        return dynamic(v, v)
    }

    /// Light/dark pair for a legacy Windows page colour, or nil when it is not part of the palette.
    static func legacyPair(_ hex: String) -> (light: UInt32, dark: UInt32)? {
        switch hex.uppercased() {
        case "#17263C", "#E5ECF8": return (0x202445, 0xF3F3F5)
        case "#64738A", "#52647C", "#A3B2CC": return (0x646879, 0xB2B3BD)
        case "#F4F6FA", "#101A2B": return (0xF7F7F7, 0x1C1C1E)
        case "#F3F3F3": return (0xF3F3F3, 0x202022)
        case "#19253A": return (0xFFFFFF, 0x272729)
        case "#E5EAF3", "#D6DFEC", "#34425B": return (0xE1E1E5, 0x3D3D42)
        case "#274CDB", "#345BEB", "#9BB4FF": return (0x0057FF, 0x82AAFF)
        case "#0D7959": return (0x007D68, 0x65D3B5)
        case "#E4F5EE": return (0xE4F5EE, 0x193D34)
        case "#926410": return (0x8B5A0A, 0xF0C079)
        case "#B5333D": return (0xB22D3B, 0xFFA4AC)
        case "#EEF3FF", "#233654": return (0xEDF2FF, 0x28364E)
        case "#152137": return (0xFFFFFF, 0x2D2D30)
        default: return nil
        }
    }

    /// A fixed (appearance-independent) colour from `0xRRGGBB`.
    static func fixed(_ rgb: UInt32) -> Color { Color(nsColor: nsColor(rgb)) }

    /// A colour that switches between `light` and `dark` (`0xRRGGBB`) with the effective appearance.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        })
    }

    static func nsColor(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func parseHex(_ hex: String) -> UInt32? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }
}
#endif
