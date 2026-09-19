import SwiftUI
import AppKit

/// Renders one of the real Teleport resource/app icons (ported from
/// design/ResourceIcon + its ~400 bundled SVGs — see ResourceIconSpecs.generated.swift)
/// via AppKit's native SVG support, picking the dark/light variant to match the current
/// appearance. Falls back to a generic SF Symbol if the name isn't recognized.
///
/// `customFilePath`, when set (from CustomIconStore, a user-uploaded icon), takes priority over
/// the built-in name lookup entirely — there's no dark/light variant for those, just one file.
struct ResourceIconImage: View {
    let name: String
    var customFilePath: String? = nil
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
        if let customFilePath {
            return ResourceIconCache.shared.image(atAbsolutePath: customFilePath)
        }
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
        guard let resourceURL = Bundle.module.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("ResourceIcons").appendingPathComponent(filename)
        return image(atAbsolutePath: url.path, cacheKey: filename)
    }

    /// For user-uploaded custom icons living outside the app bundle (CustomIconStore).
    func image(atAbsolutePath path: String) -> NSImage? {
        image(atAbsolutePath: path, cacheKey: path)
    }

    private func image(atAbsolutePath path: String, cacheKey: String) -> NSImage? {
        if let cached = cache[cacheKey] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        // AppKit sometimes infers isTemplate for vector images, which makes SwiftUI render
        // them as a flat monochrome silhouette in the current tint color instead of their
        // actual colors — force it off so brand icons show their real colors.
        image.isTemplate = false
        cache[cacheKey] = image
        return image
    }

    /// Call after replacing/removing a custom icon so the old cached image doesn't linger.
    func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }
}
