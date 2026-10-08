import Darwin
import Foundation
import Testing
@testable import ServerLife

/// A one-shot HTTP server on 127.0.0.1 that answers with fixed bytes.
private func serveOnce(_ response: Data) throws -> (port: Int, done: DispatchSemaphore) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(fd, 1)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let port = Int(UInt16(bigEndian: addr.sin_port))
    let done = DispatchSemaphore(value: 0)
    Thread {
        let c = accept(fd, nil, nil)
        var buf = [UInt8](repeating: 0, count: 8192)
        var got = Data()
        while !(String(decoding: got, as: UTF8.self).contains("\r\n\r\n")) {
            let n = recv(c, &buf, buf.count, 0); if n <= 0 { break }; got.append(contentsOf: buf[0..<n])
        }
        _ = response.withUnsafeBytes { Darwin.send(c, $0.baseAddress, $0.count, 0) }
        close(c); close(fd); done.signal()
    }.start()
    return (port, done)
}

@Suite struct S3HTTPTests {
    /// An object stored gzip-encoded is written byte for byte, not un-gzipped.
    @Test func keepsContentEncodedBytes() async throws {
        // gzip of "hello\n"
        let gz = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
                       0xe7, 0x02, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00, 0x00, 0x00])
        var resp = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: text/plain\r\nContent-Length: \(gz.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(gz)
        let (port, done) = try serveOnce(resp)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("s3-gz-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dest) }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/obj")!)
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let r = try await S3HTTP.send(req, tunnel: nil, sinkPath: dest)
        _ = done.wait(timeout: .now() + 5)
        #expect(r.status == 200)
        #expect(try Data(contentsOf: URL(fileURLWithPath: dest)) == gz)
    }

    @Test func connectRefusalIsReported() throws {
        let (port, done) = try serveOnce(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8))
        let r = S3HTTP.probeConnect(S3Tunnel(proxyHost: "127.0.0.1", proxyPort: port, caBundle: nil), target: "b.s3.amazonaws.com:443")
        _ = done.wait(timeout: .now() + 5)
        #expect(r == .refused(403))
    }
}
