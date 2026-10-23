import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Guardian VPN provider client (port of `GuardianApi`). Never sends eero cookies; only Guardian hosts are reachable.
public struct GuardianAPI: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    @discardableResult
    public func send(_ method: String, _ host: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
        if host != VpnContracts.partnerHost && host != VpnContracts.serverHost { _ = try VpnContracts.gateway(host) }
        if !path.hasPrefix("/api/v1") || path.contains("..") || path.unicodeScalars.contains(where: { $0.value <= 32 })
            || path.contains("#") || path.contains("\\") {
            throw EeroError.argument("Invalid Guardian API path.")
        }
        guard let c = URLComponents(string: "https://" + host + path), let url = c.url,
              c.host == host, host == host.lowercased(), c.port == nil || c.port == 443, c.user == nil, c.password == nil
        else { throw EeroError.argument("Invalid Guardian API host.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 35
        request.setValue(EeroAPI.userAgent, forHTTPHeaderField: "User-Agent")
        if host == VpnContracts.partnerHost { request.setValue(VpnContracts.publishableKey, forHTTPHeaderField: "GRD-Connect-Publishable-Key") }
        if var body {
            if host == VpnContracts.partnerHost, body.object != nil { body["connect-publishable-key"] = .string(VpnContracts.publishableKey) }
            request.httpBody = body.data
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let response = try await transport.send(request)
        try Task.checkCancellation()
        if !response.isSuccess {
            throw EeroError.operation("Guardian could not complete the request (HTTP \(response.status)). Check your benefit eligibility and try again.")
        }
        if response.body.count > 4 * 1024 * 1024 { throw EeroError.data("Guardian returned an oversized response.") }
        let text = response.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([:]) }
        do { return try JSON.parse(response.body) } catch { throw EeroError.data("Guardian returned an unexpected response.") }
    }

    public func regions() async throws -> JSON {
        try await send("GET", VpnContracts.serverHost, "/api/v1.3/servers/all-server-regions/city")
    }

    public func devices(_ credentials: JSON) async throws -> JSON {
        try await send("POST", VpnContracts.partnerHost, "/api/v1.2/partners/subscriber/devices/list", try VpnContracts.subscriber(credentials))
    }

    @discardableResult
    public func removeDevice(_ credentials: JSON, _ uuid: String) async throws -> JSON {
        var body = try VpnContracts.subscriber(credentials)
        body["ep-grd-device-uuid"] = .string(try ExtendedContracts.identifier(uuid))
        return try await send("POST", VpnContracts.partnerHost, "/api/v1.2/partners/subscriber/device/delete", body)
    }

    /// Provisions a WireGuard profile on the least-loaded online server in `region` (port of `CreateProfile`).
    public func createProfile(_ pet: String?, _ region: String, _ privateKey: String, _ publicKey: String) async throws -> JSON {
        guard let pet, !pet.isEmpty else { throw EeroError.operation("Register this Mac first.") }
        let rows = try await send("POST", VpnContracts.serverHost, "/api/v1.3/servers/hostnames-for-region",
                                  JSON.obj(("region", region), ("region-precision", "city"), ("paid", true), ("feature-environment", 0), ("beta-capable", false)))
        let online = rows.list.enumerated().filter { !$0.element.b("offline") }
        func score(_ r: JSON) -> Int { Int32(r.s("capacity-score")).map(Int.init) ?? Int(Int32.max) }
        guard let host = online.min(by: { (score($0.element), $0.offset) < (score($1.element), $1.offset) })?.element else {
            throw EeroError.operation("Guardian did not return an online server for that region.")
        }
        let gateway = try VpnContracts.gateway(host.s("hostname"))
        let credential = try await send("POST", VpnContracts.serverHost, "/api/v1.2/subscriber-credential/create",
                                        JSON.obj(("validation-method", "pe-token"), ("pe-token", pet)))
        let subscriber = credential.s("subscriber-credential")
        if subscriber.isEmpty { throw EeroError.data("Guardian did not return a subscriber credential.") }
        let device = try await send("POST", gateway, "/api/v1.4/device-credentials",
                                    JSON.obj(("subscriber-credential", subscriber), ("transport-protocol", "wireguard"), ("public-key", try VpnContracts.key(publicKey))))
        return try VpnContracts.profile(privateKey, gateway, device)
    }
}
