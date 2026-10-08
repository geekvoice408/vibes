import Testing
import Foundation
@testable import ServerLife

// Port of tests/links.test.mjs: the edges get most of the attention, because
// claiming a link that is not under the pointer is how a click lands somewhere
// nobody chose.

private func at(_ line: String, _ needle: String, plus: Int = 0) -> Int {
    (line as NSString).range(of: needle).location + plus
}

@Test func linksFoundAnywhereInThem() {
    let line = "see https://example.com/a/b?x=1#frag for details"
    let start = at(line, "https"), end = at(line, " for")
    for i in start..<end { #expect(TermLinks.urlAt(line, i)?.url == "https://example.com/a/b?x=1#frag") }
}

@Test func linksNothingClaimedOutside() {
    let line = "see https://example.com/a for details"
    #expect(TermLinks.urlAt(line, 0) == nil)
    #expect(TermLinks.urlAt(line, 3) == nil)
    #expect(TermLinks.urlAt(line, at(line, "for")) == nil)
    #expect(TermLinks.urlAt(line, (line as NSString).length + 5) == nil)
    #expect(TermLinks.urlAt("", 0) == nil)
    #expect(TermLinks.urlAt("no links here at all", 4) == nil)
}

@Test func linksSentencePunctuationTrimmed() {
    let cases = [("Try https://example.com/a.", "https://example.com/a"), ("Try https://example.com/a, then stop", "https://example.com/a"),
                 ("(see https://example.com/a)", "https://example.com/a"), ("[https://example.com/a]", "https://example.com/a"),
                 ("Try https://example.com/a!", "https://example.com/a"), ("url: \"https://example.com/a\"", "https://example.com/a")]
    for (line, want) in cases { #expect(TermLinks.urlAt(line, at(line, "http", plus: 10))?.url == want, "\(line)") }
}

@Test func linksOwnBracketsKept() {
    let line = "https://en.wikipedia.org/wiki/Foo_(disambiguation) ok"
    #expect(TermLinks.urlAt(line, 10)?.url == "https://en.wikipedia.org/wiki/Foo_(disambiguation)")
}

@Test func linksPunctuationAfterIsNotTheLink() {
    let line = "Try https://example.com/a. Next"
    #expect(TermLinks.urlAt(line, at(line, "a.", plus: 1)) == nil)
}

@Test func linksBareWww() {
    #expect(TermLinks.urlAt("go to www.example.com/x now", 8)?.url == "https://www.example.com/x")
    #expect(TermLinks.normalize("www.example.com") == "https://www.example.com")
    #expect(TermLinks.normalize("https://example.com") == "https://example.com")
}

@Test func linksOnlyHttp() {
    #expect(TermLinks.openable("https://example.com"))
    #expect(TermLinks.openable("http://example.com"))
    #expect(TermLinks.openable("www.example.com"))
    for bad in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "data:text/html,x", ""] {
        #expect(!TermLinks.openable(bad), "\(bad)")
    }
}

@Test func linksInMachineOutput() {
    let json = "{\"url\":\"https://api.example.com/v1/things?page=2\",\"n\":3}"
    #expect(TermLinks.urlAt(json, 20)?.url == "https://api.example.com/v1/things?page=2")
    let log = "2026-10-02 12:00:01 WARN fetch failed <https://example.com/a/b> retrying"
    #expect(TermLinks.urlAt(log, at(log, "http", plus: 5))?.url == "https://example.com/a/b")
}

@Test func linksHostNamed() {
    #expect(TermLinks.hostOf("https://example.com/a/b") == "example.com")
    #expect(TermLinks.hostOf("https://user@evil.test/login?x=example.com") == "evil.test")
    #expect(TermLinks.hostOf("www.example.com") == "www.example.com")
    #expect(TermLinks.hostOf("nonsense") == "")
}

@Test @MainActor func linksShortenedInTheMiddle() {
    let u = "https://example.com/" + String(repeating: "a", count: 80) + "/end"
    let s = SessionsWindow.shortLink(u)
    #expect(s.count == 52)
    #expect(s.hasPrefix("https://example.com/"))
    #expect(s.hasSuffix("/end"))
}
