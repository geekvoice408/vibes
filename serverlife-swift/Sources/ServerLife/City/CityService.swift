import Foundation

/// main.js's `city:*` handlers: the 3D view's measurements and processes.
/// One walk here, one find|awk on a server; one ps either way.
@MainActor
enum CityService {
    static func scanLocal(_ dir: String) async throws -> CityScanResult {
        try await CityScan.scanLocal(dir)
    }

    static func scanRemote(connId: String, dir: String) async throws -> CityScanResult {
        let r = try await ConnectionManager.shared.exec(connId, CityScan.remoteCommand(dir))
        return try CityScan.parseRemote(r.stdout, dir: dir)
    }

    static func procsLocal() async throws -> [CityProc] {
        try await ProcScan.scanLocal()
    }

    static func procsRemote(connId: String) async throws -> [CityProc] {
        let r = try await ConnectionManager.shared.exec(connId, ProcScan.remoteCommand())
        return ProcScan.parse(r.stdout)
    }

    /// `needsMfaApproval(conn)`: every command on a tsh-for-MFA connection is
    /// one more approval.
    static func needsMfaApproval(_ connId: String?) -> Bool {
        guard let connId, let c = ConnectionManager.shared.connection(connId) else { return false }
        return c.transport == .tsh
    }

    static func isConnected(_ connId: String?) -> Bool {
        guard let connId, let c = ConnectionManager.shared.connection(connId) else { return false }
        return c.state == .connected
    }
}

/// Measurements, per source and directory, shared by every explorer — and
/// the scans in flight, so two explorers on one folder walk it once.
@MainActor
final class CityScans {
    static let shared = CityScans()
    private(set) var results: [String: CityScanResult] = [:]
    private var inflight: [String: Task<CityScanResult, Error>] = [:]

    func cached(_ key: String) -> CityScanResult? { results[key] }
    func forget(_ key: String) { results.removeValue(forKey: key) }

    func measure(_ key: String, _ work: @escaping @MainActor () async throws -> CityScanResult) async throws -> CityScanResult {
        let t: Task<CityScanResult, Error>
        if let existing = inflight[key] { t = existing } else {
            t = Task { @MainActor in try await work() }
            inflight[key] = t
        }
        defer { if inflight[key] == t { inflight.removeValue(forKey: key) } }
        let r = try await t.value
        results[key] = r
        return r
    }
}
