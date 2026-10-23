import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Classifies connection failures into user-facing explanations (port of `ConnectionDiagnostics`).
/// Windows socket/WebException categories are mapped to `URLError` codes and POSIX errno values.
public enum ConnectionDiagnostics {
    /// The error and every `NSUnderlyingErrorKey` beneath it, outermost first.
    static func chain(_ error: Error) -> [Error] {
        var out: [Error] = []
        var current: Error? = error
        while let e = current, out.count < 16 {
            out.append(e)
            let ns = e as NSError
            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return out
    }

    private static func posixCode(_ e: Error) -> Int32? {
        if let p = e as? POSIXError { return p.code.rawValue }
        let ns = e as NSError
        return ns.domain == NSPOSIXErrorDomain ? Int32(truncatingIfNeeded: ns.code) : nil
    }

    private static func urlCode(_ e: Error) -> URLError.Code? {
        if let u = e as? URLError { return u.code }
        let ns = e as NSError
        return ns.domain == NSURLErrorDomain ? URLError.Code(rawValue: ns.code) : nil
    }

    private static func category(posix code: Int32) -> String? {
        switch code {
        case EACCES, EPERM: return "network_access_blocked"
        case ETIMEDOUT: return "timeout"
        case ECONNREFUSED: return "connection_refused"
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN: return "network_unreachable"
        default: return nil
        }
    }

    private static func category(url code: URLError.Code) -> String? {
        switch code {
        case .dataNotAllowed, .internationalRoamingOff, .callIsActive: return "network_access_blocked"
        case .cannotFindHost, .dnsLookupFailed: return "dns_failure"
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return "tls_failure"
        case .timedOut: return "timeout"
        case .cannotConnectToHost: return "connection_refused"
        case .notConnectedToInternet: return "network_unreachable"
        default: return nil
        }
    }

    /// One of network_access_blocked, dns_failure, tls_failure, timeout, connection_refused, network_unreachable or connection_failure.
    public static func category(_ error: Error) -> String {
        let errors = chain(error)
        // The innermost system errno is the most specific signal (like the Windows SocketException), so check it first.
        for e in errors { if let c = posixCode(e), let category = category(posix: c) { return category } }
        for e in errors { if let c = urlCode(e), let category = category(url: c) { return category } }
        if error is CancellationError || urlCode(error) == .cancelled { return "timeout" }
        return "connection_failure"
    }

    /// The most specific system error code in the chain (errno, else the URLError code), or 0.
    public static func nativeCode(_ error: Error) -> Int {
        let errors = chain(error)
        for e in errors { if let c = posixCode(e) { return Int(c) } }
        for e in errors { if let c = urlCode(e) { return c.rawValue } }
        return 0
    }

    public static func userMessage(_ error: Error) -> String {
        switch category(error) {
        case "network_access_blocked":
            return "macOS blocked this app's network access. Check Screen Time content restrictions and any network filter or firewall, then quit and reopen eero Desktop from the Applications folder and try again."
        case "dns_failure": return "macOS could not resolve api-user.e2ro.com. Check your DNS or VPN connection and try again."
        case "tls_failure": return "macOS could not establish a trusted TLS connection to eero. Check the Mac's date, time, and certificate configuration."
        case "timeout": return "The connection to eero timed out. Try again in a moment."
        case "connection_refused": return "The connection to eero was refused. Check whether your proxy or network filter is blocking this app."
        case "network_unreachable": return "macOS reports that eero's network is unreachable. Check your internet or VPN connection."
        default:
            let code = nativeCode(error)
            return "The connection to eero failed" + (code == 0 ? "" : " (macOS error \(code))") + ". Use Check connection for details, or restart the app from the Applications folder."
        }
    }

    /// The JSON report written by the `--connection-test <path>` command-line mode.
    public static func report(transport: HTTPTransport = URLSessionTransport()) async -> (ok: Bool, json: JSON) {
        let api = EeroAPI(store: MemorySessionStore(), transport: transport)
        do {
            try await api.checkConnection()
            return (true, .obj(("ok", true), ("endpoint", EeroAPI.origin),
                               ("result", "HTTPS connection succeeded; eero returned the expected unauthenticated response. No login or verification-code request was made.")))
        } catch {
            return (false, .obj(("ok", false), ("category", category(error)), ("native_code", nativeCode(error)),
                                ("exception_type", String(describing: type(of: error))), ("message", userMessage(error))))
        }
    }

    /// Runs the unauthenticated connection check and writes the JSON report to `path`. Returns the process exit code.
    public static func run(path: String, transport: HTTPTransport = URLSessionTransport()) async -> Int32 {
        let result = await report(transport: transport)
        do { try result.json.serialized().write(toFile: path, atomically: true, encoding: .utf8) } catch { return 1 }
        return result.ok ? 0 : 1
    }
}
