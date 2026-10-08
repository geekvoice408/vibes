import AppKit
import UniformTypeIdentifiers

/// A saved Remote Desktop connection, as the original passed it to
/// `rdp:launch` (field names are the JS ones).
struct RDPConnection: Hashable {
    var name: String?
    var hostname: String
    var port: Int?
    var username: String?
    var domain: String?
    var fullscreen = false
    var multimon = false
    var width: Int?
    var height: Int?
    var colorDepth: Int?
    /// nil = on (only an explicit false turns it off).
    var clipboard: Bool?
    /// "local" (default), "remote", "none".
    var audio: String?
    var printers = false
    var drives = false
    var adminSession = false
    var gateway: String?

    init(hostname: String) { self.hostname = hostname }

    /// From the launch request or a saved profile (`host`/`devicePort` are
    /// the profile's names for hostname/port).
    init(json j: JSON) {
        hostname = j["hostname"].stringish ?? j["host"].stringish ?? ""
        name = j["name"].string
        port = j["port"].int ?? j["devicePort"].int
        username = j["username"].string ?? j["user"].string
        domain = j["domain"].string
        fullscreen = j["fullscreen"].truthy
        multimon = j["multimon"].truthy
        width = j["width"].int
        height = j["height"].int
        colorDepth = j["colorDepth"].int
        clipboard = j["clipboard"].bool
        audio = j["audio"].string
        printers = j["printers"].truthy
        drives = j["drives"].truthy
        adminSession = j["adminSession"].truthy
        gateway = j["gateway"].string
    }
}

/// Remote Desktop, handed to the client the machine already has (rdp.js).
///
/// RDP is not drawn in the app: it is a bundle of virtual channels, and a
/// viewer that implements the drawing orders and none of the rest is a demo.
/// What is kept here is the settings, written into the `.rdp` file the
/// platform's client reads.
enum RDPLauncher {
    /// Windows App and Microsoft Remote Desktop 10 share the first id; the
    /// others are the older and beta clients.
    static let bundleIds = ["com.microsoft.rdc.macos", "com.microsoft.rdc.osx.beta", "com.microsoft.rdc.mac",
                            "com.microsoft.rdc"]

    /// The settings, in the `.rdp` format (`rdpFile`). Only the keys worth a
    /// saved connection; CRLF line endings.
    static func rdpFile(_ c: RDPConnection) -> String {
        let addr = (c.port != nil && c.port != 3389) ? "\(c.hostname):\(c.port!)" : c.hostname
        let audio = c.audio == "none" ? 2 : c.audio == "remote" ? 1 : 0
        var lines = [
            "full address:s:\(addr)",
            "screen mode id:i:\(c.fullscreen ? 2 : 1)",
            "session bpp:i:\(c.colorDepth.flatMap { $0 > 0 ? $0 : nil } ?? 32)",
            "redirectclipboard:i:\(c.clipboard == false ? 0 : 1)",
            "audiomode:i:\(audio)",
            "redirectprinters:i:\(c.printers ? 1 : 0)",
            "drivestoredirect:s:\(c.drives ? "*" : "")",
            "administrative session:i:\(c.adminSession ? 1 : 0)",
            "prompt for credentials:i:1",
            // Without this a saved file is "untrusted publisher" on every launch.
            "authentication level:i:2",
        ]
        if !c.fullscreen {
            lines.append("desktopwidth:i:\(c.width.flatMap { $0 > 0 ? $0 : nil } ?? 1440)")
            lines.append("desktopheight:i:\(c.height.flatMap { $0 > 0 ? $0 : nil } ?? 900)")
            lines.append("smart sizing:i:1")
        } else if c.multimon {
            lines.append("use multimon:i:1")
        }
        if let u = c.username, !u.isEmpty { lines.append("username:s:\(u)") }
        if let d = c.domain, !d.isEmpty { lines.append("domain:s:\(d)") }
        if let g = c.gateway, !g.isEmpty {
            lines.append("gatewayhostname:s:\(g)")
            lines.append("gatewayusagemethod:i:1")
            lines.append("gatewaycredentialssource:i:4")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Where the generated file goes: per user, overwritten each launch (`rdpPath`).
    static func rdpPath(_ name: String?) -> URL {
        let raw = (name?.isEmpty == false) ? name! : "session"
        let re = try! NSRegularExpression(pattern: #"[^\w.-]+"#)
        var safe = re.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "_")
        if safe.count > 60 { safe = String(safe.prefix(60)) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("serverlife-\(safe).rdp")
    }

    /// The installed Microsoft client, if any (by bundle id), else whatever
    /// claims `.rdp` files.
    static func clientApp(for file: URL? = nil) -> URL? {
        // Whatever the user has chosen for .rdp files comes first, as
        // `shell.openPath` did (Royal TSX, Jump Desktop …).
        if let file, let u = NSWorkspace.shared.urlForApplication(toOpen: file) { return u }
        if let t = UTType(filenameExtension: "rdp"), let u = NSWorkspace.shared.urlForApplication(toOpen: t) { return u }
        for id in bundleIds {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        return nil
    }

    /// `rdp:available`: is there anything on this machine that could open one?
    static func clientAvailable() -> Bool { clientApp() != nil }

    /// The client's display name ("Windows App", "Microsoft Remote Desktop").
    static func clientName() -> String? {
        guard let u = clientApp() else { return nil }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }

    struct Launched { var client: String; var file: URL; var app: URL }

    /// `rdp:launch`: write the file and open it in the Microsoft client.
    /// Returns what was used, so the app can say where it opened.
    @MainActor
    static func launch(_ c: RDPConnection) async throws -> Launched {
        if c.hostname.isEmpty { throw AppError("No hostname") }
        let file = rdpPath(c.name ?? c.hostname)
        do {
            try rdpFile(c).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw AppError("Could not write \(file.path): \(error.localizedDescription)")
        }
        guard let app = clientApp(for: file) else {
            throw AppError("No RDP client is set up to open .rdp files — install "
                + "Windows App (formerly Microsoft Remote Desktop) from the App Store")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: cfg)
        } catch {
            throw AppError("No RDP client is set up to open .rdp files — install "
                + "Windows App (formerly Microsoft Remote Desktop) from the App Store")
        }
        return Launched(client: "system", file: file, app: app)
    }
}
