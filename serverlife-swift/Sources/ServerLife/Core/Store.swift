import Foundation
import Observation
import Security

/// Persistent state: the port of `src/main/store.js`.
///
/// The document is the Electron app's `sessions.json`, field for field, held
/// as `JSON` so the file stays interchangeable with the original app (and an
/// existing one is imported on first launch). Feature code reads and writes it
/// through typed accessors declared in its own files:
///
/// ```swift
/// extension Store {
///     var mfaMode: String {
///         get { setting("mfaMode", "platform") }
///         set { setSetting("mfaMode", newValue) }
///     }
/// }
/// ```
///
/// Writes are atomic (tmp + rename) and debounced by 250 ms, as in store.js.
/// No secrets are ever stored here.
@MainActor
@Observable
final class Store {
    static let shared = Store()

    /// `~/Library/Application Support/ServerLife-Swift`. Separate from the
    /// Electron app's directory so the two can run side by side without
    /// overwriting each other; the original is imported once on first run.
    @ObservationIgnored let dir: URL
    @ObservationIgnored let file: URL

    /// Everything except `settings`.
    private(set) var data: JSON = .object([:])
    /// The `settings` object. Kept apart from `data` so views that only read
    /// settings are not invalidated by history or transfer bookkeeping.
    private(set) var settings: JSON = .object([:])

    /// Fires after every successful save (store.js emitted 'saved').
    @ObservationIgnored var onSaved: [() -> Void] = []
    /// Fires on every settings change (store.js emitted 'changed').
    @ObservationIgnored var onSettingsChanged: [() -> Void] = []

    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private(set) var loaded = false

    static let defaults: JSON = {
        var d = (try? JSON.parse(StoreDefaults.json)) ?? .object([:])
        d["settings"]["defaultLocalPath"] = .string(NSHomeDirectory())
        return d
    }()

    init(dir: URL? = nil) {
        let override = CommandLine.arguments.firstIndex(of: "--data-dir").flatMap {
            $0 + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil
        }
        // Under the test runner the shared store must never touch the user's
        // real sessions.json: give it a throwaway directory.
        let testing = Bundle.main.bundlePath.hasSuffix(".xctest")
            || ProcessInfo.processInfo.processName.contains("PackageTests")
            || ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || CommandLine.arguments.contains { $0.contains(".xctest") }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let testDir = testing ? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("serverlife-tests-\(ProcessInfo.processInfo.processIdentifier)") : nil
        let base = dir ?? override ?? testDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerLife-Swift", isDirectory: true)
        self.dir = base
        self.file = base.appendingPathComponent("sessions.json")
        var d = Store.defaults
        settings = d["settings"]
        d.removeKey("settings")
        data = d
    }

    /// The Electron app's data file, offered as a one-time import.
    static var electronStoreFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerLife/sessions.json")
    }

    // MARK: - Load / save

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: file.path), !file.path.contains("serverlife-tests-"),
           fm.fileExists(atPath: Store.electronStoreFile.path) {
            try? fm.copyItem(at: Store.electronStoreFile, to: file)
        }
        var parsed: JSON = .null
        if fm.fileExists(atPath: file.path) {
            // Anything that exists but cannot be read or parsed is kept aside
            // (store.js: `.corrupt-<ms>`) rather than overwritten by the next save.
            if let raw = try? Data(contentsOf: file), let p = try? JSON.parse(raw), p.object != nil {
                parsed = p
            } else {
                let aside = file.path + ".corrupt-\(Int(Date().timeIntervalSince1970 * 1000))"
                if rename(file.path, aside) != 0 { try? fm.copyItem(atPath: file.path, toPath: aside) }
            }
        }
        apply(parsed: parsed)
        loaded = true
    }

    /// Merge a parsed document over the defaults the way store.js `load()` does.
    func apply(parsed: JSON) {
        var d = Store.defaults
        var s = d["settings"]
        if let p = parsed.object {
            for (k, v) in p where k != "settings" { d[k] = v }
            s.merge(parsed["settings"])
        }
        // Arrays that must be arrays, whatever an older or damaged file held.
        for key in ["profiles", "folders", "history", "layouts", "snippets", "requestTemplates", "tshLogins",
                    "downloads", "sessionNotes", "forwardFavorites", "netRequests", "netRuns", "execRuns",
                    "macros", "hiddenMacros", "macroPins", "macroCategoryOrder", "s3Targets"] where d[key].array == nil {
            d[key] = .array([])
        }
        // A file written before multi-window has only `workspace`; lift it into slot w1.
        if parsed["workspaces"].object == nil {
            if parsed["workspace"].truthy {
                var w = parsed["workspace"]; w["slot"] = "w1"
                d["workspaces"] = .object(["w1": w])
            } else {
                d["workspaces"] = .object([:])
            }
        }
        d.removeKey("settings")
        data = d
        settings = s
    }

    /// The whole document as written to disk.
    var document: JSON {
        var d = data
        d["settings"] = settings
        return d
    }

    /// Debounced atomic save.
    func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = file.appendingPathExtension("tmp")
        let bytes = Data(document.jsText(indent: 2).utf8)
        do {
            try bytes.write(to: tmp)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            // rename(2) replaces the file in one step: there is never a moment
            // with no sessions.json on disk.
            guard rename(tmp.path, file.path) == 0 else {
                throw AppError("rename failed: \(String(cString: strerror(errno)))")
            }
            onSaved.forEach { $0() }
        } catch {
            NSLog("ServerLife: could not save store: \(error)")
        }
    }

    // MARK: - Top-level collections

    subscript(key: String) -> JSON {
        get { data[key] }
        set { data[key] = newValue; save() }
    }

    /// Decode a top-level array into Codable records, skipping ones that do not fit.
    func list<T: Decodable>(_ key: String, as type: T.Type = T.self) -> [T] {
        data[key].items.compactMap { $0.decode(T.self) }
    }

    func setList<T: Encodable>(_ key: String, _ items: [T]) {
        data[key] = .array(items.map { JSON.encode($0) })
        save()
    }

    /// Mutate a top-level value in place and save.
    func mutate(_ key: String, _ body: (inout JSON) -> Void) {
        var v = data[key]
        body(&v)
        data[key] = v
        save()
    }

    // MARK: - Settings

    func setting<T: Decodable>(_ key: String, _ fallback: T) -> T {
        let v = settings[key]
        if v.isNull { return fallback }
        if let s = v as? T { return s }
        return v.decode(T.self) ?? fallback
    }

    func settingJSON(_ key: String) -> JSON { settings[key] }

    func setSetting<T: Encodable>(_ key: String, _ value: T) {
        updateSettings([key: JSON.encode(value)])
    }

    func setSettingJSON(_ key: String, _ value: JSON) {
        updateSettings([key: value])
    }

    /// Shallow-merge a patch into settings (store.js `updateSettings`).
    func updateSettings(_ patch: [String: JSON]) {
        var s = settings
        for (k, v) in patch { s[k] = v }
        settings = s
        save()
        onSettingsChanged.forEach { $0() }
    }

    /// Mutate one settings value in place (for maps such as hostColors).
    func mutateSetting(_ key: String, _ body: (inout JSON) -> Void) {
        var v = settings[key]
        body(&v)
        updateSettings([key: v])
    }
}

/// `newId('p')` from store.js: a prefix and 12 hex characters.
func newId(_ prefix: String = "p") -> String {
    var bytes = [UInt8](repeating: 0, count: 6)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return prefix + "_" + bytes.map { String(format: "%02x", $0) }.joined()
}

/// Milliseconds since the epoch, the timestamp format every record in the
/// store uses (JavaScript `Date.now()`).
func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }
