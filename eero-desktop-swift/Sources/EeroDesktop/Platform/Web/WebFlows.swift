#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import EeroCore

/// Owns the auxiliary windows opened by web and chat flows (service browser, Amazon sign-in,
/// provider chooser, chat). The Windows client opened owned `Window`s; on macOS each flow gets its
/// own `NSWindow` hosting a SwiftUI view, so nothing has to be attached to `RootView`.
@MainActor
final class WebFlows: ObservableObject {
    static let shared = WebFlows()

    /// "Remember me" choice applied to external sign-ins (the Windows `rememberBox`). The login screen
    /// sets this before calling `websiteSignIn()`, `providerSignIn()` or `amazonSignIn()`.
    @Published var remember = true
    /// Optional diagnostics path (the Windows `--status` argument). When set, the Amazon flow writes
    /// `<path>.amazon-native.json` and appends to `<path>.amazon-native.history.jsonl`.
    var statusPath: String?

    private struct Entry { let key: String?; let onClose: () -> Void; let observer: NSObjectProtocol }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var keyed: [String: NSWindow] = [:]

    private init() {}

    /// Brings an existing keyed window to the front. Returns false when none is open.
    @discardableResult
    func activate(_ key: String) -> Bool {
        guard let window = keyed[key] else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func window(_ key: String) -> NSWindow? { keyed[key] }

    /// Opens a window hosting `content`. `onClose` runs once when the window closes.
    @discardableResult
    func present<Content: View>(key: String? = nil, title: String, size: CGSize, minSize: CGSize,
                                onClose: @escaping () -> Void = {}, content: Content) -> NSWindow {
        if let key, let existing = keyed[key] { existing.makeKeyAndOrderFront(nil); return existing }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(size)
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            let f = parent.frame
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: max(f.midY - size.height / 2, 0)))
        } else {
            window.center()
        }
        let id = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(id) }
        }
        entries[id] = Entry(key: key, onClose: onClose, observer: observer)
        if let key { keyed[key] = window }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func closed(_ id: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(entry.observer)
        if let key = entry.key { keyed[key] = nil }
        entry.onClose()
    }

    /// Yes/No question attached to `window` when given (port of `MessageBox.Show(..., YesNo)` / `Confirm`).
    static func ask(_ message: String, title: String = "eero Desktop", window: NSWindow? = nil, defaultNo: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        let yes = alert.addButton(withTitle: "Yes")
        let no = alert.addButton(withTitle: "No")
        if defaultNo { yes.keyEquivalent = ""; no.keyEquivalent = "\r" }
        if let window, window.isVisible {
            return await withCheckedContinuation { c in
                alert.beginSheetModal(for: window) { c.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Writes an Amazon sign-in diagnostic record (port of the `report` callback in `AmazonConsumerSignIn`).
    func writeAmazonReport(_ state: String, _ details: JSON?) {
        guard let statusPath, !statusPath.isEmpty else { return }
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let json = JSON.obj(("state", state), ("time_utc", time.string(from: Date())), ("details", details)).serialized()
        try? json.write(toFile: statusPath + ".amazon-native.json", atomically: true, encoding: .utf8)
        let history = statusPath + ".amazon-native.history.jsonl"
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: history))?[.size] as? NSNumber)?.intValue ?? 0
        if !fm.fileExists(atPath: history) || size < 65536 {
            let line = Data((json + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: history) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: URL(fileURLWithPath: history))
            }
        }
    }
}

/// Hosts a controller-owned `WKWebView` inside SwiftUI.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

enum WebKitSupport {
    /// A private, per-window browser profile (WebView2 `IsInPrivateModeEnabled`).
    @MainActor
    static func privateWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    /// Failures caused by our own navigation cancellations, which should not be reported.
    static func ignorable(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return true }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return true } // frame load interrupted by policy change
        return false
    }

    /// The raw query of a URL with its leading "?", like .NET `Uri.Query`.
    static func query(_ url: URL) -> String {
        guard let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return "" }
        return "?" + q
    }
}

extension AppModel {
    /// Serialises external sign-in completions (port of `CompleteExternalSignIn`).
    func completeExternalSignIn(_ action: @MainActor () async throws -> Void) async throws {
        if busy { throw EeroError.operation("Another sign-in operation is in progress. Wait for it to finish.") }
        busy = true
        defer { busy = false }
        try await action()
    }
}
#endif
