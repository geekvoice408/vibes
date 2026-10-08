import Foundation

/// What each session is doing, for the tab strip to show — the port of
/// activity.js.
///
/// A row of tabs says what is open and nothing about what is happening in
/// them. That is fine with two; with eight it means clicking through the lot
/// to find the build that is still running, or — worse — the one that stopped
/// four minutes ago on `[sudo] password for steven:` and has been waiting
/// ever since. Both are visible from the output alone, and the output all
/// passes through one function on its way to the terminal.
///
/// Three states, in order of how much they want you:
///
///   waiting — output has stopped at something that reads like a question.
///   moving  — bytes arrived just now: a build, a tail, a long install.
///   idle    — neither.
///
/// Deliberately built on the byte stream and not on anything the shell is
/// asked, because a probe costs a channel — and on a recorded cluster, an
/// audit entry — every few seconds per pane.
@MainActor
final class PaneActivity {
    static let shared = PaneActivity()

    enum State: String { case idle, moving, waiting }

    /// How long after the last byte a pane still counts as moving.
    static let movingMs: Double = 900
    /// How long it has to have been quiet before a question counts as one.
    static let settleMs: Double = 400
    /// The tail kept per pane: long enough for a whole permission box.
    static let tailLength = 700

    private struct Record { var at: Double; var tail: String }
    private var panes: [String: Record] = [:]

    /// Reads what is on a pane's screen (the bottom of the buffer), where
    /// that can be read. Sessions installs it; tests leave it nil.
    var screenOf: ((String) -> String?)?

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// Output has arrived in a pane. On the hot path: a timestamp, and a few
    /// hundred characters kept for the prompt test. A big chunk is trimmed
    /// before it is cleaned, so a megabyte of `cat` costs the same as a line.
    func noteOutput(_ paneId: String, _ data: String) {
        guard !paneId.isEmpty, !data.isEmpty else { return }
        let raw = data.count > 400 ? String(data.suffix(400)) : data
        let prev = panes[paneId]?.tail ?? ""
        let tail = String((prev + ActivityText.plain(raw)).suffix(PaneActivity.tailLength))
        panes[paneId] = Record(at: PaneActivity.now(), tail: tail)
    }

    func noteOutput(_ paneId: String, bytes: Data) {
        guard !bytes.isEmpty else { return }
        let slice = bytes.count > 400 ? bytes.suffix(400) : bytes
        noteOutput(paneId, String(decoding: slice, as: UTF8.self))
    }

    /// A pane that has gone takes its record with it.
    func forget(_ paneId: String) { panes.removeValue(forKey: paneId) }

    /// 'moving' | 'waiting' | 'idle' for one pane.
    func paneActivity(_ paneId: String) -> State {
        guard let rec = panes[paneId] else { return .idle }
        let since = PaneActivity.now() - rec.at
        if since >= PaneActivity.settleMs {
            let screen = screenOf?(paneId) ?? ""
            if ActivityText.looksLikePrompt(screen.isEmpty ? rec.tail : screen) { return .waiting }
        }
        if since < PaneActivity.movingMs { return .moving }
        return .idle
    }

    /// For a tab: whichever of its panes wants you most.
    func tabActivity(_ paneIds: [String]) -> State {
        var out = State.idle
        for id in paneIds {
            let a = paneActivity(id)
            if a == .waiting { return .waiting }
            if a == .moving { out = .moving }
        }
        return out
    }

    /// Whether the tabs report what their sessions are doing at all.
    static var showTabActivity: Bool { Store.shared.settingJSON("showTabActivity").bool != false }
}

