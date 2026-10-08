import SwiftUI

/// "Cluster info" when network tools' `webapi-ping` is not registered: the
/// proxy's /webapi/ping, laid out as nettools.js `renderTeleportPing` does
/// (badges, then titled key/value sections). Needs no credentials.
@MainActor
enum ClusterInfoPanel {
    static func open(proxy: String, window: WindowModel? = nil) {
        let m = ClusterInfoModel(proxy: proxy)
        Modal.panel(id: "cluster-info", title: "Cluster information", width: 640, height: 600, autosave: "clusterinfo") { _ in
            ClusterInfoView(m: m)
        }
        if !proxy.isEmpty { m.run() }
    }
}

@MainActor
final class ClusterInfoModel: ObservableObject {
    @Published var proxy: String
    @Published var insecure = false
    @Published var running = false
    @Published var result: WebAPIPing.Result?
    @Published var error: String?

    init(proxy: String) {
        self.proxy = proxy.isEmpty ? (TUI.activeProfile()?.proxy ?? "") : proxy
    }

    func run() {
        let px = proxy.trimmed
        if px.isEmpty || running { return }
        running = true; error = nil
        Task { @MainActor in
            do { result = try await WebAPIPing.ping(proxy: px, insecure: insecure) } catch { self.error = error.localizedDescription; result = nil }
            running = false
        }
    }
}

private struct ClusterInfoView: View {
    @ObservedObject var m: ClusterInfoModel

    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("teleport.example.com:443", text: $m.proxy).textFieldStyle(.roundedBorder).onSubmit { m.run() }
                Toggle("Skip certificate check", isOn: $m.insecure).toggleStyle(.checkbox).font(.system(size: 11.5))
                Button(m.running ? "Asking…" : "Ask") { m.run() }.buttonStyle(.primary).disabled(m.running)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let e = m.error { Text(e).foregroundStyle(p.red).textSelection(.enabled) }
                    if let r = m.result {
                        TUIFlow(spacing: 5) {
                            ForEach(Array(r.badges.enumerated()), id: \.offset) { _, b in
                                TUITag(text: b.text, kind: b.kind == "warn" ? .warn : b.kind == "ok" ? .ok : b.kind == "name" ? .accent : .plain)
                            }
                        }
                        if !r.licenseWarnings.isEmpty {
                            ForEach(r.licenseWarnings, id: \.self) { Text($0).font(.system(size: 11.5)).foregroundStyle(p.amber) }
                        }
                        ForEach(Array(r.sections.enumerated()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(p.textDim).padding(.bottom, 2)
                                ForEach(Array(s.rows.enumerated()), id: \.offset) { _, row in TUIKeyValue(key: row.key, value: row.value) }
                            }
                        }
                        Text("\(r.url) · \(r.ms) ms").font(.system(size: 10.5)).foregroundStyle(p.muted)
                    } else if m.error == nil {
                        Text(m.running ? "Asking the proxy…" : "Give a proxy address and press Ask.")
                            .font(.system(size: 12)).foregroundStyle(p.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.panel)
    }
}
