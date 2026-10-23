#if os(macOS)
import Foundation
import SwiftUI
import EeroCore

/// Application state shared by every page (port of the state held by the Windows `MainWindow`).
/// Feature areas add behaviour through `extension AppModel` in their own files.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable { case login(verify: Bool), shell }

    let api: EeroAPI
    let preview: Bool

    @Published var screen: Screen = .login(verify: false)
    @Published var currentPage = "Home"
    @Published var busy = false
    @Published var notice = ""
    @Published var noticeIsError = false

    @Published var account: JSON = .null
    @Published var network: JSON = .null
    @Published var networkURL: String?
    @Published var networkList: [JSON] = []
    @Published var devices: [JSON] = []
    @Published var nodes: [JSON] = []
    @Published var profiles: [JSON] = []
    @Published var loadErrors: [String: String] = [:]
    @Published var lastRefresh = Date()
    /// Per-route data fetched by `loadFeature`, keyed by route (`featureData` in the Windows client).
    @Published var featureData: [String: JSON] = [:]
    @Published var selectedProfile: JSON = .null
    @Published var selectedNode: JSON = .null

    /// Pending confirmation shown by the root view; `confirm` awaits it.
    @Published var confirmation: Confirmation?
    struct Confirmation: Identifiable { let id = UUID(); let message: String; let resume: (Bool) -> Void }

    var resendAfter = Date.distantPast
    var registrationCountry = "US"
    var registrationConsents: JSON = .object([:])

    init(preview: Bool, store: SessionStore? = nil) {
        self.preview = preview
        api = EeroAPI(store: store ?? (preview ? MemorySessionStore() : KeychainSessionStore()))
        if preview { loadSampleData(); screen = .shell }
    }

    // MARK: Status

    func setNotice(_ message: String, error: Bool = false) { notice = message; noticeIsError = error }

    /// Runs an action with a busy indicator and user-facing error reporting (port of `Run`).
    func run(_ status: String = "Working…", _ action: @escaping () async throws -> Void) async {
        if busy { return }
        busy = true
        setNotice(status)
        defer { busy = false }
        do { try await action() }
        catch let ex as ApiError where ex.sessionExpired {
            await api.forget(); clearData(); screen = .login(verify: false)
            setNotice("Your session expired. Sign in again to continue.", error: true)
        }
        catch { setNotice(userMessage(error), error: true) }
    }

    /// Fire-and-forget variant for button handlers.
    func perform(_ status: String = "Working…", _ action: @escaping () async throws -> Void) {
        Task { await run(status, action) }
    }

    func confirm(_ message: String) async -> Bool {
        await withCheckedContinuation { c in confirmation = Confirmation(message: message) { c.resume(returning: $0) } }
    }

    func clearData() {
        account = .null; network = .null; selectedProfile = .null; selectedNode = .null
        networkURL = nil; currentPage = "Home"
        networkList = []; devices = []; nodes = []; profiles = []; loadErrors = [:]; featureData = [:]
        BluetoothScanner.shared.clear()
    }

    // MARK: Loading

    func loadAccount() async throws {
        account = try await api.send("GET", "account")
        networkList = account["networks"].list
        if networkList.isEmpty { networkList = try await api.send("GET", "networks").list }
        networkURL = networkList.first?.s("url").nilIfEmpty
        if networkURL != nil { try await loadNetwork() }
    }

    func resource(_ o: JSON, _ key: String, _ fallback: String) -> String {
        let r = o.get("resources", key)
        let s: String
        if case .string(let v) = r { s = v } else { s = r.s("url") }
        return s.isEmpty ? fallback : s
    }

    func loadNetwork() async throws {
        guard let networkURL, !networkURL.isEmpty else { return }
        if preview { return }
        loadErrors = [:]
        network = try await api.send("GET", networkURL)
        devices = try await loadList("Devices", resource(network, "devices", networkURL + "/devices"))
        nodes = try await loadList("eero nodes", resource(network, "eeros", networkURL + "/eeros"))
        profiles = try await loadList("Profiles", resource(network, "profiles", networkURL + "/profiles"))
        lastRefresh = Date()
    }

    private func loadList(_ name: String, _ url: String) async throws -> [JSON] {
        do { return try await api.send("GET", url).list }
        catch let ex as ApiError { if ex.sessionExpired { throw ex }; loadErrors[name] = ex.message; return [] }
        catch let ex as URLError { loadErrors[name] = userMessage(ex); return [] }
    }

    func selectNetwork(_ url: String) async {
        networkURL = url
        featureData = [:]
        await run("Loading network…") { try await self.loadNetwork() }
    }

    // MARK: Helpers shared by feature pages

    func featureURL(_ suffix: String) throws -> String {
        guard let networkURL, !networkURL.isEmpty else { throw EeroError.operation("Select a network first.") }
        return networkURL.trimmingSuffix("/") + "/" + suffix.drop(while: { $0 == "/" })
    }
    func netResource(_ name: String) throws -> String { resource(network, name, try featureURL(name)) }
    var networkId: String { (networkURL ?? "").trimmingSuffix("/").split(separator: "/").last.map(String.init) ?? "" }

    /// Sends a change and refreshes the network (port of `Mutate`).
    func mutate(_ method: String, _ url: String, _ body: JSON?, success: String) async throws {
        if preview { throw EeroError.operation("Preview mode is read only. Sign in to manage your network.") }
        try await api.send(method, url, body)
        try await loadNetwork()
        setNotice(success)
    }

    func startSpeedTest() async throws {
        if preview { throw EeroError.operation("Preview mode is read only.") }
        guard let networkURL else { throw EeroError.operation("Select a network first.") }
        try await api.send("POST", resource(network, "speedtest", networkURL + "/speedtest"))
        setNotice("Speed test started. Results can take a few minutes. Use Refresh results on the Activity page.")
    }

    func signOut() async {
        await api.logout(); clearData(); screen = .login(verify: false)
    }
}

extension String {
    func trimmingSuffix(_ c: Character) -> String { var s = self; while s.last == c { s.removeLast() }; return s }
}
#endif
