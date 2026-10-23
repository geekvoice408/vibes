#if os(macOS)
import SwiftUI
import EeroCore

/// Top-level content of the main window: the sign-in screens or the signed-in shell, plus the shared
/// confirmation dialog (port of `ShowLogin` / `ShowShell` and `Confirm`).
@MainActor
struct RootView: View {
    @ObservedObject var model: AppModel
    @ViewState private var started = false

    var body: some View {
        Group {
            switch model.screen {
            case .login(let verify): LoginView(model: model, verify: verify)
            case .shell: ShellView(model: model)
            }
        }
        .environmentObject(model)
        .foregroundStyle(Palette.text)
        .background(Palette.page)
        .alert("Confirm change", isPresented: confirmationShown, presenting: model.confirmation) { _ in
            Button("Cancel", role: .cancel) { resolve(false) }
            Button("Continue") { resolve(true) }
        } message: { c in
            Text(c.message)
        }
        .task { await start() }
    }

    /// The alert stays up while a confirmation is pending. A dismissal without a button (should one
    /// happen) is treated as Cancel after the button handlers have had a chance to run.
    private var confirmationShown: Binding<Bool> {
        Binding(get: { model.confirmation != nil },
                set: { shown in if !shown { DispatchQueue.main.async { resolve(false) } } })
    }

    private func resolve(_ accepted: Bool) {
        guard let c = model.confirmation else { return }
        model.confirmation = nil
        c.resume(accepted)
    }

    /// Port of the window `Loaded` handler: restore a remembered session.
    private func start() async {
        if started { return }
        started = true
        model.configureDesktopNotifications()
        if model.preview { return }
        guard case .login = model.screen else { return }
        if await model.api.restore() {
            await model.run("Restoring your session…") {
                try await model.loadAccount()
                model.screen = .shell
                model.setNotice(model.pageStatus)
            }
        }
        if await model.api.signedIn { await model.pollNotifications() }
    }
}
#endif
