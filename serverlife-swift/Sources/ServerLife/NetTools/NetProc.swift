import Foundation

/// `execFile` with a `maxBuffer`: output past the cap stops the child, as
/// Node did, so a curl of a large file is never held in memory whole.
enum NetProc {
    struct Result {
        var code: Int32
        var stdout: Data
        var stderr: Data
        var timedOut = false
        /// The output passed the cap and the child was stopped.
        var overflowed = false
        var spawnError: String?
        var out: String { String(decoding: stdout, as: UTF8.self) }
        var err: String { String(decoding: stderr, as: UTF8.self) }
        var ok: Bool { code == 0 && !timedOut && !overflowed && spawnError == nil }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data()
        var overflowed = false, timedOut = false
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval, maxBuffer: Int) async -> Result {
        let box = Box()
        let proc: RunningProcess
        do {
            var me: RunningProcess?
            proc = try RunningProcess(exe, args, onStdout: { d in
                box.lock.lock()
                if box.out.count + d.count > maxBuffer {
                    box.out.append(d.prefix(max(0, maxBuffer - box.out.count)))
                    let first = !box.overflowed
                    box.overflowed = true
                    box.lock.unlock()
                    if first { me?.terminate(grace: 1) }
                    return
                }
                box.out.append(d)
                box.lock.unlock()
            }, onStderr: { d in
                box.lock.lock()
                if box.err.count < maxBuffer { box.err.append(d.prefix(maxBuffer - box.err.count)) }
                box.lock.unlock()
            })
            me = proc
        } catch {
            return Result(code: -1, stdout: Data(), stderr: Data(), spawnError: "\(exe): \(error.localizedDescription)")
        }
        let p = proc
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard p.isRunning else { return }
            box.lock.lock(); box.timedOut = true; box.lock.unlock()
            p.terminate(grace: 2)
        }
        let code = await p.wait()
        box.lock.lock(); defer { box.lock.unlock() }
        return Result(code: code, stdout: box.out, stderr: box.err, timedOut: box.timedOut, overflowed: box.overflowed)
    }
}
