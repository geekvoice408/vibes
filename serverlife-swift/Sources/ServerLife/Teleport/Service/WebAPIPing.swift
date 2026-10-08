import Foundation

/// A proxy's `/webapi/ping` (nettools.js `webapiPing` + the renderer's
/// `renderTeleportPing` field layout): cluster name, version, edition, which
/// auth connector is in play and what the proxy listens on. It needs no
/// credentials, which makes it the one thing you can always ask a cluster.
enum WebAPIPing {
    struct Result: Sendable {
        var url: String
        var ms: Int
        /// The whole response, including fields this build has never heard of.
        var ping: JSON

        /// The badges drawn above the sections: (text, kind) with kind one of
        /// name | ver | ed | warn | ok.
        var badges: [(text: String, kind: String)] { WebAPIPing.badges(ping) }
        /// Titled key/value sections, empty rows and empty sections dropped.
        var sections: [(title: String, rows: [(key: String, value: String)])] { WebAPIPing.sections(ping) }
        /// `License warnings`, when there are any.
        var licenseWarnings: [String] { ping["license_warnings"].items.compactMap(\.stringish) }
        /// The status-line note (`v<server_version>`).
        var note: String { ping["server_version"].stringish.map { "v" + $0 } ?? "" }
    }

    /// `checkHost` (nettools.js): a host name or address, nothing else.
    static func checkHost(_ host: String) throws -> String {
        var h = host.trimmed
        if h.hasPrefix("[") { h.removeFirst() }
        if h.hasSuffix("]") { h.removeLast() }
        if h.isEmpty { throw AppError("Give a host name or address.") }
        if h.count > 253 { throw AppError("That host name is too long.") }
        if !TPText.test(#"^[A-Za-z0-9._:-]+$"#, h) {
            throw AppError("Host names may only contain letters, digits, dot, dash, underscore and colon.")
        }
        return h
    }

