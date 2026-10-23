import Foundation

/// Error returned by the eero cloud API (port of `ApiException`).
public struct ApiError: Error, LocalizedError, Equatable, Sendable {
    public let code: Int
    public let apiError: String
    public let sessionExpired: Bool

    public init(code: Int, error: String, session: Bool) {
        self.code = code
        self.apiError = error
        self.sessionExpired = session && (code == 401 || code == 419)
    }

    public var errorDescription: String? { ApiError.friendly(code, apiError) }
    public var message: String { errorDescription ?? "" }

    static func friendly(_ code: Int, _ error: String) -> String {
        let detail = error.range(of: #"^[a-zA-Z0-9_.-]{1,140}$"#, options: .regularExpression) != nil ? " (\(error))" : ""
        if code == 401 || code == 419 { return "Your code or session was not accepted. Try again or request a new code." + detail }
        if code == 429 { return "eero is limiting requests. Wait a few minutes before trying again." }
        if code == 402 { return "This feature requires an active eero subscription." }
        if code == 403 { return "Your account does not have permission for this action." + detail }
        if code == 404 || code == 405 { return "This feature is not available for this network or API version." }
        if code >= 500 { return "eero's service could not complete the request. Try again later." }
        return "eero rejected the request (\(code))." + detail
    }
}

/// Validation or protocol failure with a user-facing message (stands in for
/// ArgumentException / InvalidDataException / InvalidOperationException).
public struct EeroError: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: Sendable { case invalidArgument, invalidData, invalidOperation, cancelled }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public static func argument(_ m: String) -> EeroError { EeroError(.invalidArgument, m) }
    public static func data(_ m: String) -> EeroError { EeroError(.invalidData, m) }
    public static func operation(_ m: String) -> EeroError { EeroError(.invalidOperation, m) }
    public var errorDescription: String? { message }
}

/// User-facing message for any error (port of `MainWindow.Message`).
public func userMessage(_ error: Error) -> String {
    if let e = error as? ApiError { return e.message }
    if let e = error as? EeroError { return e.message }
    if error is URLError || error is CancellationError { return ConnectionDiagnostics.userMessage(error) }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
