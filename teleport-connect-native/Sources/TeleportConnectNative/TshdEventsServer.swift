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

        /// tshd calls this when MFA is needed (local login's second factor, per-session MFA). The
        /// RPC must stay *pending* while the user completes MFA by whatever route is in progress
        /// (security key/Touch ID handled by tshd itself, or the browser handoff) — tshd races all
        /// of them and cancels this call when another one wins. Returning early would be read as
        /// an (empty) TOTP answer and fail the login. We only return when the user types a TOTP
        /// code, and throw `aborted` if they cancel (tshd then stops waiting on the other routes).
        func promptMFA(
            request: Teleport_Lib_Teleterm_V1_PromptMFARequest,
            context: GRPCCore.ServerContext
        ) async throws -> Teleport_Lib_Teleterm_V1_PromptMFAResponse {
            let waiter = MFAWaiter()
            await MainActor.run { self.model?.beginMFAPrompt(request, waiter: waiter) }
            let outcome = await withTaskCancellationHandler {
                await waiter.wait()
            } onCancel: {
                waiter.finish(.cancelled)
            }
            await MainActor.run { self.model?.endMFAPrompt(waiter: waiter) }

            switch outcome {
            case .code(let code):
                var response = Teleport_Lib_Teleterm_V1_PromptMFAResponse()
                response.totpCode = code
                return response
            case .cancelled:
                throw RPCError(code: .cancelled, message: "MFA prompt was cancelled")
            case .aborted:
                throw RPCError(code: .aborted, message: "MFA was cancelled")
            }
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
            await MainActor.run { self.model?.statusMessage = "Touch your hardware key…" }
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

/// A one-shot rendezvous between the gRPC handler (which must stay suspended) and the UI.
final class MFAWaiter: @unchecked Sendable {
    enum Outcome: Sendable { case code(String), cancelled, aborted }

    private let lock = NSLock()
    private var result: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ outcome: Outcome) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}
