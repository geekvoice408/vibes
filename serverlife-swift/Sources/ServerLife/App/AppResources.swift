import Foundation

/// Files shipped beside the binary: GUIDE.md, CHANGELOG.md, MCP.md, images.
///
/// In a bundled app they are in Contents/Resources; in a `swift run` build
/// they are read from the repository's Resources directory instead.
enum AppResources {
    static func url(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: nil) { return u }
        let repo = URL(fileURLWithPath: #filePath)            // …/Sources/ServerLife/App/AppResources.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    static func text(_ name: String) -> String {
        guard let u = url(name), let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }

    static var version: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { return v }
        return text("../VERSION").trimmed.nilIfEmpty ?? "0.15.2"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }
}
