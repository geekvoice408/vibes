import Foundation

/// Chat request builder and error messages (port of `ConversationContracts`).
public enum ConversationContracts {
    public static func request(_ networkId: String?, _ conversationId: String?, _ message: String?, mcpToken: String? = nil, permission: JSON? = nil, uiEvent: JSON? = nil) throws -> JSON {
        guard let networkId, !networkId.allSatisfy(\.isWhitespace) else { throw EeroError.argument("Select a network before opening chat.") }
        if let message, message.allSatisfy(\.isWhitespace) || message.utf16.count > 8000 {
            throw EeroError.argument("Enter a message of 1–8,000 characters.")
        }
        var body = JSON.obj(("context", JSON.obj(("focused_network_id", networkId), ("client_capabilities", JSON.obj(("opt_in_widgets", JSON.array([])))))))
        if let conversationId, !conversationId.isEmpty { body["conversation_id"] = .string(conversationId) }
        if let message { body["message"] = .string(message) }
        if let mcpToken, !mcpToken.isEmpty { body["mcp_token"] = .string(mcpToken) }
        if let permission { body["permission_grant"] = permission }
        if let uiEvent { body["ui_event"] = uiEvent }
        return body
    }

    public static func error(_ error: Error) -> String {
        if let api = error as? ApiError {
            if api.apiError == "error.conversations.not_available" { return "eero has not enabled chat for this account or network." }
            if api.apiError == "error.conversations.user_blocked" { return "eero has restricted chat access for this account." }
        }
        return userMessage(error)
    }
}
