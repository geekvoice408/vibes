#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Lists the internet providers that offer eero single sign-on (port of `SignInService`).
final class SignInService {
    private let transport: HTTPTransport
    init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    func providers() async throws -> JSON {
        var request = URLRequest(url: SignInContracts.providersURL)
        request.timeoutInterval = 30
        let response = try await transport.send(request)
        if !response.isSuccess { throw EeroError.operation("The provider list could not be loaded (HTTP \(response.status)).") }
        if response.body.count > SignInContracts.providersMaxBytes { throw EeroError.data("The provider list exceeded its size limit.") }
        return try JSON.parse(response.body)
    }
}

/// Provider choice dialog (the `Edit("Sign in through your internet provider", …)` form).
struct ProviderChoiceView: View {
    let names: [String]
    let onContinue: (String) -> Void
    let onCancel: () -> Void
    @State private var selection: String

    init(names: [String], onContinue: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.names = names; self.onContinue = onContinue; self.onCancel = onCancel
        _selection = State(initialValue: names.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in through your internet provider").font(.title2.weight(.semibold))
            Text("Choose the provider associated with your eero account. Credentials are entered only on its sign-in page.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Provider", selection: $selection) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Continue") { onContinue(selection) }.keyboardShortcut(.defaultAction).disabled(selection.isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 460, minHeight: 230)
    }
}

extension AppModel {
    /// Port of `ProviderSignIn`: choose an ISP, sign in on its page, then confirm the eero identity it returned.
    func providerSignIn() {
        perform("Loading sign-in providers…") {
            let data = try await SignInService().providers()
            let choices = try SignInContracts.providerChoices(data)
            self.setNotice("")
            self.presentProviderChoice(choices)
        }
    }

    private func presentProviderChoice(_ choices: [String: String]) {
        let flows = WebFlows.shared
        if flows.activate("provider-choice") { return }
        let names = choices.keys.sorted()
        let view = ProviderChoiceView(names: names, onContinue: { [weak self] name in
            flows.window("provider-choice")?.close()
            guard let self, let id = choices[name] else { return }
            do { try self.openProviderBrowser(name, id) }
            catch { self.setNotice(userMessage(error), error: true) }
        }, onCancel: { flows.window("provider-choice")?.close() })
        flows.present(key: "provider-choice", title: "Sign in through your internet provider",
                      size: CGSize(width: 480, height: 250), minSize: CGSize(width: 420, height: 230), content: view)
    }

    private func openProviderBrowser(_ name: String, _ id: String) throws {
        let remember = WebFlows.shared.remember
        let api = self.api
        Task { await api.setRemember(remember) }
        weak var controller: ServiceBrowserController?
        controller = openServiceBrowser("Sign in with " + name, try SignInContracts.providerUrl(id),
                                        callbackMatch: { SignInContracts.ssoReturn($0) },
                                        callback: { [weak self] url in
            guard let self else { return }
            try await self.completeExternalSignIn {
                let candidate = try SignInContracts.returnToken(url)
                let identity = try await self.api.inspectBrowserSession(candidate)
                let verified = identity.account
                try Task.checkCancellation()
                let question = "Continue as " + verified.first("name", "email", "phone") + "?\n" + verified.first("email", "phone")
                if !(await WebFlows.ask(question, window: controller?.window)) { throw EeroError.operation("Sign-in was cancelled.") }
                try await self.api.adopt(identity)
                self.clearData()
                try await self.loadAccount()
                self.screen = .shell
                self.setNotice("Provider sign-in verified with eero.")
            }
        }, providerNavigation: true)
    }
}
#endif
