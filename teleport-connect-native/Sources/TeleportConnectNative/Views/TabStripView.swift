import SwiftUI

/// Mirrors TabHost/Tabs: the always-present Resources tab (titled with the active cluster's
/// name, matching the real app's tab rather than a generic "Resources" label) plus one tab per
/// open terminal session, each closable. The "+" opens a local shell tab — TopBar/
/// AdditionalActions.tsx's "Open new terminal" action, repurposed as the tab-strip's add button.
struct TabStripView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            tab(
                id: .resources,
                icon: "square.grid.2x2",
                title: clusterTitle,
                closable: false,
                onClose: {}
            )

            ForEach(model.terminalTabs) { terminalTab in
                tab(
                    id: .terminal(terminalTab.id),
                    icon: "terminal",
                    title: terminalTab.title,
                    closable: true,
                    onClose: { model.closeTerminalTab(terminalTab.id) }
                )
            }

            Button {
                model.openLocalShellTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSlightlyMuted)
                    .frame(width: Theme.tabHeight, height: Theme.tabHeight)
            }
            .buttonStyle(.plain)
            .help("Open new terminal")

            Spacer()
        }
        .frame(height: Theme.tabHeight)
        .background(Theme.levelSurface)
    }

    private var clusterTitle: String {
        model.clusters.first { $0.uri == model.selectedClusterURI }?.name ?? "Resources"
    }

    private func tab(id: TabID, icon: String, title: String, closable: Bool, onClose: @escaping () -> Void) -> some View {
        let selected = model.selectedTab == id
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if closable {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(selected ? Theme.textMain : Theme.textSlightlyMuted)
        .padding(.horizontal, Theme.space[2])
        .frame(height: Theme.tabHeight)
        .background(selected ? Theme.levelSunken : Theme.levelSurface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.spotBackground2).frame(width: 1, height: Theme.tabHeight * 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedTab = id
        }
    }
}
