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
    /// CSS-style comma-separated font-family list, matching Connect's terminal.fontFamily
    /// config key — e.g. "Menlo, Monaco, monospace". First name that actually resolves wins.
    var fontFamily: String = "Menlo, Monaco, monospace"
    var fontSize: CGFloat = 15
    let onExit: (Int32?) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = Self.resolveFont(family: fontFamily, size: fontSize)
        view.processDelegate = context.coordinator
        view.startProcess(executable: executable, args: args)
        return view
    }

    private static func resolveFont(family: String, size: CGFloat) -> NSFont {
        for name in family.split(separator: ",") {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "monospace" { continue }
            if let font = NSFont(name: trimmed, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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
