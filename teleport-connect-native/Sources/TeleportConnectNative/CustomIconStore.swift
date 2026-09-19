import Foundation

/// Persists user-uploaded custom icons, keyed by lowercased resource name (same keying
/// convention as customResourceIconSpecs) so a custom icon applies to any resource with that
/// name, consistent with how every other icon override in this app works. Survives restarts:
/// the mapping is a JSON file, and uploaded icon files are copied into their own directory
/// rather than referenced in place (the original file could move or be deleted).
struct CustomIconStore {
    private let directory: URL
    private let mappingFile: URL

    init() {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TeleportConnectNative/CustomIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.directory = supportDir
        self.mappingFile = supportDir.appendingPathComponent("mapping.json")
    }

    func loadMapping() -> [String: String] {
        guard let data = try? Data(contentsOf: mappingFile),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return mapping
    }

    private func saveMapping(_ mapping: [String: String]) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        try? data.write(to: mappingFile, options: .atomic)
    }

    /// Copies `sourceFile` into the store and records it under `resourceName` (lowercased).
    /// Returns the absolute path it was copied to, or nil if the copy failed.
    func setIcon(forResourceName resourceName: String, sourceFile: URL) -> String? {
        let key = resourceName.lowercased()
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(sourceFile.pathExtension)")
        do {
            try FileManager.default.copyItem(at: sourceFile, to: destination)
        } catch {
            return nil
        }

        var mapping = loadMapping()
        if let oldPath = mapping[key] {
            try? FileManager.default.removeItem(atPath: oldPath)
        }
        mapping[key] = destination.path
        saveMapping(mapping)
        return destination.path
    }

    func removeIcon(forResourceName resourceName: String) {
        let key = resourceName.lowercased()
        var mapping = loadMapping()
        if let path = mapping.removeValue(forKey: key) {
            try? FileManager.default.removeItem(atPath: path)
        }
        saveMapping(mapping)
    }
}
