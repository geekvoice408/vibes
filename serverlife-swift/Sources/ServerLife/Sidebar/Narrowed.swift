import Foundation

/// Port of narrowed.js — a cluster seen through an assumed resource request.
///
/// Assuming a request for particular resources narrows the certificate to
/// exactly those: `tsh ls` then lists only them, and every other machine on
/// the cluster drops out of the list while still being there. A narrowed list
/// is treated as a partial view; the last full list is remembered so the rest
/// can still be drawn, dimmed, while the request is in force.
@MainActor
enum Narrowed {
    /// The last list read without a request narrowing it, per profile key.
    private static var full: [String: [Host]] = [:]

    /// Whether this profile's certificate is limited to particular resources.
    nonisolated static func isNarrowed(_ p: TeleportProfile?) -> Bool {
        !(p?.allowedResources.isEmpty ?? true)
    }

    /// Record a successful read. Only an un-narrowed one stands for the whole cluster.
    static func noteRead(_ p: TeleportProfile, _ nodes: [Host]) {
        if !isNarrowed(p) { full[p.key] = nodes }
    }

    private static func idOf(_ n: Host) -> String { n.uuid?.nilIfEmpty ?? n.id.nilIfEmpty ?? n.name }

    /// The machines the request is keeping out of the list, marked
    /// `heldBack` with `heldBy` (the assumed request ids).
    static func heldBack(for p: TeleportProfile, reachable: [Host]) -> [Host] {
        guard isNarrowed(p) else { return [] }
        let have = Set(reachable.map(idOf))
        return (full[p.key] ?? []).filter { !have.contains(idOf($0)) }.map { n in
            var h = n
            h.extra["heldBack"] = true
            h.extra["heldBy"] = JSON(p.activeRequests)
            return h
        }
    }

    static func reset() { full = [:] }
}