    /// `splitHostPort`: strip a scheme and any path; `[v6]:port`, bare v6, `host:port`.
    static func splitHostPort(_ value: String) -> (host: String, port: Int?) {
        var v = value.trimmed.replacingOccurrences(of: #"^[a-z][a-z0-9+.-]*://"#, with: "",
                                                   options: [.regularExpression, .caseInsensitive])
        v = String(v.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if let m = TPText.match(#"^\[([^\]]+)\](?::(\d+))?$"#, v) { return ((m[1] ?? nil) ?? "", (m[2] ?? nil).flatMap { Int($0) }) }
        if v.filter({ $0 == ":" }).count > 1 { return (v, nil) }
        let parts = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? Int(parts[1]) : nil)
    }

    /// `teleport:webapiPing`: HTTPS GET, no credentials, 15 s, 2 MB cap.
    static func ping(proxy: String, insecure: Bool = false) async throws -> Result {
        let parsed = splitHostPort(proxy)
        let h = try checkHost(parsed.host)
        let port = parsed.port ?? 443
        let hostPart = h.contains(":") ? "[\(h)]" : h
        let url = "https://\(hostPart):\(port)/webapi/ping"
        guard let u = URL(string: url) else { throw AppError("Give a host name or address.") }
        let started = Date()

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        let delegate = PingDelegate(insecure: insecure)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: u)
        req.setValue("ServerLife", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw AppError("Timed out.")
        } catch {
            throw AppError(error.localizedDescription)
        }
        if data.count > 2 * 1024 * 1024 { throw AppError("Response too large.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { throw AppError("\(url) returned HTTP \(status)") }
        guard let json = try? JSON.parse(data) else { throw AppError("The proxy did not return JSON.") }
        return Result(url: url, ms: Int(Date().timeIntervalSince(started) * 1000), ping: json)
    }

    // MARK: - Field layout (renderTeleportPing)

    static func editionLabel(_ ed: String?) -> String? {
        guard let ed, !ed.isEmpty else { return nil }
        return ["oss": "Community", "ent": "Enterprise", "team": "Team", "cloud": "Cloud"][ed] ?? ed
    }

    static func connectorLabel(_ auth: JSON) -> String? {
        guard let type = auth["type"].stringish, !type.isEmpty else { return nil }
        let c = auth[type]
        let name = c["display"].stringish?.nilIfEmpty ?? c["name"].stringish?.nilIfEmpty
        return name.map { "\(type) — \($0)" } ?? type
    }

    private static func yn(_ v: JSON) -> String? { v.bool.map { $0 ? "yes" : "no" } }

    private static func stringify(_ v: JSON) -> String? {
        switch v {
        case .null: return nil
        case .object, .array: return v.text()
        default: return v.stringish
        }
    }

    static func badges(_ p: JSON) -> [(text: String, kind: String)] {
        var out: [(String, String)] = [
            (p["cluster_name"].stringish?.nilIfEmpty ?? "unknown cluster", "name"),
            ("v" + (p["server_version"].stringish?.nilIfEmpty ?? "?"), "ver"),
        ]
        if let ed = editionLabel(p["edition"].stringish) { out.append((ed, "ed")) }
        if p["fips"].truthy { out.append(("FIPS", "warn")) }
        out.append(p["proxy"]["tls_routing_enabled"].truthy ? ("TLS routing", "ok") : ("separate listeners", "warn"))
        return out
    }

    static func sections(_ p: JSON) -> [(title: String, rows: [(key: String, value: String)])] {
        let auth = p["auth"], proxy = p["proxy"], au = p["auto_update"]
        var out: [(String, [(String, String)])] = []
        func section(_ title: String, _ rows: [(String, String?)]) {
            let kept = rows.compactMap { k, v -> (String, String)? in
                guard let v, !v.isEmpty else { return nil }
                return (k, v)
            }
            if !kept.isEmpty { out.append((title, kept)) }
        }
        section("Cluster", [
            ("Name", p["cluster_name"].stringish), ("Server version", p["server_version"].stringish),
            ("Minimum client", p["min_client_version"].stringish), ("Edition", editionLabel(p["edition"].stringish)),
            ("FIPS mode", yn(p["fips"])), ("Automatic upgrades", yn(p["automatic_upgrades"])),
        ])
        if !au.entries.isEmpty {
            section("Managed updates", [
                ("Tools version", au["tools_version"].stringish), ("Tools auto-update", yn(au["tools_auto_update"])),
                ("Agent version", au["agent_version"].stringish), ("Agent auto-update", yn(au["agent_auto_update"])),
                ("Agent jitter", au["agent_update_jitter_seconds"].truthy ? "\(au["agent_update_jitter_seconds"].stringish ?? "")s" : nil),
            ])
        }
        section("Authentication", [
            ("Connector type", connectorLabel(auth)), ("Second factor", auth["second_factor"].stringish),
            ("Preferred local MFA", auth["preferred_local_mfa"].stringish), ("Passwordless", yn(auth["allow_passwordless"])),
            ("Headless", yn(auth["allow_headless"])), ("Default session TTL", auth["default_session_ttl"].stringish),
            ("Private key policy", auth["private_key_policy"].stringish),
            ("PIV slot", auth["piv_slot"].truthy ? auth["piv_slot"].stringish : nil),
            ("Signature suite", auth["signature_algorithm_suite"].stringish), ("Message of the day", yn(auth["has_motd"])),
            ("Device trust", auth["device_trust"].entries.isEmpty ? nil : auth["device_trust"].text()),
            ("WebAuthn RP ID", auth["webauthn"]["rp_id"].stringish),
        ])
        for kind in ["saml", "oidc", "github", "local"] {
            let c = auth[kind]
            guard let o = c.object else { continue }
            section("\(kind.uppercased()) connector", o.keys.sorted().map { ($0, stringify(o[$0]!)) })
        }
        let ssh = proxy["ssh"], kube = proxy["kube"], db = proxy["db"]
        let dial = ssh["dial_timeout"].double
        section("Proxy listeners", [
            ("SSH public address", ssh["public_addr"].stringish), ("SSH listener", ssh["listen_addr"].stringish),
            ("Reverse tunnel", ssh["tunnel_listen_addr"].stringish), ("Web listener", ssh["web_listen_addr"].stringish),
            ("Dial timeout", dial.flatMap { $0 != 0 ? "\(Int(($0 / 1e9).rounded()))s" : nil }),
            ("Kubernetes", kube["enabled"].truthy
                ? (kube["public_addr"].stringish?.nilIfEmpty ?? kube["listen_addr"].stringish?.nilIfEmpty ?? "enabled") : "disabled"),
            ("PostgreSQL", db["postgres_public_addr"].stringish?.nilIfEmpty ?? db["postgres_listen_addr"].stringish),
            ("MySQL", db["mysql_public_addr"].stringish?.nilIfEmpty ?? db["mysql_listen_addr"].stringish),
            ("MongoDB", db["mongo_public_addr"].stringish?.nilIfEmpty ?? db["mongo_listen_addr"].stringish),
            ("TLS routing", yn(proxy["tls_routing_enabled"])),
        ])
        return out
    }
}

/// No credentials, ever; certificate checks off only when asked.
private final class PingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let insecure: Bool
    init(insecure: Bool) { self.insecure = insecure }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if insecure, let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
        // Client certificates, HTTP auth: never offered.
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// Redirects are not followed (Node's https.get did not either).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
