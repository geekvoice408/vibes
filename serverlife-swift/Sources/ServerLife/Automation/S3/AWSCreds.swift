import Foundation

/// The AWS access a desktop already has (awscreds.js).
///
/// Most machines that touch AWS have a `~/.aws` with named profiles, and those
/// profiles are rarely plain keys any more — they are SSO sessions, assumed
/// roles, `credential_process` hooks, or an instance role. Re-implementing
/// that chain would be a mistake, so where the AWS CLI is installed it is
/// asked to resolve the profile and hand back the credentials it would have used.
///
/// Without the CLI the fallback is the one case that can be read honestly: a
/// static key pair written in `~/.aws/credentials`.
enum AWSCreds {
    struct Profile: Sendable, Equatable, Identifiable {
        var name: String
        var region = ""
        var sso = false
        var assumesRole = false
        var staticKey = false
        var credentialProcess = false
        var id: String { name }
    }

    struct Resolved: Sendable {
        var accessKeyId: String
        var secretAccessKey: String
        var sessionToken: String?
        /// "aws cli", "~/.aws/credentials" …
        var source: String
        var expiration: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cliPath: String?
    /// profile → (creds, expiresAt ms; 0 = does not expire)
    nonisolated(unsafe) private static var cache: [String: (Resolved, Double)] = [:]

    static func findAwsCli() -> String {
        lock.lock(); defer { lock.unlock() }
        if let c = cliPath { return c }
        let candidates = [ProcessInfo.processInfo.environment["AWS_CLI_PATH"], "/opt/homebrew/bin/aws",
                          "/usr/local/bin/aws", "/usr/bin/aws"].compactMap { $0?.nilIfEmpty }
        cliPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "aws"
        return cliPath!
    }

    static func configDir(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let f = env["AWS_CONFIG_FILE"]?.nilIfEmpty { return (f as NSString).deletingLastPathComponent }
        return NSHomeDirectory() + "/.aws"
    }

    /// Minimal INI reader — enough for section names and a few keys.
    static func parseIni(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var section: String?
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if let i = line.firstIndex(where: { $0 == ";" || $0 == "#" }) { line = String(line[..<i]) }
            line = line.trimmed
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 3 {
                let name = String(line.dropFirst().dropLast()).trimmed
                section = name
                if out[name] == nil { out[name] = [:] }
                continue
            }
            if let eq = line.firstIndex(of: "="), eq != line.startIndex, let s = section {
                out[s]?[String(line[..<eq]).trimmed] = String(line[line.index(after: eq)...]).trimmed
            }
        }
        return out
    }

