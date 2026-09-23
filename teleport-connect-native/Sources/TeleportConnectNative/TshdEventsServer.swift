import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import TshdProto

/// Serves TshdEventsService — the gRPC service tshd calls INTO us on, over its own Unix domain
/// socket, to ask us to do things outside of a direct RPC response: prompt for MFA (WebAuthn tap,
/// TOTP code, SSO), prompt for a hardware key PIN/touch, show a relogin modal, etc. Electron's
/// tshd_events_service.proto explains why this exists as a separate service: tshd needs to call
/// *back* into the UI mid-request (e.g. during Login, when the cluster requires per-session MFA),
/// which a plain unary request/response can't do.
///
/// Without this, tshd's callback to us just fails outright (nothing was listening), which is what
/// surfaced as "stream unexpectedly closed" when logging in to a cluster that requires a
/// WebAuthn/Touch ID tap after username+password.
final class TshdEventsServer {
    let socketPath: String
    private weak var model: AppModel?

    init(socketPath: String, model: AppModel) {
        self.socketPath = socketPath
        self.model = model
    }

    /// Starts serving and suspends until the socket is actually bound (so the caller can safely
    /// call TerminalService.UpdateTshdEventsServerAddress right after this returns), while the
    /// serve loop itself keeps running in the returned task.
    func start() async throws -> Task<Void, Never> {
        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [Handler(model: model)])
        let serveTask = Task { () -> Void in try? await server.serve() }
        _ = try await transport.listeningAddress
        return serveTask
    }

    /// The actual RPC handlers. A plain (non-actor) type so grpc-swift can dispatch to it freely;
    /// state mutations are always funneled onto the main actor via `model`.
    private final class Handler: Teleport_Lib_Teleterm_V1_TshdEventsService.SimpleServiceProtocol, @unchecked Sendable {
        weak var model: AppModel?
        init(model: AppModel?) { self.model = model }

        func relogin(
            request: Teleport_Lib_Teleterm_V1_ReloginRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_ReloginResponse {
            // Gateways/VNet (the only things that trigger this) aren't implemented, so there's
            // never a legitimate reason for this to fire yet.
            throw RPCError(code: .unimplemented, message: "Relogin is not implemented")
        }

        func sendNotification(
            request: Teleport_Lib_Teleterm_V1_SendNotificationRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_SendNotificationResponse {
            .init()
        }

        func sendPendingHeadlessAuthentication(
            request: Teleport_Lib_Teleterm_V1_SendPendingHeadlessAuthenticationRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_SendPendingHeadlessAuthenticationResponse {
            .init()
        }

        /// tshd calls this during Login when the cluster wants MFA. Per service's doc comment,
        /// our response *chooses* the method: an empty response (no totp_code) means "go ahead
        /// with WebAuthn/SSO"; a filled totp_code means "use TOTP instead". WebAuthn's actual
        /// Touch ID/security key ceremony happens in tshd's own process after we respond — we
        /// just need to acknowledge and show a waiting state.
        func promptMFA(
            request: Teleport_Lib_Teleterm_V1_PromptMFARequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_PromptMFAResponse {
            if request.webauthn {
                await MainActor.run { self.model?.beginMFAWebAuthnWait() }
                return .init()
            }
            if request.totp {
                let code = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    Task { @MainActor in
                        self.model?.beginMFATOTPPrompt { code in
                            continuation.resume(returning: code)
                        }
                    }
                }
                var response = Teleport_Lib_Teleterm_V1_PromptMFAResponse()
                response.totpCode = code
                return response
            }
            throw RPCError(
                code: .failedPrecondition,
                message: "This cluster requires an MFA method (SSO) that Teleport Connect Native doesn't support yet."
            )
        }

        func promptHardwareKeyPIN(
            request: Teleport_Lib_Teleterm_V1_PromptHardwareKeyPINRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_PromptHardwareKeyPINResponse {
            .init()
        }

        /// "When the daemon detects the touch, it cancels the prompt" — so just wait for that
        /// cancellation rather than returning immediately.
        func promptHardwareKeyTouch(
            request: Teleport_Lib_Teleterm_V1_PromptHardwareKeyTouchRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_PromptHardwareKeyTouchResponse {
            await MainActor.run { self.model?.beginMFAWebAuthnWait() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            return .init()
        }

        func promptHardwareKeyPINChange(
            request: Teleport_Lib_Teleterm_V1_PromptHardwareKeyPINChangeRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_PromptHardwareKeyPINChangeResponse {
            .init()
        }

        func confirmHardwareKeySlotOverwrite(
            request: Teleport_Lib_Teleterm_V1_ConfirmHardwareKeySlotOverwriteRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_ConfirmHardwareKeySlotOverwriteResponse {
            var response = Teleport_Lib_Teleterm_V1_ConfirmHardwareKeySlotOverwriteResponse()
            response.confirmed = false
            return response
        }

        func getUsageReportingSettings(
            request: Teleport_Lib_Teleterm_V1_GetUsageReportingSettingsRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_GetUsageReportingSettingsResponse {
            var response = Teleport_Lib_Teleterm_V1_GetUsageReportingSettingsResponse()
            response.usageReportingSettings.enabled = false
            return response
        }

        func reportUnexpectedVnetShutdown(
            request: Teleport_Lib_Teleterm_V1_ReportUnexpectedVnetShutdownRequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_ReportUnexpectedVnetShutdownResponse {
            .init()
        }
    }
}
