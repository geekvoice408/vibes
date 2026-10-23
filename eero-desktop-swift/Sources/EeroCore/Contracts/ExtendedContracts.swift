import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Contracts for invitations, licences, ISP settings, captive-portal assets and DNS tests (port of `ExtendedContracts`).
public enum ExtendedContracts {
    /// `Uri.UnescapeDataString`: decodes percent escapes, leaving invalid sequences as they are.
    static func unescape(_ s: Substring) -> String { unescape(String(s)) }
    static func unescape(_ s: String) -> String { s.removingPercentEncoding ?? s }

    /// Accepts an invitation code or an https eero.com invitation link and returns the code.
    public static func inviteCode(_ input: String?) throws -> String {
        var code = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: code), let scheme = url.scheme, !scheme.isEmpty, code.contains(":") {
            let host = (url.host ?? "").lowercased()
            guard scheme.lowercased() == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
                  host == "eero.com" || host.hasSuffix(".eero.com") else {
                throw EeroError.argument("Use the eero invitation link or its invitation code.")
            }
            let query = (url.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: false)
                .map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
                .filter { $0.count == 2 }
            if let pair = query.first(where: { ["invite_code", "inviteCode", "code"].contains(unescape($0[0])) }) {
                code = unescape(pair[1])
            } else {
                let trimmed = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                code = trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            }
        }
        guard code.range(of: "^[A-Za-z0-9_~.+/=-]{4,2048}$", options: .regularExpression) != nil else {
            throw EeroError.argument("Enter a valid invitation code or eero invitation link.")
        }
        return code
    }

    /// Server-provided identifier that is safe to place in an API path.
    @discardableResult
    public static func identifier(_ input: String?) throws -> String {
        guard let input, input.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw EeroError.argument("The service returned an invalid identifier.")
        }
        return input
    }

    public static func inviteResponse(_ code: String, _ accept: Bool) throws -> JSON {
        .obj(("invite_code", try inviteCode(code)), ("accept", accept))
    }

    /// Software licence validation body, or an activation body when `networkId` is given.
    public static func license(_ key: String?, _ networkId: String? = nil, autoRenew: Bool = false) throws -> JSON {
        let key = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let length = key.utf16.count
        if length < 4 || length > 512 || key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw EeroError.argument("Enter the software license key supplied with your subscription.")
        }
        guard let networkId else { return .obj(("software_key", key)) }
        return .obj(("software_key", key), ("network_id", try identifier(networkId)), ("auto_renew", autoRenew))
    }

    public static func pppoe(_ enabled: Bool, _ username: String?, _ password: String?, _ replaceCredentials: Bool, _ vlan: String?) throws -> JSON {
        var pppoe = JSON.obj(("enabled", enabled))
        if enabled && replaceCredentials {
            let user = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, let password, !password.isEmpty else {
                throw EeroError.argument("Enter both the PPPoE username and password provided by your ISP.")
            }
            pppoe["credentials"] = .obj(("username", user), ("password", password))
        }
        var body = JSON.obj(("pppoe", pppoe))
        let v = vlan ?? ""
        if !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let tag = FeatureContracts.parseInt(Substring(v)), tag >= 0, tag <= 4094 else {
                throw EeroError.argument("VLAN ID must be between 0 and 4094.")
            }
            body["vlan"] = .string(String(tag))
        } else {
            body["vlan"] = ""
        }
        return body
    }

    /// Only HTTPS Amazon S3 destinations are accepted for captive-portal uploads.
    public static func uploadUrl(_ input: String?) throws -> URL {
        let invalid = EeroError.data("eero did not return a supported secure S3 upload destination.")
        guard let input, let c = URLComponents(string: input), let url = c.url, let host = c.host,
              c.scheme?.lowercased() == "https", c.port == nil || c.port == 443, c.user == nil, c.password == nil, c.fragment == nil,
              host.range(of: #"^(?:[a-z0-9][a-z0-9.-]*\.)?s3(?:[.-][a-z0-9-]+)?\.amazonaws\.com$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { throw invalid }
        return url
    }

    /// Verifies a captive-portal asset by size, extension and file signature and returns its MIME type.
    public static func portalMime(_ path: String, _ bytes: Data?, logo: Bool) throws -> String {
        guard let bytes, bytes.count >= 8, bytes.count <= (logo ? 5 : 10) * 1024 * 1024 else {
            throw EeroError.argument("Select a logo up to 5 MB or a PDF up to 10 MB.")
        }
        let b = [UInt8](bytes.prefix(8))
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if logo && ext == "png" && b == [137, 80, 78, 71, 13, 10, 26, 10] { return "image/png" }
        if logo && (ext == "jpg" || ext == "jpeg") && b[0] == 255 && b[1] == 216 && b[2] == 255 { return "image/jpeg" }
        if !logo && ext == "pdf" && Array(b.prefix(5)) == [37, 80, 68, 70, 45] { return "application/pdf" }
        throw EeroError.argument(logo ? "Select a PNG or JPEG image." : "Select a PDF document.")
    }

    public static func importJob(_ importPath: String?, logo: Bool, _ configurationId: String) throws -> JSON {
        guard let importPath, !importPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, importPath.utf16.count <= 4096 else {
            throw EeroError.data("eero did not return an import path.")
        }
        let metadata = JSON.obj(("configuration-id", try identifier(configurationId))).serialized()
        return .obj(("import_file_path", importPath), ("import_job_type", logo ? "CaptivePortalLogo" : "CaptivePortalToS"), ("metadata", metadata))
    }

    public static func email(_ value: String?) throws -> String {
        let value = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.utf16.count > 254 || value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            throw EeroError.argument("Enter a valid email address.")
        }
        return value
    }

    /// Gateway DNS performance test request.
    public static func dnsPerformance(_ text: String?, _ port: Int) throws -> JSON {
        var servers: [String] = []
        for s in (text ?? "").split(whereSeparator: { ["\r", "\n", "\r\n", ",", ";"].contains($0) }) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !servers.contains(t) { servers.append(t) }
        }
        if servers.isEmpty || servers.count > 8 || port < 1 || port > 65535 {
            throw EeroError.argument("Enter one to eight DNS server IP addresses and a port between 1 and 65535.")
        }
        var entries: [JSON] = []
        for server in servers {
            guard let ip = FeatureContracts.parseIP(server) else { throw EeroError.argument("Enter DNS server IP addresses rather than hostnames or URLs.") }
            entries.append(.obj(("ip", ip.canonical), ("port", port)))
        }
        return .obj(("servers", JSON.array(entries)))
    }
}

/// Uploads a captive-portal asset to the signed S3 URL eero returns (port of `PortalUpload`).
/// Uses its own transport so the eero session cookie is never forwarded to storage.
public enum PortalUpload {
    public static func send(_ upload: JSON, _ data: Data, mime: String, transport: HTTPTransport = URLSessionTransport()) async throws {
        let url = try ExtendedContracts.uploadUrl(upload.s("signed_upload_url"))
        let key = upload.s("kms_key_id")
        if key.isEmpty || key.utf16.count > 2048 || key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw EeroError.data("The upload encryption key is missing or invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("aws:kms", forHTTPHeaderField: "x-amz-server-side-encryption")
        request.setValue(key, forHTTPHeaderField: "x-amz-server-side-encryption-aws-kms-key-id")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let response = try await transport.send(request)
        if !response.isSuccess {
            throw EeroError.operation("The storage service rejected the upload (\(response.status)). No import was requested.")
        }
    }
}
