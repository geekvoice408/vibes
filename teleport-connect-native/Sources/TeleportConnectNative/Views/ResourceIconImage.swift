import SwiftUI
import AppKit

/// Renders one of the real Teleport resource/app icons (ported from
/// design/ResourceIcon + its ~400 bundled SVGs — see ResourceIconSpecs.generated.swift)
/// via AppKit's native SVG support, picking the dark/light variant to match the current
/// appearance. Falls back to a generic SF Symbol if the name isn't recognized.
struct ResourceIconImage: View {
    let name: String
    var fallbackSymbol: String = "square.grid.2x2.fill"
    var fallbackTint: Color = .purple

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let nsImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 20))
                .foregroundStyle(fallbackTint)
        }
    }

    private var nsImage: NSImage? {
        guard let spec = resourceIconSpecs[name] else { return nil }
        let filename = colorScheme == .dark ? spec.dark : spec.light
        return ResourceIconCache.shared.image(for: filename)
    }
}

/// SVG decoding isn't free; icons repeat constantly across a resource grid, so cache by filename.
@MainActor
final class ResourceIconCache {
    static let shared = ResourceIconCache()
    private var cache: [String: NSImage] = [:]

    func image(for filename: String) -> NSImage? {
        if let cached = cache[filename] { return cached }
        guard let resourceURL = Bundle.module.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("ResourceIcons").appendingPathComponent(filename)
        guard let image = NSImage(contentsOf: url) else { return nil }
        // AppKit sometimes infers isTemplate for vector images, which makes SwiftUI render
        // them as a flat monochrome silhouette in the current tint color instead of their
        // actual colors — force it off so brand icons show their real colors.
        image.isTemplate = false
        cache[filename] = image
        return image
    }
}
