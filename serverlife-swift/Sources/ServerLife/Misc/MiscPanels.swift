import AppKit
import UniformTypeIdentifiers

/// Open/save panels attached to a specific NSWindow (a panel such as the
/// guide, which is not a WindowModel) and carrying the original's dialog
/// titles. `title` shows as the panel's message when it is a sheet.
@MainActor
enum MiscPanels {
    /// The window a dialog for `owner` should attach to (its topmost sheet).
    static func parent(_ owner: WindowModel?) -> NSWindow? {
        guard var w = (owner ?? WindowManager.shared.focused)?.nsWindow ?? NSApp.keyWindow else { return nil }
        while let s = w.attachedSheet { w = s }
        return w
    }

    static func save(_ parent: NSWindow?, title: String, defaultName: String, directory: String? = nil,
                     types: [UTType]? = nil) async -> URL? {
        let p = NSSavePanel()
        p.title = title
        p.message = title
        p.nameFieldStringValue = defaultName
        p.canCreateDirectories = true
        p.showsHiddenFiles = true
        if let directory { p.directoryURL = URL(fileURLWithPath: directory.expandingTilde) }
        if let types { p.allowedContentTypes = types }
        return await present(p, parent) ? p.url : nil
    }

    static func open(_ parent: NSWindow?, title: String, types: [UTType]? = nil) async -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.message = title
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        if let types { p.allowedContentTypes = types }
        return await present(p, parent) ? p.url : nil
    }

    private static func present(_ panel: NSSavePanel, _ parent: NSWindow?) async -> Bool {
        var w = parent
        while let s = w?.attachedSheet { w = s }
        if let w {
            return await withCheckedContinuation { cont in
                panel.beginSheetModal(for: w) { cont.resume(returning: $0 == .OK) }
            }
        }
        return panel.runModal() == .OK
    }
}