    /// Profiles the user has. `~/.aws/config` names them `[profile x]` while
    /// `~/.aws/credentials` names them `[x]`, so both are normalised here.
    static func listProfiles(dir: String? = nil) -> [Profile] {
        let d = dir ?? configDir()
        var names: [String] = []
        var details: [String: Profile] = [:]
        for (file, stripPrefix) in [("config", true), ("credentials", false)] {
            guard let text = try? String(contentsOfFile: d + "/" + file, encoding: .utf8) else { continue }
            let ini = parseIni(text)
            for section in ini.keys.sorted() {
                let values = ini[section] ?? [:]
                if section.hasPrefix("sso-session ") { continue }
                let name = stripPrefix
                    ? section.replacingOccurrences(of: #"^profile\s+"#, with: "", options: .regularExpression) : section
                if !names.contains(name) { names.append(name) }
                var p = details[name] ?? Profile(name: name)
                p.region = values["region"]?.nilIfEmpty ?? p.region
                p.sso = values["sso_session"]?.nilIfEmpty != nil || values["sso_start_url"]?.nilIfEmpty != nil || p.sso
                p.assumesRole = values["role_arn"]?.nilIfEmpty != nil || p.assumesRole
                p.staticKey = values["aws_access_key_id"]?.nilIfEmpty != nil || p.staticKey
                p.credentialProcess = values["credential_process"]?.nilIfEmpty != nil || p.credentialProcess
                details[name] = p
            }
        }
        return names.sorted { a, b in
            if a == "default" { return b != "default" }
            if b == "default" { return false }
            return a.localizedCompare(b) == .orderedAscending
        }.map { details[$0] ?? Profile(name: $0) }
    }

    /// Credentials for a profile, however that profile happens to get them.
    /// The CLI's `export-credentials` runs the whole provider chain — SSO,
    /// assumed roles, credential_process, instance metadata — which is
    /// precisely the part worth not reimplementing.
    static func resolveProfile(_ profile: String? = "default", refresh: Bool = false) async throws -> Resolved {
        let key = profile?.nilIfEmpty ?? "default"
        let hit = lock.withLock { cache[key] }
        // A minute of headroom: credentials that expire mid-upload are worse
        // than fetching them again.
        if !refresh, let hit, hit.1 == 0 || hit.1 - nowMs() > 60_000 { return hit.0 }

        let r = await Proc.run(findAwsCli(), ["configure", "export-credentials", "--profile", key, "--format", "process"],
                               env: ["PATH": Proc.path + ":/usr/local/bin:/opt/homebrew/bin"], timeout: 60)
        if r.ok {
            let doc = JSON.tryParse(r.out)
            if let id = doc["AccessKeyId"].string?.nilIfEmpty, let secret = doc["SecretAccessKey"].string?.nilIfEmpty {
                let exp = doc["Expiration"].string?.nilIfEmpty
                let creds = Resolved(accessKeyId: id, secretAccessKey: secret, sessionToken: doc["SessionToken"].string?.nilIfEmpty,
                                     source: "aws cli", expiration: exp)
                lock.withLock { cache[key] = (creds, exp.map { S3Pure.parseIsoMs($0) } ?? 0) }
                return creds
            }
        }
        let cliMessage = (r.spawnError == nil ? (r.err.nilIfEmpty ?? r.out) : "").trimmed
            .components(separatedBy: "\n").filter { !$0.isEmpty }.last

        // Fall back to a static key pair, the one case readable without the CLI.
        if let s = staticKeys(key) { return s }

        if let m = cliMessage, m.range(of: #"sso|token.*expired|Error loading SSO"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw AppError("AWS profile \"\(key)\" needs a fresh login. Run: aws sso login --profile \(key)")
        }
        if let m = cliMessage { throw AppError("AWS profile \"\(key)\": \(m)") }
        throw AppError("AWS profile \"\(key)\" has no usable credentials, and the AWS CLI is not available to resolve it.")
    }

    static func staticKeys(_ profile: String, dir: String? = nil) -> Resolved? {
        let d = dir ?? configDir()
        for file in ["credentials", "config"] {
            guard let text = try? String(contentsOfFile: d + "/" + file, encoding: .utf8) else { continue }
            let ini = parseIni(text)
            let section = ini[profile] ?? ini["profile " + profile]
            if let id = section?["aws_access_key_id"]?.nilIfEmpty, let secret = section?["aws_secret_access_key"]?.nilIfEmpty {
                return Resolved(accessKeyId: id, secretAccessKey: secret, sessionToken: section?["aws_session_token"]?.nilIfEmpty,
                                source: "~/.aws/\(file)", expiration: nil)
            }
        }
        return nil
    }

    /// The profile's configured region, so a bucket need not be told twice.
    static func profileRegion(_ profile: String? = "default") -> String {
        let name = profile?.nilIfEmpty ?? "default"
        if let r = listProfiles().first(where: { $0.name == name })?.region.nilIfEmpty { return r }
        let env = ProcessInfo.processInfo.environment
        return env["AWS_REGION"]?.nilIfEmpty ?? env["AWS_DEFAULT_REGION"]?.nilIfEmpty ?? ""
    }

    static func forget(_ profile: String?) {
        lock.lock(); defer { lock.unlock() }
        if let p = profile?.nilIfEmpty { cache.removeValue(forKey: p) } else { cache.removeAll() }
    }
}
