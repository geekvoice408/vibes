import Testing
import Foundation
@testable import ServerLife

// Port of tests/activity.test.mjs. The risk is not missing a prompt — it is
// claiming one, so the wolf cases get as much attention as the real ones.

private func sleepMs(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

@Test func activityRecognisesRealPrompts() {
    let asks = [
        "[sudo] password for steven: ", "steven@web-1's password: ",
        "Enter passphrase for key /Users/steven/.ssh/id_ed25519: ",
        "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
        "Do you want to continue? [Y/n] ", "Overwrite /etc/nginx/nginx.conf? ", "Press enter to continue",
        "Press any key to continue . . .", "Enter an OTP code from a device: ", "Tap any security key", "MFA code: ",
    ]
    for line in asks { #expect(ActivityText.looksLikePrompt(line), "waiting: \(line)") }
}

@Test func activityIgnoresOrdinaryOutput() {
    let noise = [
        "➜  ~ ", "steven@web-1:~$ ", "[root@db-2 ~]# ", "Reading package lists... Done",
        "What is this? It is a line in a log file that ends in a question mark?", "Compiling serde v1.0.203",
        "100%[===================>] 4.21M  --.-KB/s    in 0.4s",
        "error: failed to run custom build command for `openssl-sys`",
        "Password changed successfully", "sudo: 1 incorrect password attempt", "", "   ",
    ]
    for line in noise { #expect(!ActivityText.looksLikePrompt(line), "not waiting: \(line)") }
}

@Test func activityOnlyLastLineCounts() {
    let tail = ["[sudo] password for steven: ", "Reading package lists... Done", "Building dependency tree... Done"].joined(separator: "\n")
    #expect(!ActivityText.looksLikePrompt(tail))
}

@Test @MainActor func activityColouredPromptIsStillAPrompt() async {
    let A = PaneActivity.shared
    A.forget("p1")
    let raw = "\u{1b}[1;31mPassword:\u{1b}[0m "
    #expect(!ActivityText.looksLikePrompt(raw))
    A.noteOutput("p1", raw)
    #expect(A.paneActivity("p1") == .moving)
    await sleepMs(450)
    #expect(A.paneActivity("p1") == .waiting)
}

@Test @MainActor func activityMovingThenWaiting() async {
    let A = PaneActivity.shared
    A.forget("p2")
    A.noteOutput("p2", "Reading package lists... ")
    #expect(A.paneActivity("p2") == .moving)
    A.noteOutput("p2", "\nDo you want to continue? [Y/n] ")
    #expect(A.paneActivity("p2") == .moving)
    await sleepMs(450)
    #expect(A.paneActivity("p2") == .waiting)
}

@Test @MainActor func activityGoesQuiet() async {
    let A = PaneActivity.shared
    A.forget("p3")
    A.noteOutput("p3", "make: Nothing to be done for `all'.\n➜  ~ ")
    await sleepMs(950)
    #expect(A.paneActivity("p3") == .idle)
}

private let claudeBox = [
    "\u{256d}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256e}",
    "\u{2502} Bash command                                    \u{2502}",
    "\u{2502}                                                 \u{2502}",
    "\u{2502}   rm -rf build/                                 \u{2502}",
    "\u{2502}   Remove the build directory                    \u{2502}",
    "\u{2502}                                                 \u{2502}",
    "\u{2502} Do you want to proceed?                         \u{2502}",
    "\u{2502} \u{276f} 1. Yes                                       \u{2502}",
    "\u{2502}   2. Yes, and don't ask again for rm commands   \u{2502}",
    "\u{2502}   3. No, and tell Claude what to do differently \u{2502}",
    "\u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256f}",
].joined(separator: "\n")

@Test @MainActor func activityAgentPermissionBox() async {
    let A = PaneActivity.shared
    A.forget("agent")
    A.noteOutput("agent", claudeBox)
    await sleepMs(450)
    #expect(A.paneActivity("agent") == .waiting)
}

@Test func activityAgentPhrasings() {
    let asks = [
        "Do you want to make this edit to sessions.js?\n  1. Yes\n  2. No",
        "Do you want to create tools/run-tests.mjs?\n\u{276f} 1. Yes",
        "Would you like to run this command?\n  y / n",
        "Allow command?\n  1. Yes (y)\n  2. No (n)",
        "Approve this edit before it is applied?",
        "  2. Yes, and don't ask again this session",
        "  3. No, and tell Codex what to do differently",
        "Waiting for your approval",
        "Press y to confirm",
    ]
    for a in asks { #expect(ActivityText.looksLikePrompt(a), "waiting: \(a.prefix(40))") }
}

@Test func activityRealBoxWithFooter() {
    let box = [String(repeating: " \u{2500}", count: 40), " Tool use", "",
               "   Google Calendar \u{2014} Lists calendar events in a gi\u{2026} Tool: (MCP)", "",
               "   startTime: \"2026-09-24T00:00:00-04:00\"", "   orderBy: \"startTime\"", "",
               " Do you want to proceed?", " \u{276f} 1. Yes", "   2. No", "", " Esc to cancel \u{00b7} Tab to amend", "", ""]
        .joined(separator: "\n")
    #expect(ActivityText.looksLikePrompt(box))
    #expect(ActivityText.looksLikePrompt(claudeBox + "\n\n\n   \n"))
}

@Test func activityBusyAgentIsNotAsking() {
    let busy = ["\u{2733} Thinking\u{2026} (12s \u{00b7} esc to interrupt)", "\u{2022} Running tests\u{2026} (esc to interrupt)",
                "\u{23fa} Reading src/renderer/js/activity.js", "Tool use: Bash(npm test)", "I will ask before I proceed.",
                "The docs explain what to do if you want to continue from here."]
    for line in busy { #expect(!ActivityText.looksLikePrompt(line), "not waiting: \(line)") }
}

@Test func activityAnsweredBoxStopsCounting() {
    #expect(ActivityText.looksLikePrompt(claudeBox))
    for back in ["\u{279c}  ~ ", "steven@web-1:~$ ", "[root@db-2 ~]# "] {
        #expect(!ActivityText.looksLikePrompt(claudeBox + "\n" + back), "back at \(back)")
    }
    let after = (1...14).map { "running step \($0)" }.joined(separator: "\n")
    #expect(!ActivityText.looksLikePrompt(claudeBox + "\n" + after))
}

@Test @MainActor func activityIdleAndForgotten() {
    let A = PaneActivity.shared
    #expect(A.paneActivity("never-seen") == .idle)
    A.noteOutput("p4", "something")
    #expect(A.paneActivity("p4") == .moving)
    A.forget("p4")
    #expect(A.paneActivity("p4") == .idle)
}

@Test @MainActor func activityTabTakesTheMostUrgent() async {
    let A = PaneActivity.shared
    for id in ["t1:a", "t1:b"] { A.forget(id) }
    #expect(A.tabActivity(["t1:a", "t1:b"]) == .idle)
    A.noteOutput("t1:a", "building...")
    #expect(A.tabActivity(["t1:a", "t1:b"]) == .moving)
    A.noteOutput("t1:b", "[sudo] password for steven: ")
    await sleepMs(450)
    A.noteOutput("t1:a", "building...")
    #expect(A.tabActivity(["t1:a", "t1:b"]) == .waiting)
}

@Test @MainActor func activityBigChunk() {
    let A = PaneActivity.shared
    A.forget("p5")
    A.noteOutput("p5", String(repeating: "x", count: 200_000) + "\n[sudo] password for steven: ")
    #expect(A.paneActivity("p5") == .moving)
}
