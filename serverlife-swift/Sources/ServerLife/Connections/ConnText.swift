import Foundation

/// The pure text handling of connections.js: prompt and MFA detection, error
/// clean-up, ANSI stripping, the remote probe scripts and their parsers.
/// Nothing here spawns anything, so all of it is unit-tested.
enum ConnText {
    // MARK: regex helpers

    static func re(_ pattern: String, ci: Bool = false) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }

    static func test(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Capture groups of the first match (index 0 = whole match); nil groups are "".
    static func match(_ r: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let rg = m.range(at: i)
            guard rg.location != NSNotFound, let r = Range(rg, in: s) else { return "" }
            return String(s[r])
        }
    }

    static func replace(_ r: NSRegularExpression, in s: String, with t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    // MARK: prompts and failures

    /// `PROMPT_RE`: output from the master that wants an answer.
    static let promptRE = re(#"(password:|passphrase for|passcode|verification code|otp|tap any security key|touch your|enter your |2fa|yubikey|\(yes/no|press any key)"#, ci: true)

    static func isPrompt(_ text: String) -> Bool { test(promptRE, text) }

    private static let rbacDenied = re(#"access denied to \S+ connecting"#, ci: true)
    private static let mfaWords = re(#"mfa|multi.?factor|second factor|per-session|webauthn|security key"#, ci: true)
    private static let tooMany = re(#"too many authentication failures"#, ci: true)
    private static let deniedPublickey = re(#"permission denied \(publickey"#, ci: true)

    /// `looksLikeMfa`: does this failure look like a node that requires
    /// per-session MFA? `tsh proxy ssh` does not perform the ceremony, so the
    /// OpenSSH path just runs out of keys.
    static func looksLikeMfa(_ text: String) -> Bool {
        // An explicit RBAC refusal names the login and is not an MFA problem.
        if test(rbacDenied, text) { return false }
        return test(mfaWords, text) || test(tooMany, text) || test(deniedPublickey, text)
    }

    private static let interesting = re(#"permission denied|connection refused|connection closed|could not resolve|no route to host|timed out|host key|offline or does not exist|not found|access denied|ERROR|Too many authentication"#, ci: true)
    private static let sgr = re(#"\x1b\[[0-9;]*m"#)

    /// `cleanupError`: turn noisy ssh output into something worth showing.
    static func cleanupError(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmed }.filter { !$0.isEmpty }
        let hits = lines.filter { test(interesting, $0) }
        let pick = (hits.isEmpty ? lines : hits).suffix(2).joined(separator: " — ")
        let clean = String(replace(sgr, in: pick, with: "").prefix(300))
        return clean.isEmpty ? nil : clean
    }

    private static let problem = re(#"open failed|refused|timed out|unreachable|Could not resolve|No route"#, ci: true)

    /// `firstProblem`: the line of ssh's complaint that says what went wrong.
    static func firstProblem(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
        return lines.first { test(problem, $0) } ?? lines.last ?? ""
    }

    private static let osc = re(#"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#)
    private static let csi = re(#"\x1b\[[0-9;?]*[ -/]*[@-~]"#)
    private static let charset = re(#"\x1b[()][A-Za-z0-9]"#)
    private static let keypad = re(#"\x1b[=>]"#)
    private static let loneCR = re(#"\r(?!\n)"#)

    /// `stripAnsi`: remove escape sequences so a session log reads as text.
    static func stripAnsi(_ text: String) -> String {
        var s = replace(osc, in: text, with: "")
        s = replace(csi, in: s, with: "")
        s = replace(charset, in: s, with: "")
        s = replace(keypad, in: s, with: "")
        return replace(loneCR, in: s, with: "\n")
    }

    private static let anyCSI = re(#"\x1b\[[0-9;?]*[a-zA-Z]"#)
    private static let spaces = re(#"\s+"#)

    /// What `tshScp` shows when it fails: no escapes, one line.
    static func flatten(_ text: String) -> String {
        replace(spaces, in: replace(anyCSI, in: text, with: ""), with: " ").trimmed
    }

    // MARK: remote scripts

    /// Exec the first sftp-server that exists, writing nothing to stdout
    /// before it so the SFTP stream starts clean.
    static let sftpServerChain = [
        "for p in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server",
        "/usr/lib/ssh/sftp-server /usr/libexec/sftp-server /usr/lib/sftp-server",
        "/usr/lib/ssh/sftp-server; do [ -x \"$p\" ] && exec \"$p\"; done;",
        "command -v sftp-server >/dev/null 2>&1 && exec sftp-server;",
        "echo \"sftp-server not found on this host\" >&2; exit 127",
    ].joined(separator: " ")

    /// Best-effort "what directory is the user's shell in" — walks real shell
    /// processes newest-first, skipping this probe and its parent.
    static let cwdProbe = #"""
self=$$
parent=$PPID
for p in $(ps -u "$(id -un)" -o pid=,comm= 2>/dev/null \
           | awk '$2 ~ /^-?(bash|zsh|sh|fish|ksh|dash|tcsh|csh)$/ { print $1 }' \
           | sort -rn); do
  [ "$p" = "$self" ] && continue
  [ "$p" = "$parent" ] && continue
  d=$(readlink "/proc/$p/cwd" 2>/dev/null)
  if [ -z "$d" ]; then
    d=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  fi
  case "$d" in
    /*) echo "$d"; break ;;
  esac
done
"""#

    /// The "Server profile" probe: any POSIX shell, silent about anything the
    /// box does not have, and always exit 0 (a report, not a test).
    static let infoScript = #"""
echo "kernel_sys=$(uname -s 2>/dev/null)"
echo "kernel=$(uname -r 2>/dev/null)"
echo "arch=$(uname -m 2>/dev/null)"
echo "hostname=$(hostname 2>/dev/null)"
echo "user=$(id -un 2>/dev/null)"
echo "shell=$SHELL"
if [ -r /etc/os-release ]; then
  . /etc/os-release 2>/dev/null
  echo "os_pretty=$PRETTY_NAME"
  echo "os_name=$NAME"
  echo "os_version=$VERSION"
  echo "os_id=$ID"
elif [ "$(uname -s)" = "Darwin" ]; then
  echo "os_pretty=macOS $(sw_vers -productVersion 2>/dev/null)"
  echo "os_id=macos"
fi
echo "uptime=$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/^ *//')"
echo "cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null)"
echo "cpu_model=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "mem_total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
echo "mem_avail_kb=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)"
echo "load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
echo "disk_root=$(df -Ph / 2>/dev/null | awk 'NR==2{print $2" used "$3" ("$5")"}')"
echo "virt=$(systemd-detect-virt 2>/dev/null)"
echo "init=$(command -v systemctl >/dev/null 2>&1 && echo systemd || echo other)"
echo "users_online=$(who 2>/dev/null | wc -l | tr -d ' ')"
for p in apt dnf yum zypper apk pacman brew; do
  if command -v "$p" >/dev/null 2>&1; then echo "pkg=$p"; break; fi
done
for c in docker kubectl podman; do
  if command -v "$c" >/dev/null 2>&1; then echo "has_$c=yes"; fi
done
# The script is a report, not a test. Without this its exit status is whatever
# the last thing in it happened to return, and a perfectly good read gets
# thrown away because some box's final `command -v` found nothing.
exit 0
"""#

    /// Every common shell history file in one command, tail-bounded.
    static let historyScript: String = {
        let files = ["$HOME/.bash_history", "$HOME/.zsh_history", "$HOME/.histfile",
                     "$HOME/.local/share/fish/fish_history", "$HOME/.ash_history", "$HOME/.sh_history"]
        return [
            "LC_ALL=C",
            "for f in \(files.map { "\"\($0)\"" }.joined(separator: " ")); do",
            "  [ -r \"$f\" ] || continue",
            "  printf '@@SLHIST@@%s\\n' \"$f\"",
            "  tail -n 4000 \"$f\" 2>/dev/null",
            "done",
            "exit 0",
        ].joined(separator: "\n")
    }()

    /// The identity probe run after connecting.
    static let identityProbe = "echo \"$HOME\"; id -un; hostname"

    // MARK: parsers

    /// `key=value` lines into a map, dropping empty values (serverInfo).
    static func parseKeyValues(_ raw: String) -> [String: String] {
        var info: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            guard let i = line.firstIndex(of: "="), i > line.startIndex else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespacesAndNewlines)
            let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { info[k] = v }
        }
        return info
    }

    /// The derived fields serverInfo adds to what the probe printed.
    static func serverInfo(from values: [String: String], partial: String?, at: Double = nowMs()) -> ServerInfo {
        let osLabel = values["os_pretty"]
            ?? [values["os_name"], values["os_version"]].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            ?? values["kernel_sys"] ?? "Unknown"
        return ServerInfo(values: values,
                          memTotal: values["mem_total_kb"].flatMap(Double.init).map { $0 * 1024 },
                          memAvail: values["mem_avail_kb"].flatMap(Double.init).map { $0 * 1024 },
                          osLabel: osLabel, fetchedAt: at, partial: partial)
    }

    private static let zshLine = re(#"^:\s*(\d+):\d+;(.*)$"#)
    private static let fishLine = re(#"^- cmd:\s?(.*)$"#)
    private static let bashStamp = re(#"^#(\d{9,})$"#)
    private static let zshPath = re(#"zsh|histfile"#)

    /// `parseHistory`: bash (with or without HISTTIMEFORMAT stamps), zsh
    /// (EXTENDED_HISTORY, with backslash continuations), fish (`- cmd:`).
    static func parseHistory(_ text: String) -> [ShellHistoryEntry] {
        var out: [ShellHistoryEntry] = []
        var shell = ""
        var pending: (command: String, at: Double)?

        func push(_ command: String, _ at: Double?) {
            let c = command.trimmed
            if !c.isEmpty { out.append(ShellHistoryEntry(command: c, shell: shell, at: at)) }
        }
        func dropBackslash(_ s: String) -> String { s.hasSuffix("\\") ? String(s.dropLast()) : s }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("@@SLHIST@@") {
                if let p = pending { push(p.command, p.at); pending = nil }
                let path = String(raw.dropFirst("@@SLHIST@@".count))
                shell = test(zshPath, path) ? "zsh" : path.contains("fish") ? "fish" : path.contains("bash") ? "bash" : "sh"
                continue
            }
            if var p = pending {
                p.command += "\n" + dropBackslash(raw)
                if raw.hasSuffix("\\") { pending = p } else { push(p.command, p.at); pending = nil }
                continue
            }
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.trimmed.isEmpty { continue }

            if let m = match(zshLine, line) {
                let at = (Double(m[1]) ?? 0) * 1000
                if line.hasSuffix("\\") { pending = (dropBackslash(m[2]), at) } else { push(m[2], at) }
                continue
            }
            if let m = match(fishLine, line) { push(m[1], nil); continue }
            // fish's other keys, and its continuation lines, are not commands.
            if shell == "fish", let f = line.unicodeScalars.first, CharacterSet.whitespaces.contains(f) { continue }
            // bash's HISTTIMEFORMAT stamp is a time, not a command.
            if test(bashStamp, line) { continue }
            push(line, nil)
        }
        if let p = pending { push(p.command, p.at) }
        return out
    }

    /// Newest first, each command once, at most `limit` (shellHistory).
    static func dedupeNewestFirst(_ entries: [ShellHistoryEntry], limit: Int) -> [ShellHistoryEntry] {
        var seen = Set<String>()
        var out: [ShellHistoryEntry] = []
        for e in entries.reversed() where out.count < limit {
            if seen.contains(e.command) { continue }
            seen.insert(e.command)
            out.append(e)
        }
        return out
    }
}
