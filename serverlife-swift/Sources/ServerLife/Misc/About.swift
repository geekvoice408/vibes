import AppKit
import SwiftUI

/// Facts about this installation that the About box and Settings show
/// (the parts of main.js `app:info` that apply to a native macOS build).
@MainActor
@Observable
final class MiscAppInfo {
    static let shared = MiscAppInfo()

    /// `tsh version --client`, once read. nil until then or when not found.
    private(set) var tshVersion: String?
    private(set) var tshVersionRead = false

    /// Re-read the tsh version (after a path changes, or on first use).
    func refreshTshVersion() {
        Task {
            guard Tools.tshAvailable else {
                await MainActor.run { self.tshVersion = nil; self.tshVersionRead = true }
                return
            }
            let r = await Tools.runTsh(["version", "--client"], timeout: 10)
            let out = r.out
            var v: String?
            if let m = out.range(of: #"Teleport\s+v([0-9.]+)"#, options: .regularExpression) {
                v = String(out[m]).replacingOccurrences(of: #"Teleport\s+v"#, with: "", options: .regularExpression)
            } else if !out.trimmed.isEmpty {
                v = out.trimmed.components(separatedBy: "\n").first
            }
            await MainActor.run { self.tshVersion = v; self.tshVersionRead = true }
        }
    }

    var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    /// `os.release()`: the Darwin kernel release.
    var osRelease: String {
        var u = utsname()
        uname(&u)
        return withUnsafePointer(to: &u.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }

    /// teleport.js DEFAULT_HOME.
    var defaultTshHome: String {
        ProcessInfo.processInfo.environment["TELEPORT_HOME"]?.nilIfEmpty
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".tsh")
    }
}

/// The About box (index.js `openAbout`): version plus the environment facts
/// worth reporting in a bug.
@MainActor
enum AboutBox {
    static func rows() -> [(String, String)] {
        let i = MiscAppInfo.shared
        let tsh = Tools.tshStatus
        let rows: [(String, String?)] = [
            ("Version", AppResources.version),
            ("Build", AppResources.build),
            ("Platform", "darwin \(i.arch) (\(i.osRelease))"),
            ("Connection multiplexing", "enabled (one auth per host)"),
            ("tsh", i.tshVersion.map { "v" + $0 } ?? (i.tshVersionRead ? "not found" : "…")),
            ("tsh path", tsh["path"].string),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("Settings", Store.shared.dir.path),
        ]
        return rows.compactMap { k, v in (v?.isEmpty ?? true) ? nil : (k, v!) }
    }

    static func open(_ window: WindowModel? = nil) {
        MiscAppInfo.shared.refreshTshVersion()
        Modal.sheet(window, title: "About ServerLife", width: 540) { handle in
            AboutView(handle: handle)
        }
    }
}

private struct AboutView: View {
    let handle: ModalHandle
    var body: some View {
        let p = Theme.shared.p
        // Read so the rows redraw once the tsh version arrives.
        _ = MiscAppInfo.shared.tshVersion
        let rows = AboutBox.rows()
        return DialogScaffold(title: "About ServerLife") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [p.accent, p.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                        .overlay(Text("\u{1F5A5}").font(.system(size: 25)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ServerLife").font(.system(size: 17, weight: .semibold))
                        Text("Version \(AppResources.version)").font(.system(size: 12)).foregroundStyle(p.muted)
                        Text("Teleport & SSH terminals, file transfer, multi-exec")
                            .font(.system(size: 11.5)).foregroundStyle(p.muted).padding(.top, 1)
                    }
                }
                .padding(.bottom, 15)
                p.borderSoft.frame(height: 1).padding(.bottom, 16)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.0).font(.system(size: 12)).foregroundStyle(p.muted).frame(width: 150, alignment: .leading)
                            Text(r.1).font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } footer: {
            Button("Version history") {
                let w = WindowManager.shared.model(for: handle.window)
                handle.close()
                VersionHistory.open(w)
            }.buttonStyle(.ghost)
            Button("Copy details") {
                Clipboard.write(AboutBox.rows().map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
                StatusBus.shared.show("Copied")
            }.buttonStyle(.ghost)
            Button("Close") { handle.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
