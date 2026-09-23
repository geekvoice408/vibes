import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import TshdProto

/// A connected gRPC client to tshd's TerminalService, talking over a Unix domain socket
/// with no TLS — the same transport Teleport Connect's Electron app uses on macOS
/// (see web/packages/teleterm/src/services/grpcCredentials/credentials.ts:68-74).
public final class TshdClient: Sendable {
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    public let terminal: Teleport_Lib_Teleterm_V1_TerminalService.Client<HTTP2ClientTransport.Posix>

    public init(socketPath: String) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let client = GRPCClient(transport: transport)
        self.grpcClient = client
        self.terminal = Teleport_Lib_Teleterm_V1_TerminalService.Client(wrapping: client)
    }

    /// Runs the underlying connection. Must be called concurrently with any RPCs (e.g. from a
    /// task group) — RPCs will wait for the connection to become ready.
    public func run() async throws {
        try await grpcClient.runConnections()
    }

    public func shutdown() {
        grpcClient.beginGracefulShutdown()
    }

    /// Must be called before any other RPC on this service — see service.proto's doc comment
    /// on UpdateTshdEventsServerAddress. `address` should look like `unix:///path/to/socket`,
    /// matching the scheme tshd's own `--addr` flag uses.
    public func updateTshdEventsServerAddress(_ address: String) async throws {
        var request = Teleport_Lib_Teleterm_V1_UpdateTshdEventsServerAddressRequest()
        request.address = address
        _ = try await terminal.updateTshdEventsServerAddress(
            request: ClientRequest(message: request)
        )
    }

    public func listRootClusters() async throws -> Teleport_Lib_Teleterm_V1_ListClustersResponse {
        try await terminal.listRootClusters(
            request: ClientRequest(message: Teleport_Lib_Teleterm_V1_ListClustersRequest())
        )
    }

    public func getCluster(clusterURI: String) async throws -> Teleport_Lib_Teleterm_V1_Cluster {
        var request = Teleport_Lib_Teleterm_V1_GetClusterRequest()
        request.clusterUri = clusterURI
        return try await terminal.getCluster(request: ClientRequest(message: request))
    }

    public func getAuthSettings(clusterURI: String) async throws -> Teleport_Lib_Teleterm_V1_AuthSettings {
        var request = Teleport_Lib_Teleterm_V1_GetAuthSettingsRequest()
        request.clusterUri = clusterURI
        return try await terminal.getAuthSettings(request: ClientRequest(message: request))
    }

    /// Blocks until the SSO browser flow completes (tshd opens the browser itself) or fails.
    public func loginSSO(clusterURI: String, providerType: String, providerName: String) async throws {
        var request = Teleport_Lib_Teleterm_V1_LoginRequest()
        request.clusterUri = clusterURI
        var sso = Teleport_Lib_Teleterm_V1_LoginRequest.SsoParams()
        sso.providerType = providerType
        sso.providerName = providerName
        request.params = .sso(sso)
        _ = try await terminal.login(request: ClientRequest(message: request))
    }

    public func loginLocal(clusterURI: String, username: String, password: String, otpToken: String = "") async throws {
        var request = Teleport_Lib_Teleterm_V1_LoginRequest()
        request.clusterUri = clusterURI
        var local = Teleport_Lib_Teleterm_V1_LoginRequest.LocalParams()
        local.user = username
        local.password = password
        local.token = otpToken
        request.params = .local(local)
        _ = try await terminal.login(request: ClientRequest(message: request))
    }

    /// A step in the passwordless (WebAuthn/hardware-key) login flow — mirrors the prompt
    /// sequence documented on the LoginPasswordless RPC: tshd itself watches for the physical
    /// tap via the platform's WebAuthn library, so `.tap`/`.retap` are informational only;
    /// `.pin` and `.credentials` need a response written back into the same stream.
    public enum PasswordlessEvent: Sendable {
        case tap
        case retap
        case pin(respond: @Sendable (String) -> Void)
        case credentials(usernames: [String], respond: @Sendable (Int) -> Void)
    }

    /// Drives the bidirectional LoginPasswordless RPC: sends Init immediately, then forwards
    /// each server prompt to `onEvent` and writes back whatever the caller responds with (PIN
    /// digits, or the index of a chosen credential) via the closures in `PasswordlessEvent`.
    /// Returns once the server closes the stream (successful login) or throws on failure.
    public func loginPasswordless(
        clusterURI: String,
        onEvent: @escaping @Sendable (PasswordlessEvent) -> Void
    ) async throws {
        let (outgoing, continuation) = AsyncStream<Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest>.makeStream()

        var initRequest = Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest()
        var initParams = Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest.LoginPasswordlessRequestInit()
        initParams.clusterUri = clusterURI
        initRequest.request = .init_p(initParams)
        continuation.yield(initRequest)

        let request = StreamingClientRequest<Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest>(producer: { writer in
            for await message in outgoing {
                try await writer.write(message)
            }
        })

        try await terminal.loginPasswordless(request: request) { response in
            defer { continuation.finish() }
            switch response.accepted {
            case .success(let contents):
                var hasTapped = false
                for try await part in contents.bodyParts {
                    guard case .message(let message) = part else { continue }
                    switch message.prompt {
                    case .tap:
                        onEvent(hasTapped ? .retap : .tap)
                        hasTapped = true
                    case .pin:
                        onEvent(.pin(respond: { pin in
                            var req = Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest()
                            var pinResponse = Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest.LoginPasswordlessPINResponse()
                            pinResponse.pin = pin
                            req.request = .pin(pinResponse)
                            continuation.yield(req)
                        }))
                    case .credential:
                        let usernames = message.credentials.map(\.username)
                        onEvent(.credentials(usernames: usernames, respond: { index in
                            var req = Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest()
                            var credResponse = Teleport_Lib_Teleterm_V1_LoginPasswordlessRequest.LoginPasswordlessCredentialResponse()
                            credResponse.index = Int64(index)
                            req.request = .credential(credResponse)
                            continuation.yield(req)
                        }))
                    case .unspecified, .UNRECOGNIZED:
                        break
                    }
                }
            case .failure(let error):
                throw error
            }
        }
    }

    public func logout(clusterURI: String, removeProfile: Bool = false) async throws {
        var request = Teleport_Lib_Teleterm_V1_LogoutRequest()
        request.clusterUri = clusterURI
        request.removeProfile = removeProfile
        _ = try await terminal.logout(request: ClientRequest(message: request))
    }

    public func addCluster(proxyAddress: String) async throws -> Teleport_Lib_Teleterm_V1_Cluster {
        var request = Teleport_Lib_Teleterm_V1_AddClusterRequest()
        request.name = proxyAddress
        return try await terminal.addCluster(request: ClientRequest(message: request))
    }

    public func listUnifiedResources(
        clusterURI: String,
        search: String = "",
        limit: Int32 = 100
    ) async throws -> Teleport_Lib_Teleterm_V1_ListUnifiedResourcesResponse {
        var request = Teleport_Lib_Teleterm_V1_ListUnifiedResourcesRequest()
        request.clusterUri = clusterURI
        request.search = search
        request.limit = limit
        return try await terminal.listUnifiedResources(request: ClientRequest(message: request))
    }
}
