import SwiftUI

/// Stand-in for design/ResourceIcon's large library of per-app SVG icons (guessAppIcon.ts
/// matches on name/label keywords against hundreds of brand icons) — replicating that exactly
/// would mean shipping that whole icon set. This maps each resource kind to an SF Symbol and a
/// brand-ish tint so cards are still visually distinct and legible, not because it's a full
/// substitute for the real icon set.
enum ResourceIconStyle {
    static func symbol(for kind: ResourceKind) -> String {
        switch kind {
        case .server: "server.rack"
        case .database: "cylinder.fill"
        case .kube: "square.stack.3d.up.fill"
        case .app: "square.grid.2x2.fill"
        case .windowsDesktop: "display"
        }
    }

    static func tint(for kind: ResourceKind) -> Color {
        switch kind {
        case .server: .blue
        case .database: .teal
        case .kube: .indigo
        case .app: .purple
        case .windowsDesktop: .cyan
        }
    }
}
