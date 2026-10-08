import Foundation

/// AWS credentials from Teleport (awsproxy.js).
///
/// `tsh proxy aws` does not hand back real AWS keys. It starts a local forward
/// proxy, prints throwaway credentials that only that proxy accepts, and a CA
/// bundle for the certificate it presents. Requests are signed with the
/// throwaway keys, tunnelled through the proxy, and re-signed by Teleport with
/// whatever the user's IAM role actually is — so nothing long-lived is ever
/// stored, and every call lands in the cluster's audit log.
///
/// That means a proxy has to be running for as long as a bucket is in use, so
/// one is kept per app and shut down with the app.
enum AWSProxy {
    struct Env: Sendable, Equatable {
        var accessKeyId: String
        var secretAccessKey: String
        var caBundle: String?
        var httpsProxy: String
        var app: String

        /// The tunnel requests go through (`tunnelAgent`).
        var tunnel: S3Tunnel? {
            guard let u = URLComponents(string: httpsProxy), let host = u.host else { return nil }
            return S3Tunnel(proxyHost: host, proxyPort: u.port ?? 80, caBundle: caBundle)
        }
    }

    struct Running: Sendable { var app: String; var startedAt: Double; var proxy: String }

    struct App: Sendable, Identifiable, Equatable {
        var name: String
        var description: String
        var accountId: String?
        var publicAddr: String
        var labels: [String: String]
        var id: String { name }
    }

    struct Role: Sendable, Identifiable, Equatable { var name: String; var arn: String; var id: String { name } }

    private final class Entry: @unchecked Sendable {
        let child: RunningProcess
        let env: Env
        let startedAt: Double
        init(child: RunningProcess, env: Env, startedAt: Double) { self.child = child; self.env = env; self.startedAt = startedAt }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [String: Entry] = [:]

