import Testing
import Foundation
@testable import ServerLife

/// tests/changelog.test.mjs: the version history is read from CHANGELOG.md,
/// so these run the parser over the real file — the history and the
/// changelog drifting apart is what went wrong before.
@Suite struct MiscChangelogTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let md = (try? String(contentsOf: root.appendingPathComponent("Resources/CHANGELOG.md"), encoding: .utf8)) ?? ""
    static let version = ((try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    static let releases = VersionHistory.parse(md)

    @Test func theNewestReleaseInTheHistoryIsTheVersionBeingBuilt() {
        #expect(Self.releases.first?.version == Self.version)
    }

    @Test func everyReleaseHasADateAndSomethingInIt() {
        let date = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        for r in Self.releases {
            #expect(date.matches(r.date), "\(r.version) has no date")
            let items = r.sections.reduce(0) { $0 + $1.items.count }
            #expect(items > 0 || !r.summary.isEmpty, "\(r.version) is empty")
        }
    }

    @Test func theReleasesSinceTheMoveAreAllThere() {
        let versions = Set(Self.releases.map(\.version))
        for v in ["0.1.16", "0.13.0", "0.14.0", "0.14.1"] { #expect(versions.contains(v), "\(v) missing") }
    }

    @Test func aWrappedBulletIsOneEntryReadAsPlainText() {
        let r = VersionHistory.parse([
            "## [9.9.9] — 2030-01-01", "", "The summary", "over two lines.", "",
            "### Added", "", "- **Bold** and `code` and a [link](https://x),",
            "  continued here.", "- Second.", "", "### Fixed", "", "- Third.", "", "---",
        ].joined(separator: "\n"))[0]
        #expect(r.summary == "The summary over two lines.")
        #expect(r.sections.map(\.name) == ["Added", "Fixed"])
        #expect(r.sections[0].items == ["Bold and code and a link, continued here.", "Second."])
        #expect(r.sections[1].items == ["Third."])
    }

    @Test func emphasisComesOffAsterisksInProseDoNotBreakIt() {
        #expect(VersionHistory.plainText("*Open in tmux…* on the menu") == "Open in tmux… on the menu")
        #expect(VersionHistory.plainText("a * b") == "a * b")
    }

    @Test func theCuratedEarlyReleasesKeepTheirTitles() {
        let all = VersionHistory.releases(from: Self.md)
        #expect(all.first(where: { $0.version == "0.1.16" })?.title == "A new home")
        #expect(Set(all.map(\.version)).count == all.count)
    }
}

/// guide.js's Markdown subset.
@Suite struct MiscGuideTests {
    @Test func headingsBecomeSectionsWithSlugs() {
        let d = GuideMarkdown.parse("# The guide\n\n## Connections\n\nText.\n\n### Deeper\n\n## Port forwarding\n")
        #expect(d.sections.map(\.text) == ["The guide", "Connections", "Port forwarding"])
        #expect(d.sections.map(\.id) == ["g-the-guide", "g-connections", "g-port-forwarding"])
    }

    @Test func inlineSpans() {
        let s = GuideMarkdown.inline("Press `⌘N` for **New** or *see* [docs](https://x.y) and [here](#tmux) or [rel](a.md).")
        #expect(s.contains(.code("⌘N")))
        #expect(s.contains(.bold("New")))
        #expect(s.contains(.em("see")))
        #expect(s.contains(.link("docs", url: "https://x.y")))
        #expect(s.contains(.anchor("here", id: "tmux")))
        #expect(s.contains(.text("rel")) || s.map(\.plain).joined().contains("rel"))
        #expect(GuideMarkdown.plain("**a** `b` [c](#d)") == "a b c")
    }

    @Test func listsTablesCodeAndNotes() {
        let md = """
        - one **wrapped
          bold** item
          - nested
        - two

        | A | B |
        |---|---|
        | 1 | 2 |

        ```
        code here
        ```

        > [!NOTE]
        > careful
        """
        let d = GuideMarkdown.parse(md)
        #expect(d.blocks[0] == .list(ordered: false, items: [.init(text: "one **wrapped bold** item", children: ["nested"]),
                                                             .init(text: "two")]))
        #expect(d.blocks[1] == .table(head: ["A", "B"], rows: [["1", "2"]]))
        #expect(d.blocks[2] == .code("code here"))
        #expect(d.blocks[3] == .note(tag: "note", text: "careful"))
    }

    @Test func theRealGuideParsesAndEveryContentsLinkLands() {
        let md = AppResources.text("GUIDE.md")
        #expect(!md.isEmpty)
        let d = GuideMarkdown.parse(md)
        #expect(d.sections.count > 20)
        let ids = Set(d.blocks.compactMap { b -> String? in if case .heading(_, _, let id) = b { return id }; return nil })
        for case .list(_, let items) in d.blocks.prefix(8) {
            for it in items {
                for case .anchor(_, let id) in GuideMarkdown.inline(it.text) { #expect(ids.contains("g-" + id), "#\(id)") }
            }
        }
    }

    @Test func searchFindsEveryOccurrence() {
        #expect(GuideMarkdown.occurrences(of: "ab", in: "Ab ab xab").count == 3)
        #expect(GuideMarkdown.occurrences(of: "", in: "abc").isEmpty)
    }
}

/// backup.js's envelope checks and the summary the import dialog shows.
@Suite @MainActor struct MiscBackupTests {
    @Test func parseRefusesWhatIsNotAnExport() {
        #expect(throws: AppError.self) { try BackupOps.parse("nope") }
        #expect(throws: AppError.self) { try BackupOps.parse(#"{"format":"other","data":{}}"#) }
        #expect(throws: AppError.self) { try BackupOps.parse(#"{"format":"serverlife.backup","version":9,"data":{}}"#) }
        #expect(throws: AppError.self) { try BackupOps.parse(#"{"format":"serverlife.backup","version":1}"#) }
    }

    @Test func describeCountsWhatIsInside() throws {
        let doc = try BackupOps.parse(#"{"format":"serverlife.backup","version":1,"kind":"settings","exportedAt":"2026-01-01T00:00:00.000Z","data":{"profiles":[{"id":"a"},{"id":"b"}],"macros":[],"settings":{"theme":"nord"}}}"#)
        let s = BackupOps.describe(doc)
        #expect(s["counts"]["profiles"].int == 2)
        #expect(s["hasSettings"].bool == true)
        #expect(BackupUI.summarise(s["counts"]) == ["2 saved profiles"])
    }
}

@Suite @MainActor struct MiscBackupVersionTests {
    @Test func aVersionWrittenAsAStringIsComparedAsANumber() {
        #expect(throws: AppError.self) { try BackupOps.parse(#"{"format":"serverlife.backup","version":"2","data":{}}"#) }
        #expect((try? BackupOps.parse(#"{"format":"serverlife.backup","version":"1","data":{}}"#)) != nil)
    }
}
