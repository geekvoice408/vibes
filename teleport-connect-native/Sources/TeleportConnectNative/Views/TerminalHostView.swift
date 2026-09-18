import SwiftUI
import SwiftTerm
import AppKit

/// Hosts a real interactive terminal via SwiftTerm's LocalProcessTerminalView, which allocates
/// an actual pseudo-terminal and spawns the process attached to it — the same approach
/// Electron's node-pty takes in buildPtyOptions.ts, just without Node in the middle. This is
/// what backs both SSH sessions (`tsh ssh`) and the local shell tab.
struct TerminalHostView: NSViewRepresentable {
    let executable: String
    let args: [String]
    let onExit: (Int32?) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.startProcess(executable: executable, args: args)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (Int32?) -> Void

        init(onExit: @escaping (Int32?) -> Void) {
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onExit(exitCode)
        }
    }
}
