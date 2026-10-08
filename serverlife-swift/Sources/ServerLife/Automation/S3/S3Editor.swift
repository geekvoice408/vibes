import SwiftUI

/// Registering S3 buckets (s3.js `openS3Editor`).
///
/// Four ways to get credentials, in the order most people should reach for
/// them: Teleport (short-lived, audited, nothing stored), a profile already
/// on this machine, the environment this app was launched with, and finally a
/// stored access key — the only one that puts a long-lived secret on disk, so
/// it is last and says so.
@MainActor
final class S3EditorModel: ObservableObject {
    static let modes: [(value: String, label: String)] = [
        ("teleport", "Teleport AWS app — short-lived, audited"),
        ("profile", "AWS profile on this machine (~/.aws)"),
        ("env", "Environment variables of this app"),
        ("explicit", "Stored access key"),
    ]

    let initial: JSON
    @Published var name: String
    @Published var bucket: String
    @Published var region: String
    @Published var prefix: String
    @Published var endpoint: String
    @Published var mode: String { didSet { if mode != oldValue { modeChanged() } } }
    @Published var envPrefix: String
    @Published var keyId: String
    @Published var secret = ""
    @Published var profile: String
    @Published var profileOptions: [(value: String, label: String)] = [("", "Loading profiles…")]
    @Published var profileStatus = ""
    @Published var app: String
    @Published var appOptions: [(value: String, label: String)] = [("", "Loading AWS apps…")]
    @Published var role: String
    @Published var roleOptions: [(value: String, label: String)] = [("", "—")]
    @Published var appStatus = ""
    @Published var storageClass: String