    /// `export NAME="value"` lines from `tsh proxy aws --format=unix`.
    static func parseExports(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        guard let re = try? NSRegularExpression(pattern: #"export\s+([A-Z_]+)="([^"]*)""#) else { return found }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            found[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return found
    }

    static func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// Start (or reuse) a proxy for one AWS app. Returns once tsh has printed
    /// the values it needs to hand over.
    static func ensure(app appName: String?, proxy: String?) async throws -> Env {
        guard let appName = appName?.nilIfEmpty else { throw AppError("No AWS application chosen.") }
        if let env = lock.withLock({ running[appName].flatMap { $0.child.isRunning ? $0.env : nil } }) { return env }

        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["proxy", "aws", "--app=" + appName, "--format=unix"]

        final class State: @unchecked Sendable {
            let lock = NSLock()
            var out = ""
            var settled = false
            var cont: CheckedContinuation<Env, Error>?
            var child: RunningProcess?
            func settle(_ r: Result<Env, Error>) {
                lock.lock()
                guard !settled else { lock.unlock(); return }
                settled = true
                let c = cont
                cont = nil
                lock.unlock()
                if case .failure = r { child?.terminate() }
                c?.resume(with: r)
            }
        }
        let st = State()
        // The app lives in whichever tsh home holds this proxy's profile.
        let env = Tools.tshEnv(home: Tools.home(forProxy: proxy))

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Env, Error>) in
            st.cont = c
            let scan: @Sendable (Data) -> Void = { chunk in
                st.lock.lock()
                st.out += String(decoding: chunk, as: UTF8.self)
                let text = st.out
                st.lock.unlock()
                let found = parseExports(text)
                if let id = found["AWS_ACCESS_KEY_ID"], let secret = found["AWS_SECRET_ACCESS_KEY"], let hp = found["HTTPS_PROXY"] {
                    st.lock.lock(); let child = st.child; st.lock.unlock()
                    // Too early to keep it: looked at again once the child is recorded.
                    guard let child else { return }
                    let e = Env(accessKeyId: id, secretAccessKey: secret, caBundle: found["AWS_CA_BUNDLE"], httpsProxy: hp, app: appName)
                    lock.lock(); running[appName] = Entry(child: child, env: e, startedAt: nowMs()); lock.unlock()
                    st.settle(.success(e))
                }
            }
            do {
                let child = try RunningProcess(Tools.tsh, args, env: env, onStdout: scan, onStderr: scan, onExit: { code in
                    lock.lock()
                    if running[appName]?.child.pid == st.child?.pid { running.removeValue(forKey: appName) }
                    lock.unlock()
                    st.lock.lock(); let text = stripAnsi(st.out).trimmed; st.lock.unlock()
                    // The usual cause by a wide margin, and the fix is one command.
                    if text.range(of: #"not logged|please login|app.*not found"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        st.settle(.failure(AppError("Not logged in to the AWS app \"\(appName)\". Run: tsh apps login \(appName) --aws-role <role>")))
                    } else {
                        let last = text.components(separatedBy: "\n").filter { !$0.isEmpty }.last
                        st.settle(.failure(AppError(last ?? "tsh proxy aws exited with code \(code)")))
                    }
                })
                st.lock.lock(); st.child = child; st.lock.unlock()
                // Output can arrive before `child` is recorded; look again now.
                scan(Data())
            } catch {
                st.settle(.failure(AppError("Could not run tsh: \((error as? AppError)?.message ?? error.localizedDescription)")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                st.settle(.failure(AppError("Timed out waiting for \"tsh proxy aws --app \(appName)\".")))
            }
        }
    }

    @discardableResult
    static func stop(_ app: String) -> Bool {
        lock.lock()
        let r = running.removeValue(forKey: app)
        lock.unlock()
        guard let r else { return false }
        r.child.terminate()
        return true
    }

    static func stopAll() {
        lock.lock()
        let names = Array(running.keys)
        lock.unlock()
        for n in names { stop(n) }
    }

    static func status() -> [Running] {
        lock.lock(); defer { lock.unlock() }
        return running.map { Running(app: $0.key, startedAt: $0.value.startedAt, proxy: $0.value.env.httpsProxy) }
    }

    // MARK: discovery

    /// AWS console apps the user can see, which is where these credentials live.
    static func listAwsApps(proxy: String? = nil) async throws -> [App] {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["apps", "ls", "--format=json"]
        let r = await Teleport.run(args, timeout: 30)
        if !r.ok { throw AppError(stripAnsi(r.err.nilIfEmpty ?? r.out).trimmed.nilIfEmpty ?? r.spawnError ?? "tsh apps ls failed") }
        guard let raw = try? JSON.parse(r.out.nilIfEmpty ?? "[]") else { throw AppError("Unreadable app list from tsh.") }
        return parseApps(raw)
    }

    static func parseApps(_ raw: JSON) -> [App] {
        raw.items.filter { $0["spec"]["cloud"].string == "AWS" }.map { a in
            let labels = a["metadata"]["labels"].entries.compactMapValues { $0.stringish }
            return App(name: a["metadata"]["name"].string ?? "", description: a["metadata"]["description"].string ?? "",
                       accountId: labels["aws_account_id"], publicAddr: a["spec"]["public_addr"].string ?? "", labels: labels)
        }
    }

    /// The IAM roles an app offers. `tsh apps login` prints them and then
    /// refuses without `--aws-role`, which is the only way to ask — so the
    /// refusal is the answer, and nothing is logged in by running it.
    static func listAwsRoles(_ app: String, proxy: String? = nil) async -> [Role] {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["apps", "login", app]
        let r = await Teleport.run(args, timeout: 30)
        return parseRoles(stripAnsi(r.out + "\n" + r.err))
    }

    static func parseRoles(_ text: String) -> [Role] {
        var roles: [Role] = []
        guard let re = try? NSRegularExpression(pattern: #"^(\S+)\s+(arn:aws:iam::\d+:role/\S+)\s*$"#) else { return roles }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmed
            let ns = t as NSString
            if let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
                roles.append(Role(name: ns.substring(with: m.range(at: 1)), arn: ns.substring(with: m.range(at: 2))))
            }
        }
        return roles
    }

    static func login(_ app: String, role: String?, proxy: String? = nil) async throws -> String {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["apps", "login", app]
        if let role = role?.nilIfEmpty { args.append("--aws-role=" + role) }
        let r = await Teleport.run(args, timeout: 120)
        let text = stripAnsi(r.out + "\n" + r.err).trimmed
        if !r.ok { throw AppError(text.components(separatedBy: "\n").filter { !$0.isEmpty }.last ?? r.spawnError ?? "tsh apps login failed") }
        return text
    }

    static func logout(_ app: String, proxy: String? = nil) async -> (ok: Bool, output: String) {
        stop(app)
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["apps", "logout", app]
        let r = await Teleport.run(args, timeout: 30)
        return (r.ok, stripAnsi(r.out + "\n" + r.err).trimmed)
    }
}
