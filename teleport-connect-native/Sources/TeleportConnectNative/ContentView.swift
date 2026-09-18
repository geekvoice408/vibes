import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(model: model)

            switch model.connectionState {
            case .starting:
                VStack(spacing: Theme.space[2]) {
                    ProgressView()
                    Text("Starting tsh daemon…")
                        .font(Theme.uiFontSmall)
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.levelSunken)

            case .failed(let message):
                VStack(spacing: Theme.space[2]) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(Theme.interactiveDanger)
                    Text("Couldn't start tshd").font(Theme.uiFontMedium)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .padding(Theme.space[4])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.levelSunken)

            case .ready:
                TabStripView(model: model)
                // All tab contents stay mounted (opacity-toggled, not conditionally included) so
                // switching tabs doesn't tear down and restart a running terminal session's PTY —
                // mirrors the DOM's display:none toggle TabHost uses for the same reason.
                ZStack {
                    ResourceListView(model: model)
                        .opacity(model.selectedTab == .resources ? 1 : 0)
                        .allowsHitTesting(model.selectedTab == .resources)
                    ForEach(model.terminalTabs) { terminalTab in
                        let isSelected = model.selectedTab == .terminal(terminalTab.id)
                        TerminalHostView(
                            executable: terminalTab.executable,
                            args: terminalTab.args,
                            onExit: { _ in model.closeTerminalTab(terminalTab.id) }
                        )
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            StatusBarView(model: model)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await model.start()
        }
        .background {
            // Redundant with App.swift's Cmd+T menu command — a view-level shortcut is anchored
            // to the window's key-view hierarchy rather than the app's synthesized main menu, so
            // it still works even if the menu-bar route doesn't for some reason.
            Button("") { model.openLocalShellTab() }
                .keyboardShortcut("t", modifiers: .command)
                .opacity(0)
        }
        .sheet(isPresented: Binding(
            get: { model.loginState != .idle },
            set: { if !$0 { model.cancelLogin() } }
        )) {
            LoginSheetView(model: model)
        }
    }
}