/// The text side of activity detection: pure, so it can be tested.
enum ActivityText {
    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }
    private static func reCS(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [])
    }

    /// Lines that are asking for something, anchored to the end of the output.
    static let lastLine: [NSRegularExpression] = [
        re(#"(?:password|passphrase|passcode)(?:[^\n]{0,40})?:\s*$"#),
        re(#"\[sudo\] password for [^\n]*:\s*$"#),
        re(#"\[y/n\]\s*\??\s*$"#),
        re(#"\(yes/no(?:/\[fingerprint\])?\)\?\s*$"#),
        re(#"\b(?:y/n|yes/no)\b[^\n]{0,20}\?\s*$"#),
        re(#"press (?:enter|return|any key)[^\n]*$"#),
        re(#"(?:are you sure|do you want to|continue|proceed|overwrite|replace)[^\n]{0,40}\?\s*$"#),
        re(#"(?:otp|mfa|verification|authentication) code[^\n]{0,20}:?\s*$"#),
        re(#"tap any security key"#),
        re(#"enter your (?:otp|code|token)[^\n]*$"#),
    ]

    /// Phrases that mean somebody is being asked, not told.
    static let asking: [NSRegularExpression] = [
        re(#"\byes,? and (?:don.t ask again|approve)"#),
        re(#"\bno,? and tell (?:claude|codex|the agent)"#),
        re(#"\bwaiting for (?:your )?(?:approval|confirmation|input)\b"#),
        re(#"\ballow (?:this )?(?:command|tool|edit|request)\b[^\n]{0,30}\?"#),
        re(#"\bapprove (?:this|the) (?:command|edit|change|tool)\b"#),
        re(#"\bpress (?:1|y|enter) to (?:confirm|approve|continue)\b"#),
        re(#"\bdo you want to [^\n]{0,70}\?"#),
        re(#"\bwould you like to [^\n]{0,70}\?"#),
    ]

    /// An option, a border, or the escape hint: the furniture of a prompt box.
    static let boxLine: [NSRegularExpression] = [
        reCS(#"^[\s│|]*[❯>*]?\s*\d+[.)]\s+\S"#),
        reCS(#"^[\s│─╭╮╯╰┌┐└┘├┤]+$"#),
        re(#"\besc to (?:cancel|reject|interrupt|go back)\b"#),
        re(#"^[\s│|]*\(?y(?:es)?\)?\s*[/|]\s*\(?n(?:o)?\)?\s*$"#),
        reCS(#"^\s*[❯>]\s*$"#),
    ]

    private static func any(_ list: [NSRegularExpression], _ s: String) -> Bool {
        let r = NSRange(location: 0, length: (s as NSString).length)
        return list.contains { $0.firstMatch(in: s, range: r) != nil }
    }

    /// Does the output read as something waiting for an answer?
    ///
    /// A shell asks on the line the cursor is sitting on; an agent asks inside
    /// a box, so the question is found in the last handful of lines — but
    /// only while the last line still belongs to the prompt.
    static func looksLikePrompt(_ tail: String) -> Bool {
        var text = tail
        while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            text.unicodeScalars.removeLast()
        }
        if text.isEmpty { return false }
        var lines = text.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last else { return false }
        if any(lastLine, last) { return true }
        let stillOnScreen = any(boxLine, last) || any(asking, last)
        if !stillOnScreen { return false }
        let recent = lines.suffix(12).joined(separator: "\n")
        return any(asking, recent)
    }

    private static let osc = reCS("\u{1b}\\][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)")
    private static let csi = reCS("\u{1b}\\[[0-9;?]*[ -/]*[@-~]")
    private static let charset = reCS("\u{1b}[()][B0UK]")
    private static let controls = reCS("[\u{00}-\u{08}\u{0b}\u{0c}\u{0e}-\u{1f}]")
    private static let crlf = reCS("\r\n?")

    /// Escape sequences out, carriage returns to line breaks.
    static func plain(_ s: String) -> String {
        var out = s
        for (r, with) in [(osc, ""), (csi, ""), (charset, ""), (controls, ""), (crlf, "\n")] {
            out = r.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length),
                                             withTemplate: with)
        }
        return out
    }
}
