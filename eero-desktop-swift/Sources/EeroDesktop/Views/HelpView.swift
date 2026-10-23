#if os(macOS)
import SwiftUI
import EeroCore

/// Port of `HelpPage` (route "Help").
@MainActor
struct HelpView: View {
    @ObservedObject var model: AppModel
    @ViewState private var signedIn = false
    @ViewState private var sheet: DashboardSheet? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Subtitle("Help & support")
            HStack(spacing: 8) {
                Button("Official eero support") { model.perform { try model.openServiceWindow("eero support", "https://www.eero.com/support") } }
                SectionLink(title: "Troubleshooting", route: "Settings/Troubleshooting")
                SectionLink(title: "Feature availability", route: "Settings/About")
                SectionLink(title: "Service availability", route: "Help/Service availability")
            }
            if signedIn {
                Button("Account support details") {
                    model.perform {
                        let data = try await model.dashboardRead("/2.2/account/eero_support")
                        sheet = .info("eero support", data)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Chat with eero") { openChat(history: false) }
                Button("Support history") { openChat(history: true) }
            }
            SectionLink(title: "Contact support", route: "Help/Contact support")
            Text("Chat availability depends on your eero account. eero's assistant and a human support conversation are separate services.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
        }
        .task { signedIn = await model.api.signedIn }
        .dashboardSheet($sheet, model: model)
    }

    /// `LocalButton(... OpenChat(history))`: opens the chat window (ConversationArea).
    private func openChat(history: Bool) {
        if model.busy { return }
        do { try model.openChat(history: history) } catch { model.setNotice(userMessage(error), error: true) }
    }
}
#endif
