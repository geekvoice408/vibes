import Testing
import Foundation
@testable import ServerLife

/// tests/helpers.mjs: a Teleport node as `listNodes` shapes one.
func sbNode(_ name: String, _ labels: [String: String] = [:], cluster: String = "c1", expires: Double? = nil,
            uuid: String? = nil) -> ServerLife.Host {
    var h = ServerLife.Host(type: ServerLife.Host.teleport, id: "tsh:\(cluster):\(name)", name: name)
    h.hostname = name
    h.uuid = uuid ?? "uuid-\(name)"
    h.cluster = cluster
    h.proxy = "proxy.example:443"
    h.addr = ""
    h.tunnel = true
    h.labels = labels
    if let expires { h.expires = TPText.isoString(ms: expires) }
    return h
}

/// A host read from an ssh_config.
func sbSshHost(_ alias: String) -> ServerLife.Host {
    var h = ServerLife.Host(type: ServerLife.Host.ssh, id: "ssh:\(alias)", name: alias)
    h.alias = alias
    h.hostname = "\(alias).example"
    h.user = "root"
    h.port = 22
    return h
}

/// A throwaway store for the sidebar's models (never the real sessions.json).
@MainActor
func sbFreshStore(_ settings: [String: JSON] = [:]) -> Store {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-sidebar-tests-\(UUID().uuidString)")
    let s = Store(dir: dir)
    s.updateSettings(settings)
    SB.store = s
    return s
}

/// Every sidebar suite that swaps `SB.store` is nested in this one, so they
/// run one at a time (suites otherwise run in parallel, and an `await` in one
/// would let another replace the store under it).
@Suite(.serialized) struct SidebarStoreSuites {}
