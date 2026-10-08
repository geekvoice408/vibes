import Testing
import AppKit
@testable import ServerLife

// RDP: the settings written into the file the client reads (devices.test.mjs),
// and the VNC view drawing a real session the right way up.

@Suite struct RDPTests {
    private func file(_ j: JSON) -> String { RDPLauncher.rdpFile(RDPConnection(json: j)) }
    private func has(_ f: String, _ line: String) -> Bool { f.components(separatedBy: "\r\n").contains(line) }

    @Test func fileCarriesTheConnection() {
        let f = file(["hostname": "win-1", "port": 3389, "username": "admin", "width": 1600, "height": 1000])
        #expect(has(f, "full address:s:win-1"), "the default port is not appended")
        #expect(has(f, "username:s:admin"))
        #expect(has(f, "desktopwidth:i:1600"))
        #expect(has(f, "desktopheight:i:1000"))
        #expect(has(f, "smart sizing:i:1"))
        #expect(has(f, "screen mode id:i:1"))
        #expect(has(f, "prompt for credentials:i:1"))
        #expect(has(f, "authentication level:i:2"))
        #expect(has(f, "session bpp:i:32"))
        #expect(f.contains("\r\n") && f.hasSuffix("\r\n"), "the format is CRLF")
    }

    @Test func nonDefaultPortGoesOnTheAddress() {
        #expect(has(file(["hostname": "win-1", "port": 33389]), "full address:s:win-1:33389"))
        // A saved profile's field names.
        #expect(has(file(["host": "win-2", "devicePort": 3390]), "full address:s:win-2:3390"))
    }

    @Test func fullScreenDropsTheSize() {
        let f = file(["hostname": "w", "fullscreen": true, "multimon": true])
        #expect(has(f, "screen mode id:i:2"))
        #expect(has(f, "use multimon:i:1"))
        #expect(!f.contains("desktopwidth"))
    }

    @Test func redirectionsOffUnlessAskedFor() {
        let f = file(["hostname": "w"])
        #expect(has(f, "drivestoredirect:s:"))
        #expect(has(f, "redirectprinters:i:0"))
        #expect(has(f, "redirectclipboard:i:1"))
        #expect(has(f, "audiomode:i:0"))
        #expect(has(f, "administrative session:i:0"))
        let g = file(["hostname": "w", "drives": true, "printers": true, "clipboard": false, "audio": "none",
                      "adminSession": true, "colorDepth": 16])
        #expect(has(g, "drivestoredirect:s:*") && has(g, "redirectprinters:i:1") && has(g, "redirectclipboard:i:0"))
        #expect(has(g, "audiomode:i:2") && has(g, "administrative session:i:1") && has(g, "session bpp:i:16"))
        #expect(has(file(["hostname": "w", "audio": "remote"]), "audiomode:i:1"))
    }

    @Test func domainAndGateway() {
        let f = file(["hostname": "w", "domain": "CORP", "gateway": "gw.example.com"])
        #expect(has(f, "domain:s:CORP"))
        #expect(has(f, "gatewayhostname:s:gw.example.com"))
        #expect(has(f, "gatewayusagemethod:i:1"))
        #expect(has(f, "gatewaycredentialssource:i:4"))
        #expect(!file(["hostname": "w"]).contains("gateway"))
    }

    @Test func pathIsSafe() {
        #expect(RDPLauncher.rdpPath("Win Server / 1").lastPathComponent == "serverlife-Win_Server_1.rdp")
        #expect(RDPLauncher.rdpPath(nil).lastPathComponent == "serverlife-session.rdp")
        #expect(RDPLauncher.rdpPath(String(repeating: "a", count: 100)).lastPathComponent.count == "serverlife-.rdp".count + 60)
    }

    @MainActor @Test func noHostname() async {
        do { _ = try await RDPLauncher.launch(RDPConnection(hostname: "")); Issue.record("launched?") }
        catch { #expect("\(error)" == "No hostname") }
    }
}

@Suite(.serialized) struct VNCViewTests {
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    /// A 4×2 screen: top row red, bottom row blue, drawn scaled into a pane.
    @MainActor @Test func drawsTheScreenRightWayUp() async throws {
        let server = try LoopbackServer()
        let t = Task.detached {
            let c = try server.accept()
            try c.send(Array("RFB 003.008\n".utf8)); _ = try c.recv(exactly: 12)
            try c.send([1, 1]); _ = try c.recv(exactly: 1)
            try c.send([0, 0, 0, 0]); _ = try c.recv(exactly: 1)
            try c.send(self.be16(4) + self.be16(2) + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 1] + Array("x".utf8))
            _ = try c.recv(exactly: 20)
            let head = try c.recv(exactly: 4)
            _ = try c.recv(exactly: (Int(head[2]) << 8 | Int(head[3])) * 4 + 10)
            let red: [UInt8] = [0, 0, 255, 0], blue: [UInt8] = [255, 0, 0, 0]
            let pixels = Array([[UInt8]](repeating: red, count: 4).joined()) + Array([[UInt8]](repeating: blue, count: 4).joined())
            try c.send([0, 0] + self.be16(1) + self.be16(0) + self.be16(0) + self.be16(4) + self.be16(2) + [0, 0, 0, 0] + pixels)
            // Stay connected until the client hangs up (or 15 s pass).
            while (try? c.recv()) != nil {}
        }
        let session = VNCSession()
        session.connect(host: "127.0.0.1", port: server.port)
        for _ in 0..<150 where !(session.state == .connected && session.frame > 0) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(session.state == .connected)
        #expect(session.desktopName == "x" && session.width == 4 && session.height == 2)

        let view = VNCFramebufferView(session: session)
        view.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
        view.layoutSubtreeIfNeeded()
        view.layout()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        func color(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let c = rep.colorAt(x: x * rep.pixelsWide / 80, y: y * rep.pixelsHigh / 40)?.usingColorSpace(.sRGB)
            return (Double(c?.redComponent ?? 0), Double(c?.greenComponent ?? 0), Double(c?.blueComponent ?? 0))
        }
        let top = color(40, 8), bottom = color(40, 32)
        #expect(top.0 > 0.8 && top.2 < 0.2, "top half red: \(top)")
        #expect(bottom.2 > 0.8 && bottom.0 < 0.2, "bottom half blue: \(bottom)")

        // 1:1 mode: the canvas is the screen's size (at least the pane's).
        session.scaling = .none
        view.applyScaling()
        #expect(session.scaling == .none)
        session.disconnect()
        #expect(session.state == .closed)
        _ = try? await t.value
    }
}
