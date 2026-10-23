import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Request-body builders and input validation for network features (port of `FeatureContracts`).
public enum FeatureContracts {
    /// Address family selector (stands in for `System.Net.Sockets.AddressFamily`).
    public enum AddressFamily: Sendable { case inet, inet6 }

    public static let deviceTypes = ["air_conditioner", "air_purifier", "alarm_system", "audio", "bed", "cable_box", "car", "cash_register", "coffee_maker", "credit_card_terminal", "desktop_computer", "digital_assistant", "door_bell", "door_lock", "exercise_bike", "e_reader", "fan", "game_console", "garage_door", "generic", "hard_drive", "hub", "laptop_computer", "light", "media_streamer", "network_equipment", "oven", "pet_device", "phone", "plug", "printer", "refrigerator", "remote", "scale", "security_camera", "smoke_detector", "sprinkler", "tablet", "television", "thermostat", "toaster", "unknown_computer", "vacuum", "washer_dryer", "watch"]

    /// Normalises a MAC address to lower-case colon-separated form.
    public static func mac(_ input: String?) throws -> String {
        let s = (input ?? "").replacingOccurrences(of: "[-:. ]", with: "", options: .regularExpression)
        guard s.range(of: "^[0-9a-fA-F]{12}$", options: .regularExpression) != nil else {
            throw EeroError.argument("Enter a MAC address with 12 hexadecimal digits.")
        }
        let chars = Array(s.lowercased())
        return stride(from: 0, to: 12, by: 2).map { String(chars[$0..<$0 + 2]) }.joined(separator: ":")
    }

