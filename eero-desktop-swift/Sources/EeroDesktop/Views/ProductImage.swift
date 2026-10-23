#if os(macOS)
import SwiftUI
import AppKit
import EeroCore

/// Port of `ProductImages` (ProductImages.cs): maps eero hardware codes / model names to the bundled
/// product photos in `Resources/products` (see sources.json for provenance).
@MainActor
enum ProductImages {
    // Prefixes cover regional/channel variants documented by eero. Match the
    // hardware code first; a display label must never override a known model.
    // Ordered exactly like the Windows dictionary, which is enumerated in insertion order.
    static let codes: [(String, String)] = [
        ("A01", "eero-gen1"), ("B01", "eero-pro"), ("D01", "eero-beacon"), ("J01", "eero-gen2"),
        ("K01", "eero-pro-6"), ("N01", "eero-6"), ("Q01", "eero-6-extender"), ("R01", "eero-6-plus"),
        ("S01", "eero-pro-6e"), ("T01", "eero-poe-6"), ("U01", "eero-poe-gateway"), ("V01", "eero-max-7"),
        ("PA1", "eero-7"), ("ME1", "eero-pro-7"), ("SN1", "eero-outdoor-7"), ("NV01", "eero-poe-7"),
        ("RG4", "eero-signal-4g"), ("RG5", "eero-signal-5g"), ("FH01", "eero-telephone-adapter"),
    ]
    static let names: [String: String] = [
        "eeromax7": "eero-max-7", "eeropro7": "eero-pro-7", "eero7": "eero-7", "eerooutdoor7": "eero-outdoor-7",
        "eeropoe7": "eero-poe-7", "eeropoe6": "eero-poe-6", "eeropoegateway": "eero-poe-gateway",
        "eeropro6e": "eero-pro-6e", "eeropro6": "eero-pro-6", "eero6+": "eero-6-plus", "eero6plus": "eero-6-plus",
        "eero6+extender": "eero-6-plus-extender", "eero6plusextender": "eero-6-plus-extender",
        "eero6extender": "eero-6-extender", "eero6": "eero-6", "eerobeacon": "eero-beacon",
        "eeropro": "eero-pro", "eeropro2ndgen": "eero-pro", "eero1stgen": "eero-gen1", "eero1stgeneration": "eero-gen1",
        "eero2ndgen": "eero-gen2", "eero2ndgeneration": "eero-gen2", "eerosignal4glte": "eero-signal-4g",
        "eerosignal4g": "eero-signal-4g", "eerosignal5g": "eero-signal-5g",
        "eerotelephoneadapter": "eero-telephone-adapter", "eerofh01": "eero-telephone-adapter",
    ]
    private static var cache: [String: NSImage] = [:]

    private static func matches(_ normalized: String, _ key: String) -> Bool {
        normalized.hasPrefix(key) && normalized.count >= key.count + (key.count == 4 ? 0 : 1)
    }

    /// Port of `Resolve(model, code)`: the product image id, or nil when unknown.
    static func resolve(model: String?, code: String?) -> String? {
        let normalized = (code ?? "").replacingOccurrences(of: "[^a-zA-Z0-9]", with: "", options: .regularExpression).uppercased()
        for (key, id) in codes where matches(normalized, key) { return id }
        let name = (model ?? "").replacingOccurrences(of: "[\\s_()\\-]", with: "", options: .regularExpression).lowercased()
        if let id = names[name] { return id }
        // Some API versions put the hardware number in the model field.
        let modelCode = (model ?? "").replacingOccurrences(of: "[^a-zA-Z0-9]", with: "", options: .regularExpression).uppercased()
        let shaped = modelCode.range(of: "^[A-Z]{1,2}[0-9][A-Z0-9]{1,6}$", options: .regularExpression) != nil
        for (key, id) in codes where matches(modelCode, key) && shaped { return id }
        return nil
    }

    /// Port of `Resolve(node)`.
    static func resolve(_ node: JSON) -> String? {
        resolve(model: node.first("model", "model_name", "product_name"), code: node.first("model_number", "model_code", "hardware_model"))
    }

    /// Port of `Load`: the bundled image for an id.
    static func load(_ id: String?) -> NSImage? {
        guard let id, !id.isEmpty else { return nil }
        if let image = cache[id] { return image }
        guard let url = AppResources.bundle.url(forResource: id, withExtension: "png", subdirectory: "products"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[id] = image
        return image
    }

    /// The bundled image for a model name (and optional hardware code).
    static func image(forModel model: String, code: String = "") -> NSImage? { load(resolve(model: model, code: code)) }

    /// The bundled image for an eero JSON object.
    static func image(for node: JSON) -> NSImage? { load(resolve(node)) }

    /// Port of `Ids`: every bundled product image id, sorted.
    static var ids: [String] {
        guard let dir = AppResources.bundle.url(forResource: "products", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }.sorted()
    }
}

/// Port of `HardwareImage`: the product photo for an eero, or a generic router symbol.
@MainActor
struct ProductImage: View {
    let node: JSON
    var size: CGFloat = 54

    var body: some View {
        let label = node.first("model", "model_name", "product_name")
        if let image = ProductImages.image(for: node) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .help(label)
                .accessibilityLabel("Product image: " + label)
        } else {
            Image(systemName: "wifi.router")
                .font(.system(size: size * 0.5))
                .foregroundStyle(Palette.muted)
                .frame(width: size, height: size)
        }
    }
}

/// Port of `ProductGalleryPage` (route "Product gallery").
@MainActor
struct ProductGalleryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Subtitle("Bundled manufacturer imagery · matched by hardware number or model name.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(ProductImages.ids, id: \.self) { id in
                    Card(padding: 16) {
                        if let image = ProductImages.load(id) {
                            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                .frame(width: 110, height: 90)
                                .frame(maxWidth: .infinity)
                        }
                        Text(id).font(.system(size: 12))
                    }
                }
            }
        }
    }
}
#endif
