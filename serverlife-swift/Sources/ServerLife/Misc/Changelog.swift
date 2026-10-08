import AppKit
import SwiftUI

/// CHANGELOG.md read into the releases the version history shows: the port
/// of changelog.js and versions.js.
///
/// The history used to be a second copy of the changelog kept by hand, and it
/// fell behind; it is read from the bundled CHANGELOG.md instead, with the
/// hand-written titles of the early releases (`curated`, generated from
/// versions.js into VersionsCurated.swift) kept.
enum VersionHistory {
    struct Section: Equatable {
        var name: String
        var items: [String]
    }

    struct Release: Equatable {
        var version: String
        var date: String
        var title: String
        var summary: String
        var sections: [Section]
    }

    // MARK: - changelog.js

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns here are constants; a typo is a programming error.
        try! NSRegularExpression(pattern: p, options: opts)
    }

    private static let linkRE = re(#"\[([^\]]+)\]\([^)]*\)"#)
    private static let boldRE = re(#"\*\*([^*]+)\*\*"#)
    private static let emRE = re(#"(^|[^*])\*([^*\s][^*]*)\*"#)
    private static let codeRE = re(#"`([^`]+)`"#)
    private static let spaceRE = re(#"\s+"#)

    private static func sub(_ r: NSRegularExpression, _ s: String, _ template: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Markdown inline marks to plain text: the history draws text, not markup.
    static func plainText(_ s: String) -> String {
        var t = s
        t = sub(linkRE, t, "$1")
        t = sub(boldRE, t, "$1")
        t = sub(emRE, t, "$1$2")
        t = sub(codeRE, t, "$1")
        t = sub(spaceRE, t, " ")
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static let headRE = re(#"^## \[([^\]]+)\]\s*[—–-]\s*(\S+)"#)
    private static let ruleRE = re(#"^---\s*$"#)
    private static let linkRefRE = re(#"^\[[^\]]+\]:\s"#)
    private static let subRE = re(#"^### (.+)$"#)
    private static let bulletRE = re(#"^- (.*)$"#)
    private static let contRE = re(#"^\s+\S"#)

    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    /// Every `## [x.y.z] — date` section, newest first as the file has them.
    ///
    /// The paragraph between the heading and the first `###` is the summary;
    /// each `###` is a section and each `- ` item in it one entry, wrapped
    /// continuation lines joined back on. The preamble, the `---` rules and
    /// the link references at the foot are not part of any release.
    static func parse(_ md: String) -> [Release] {
        var releases: [Release] = []
        var rel: Release?
        var sectionIndex: Int?
        var item: [String]?
        var summary: [String] = []

        func endItem() {
            if let it = item, var r = rel, let si = sectionIndex {
                r.sections[si].items.append(plainText(it.joined(separator: " ")))
                rel = r
            }
            item = nil
        }
        func endRelease() {
            endItem()
            if var r = rel {
                r.summary = plainText(summary.joined(separator: " "))
                releases.append(r)
            }
            rel = nil; sectionIndex = nil; summary = []
        }

        for line in md.components(separatedBy: "\n") {
            if let h = groups(headRE, line) {
                endRelease()
                rel = Release(version: h[1], date: h[2], title: "", summary: "", sections: [])
                continue
            }
            guard rel != nil else { continue }
            if groups(ruleRE, line) != nil || groups(linkRefRE, line) != nil { endRelease(); continue }
            if let s = groups(subRE, line) {
                endItem()
                rel!.sections.append(Section(name: plainText(s[1]), items: []))
                sectionIndex = rel!.sections.count - 1
                continue
            }
            if sectionIndex != nil {
                if let b = groups(bulletRE, line) { endItem(); item = [b[1]]; continue }
                if item != nil, groups(contRE, line) != nil {
                    item!.append(line.trimmingCharacters(in: .whitespaces)); continue
                }
                if line.trimmingCharacters(in: .whitespaces).isEmpty { endItem(); continue }
                // Prose inside a section, outside any bullet, is kept as its own entry.
                endItem()
                item = [line.trimmingCharacters(in: .whitespaces)]
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { summary.append(t) }
        }
        endRelease()
        return releases.filter { !$0.sections.isEmpty || !$0.summary.isEmpty }
    }

    // MARK: - versions.js

    /// Every release, newest first: the changelog's, with the hand-written titles.
    static func releases(from md: String) -> [Release] {
        let byVersion = Dictionary(curated.map { ($0.version, $0) }, uniquingKeysWith: { a, _ in a })
        let parsed = parse(md).map { r -> Release in
            var r = r
            if let c = byVersion[r.version], !c.title.isEmpty { r.title = c.title }
            return r
        }
        let seen = Set(parsed.map(\.version))
        return parsed + curated.filter { !seen.contains($0.version) }
    }

    @MainActor static let all: [Release] = releases(from: AppResources.text("CHANGELOG.md"))

    /// The Version history dialog (`openVersionHistory`).
    @MainActor static func open(_ window: WindowModel? = nil) {
        let list = all
        Modal.sheet(window, title: "Version history", width: 680, height: 640, resizable: true,
                    autosave: "version-history") { handle in
            DialogScaffold(title: "Version history",
                           subtitle: "\(list.count) release\(list.count == 1 ? "" : "s")") {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, r in ReleaseBlock(release: r) }
                }
            } footer: {
                Button("Close") { handle.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ReleaseBlock: View {
    let release: VersionHistory.Release
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("v" + release.version).font(.system(size: 15, weight: .semibold))
                Badge(text: release.date)
                if !release.title.isEmpty {
                    Text(release.title).font(.system(size: 12)).foregroundStyle(p.muted)
                }
            }
            .padding(.bottom, 4)
            if !release.summary.isEmpty {
                Text(release.summary).font(.system(size: 12)).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
            ForEach(Array(release.sections.enumerated()), id: \.offset) { _, s in
                Text(s.name.uppercased())
                    .font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(p.muted)
                    .padding(.top, 12).padding(.bottom, 5)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(s.items.enumerated()), id: \.offset) { _, it in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(p.muted)
                            Text(it).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                        .lineSpacing(3)
                    }
                }
                .padding(.leading, 6)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
        .padding(.bottom, 20)
    }
}