    /// Parses an IP address, returning its family and canonical text form (like `IPAddress.TryParse` + `ToString`).
    public static func parseIP(_ text: String) -> (family: AddressFamily, canonical: String)? {
        if text.isEmpty || text.contains("\0") { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &buf, socklen_t(buf.count)) != nil else { return nil }
            return (.inet, String(cString: buf))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &buf, socklen_t(buf.count)) != nil else { return nil }
            return (.inet6, String(cString: buf))
        }
        return nil
    }

    public static func isIPAddress(_ text: String) -> Bool { parseIP(text) != nil }

    /// Validates an address of the given family and returns its canonical form.
    public static func address(_ input: String?, _ family: AddressFamily) throws -> String {
        let s = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = parseIP(s), parsed.family == family,
              family != .inet || s.range(of: #"^(\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil
        else { throw EeroError.argument("Enter a valid " + (family == .inet ? "IPv4" : "IPv6") + " address.") }
        return parsed.canonical
    }

    /// Parses an integer like `Int32.TryParse` (surrounding whitespace and a leading sign are allowed).
    static func parseInt(_ s: Substring) -> Int? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let v = Int(t), v >= Int(Int32.min), v <= Int(Int32.max) else { return nil }
        return v
    }

    /// Validates a single port or ascending port range such as `8000-8010`.
    public static func portRange(_ input: String?) throws -> String {
        let parts = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2, let a = parseInt(parts[0]), a >= 1, a <= 65535 else {
            throw EeroError.argument("Ports must be between 1 and 65535, for example 443 or 8000-8010.")
        }
        var b = a
        if parts.count == 2 {
            guard let parsed = parseInt(parts[1]), parsed >= a, parsed <= 65535 else {
                throw EeroError.argument("Enter an ascending port range between 1 and 65535.")
            }
            b = parsed
        }
        return a == b ? String(a) : "\(a)-\(b)"
    }

    private static func portCount(_ range: String) -> Int {
        let a = range.split(separator: "-")
        return a.count == 1 ? 1 : Int(a[1])! - Int(a[0])! + 1
    }

    public static func forward(_ ip: String, _ external: String, _ internalPort: String, _ protocolName: String, _ description: String, _ enabled: Bool) throws -> JSON {
        let gateway = try portRange(external), client = try portRange(internalPort)
        if portCount(gateway) != portCount(client) { throw EeroError.argument("External and internal port ranges must contain the same number of ports.") }
        if !["tcp", "udp", "both"].contains(protocolName) { throw EeroError.argument("Choose TCP, UDP, or both.") }
        return .obj(("ip", try address(ip, .inet)), ("gateway_port", gateway), ("client_port", client), ("protocol", protocolName),
                    ("description", description.trimmingCharacters(in: .whitespacesAndNewlines)), ("enabled", enabled))
    }

    public static func reservation(_ name: String, _ mac: String, _ ip: String) throws -> JSON {
        .obj(("description", name.trimmingCharacters(in: .whitespacesAndNewlines)), ("mac", try self.mac(mac)), ("ip", try address(ip, .inet)))
    }

    public static let scheduleDays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    /// Scheduled pause (or power-saving schedule when `power` is true).
    public static func schedule(_ name: String, _ days: [String], _ start: String, _ end: String, _ enabled: Bool, power: Bool = false) throws -> JSON {
        try Validation.validateName(name)
        var selected: [String] = []
        for d in days where !selected.contains(d) { selected.append(d) }
        if selected.isEmpty || selected.contains(where: { !scheduleDays.contains($0) }) { throw EeroError.argument("Choose at least one day.") }
        let a = start.trimmingCharacters(in: .whitespacesAndNewlines), b = end.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^([01][0-9]|2[0-3]):[0-5][0-9]$"
        guard a.range(of: pattern, options: .regularExpression) != nil, b.range(of: pattern, options: .regularExpression) != nil, a != b else {
            throw EeroError.argument("Use different start and end times in 24-hour HH:mm format. Overnight schedules are supported.")
        }
        return .obj(("name", name.trimmingCharacters(in: .whitespacesAndNewlines)), ("days", selected),
                    (power ? "start_time" : "start", a), (power ? "end_time" : "end", b), ("enabled", enabled))
    }

    public static func dns(_ custom: Bool, _ servers: String?, _ caching: Bool) throws -> JSON {
        let ips = (servers ?? "").split(whereSeparator: { [",", ";", "\n", "\r", " ", "\r\n"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for s in ips where !isIPAddress(s) { throw EeroError.argument("Every DNS server must be a valid IPv4 or IPv6 address.") }
        if custom && ips.isEmpty { throw EeroError.argument("Enter at least one custom DNS server.") }
        if ips.count > 4 { throw EeroError.argument("Enter no more than four DNS servers.") }
        var result = JSON.obj(("mode", custom ? "custom" : "automatic"), ("caching", caching))
        if custom { result["custom"] = .obj(("ips", ips)) }
        return .obj(("dns", result))
    }

    private static func number(_ v: String) -> UInt32 {
        v.split(separator: ".").reduce(UInt32(0)) { ($0 << 8) | UInt32($1)! }
    }

    public static func dhcp(_ mode: String, _ subnet: String, _ mask: String, _ first: String, _ last: String, _ randomization: Bool) throws -> JSON {
        if !["automatic", "custom", "bridge"].contains(mode) { throw EeroError.argument("Choose Automatic, Manual, or Bridge.") }
        var result = JSON.obj(("connection", JSON.obj(("mode", mode == "bridge" ? "bridged" : "nat"))), ("nat_port_randomization", randomization))
        var dhcp = JSON.obj(("mode", mode == "custom" ? "custom" : "automatic"))
        if mode == "custom" {
            let s = try address(subnet, .inet), m = try address(mask, .inet), f = try address(first, .inet), l = try address(last, .inet)
            let network = number(s), netmask = number(m), begin = number(f), end = number(l), inverse = ~netmask
            if netmask == 0 || (inverse & (inverse &+ 1)) != 0 || (network & netmask) != network {
                throw EeroError.argument("Enter a contiguous subnet mask and the matching subnet network address.")
            }
            if (begin & netmask) != network || (end & netmask) != network || begin <= network || end >= (network | inverse) || begin > end {
                throw EeroError.argument("The DHCP range must be ordered and inside the subnet, excluding network and broadcast addresses.")
            }
            dhcp["custom"] = .obj(("subnet_ip", s), ("subnet_mask", m), ("start_ip", f), ("end_ip", l))
        }
        if mode != "bridge" { result["dhcp"] = dhcp }
        return result
    }

    /// Normalises a website-rule domain (IDN to ASCII, lower case, no trailing dot).
    public static func domain(_ value: String?) throws -> String {
        var s = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") { s.removeLast() }
        s = s.lowercased()
        if s.contains("://") || s.contains("/") || s.contains(" ") || s.contains("@") {
            throw EeroError.argument("Enter a domain such as example.com, without https:// or a path.")
        }
        guard let ascii = IDNA.toASCII(s) else { throw EeroError.argument("Enter a valid domain name.") }
        s = ascii
        if !IDNA.isDnsHostName(s) || !s.contains(".") || s.count > 253 { throw EeroError.argument("Enter a valid domain such as example.com.") }
        return s
    }

    /// Wifi network QR-code payload.
    public static func wifiQr(_ name: String?, _ password: String?) -> String {
        func escape(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "WIFI:T:" + ((password ?? "").isEmpty ? "nopass" : "WPA") + ";S:" + escape(name) + ";P:" + escape(password) + ";;"
    }
}

/// Minimal IDNA ToASCII (the role of .NET `IdnMapping.GetAscii`) and DNS host-name check (`Uri.CheckHostName`).
public enum IDNA {
    public static func toASCII(_ host: String) -> String? {
        let normalized = host.precomposedStringWithCompatibilityMapping.lowercased()
        // Ideographic and fullwidth dots separate labels too.
        let unified = normalized.replacingOccurrences(of: "\u{3002}", with: ".").replacingOccurrences(of: "\u{FF0E}", with: ".").replacingOccurrences(of: "\u{FF61}", with: ".")
        if unified.isEmpty { return nil }
        var labels: [String] = []
        for label in unified.split(separator: ".", omittingEmptySubsequences: false) {
            if label.isEmpty { return nil }
            let scalars = Array(label.unicodeScalars)
            if scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
            let out: String
            if scalars.allSatisfy({ $0.isASCII }) { out = String(label) }
            else { guard let p = punycode(scalars) else { return nil }; out = "xn--" + p }
            if out.count > 63 { return nil }
            labels.append(out)
        }
        let result = labels.joined(separator: ".")
        return result.count > 255 ? nil : result
    }

    /// RFC 3492 Punycode encoder.
    static func punycode(_ input: [Unicode.Scalar]) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        func digit(_ d: Int) -> Character { Character(Unicode.Scalar(UInt8(d < 26 ? d + 97 : d + 22))) }
        func adapt(_ delta: Int, _ numPoints: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / numPoints
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        let codes = input.map { Int($0.value) }
        var output = String(codes.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) })
        let b = output.count
        var h = b
        if b > 0 { output.append("-") }
        var n = 0x80, delta = 0, bias = 72
        while h < codes.count {
            guard let m = codes.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (h + 1)
            n = m
            for c in codes {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta, k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1; n += 1
        }
        return output
    }

    /// True for a syntactically valid DNS host name that is not an IP literal.
    public static func isDnsHostName(_ s: String) -> Bool {
        if s.isEmpty || s.count > 255 { return false }
        if FeatureContracts.parseIP(s) != nil { return false }
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let first = label.unicodeScalars.first, label.count <= 63,
                  first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
            for u in label.unicodeScalars where !(u.isASCII && (CharacterSet.alphanumerics.contains(u) || u == "-" || u == "_")) { return false }
        }
        return true
    }
}
