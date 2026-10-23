import Foundation

/// Creates a network and claims a wired gateway eero exactly once (port of `WiredNetworkSetup`).
/// A creation request whose outcome is unknown blocks further attempts until the account is reviewed.
public final class WiredNetworkSetup {
    public private(set) var creationUncertain = false
    public private(set) var createdURL: String?
    private var serial: String?
    private var location: String?

    public init() {}

    public func create(_ api: EeroAPI, _ body: JSON, _ serialNumber: String, _ nodeLocation: String) async throws {
        if createdURL != nil || creationUncertain {
            throw EeroError.operation("A creation request was already sent. Review the network in your account before starting another setup.")
        }
        let serial = try RuntimeContracts.serial(serialNumber)
        try Validation.validateName(nodeLocation)
        self.serial = serial
        location = nodeLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        creationUncertain = true
        let created = try await api.send("POST", "/2.3/networks", body)
        let resource = try EeroAPI.resource(created.s("url"))
        let c = URLComponents(url: resource, resolvingAgainstBaseURL: false)
        let path = c?.percentEncodedPath ?? ""
        if !CoreBPattern.matches(path, #"/2\.[23]/networks/[A-Za-z0-9_-]+"#) || c?.percentEncodedQuery != nil {
            throw EeroError.operation("The server did not return a valid created network. Refresh your account before continuing.")
        }
        createdURL = path
        creationUncertain = false
    }

    @discardableResult
    public func claim(_ api: EeroAPI) async throws -> String {
        guard let destination = createdURL, let serial, let location else { throw EeroError.operation("Create a network first.") }
        try await api.send("POST", "/2.2/eeros?requireSession=true", JSON.obj(("serial", serial), ("location", location), ("network", destination)), form: true)
        createdURL = nil; self.serial = nil; self.location = nil
        return destination
    }
}