    init(_ t: JSON) {
        initial = t
        let c = t["credentials"]
        name = t["name"].string ?? ""
        bucket = t["bucket"].string ?? ""
        region = t["region"].string ?? ""
        prefix = t["prefix"].string ?? ""
        endpoint = t["endpoint"].string ?? ""
        mode = c["mode"].string?.nilIfEmpty ?? "teleport"
        envPrefix = c["envPrefix"].string ?? ""
        keyId = c["accessKeyId"].string ?? ""
        profile = c["profile"].string ?? ""
        app = c["app"].string ?? ""
        role = c["role"].string ?? ""
        storageClass = t["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD"
    }

    var isEdit: Bool { initial["id"].string != nil }
    var hasSecret: Bool { initial["credentials"]["hasSecret"].truthy }

    func start() {
        if mode == "profile" { loadProfiles() }
        if mode == "teleport" { loadApps() }
    }

    private func modeChanged() {
        if mode == "profile" { loadProfiles() }
    }

    func loadProfiles() {
        let list = AWSCreds.listProfiles()
        if list.isEmpty {
            profileOptions = [("", "No profiles in ~/.aws")]
            profile = ""
            profileStatus = "Nothing configured on this machine yet."
            return
        }
        profileOptions = list.map { p in
            (p.name, p.name + (p.sso ? " — SSO" : p.assumesRole ? " — assumed role" : p.staticKey ? " — key" : ""))
        }
        if let want = initial["credentials"]["profile"].string?.nilIfEmpty, list.contains(where: { $0.name == want }) {
            profile = want
        } else if !list.contains(where: { $0.name == profile }) {
            profile = list[0].name
        }
        let chosen = list.first { $0.name == profile } ?? list[0]
        profileStatus = chosen.region.isEmpty ? "" : "Region from the profile: \(chosen.region)"
    }

    func checkProfile() {
        profileStatus = "Resolving…"
        let want = profile.nilIfEmpty ?? "default"
        Task {
            do {
                let r = try await S3Service.shared.profileCheck(want)
                var text = "\(r.accessKeyId) via \(r.source)"
                if r.temporary { text += " — temporary" }
                if let exp = r.expiration {
                    let ms = S3Pure.parseIsoMs(exp)
                    let shown = ms > 0 ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: ms / 1000),
                                                                      dateStyle: .short, timeStyle: .medium) : exp
                    text += ", expires \(shown)"
                }
                if !r.region.isEmpty { text += " · \(r.region)" }
                profileStatus = text
                if region.trimmed.isEmpty && !r.region.isEmpty { region = r.region }
                StatusBus.shared.s3Ok("Profile resolved")
            } catch {
                profileStatus = s3Message(error)
                StatusBus.shared.s3Error(s3Message(error))
            }
        }
    }

    func loadApps() {
        appStatus = "Listing AWS applications…"
        Task {
            do {
                let apps = try await AWSProxy.listAwsApps()
                if apps.isEmpty {
                    appOptions = [("", "No AWS apps on this cluster")]
                    app = ""
                    appStatus = "No application with cloud: AWS is visible to you."
                    return
                }
                appOptions = apps.map { a in (a.name, a.accountId.map { "\(a.name) (\($0))" } ?? a.name) }
                if let want = initial["credentials"]["app"].string?.nilIfEmpty, apps.contains(where: { $0.name == want }) {
                    app = want
                } else if !apps.contains(where: { $0.name == app }) {
                    app = apps[0].name
                }
                appStatus = "\(apps.count) AWS application\(apps.count == 1 ? "" : "s")."
                await loadRoles()
            } catch {
                appOptions = [("", "Could not list apps")]
                app = ""
                appStatus = s3Message(error)
            }
        }
    }

    func appChanged() { Task { await loadRoles() } }

    func loadRoles() async {
        guard !app.isEmpty else { return }
        roleOptions = [("", "Loading roles…")]
        let roles = await AWSProxy.listAwsRoles(app)
        roleOptions = [("", roles.isEmpty ? "Already logged in" : "Choose a role…")] + roles.map { ($0.name, $0.name) }
        if let want = initial["credentials"]["role"].string?.nilIfEmpty, roles.contains(where: { $0.name == want }) {
            role = want
        } else if !roles.contains(where: { $0.name == role }) {
            role = ""
        }
    }

    func appLogin() {
        guard !app.isEmpty else { StatusBus.shared.s3Error("Choose an application first"); return }
        appStatus = "Logging in to \(app)…"
        let a = app, r = role
        Task {
            do {
                _ = try await AWSProxy.login(a, role: r.nilIfEmpty)
                appStatus = "Logged in to \(a)\(r.isEmpty ? "" : " as " + r)."
                StatusBus.shared.s3Ok("Logged in to the AWS app")
            } catch {
                appStatus = s3Message(error)
                StatusBus.shared.s3Error(s3Message(error))
            }
        }
    }

    /// `collect()`: the target as the form describes it.
    func collect() -> JSON {
        var t: JSON = [
            "name": .string(name.trimmed.nilIfEmpty ?? bucket.trimmed),
            "bucket": .string(bucket.trimmed),
            "region": .string(region.trimmed),
            "prefix": .string(prefix.trimmed),
            "endpoint": .string(endpoint.trimmed),
            "pathStyle": .bool(!endpoint.trimmed.isEmpty),
            "defaultStorageClass": .string(storageClass),
        ]
        if let id = initial["id"].string { t["id"] = .string(id) }
        switch mode {
        case "teleport": t["credentials"] = ["mode": "teleport", "app": .string(app), "role": .string(role)]
        case "profile": t["credentials"] = ["mode": "profile", "profile": .string(profile.nilIfEmpty ?? "default")]
        case "env": t["credentials"] = ["mode": "env", "envPrefix": .string(envPrefix.trimmed)]
        default: t["credentials"] = ["mode": "explicit", "accessKeyId": .string(keyId.trimmed), "secretAccessKey": .string(secret)]
        }
        return t
    }

    func browseIntoField(_ owner: WindowModel?) {
        Task {
            guard let picked = await S3UI.browseBuckets(owner, target: collect()) else { return }
            bucket = picked.name
            if !picked.region.isEmpty { region = picked.region }
            if name.trimmed.isEmpty { name = picked.name }
        }
    }

    func testNow() {
        let t = collect()
        guard let b = t["bucket"].string?.nilIfEmpty else { StatusBus.shared.s3Error("Give a bucket name first"); return }
        StatusBus.shared.show("Testing \(b)…", seconds: 0)
        Task {
            do {
                let r = try await S3Service.shared.test(t)
                StatusBus.shared.clear()
                StatusBus.shared.s3Ok("Reached \(r.bucket) in \(r.region)")
                if region.trimmed.isEmpty && !r.region.isEmpty { region = r.region }
            } catch {
                StatusBus.shared.clear()
                StatusBus.shared.s3Error(s3Message(error))
            }
        }
    }
}

