import Foundation
import XCTest
@testable import EeroCore

/// Platform-neutral parts of `Tests.NativeChecks`: the bundled product photography catalog.
/// (Model-to-image resolution and layout rendering live in the macOS app target and are not testable on Linux.)
final class NativeTests: XCTestCase {
    private var productsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EeroDesktop/Resources/products")
    }

    static let expectedIds = ["eero-gen1", "eero-gen2", "eero-pro", "eero-beacon", "eero-pro-6", "eero-6", "eero-6-extender", "eero-6-plus",
                              "eero-6-plus-extender", "eero-pro-6e", "eero-poe-6", "eero-poe-gateway", "eero-max-7", "eero-7", "eero-pro-7",
                              "eero-outdoor-7", "eero-poe-7", "eero-signal-4g", "eero-signal-5g", "eero-telephone-adapter"]

    func testCompleteProductImageCatalogIsBundled() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: productsDirectory.path).filter { $0.hasSuffix(".png") }
        let ids = files.map { String($0.dropLast(4)) }.sorted()
        XCTAssertEqual(ids, NativeTests.expectedIds.sorted(), "complete 20-variant image catalog is embedded")
        for id in ids {
            let data = try Data(contentsOf: productsDirectory.appendingPathComponent(id + ".png"))
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10], "bundled image loads without network: " + id)
            // PNG IHDR width (big-endian at offset 16) must be at least 100 pixels.
            let width = data.count > 24 ? data[16..<20].reduce(0) { ($0 << 8) | Int($1) } : 0
            XCTAssertGreaterThanOrEqual(width, 100, "bundled image is a usable photograph: " + id)
        }
    }

    func testProductSourcesDocumentEveryImage() throws {
        let sources = try JSON.parse(Data(contentsOf: productsDirectory.appendingPathComponent("sources.json")))
        let listed = sources["products"].list.map { $0.s("id") }
        XCTAssertEqual(Set(listed), Set(NativeTests.expectedIds), "every bundled photograph has a documented source")
        for product in sources["products"].list {
            XCTAssertEqual(product.s("file"), product.s("id") + ".png")
            XCTAssertTrue(product.s("source_url").hasPrefix("https://"), "source recorded for " + product.s("id"))
        }
    }
}
