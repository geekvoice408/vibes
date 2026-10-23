#if os(macOS)
import SwiftUI
import EeroCore

/// "Home/Chat" and "Help/Support history" pages (port of `ChatPage`).
enum ConversationArea: FeatureArea {
    static let routes = ["Home/Chat", "Help/Support history"]

    static func handles(_ route: String) -> Bool { routes.contains(route) }

    static func load(_ route: String, model: AppModel) async throws -> JSON? { nil }

    static func view(_ route: String, model: AppModel) -> AnyView {
        AnyView(ChatPage(model: model, history: route == "Help/Support history"))
    }
}

private struct ChatPage: View {
    @ObservedObject var model: AppModel
    let history: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(history ? "Support history" : "Chat with eero").font(.system(size: 22, weight: .semibold))
            Text("Ask eero about your network, review previous conversations and respond to requested changes. Availability is controlled by eero for your account, region and network.")
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            HStack {
                Button(history ? "Open support history" : "Open chat") { model.openConversation(history: history) }
                Button("Official support") { model.openServiceLink("eero support", "https://www.eero.com/support") }
            }
            Button("Chat with Alexa on the web") { model.openServiceLink("Alexa", "https://alexa.com/") }
            Text("Alexa opens in its own window. Available features depend on your Amazon account and region.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AppModel {
    /// Opens the chat window, or brings an open one forward (port of `OpenChat`).
    func openChat(history: Bool = false) throws {
        guard let networkURL, !networkURL.isEmpty else {
            throw EeroError.operation("Select a network before opening chat or its support history.")
        }
        let flows = WebFlows.shared
        if flows.activate("conversation") { return }
        let controller = ConversationController(api: api, networkId: networkId, networkName: network.s("name"), sample: preview, showHistory: history)
        presentConversation(controller)
    }

    /// Button-friendly `openChat` that reports failures in the status bar. Used by Help & support
    /// ("Chat with eero" / "Support history") and the chat pages.
    func openConversation(history: Bool = false) {
        do { try openChat(history: history) }
        catch { setNotice(userMessage(error), error: true) }
    }

    /// Opens a sample chat window without any account request (port of `ChatSample`, `--chat-preview`).
    static func chatSample() {
        let controller = ConversationController(api: nil, networkId: "sample-network", networkName: "Sample home", sample: true, showHistory: false)
        presentConversation(controller)
    }

    /// `openServiceWindow` for button handlers.
    func openServiceLink(_ title: String, _ url: String) {
        do { try openServiceWindow(title, url) }
        catch { setNotice(userMessage(error), error: true) }
    }
}

@MainActor
private func presentConversation(_ controller: ConversationController) {
    let window = WebFlows.shared.present(key: "conversation", title: "Chat with eero · " + controller.networkName,
                                         size: CGSize(width: 960, height: 820), minSize: CGSize(width: 700, height: 620),
                                         onClose: { controller.didClose() }, content: ConversationView(controller: controller))
    controller.window = window
}
#endif