struct S3EditorView: View {
    @ObservedObject var m: S3EditorModel
    let owner: WindowModel?
    let done: (JSON?) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: m.isEdit ? "Edit S3 bucket" : "Register an S3 bucket", width: 660) {
            VStack(alignment: .leading, spacing: 0) {
                S3Field(label: "Credentials") { S3Select(options: S3EditorModel.modes, selection: $m.mode) }
                modeBlock
                p.borderSoft.frame(height: 1).padding(.top, 4).padding(.bottom, 12)
                HStack(alignment: .top, spacing: 12) {
                    S3Field(label: "Bucket") { TextField("my-bucket", text: $m.bucket).textFieldStyle(.roundedBorder) }
                    S3Field(label: "Region") { TextField("us-east-1 — blank to detect", text: $m.region).textFieldStyle(.roundedBorder) }
                }
                HStack(spacing: 6) {
                    Button("Browse buckets…") { m.browseIntoField(owner) }.buttonStyle(.ghostSmall)
                        .help("List what these credentials can see and pick one")
                    Button("Test") { m.testNow() }.buttonStyle(.ghostSmall)
                }
                .padding(.top, -4).padding(.bottom, 12)
                HStack(alignment: .top, spacing: 12) {
                    S3Field(label: "Name") { TextField("Backups", text: $m.name).textFieldStyle(.roundedBorder) }
                    S3Field(label: "Default storage class") {
                        S3Select(options: S3StorageClass.all.map { ($0.value, $0.label) }, selection: $m.storageClass)
                    }
                }
                S3Field(label: "Prefix", hint: "Restricts this bucket to one folder.") {
                    TextField("optional — only show keys under this", text: $m.prefix).textFieldStyle(.roundedBorder)
                }
                S3Field(label: "Endpoint", hint: "Leave blank for AWS. Setting one switches to path-style addressing.") {
                    TextField("optional — MinIO or another S3-compatible host", text: $m.endpoint).textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 12))
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") {
                let t = m.collect()
                if (t["bucket"].string ?? "").isEmpty { StatusBus.shared.s3Error("Give a bucket name"); return }
                done(t)
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .onAppear { m.start() }
    }

    @ViewBuilder private var modeBlock: some View {
        let p = Theme.shared.p
        switch m.mode {
        case "env":
            S3Field(label: "Variable prefix", hint: "Blank uses AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN.") {
                TextField("optional — e.g. BACKUP_ for BACKUP_AWS_ACCESS_KEY_ID", text: $m.envPrefix).textFieldStyle(.roundedBorder)
            }
            S3Hint(text: "Read from the environment ServerLife itself was launched with — so launch it from a shell that has them, "
                   + "or they will not be visible.")
        case "profile":
            S3Field(label: "Profile") {
                S3Select(options: m.profileOptions, selection: Binding(get: { m.profile }, set: { m.profile = $0; m.profileStatus = "" }))
            }
            if !m.profileStatus.isEmpty { S3Hint(text: m.profileStatus) }
            Button("Check") { m.checkProfile() }.buttonStyle(.ghostSmall).padding(.top, 6)
            S3Hint(text: "Whatever this machine already uses — SSO, an assumed role, a credential_process hook or a static key. "
                   + "The AWS CLI resolves the profile, so an SSO session that has expired is refreshed with aws sso login.")
                .padding(.top, 8)
        case "explicit":
            HStack(alignment: .top, spacing: 12) {
                S3Field(label: "Access key ID") { TextField("AKIA…", text: $m.keyId).textFieldStyle(.roundedBorder) }
                S3Field(label: "Secret access key") {
                    SecureField(m.hasSecret ? "•••••••• — stored, leave blank to keep" : "Secret access key", text: $m.secret)
                        .textFieldStyle(.roundedBorder)
                }
            }
            S3Hint(text: "A stored key is long-lived. It is encrypted with this machine’s keychain, but Teleport or environment "
                   + "credentials avoid keeping one at all.", color: p.amber)
        default:
            HStack(alignment: .top, spacing: 12) {
                S3Field(label: "AWS application") {
                    S3Select(options: m.appOptions, selection: Binding(get: { m.app }, set: { m.app = $0; m.appChanged() }))
                }
                S3Field(label: "IAM role") { S3Select(options: m.roleOptions, selection: $m.role) }
            }
            if !m.appStatus.isEmpty { S3Hint(text: m.appStatus) }
            HStack(spacing: 6) {
                Button("Reload apps") { m.loadApps() }.buttonStyle(.ghostSmall)
                Button("Log in to app") { m.appLogin() }.buttonStyle(.ghostSmall)
            }
            .padding(.top, 6)
            S3Hint(text: "Credentials are minted per session by tsh and never stored. Every call is signed by Teleport with the "
                   + "IAM role above and lands in the cluster’s audit log.")
                .padding(.top, 8)
        }
    }
}
