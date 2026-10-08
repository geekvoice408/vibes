import SwiftUI

/// The four buttons at the right of the title bar (index.html
/// `#titlebar-actions`): file browsers, multi-exec, transfers, sidebar.
/// Each is lit while the thing it toggles is showing, as index.js did.
struct TitlebarActionsView: View {
    let window: WindowModel

    var body: some View {
        HStack(spacing: 2) {
            button("toggle-files", "folder", "File browser (⌘E)", active: XPFiles.anyVisible(window: window))
                .contextMenu {
                    // files-button-menu fills an NSMenu; mirror its items here.
                    ForEach(Array(filesMenuItems().enumerated()), id: \.offset) { _, item in
                        if item.isSeparatorItem { Divider() } else {
                            Button(item.title) {
                                if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                            }
                            .disabled(!item.isEnabled)
                        }
                    }
                }
            button("toggle-multiexec", "list.bullet", "Multi-exec (⌘⇧M)",
                   active: window.dockVisible && window.dockTab == "multiexec") {
                window.showDock("multiexec")
            }
            button("toggle-transfers", "arrow.down.to.line", "Transfers (⌘J)",
                   active: window.dockVisible)
            button("toggle-sidebar", "sidebar.left", "Sidebar (⌘B)", active: window.sidebarVisible)
        }
    }

    private func filesMenuItems() -> [NSMenuItem] {
        let menu = NSMenu()
        menu.autoenablesItems = false
        Actions.shared.perform("files-button-menu", window: window, args: ["menu": menu])
        return menu.items
    }

    private func button(_ id: String, _ symbol: String, _ help: String, active: Bool,
                        action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else { Actions.shared.perform(id, window: window) }
        } label: {
            Image(systemName: symbol).font(.system(size: 13))
        }
        .buttonStyle(IconButtonStyle(size: 26, active: active))
        .help(help)
        .tourAnchor(id)
    }
}
