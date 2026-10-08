import Foundation
@testable import ServerLife

/// A fresh SFTP client talking to this machine's own sftp-server over
/// stdin/stdout — no ssh involved.
func localSFTP(startDir: String? = nil) async throws -> SFTPClient {
    var args: [String] = []
    if let startDir { args += ["-d", startDir] }
    let ch = try ProcessChannel("/usr/libexec/sftp-server", args)
    let c = SFTPClient(channel: ch)
    try await c.connect(timeout: 10)
    return c
}

/// A scratch directory, removed by the caller with `cleanup`.
func scratchDir(_ tag: String = "t") throws -> String {
    let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("sl-files-\(tag)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    // sftp-server reports realpaths; /var is a link to /private/var.
    return realPath(base)
}

func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

func writeFile(_ p: String, _ s: String) throws {
    try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(s.utf8).write(to: URL(fileURLWithPath: p))
}

func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

func readData(_ p: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: p)) }
