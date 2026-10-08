import AppKit
import SwiftUI

/// The guide, in the app: the port of guide.js.
///
/// The guide is for someone using the app and wondering what a button does,
/// which happens while the app is open — so it lives here, bundled as
/// Resources/GUIDE.md. The renderer handles the subset of Markdown the guide
/// is written in (headings, paragraphs, lists, tables, fenced code, block
/// quotes, rules; code, bold, italic and links inline). It cannot execute
/// anything it is given.
enum GuideMarkdown {
    enum Span: Equatable {
        case text(String)
        case code(String)
        case bold(String)
        case em(String)
        /// An http(s) link: opens in the browser.
        case link(String, url: String)
        /// An in-document link: scrolls to the heading with that slug.
        case anchor(String, id: String)

        var plain: String {
            switch self {
            case .text(let s), .code(let s), .bold(let s), .em(let s), .link(let s, _), .anchor(let s, _): return s
            }
        }
    }

    struct ListItem: Equatable {
        var text: String
        var children: [String] = []
    }

    enum Block: Equatable {
        case heading(level: Int, text: String, id: String)
        case para(String)
        case code(String)
        case rule
        case table(head: [String], rows: [[String]])
        case list(ordered: Bool, items: [ListItem])
        case note(tag: String?, text: String)
    }

    struct Section: Equatable {
        let id: String
        let text: String
        let level: Int
        let block: Int
    }

    struct Document {
        let blocks: [Block]
        let sections: [Section]
    }

    private static let inlineRE = try! NSRegularExpression(
        pattern: #"(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|(\[[^\]]+\]\([^)]+\))"#)

    /// Inline spans: code first (nothing inside backticks is markup), bold,
    /// italic, links. Only real links open; an anchor scrolls; anything else
    /// is text.
    static func inline(_ text: String) -> [Span] {
        var out: [Span] = []
        var rest = text
        while let m = inlineRE.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let r = Range(m.range, in: rest) {
            if r.lowerBound > rest.startIndex { out.append(.text(String(rest[..<r.lowerBound]))) }
            let tok = String(rest[r])
            if tok.hasPrefix("`") {
                out.append(.code(String(tok.dropFirst().dropLast())))
            } else if tok.hasPrefix("**") {
                out.append(.bold(String(tok.dropFirst(2).dropLast(2))))
            } else if tok.hasPrefix("*") {
                out.append(.em(String(tok.dropFirst().dropLast())))
            } else if let cut = tok.range(of: "](") {
                let label = String(tok[tok.index(after: tok.startIndex)..<cut.lowerBound])
                let href = String(tok[cut.upperBound..<tok.index(before: tok.endIndex)])
                if href.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    out.append(.link(label, url: href))
                } else if href.hasPrefix("#") {
                    out.append(.anchor(label, id: String(href.dropFirst())))
                } else {
                    out.append(.text(label))
                }
            }
            rest = String(rest[r.upperBound...])
        }
        if !rest.isEmpty { out.append(.text(rest)) }
        return out
    }

    static func plain(_ text: String) -> String { inline(text).map(\.plain).joined() }

    /// guide.js `slug`.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        // JS \w is ASCII letters, digits and underscore.
        var out = ""
        var inRun = false
        for u in lowered.unicodeScalars {
            let isWord = (u.value >= 48 && u.value <= 57) || (u.value >= 97 && u.value <= 122)
                || (u.value >= 65 && u.value <= 90) || u == "_"
            if isWord { out.unicodeScalars.append(u); inRun = false }
            else if !inRun { out.append("-"); inRun = true }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    private static func test(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Markdown to blocks.
    static func parse(_ md: String) -> Document {
        let lines = md.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var blocks: [Block] = []
        var sections: [Section] = []
        var para: [String] = []
        var i = 0

        func flushPara() {
            if !para.isEmpty { blocks.append(.para(para.joined(separator: " "))) }
            para.removeAll()
        }

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                flushPara()
                var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") { body.append(lines[i]); i += 1 }
                i += 1
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            if let h = match(#"^(#{1,4})\s+(.*)$"#, line) {
                flushPara()
                let level = h[1].count
                let text = h[2].replacingOccurrences(of: #"\s+#*$"#, with: "", options: .regularExpression)
                let id = "g-" + slug(text)
                blocks.append(.heading(level: level, text: text, id: id))
                if level <= 2 { sections.append(Section(id: id, text: text, level: level, block: blocks.count - 1)) }
                i += 1
                continue
            }

            if test(#"^(-{3,}|\*{3,})\s*$"#, line) {
                flushPara()
                blocks.append(.rule)
                i += 1
                continue
            }

            if line.hasPrefix("|"), i + 1 < lines.count, test(#"^\|[\s:|-]+\|?\s*$"#, lines[i + 1]) {
                flushPara()
                func cells(_ row: String) -> [String] {
                    var r = row
                    if r.hasPrefix("|") { r.removeFirst() }
                    if r.hasSuffix("|") { r.removeLast() }
                    return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let head = cells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count && lines[i].hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                blocks.append(.table(head: head, rows: rows))
                continue
            }

            let itemRE = #"^\s*([-*]|\d+\.)\s+"#
            if test(itemRE, line) {
                flushPara()
                let ordered = test(#"^\s*\d+\."#, line)
                // An item's text is gathered across its continuation lines and
                // parsed once, so a wrapped **bold span** is not split in two.
                var raw: [(indent: Int, text: String)] = []
                while i < lines.count && (test(itemRE, lines[i]) || test(#"^\s{2,}\S"#, lines[i])) {
                    if let m = match(#"^(\s*)([-*]|\d+\.)\s+(.*)$"#, lines[i]) {
                        raw.append((m[1].count, m[3]))
                    } else if !raw.isEmpty {
                        raw[raw.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    }
                    i += 1
                }
                var items: [ListItem] = []
                for it in raw {
                    // An indented bullet belongs to the item above it.
                    if it.indent >= 2, !items.isEmpty { items[items.count - 1].children.append(it.text) }
                    else { items.append(ListItem(text: it.text)) }
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            if test(#"^>\s?"#, line) {
                flushPara()
                var body: [String] = []
                while i < lines.count && test(#"^>\s?"#, lines[i]) {
                    body.append(lines[i].replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression))
                    i += 1
                }
                var tag: String?
                if let first = body.first, let t = match(#"^\[!(\w+)\]\s*$"#, first) {
                    tag = t[1].lowercased(); body.removeFirst()
                }
                blocks.append(.note(tag: tag, text: body.joined(separator: " ")))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushPara(); i += 1; continue }
            para.append(line.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        flushPara()
        return Document(blocks: blocks, sections: sections)
    }

    /// The pieces of text a block shows, in order: what search looks in.
    static func units(_ b: Block) -> [String] {
        switch b {
        case .heading(_, let t, _): return [t]
        case .para(let t): return [plain(t)]
        case .code(let t): return [t]
        case .rule: return []
        case .table(let head, let rows): return (head + rows.flatMap { $0 }).map(plain)
        case .list(_, let items): return items.flatMap { [plain($0.text)] + $0.children.map(plain) }
        case .note(let tag, let t): return (tag.map { [$0] } ?? []) + [plain(t)]
        }
    }

    /// Every case-insensitive occurrence of `needle` in `text`, as UTF-16 ranges.
    static func occurrences(of needle: String, in text: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: .caseInsensitive, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            out.append(r)
            from = r.location + max(1, r.length)
        }
        return out
    }
}

/// The guide window's state: the parsed document, the search and its marks.
@MainActor
final class GuideModel: ObservableObject {
    struct Mark: Equatable { let unit: Int; let range: NSRange }

    let source: String
    let doc: GuideMarkdown.Document
    /// The first search unit of each block.
    let unitBase: [Int]
    /// The block each unit is in.
    let unitBlock: [Int]
    let unitText: [String]
    /// The section (index into doc.sections) each block falls under.
    let blockSection: [Int?]

    @Published var query = ""
    @Published private(set) var marks: [Mark] = []
    @Published private(set) var current = 0
    @Published private(set) var countText = ""
    @Published private(set) var hitSections: Set<Int> = []
    /// Where to scroll next: a block index (and whether to centre on it).
    @Published var scrollTarget: (block: Int, centre: Bool, nonce: Int)?
    private var nonce = 0
    private let debounce = Debouncer(0.14)

    init(source: String) {
        self.source = source
        doc = GuideMarkdown.parse(source)
        var base: [Int] = [], ub: [Int] = [], ut: [String] = [], bs: [Int?] = []
        var section: Int?
        var sIdx = 0
        for (bi, b) in doc.blocks.enumerated() {
            if sIdx < doc.sections.count, doc.sections[sIdx].block == bi { section = sIdx; sIdx += 1 }
            bs.append(section)
            base.append(ut.count)
            for u in GuideMarkdown.units(b) { ut.append(u); ub.append(bi) }
        }
        unitBase = base; unitBlock = ub; unitText = ut; blockSection = bs
    }

    func queryChanged() {
        debounce.call { [weak self] in self?.search() }
    }

    /// Mark every match and jump to the first. Marks rather than filters: the
    /// sentence next to the match is usually the one that answers the question.
    func search() {
        let needle = query.trimmed
        var found: [Mark] = []
        if needle.count >= 2 {
            outer: for (u, text) in unitText.enumerated() {
                for r in GuideMarkdown.occurrences(of: needle, in: text) {
                    found.append(Mark(unit: u, range: r))
                    if found.count >= 400 { break outer }
                }
            }
        }
        marks = found
        current = 0
        hitSections = Set(found.compactMap { blockSection[unitBlock[$0.unit]] })
        if needle.count < 2 { countText = ""; return }
        countText = found.isEmpty ? "no matches" : "\(found.count) match\(found.count == 1 ? "" : "es")"
        if let first = found.first { scroll(to: unitBlock[first.unit], centre: true) }
    }

    func step(_ dir: Int) {
        guard !marks.isEmpty else { return }
        current = (current + dir + marks.count) % marks.count
        scroll(to: unitBlock[marks[current].unit], centre: true)
        countText = "\(current + 1) of \(marks.count)"
    }

    func clear() { query = ""; search() }

    func scroll(to block: Int, centre: Bool) {
        nonce += 1
        scrollTarget = (block, centre, nonce)
    }

    func scrollToAnchor(_ id: String) {
        if let bi = doc.blocks.firstIndex(where: { if case .heading(_, _, let hid) = $0 { return hid == id }; return false }) {
            scroll(to: bi, centre: false)
        }
    }

    func scrollToTopic(_ topic: String) {
        guard !topic.isEmpty else { return }
        if let s = doc.sections.first(where: { $0.text.lowercased().contains(topic.lowercased()) }) {
            scroll(to: s.block, centre: false)
        }
    }

    /// The marks in one unit, with their global indexes.
    func marks(inUnit u: Int) -> [(NSRange, Int)] {
        marks.enumerated().filter { $0.element.unit == u }.map { ($0.element.range, $0.offset) }
    }
}

/// The guide panel (`openGuide`).
@MainActor
enum GuidePanel {
    private static weak var model: GuideModel?

    static func open(topic: String = "") {
        if Modal.isPanelOpen("guide"), let m = model {
            Modal.panelHandle("guide")?.window.makeKeyAndOrderFront(nil)
            m.scrollToTopic(topic)
            return
        }
        let m = GuideModel(source: AppResources.text("GUIDE.md"))
        model = m
        let h = Modal.panel(id: "guide", title: "ServerLife guide", width: 1080, height: 720, autosave: "guide") { handle in
            GuideView(model: m, handle: handle)
        }
        h.window.subtitle = "What everything does"
        (h.window as? ModalWindow)?.closeOnEscape = true
        h.window.minSize = NSSize(width: 560, height: 360)
        if !topic.isEmpty { after(0.05) { m.scrollToTopic(topic) } }
    }
}

private struct GuideView: View {
    @ObservedObject var model: GuideModel
    let handle: ModalHandle
    @FocusState private var searchFocused: Bool

    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.muted)
                    TextField("Search the guide…", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($searchFocused)
                        .onChange(of: model.query) { _, _ in model.queryChanged() }
                        .onSubmit { model.step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                        // Escape closes the guide, from the search box too (the
                        // dialog's own key handler ran first in the original).
                        .onExitCommand { handle.close() }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? p.accent : p.border))
                if !model.marks.isEmpty {
                    Button { model.step(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.icon).help("Previous match (⇧↩)")
                    Button { model.step(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.icon).help("Next match (↩)")
                }
                Text(model.countText).font(.system(size: 11)).foregroundStyle(p.muted)
                    .frame(minWidth: 80, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)

            HStack(alignment: .top, spacing: 14) {
                GuideNav(model: model)
                    .frame(width: 196)
                p.borderSoft.frame(width: 1)
                GuideContent(model: model)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)

            p.border.frame(height: 1).padding(.top, 10)
            HStack(spacing: 8) {
                Spacer()
                Button("Copy the whole guide") {
                    Clipboard.write(model.source)
                    StatusBus.shared.show("Guide copied as Markdown")
                }
                .buttonStyle(.ghost)
                .help("The Markdown source, to paste somewhere else")
                Button("Save as a file…") {
                    Task { @MainActor in
                        guard let url = await MiscPanels.save(handle.window, title: "Save the guide",
                                                              defaultName: "ServerLife-guide.md") else { return }
                        do {
                            try Data(model.source.utf8).write(to: url)
                            StatusBus.shared.show("Saved \(url.path)")
                        } catch {
                            StatusBus.shared.toast(error.localizedDescription, kind: .error)
                        }
                    }
                }
                .buttonStyle(.ghost)
                Button("Close") { handle.close() }.buttonStyle(.primary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(p.panel)
        .onAppear { after(0.03) { searchFocused = true } }
    }
}

private struct GuideNav: View {
    @ObservedObject var model: GuideModel
    var body: some View {
        let p = Theme.shared.p
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.doc.sections.enumerated()), id: \.offset) { i, s in
                    NavRow(text: s.text, level: s.level, hit: model.hitSections.contains(i)) {
                        model.scroll(to: s.block, centre: false)
                    }
                }
            }
            .padding(.trailing, 10)
        }
        .foregroundStyle(p.textDim)
    }

    private struct NavRow: View {
        let text: String
        let level: Int
        let hit: Bool
        let action: () -> Void
        @StateObject private var hover = LocalFlag()
        var body: some View {
            let p = Theme.shared.p
            Text(text)
                .font(.system(size: level >= 2 ? 11.5 : 12))
                .foregroundStyle(hit ? p.amber : (hover.on ? p.text : p.textDim))
                .opacity(level >= 2 && !hit ? 0.85 : 1)
                .lineLimit(2)
                .padding(.vertical, 3)
                .padding(.leading, level >= 2 ? 15 : 6).padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 3).fill(hover.on ? p.panel3 : .clear))
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
                .onTapGesture(perform: action)
        }
    }
}

private struct GuideContent: View {
    @ObservedObject var model: GuideModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.doc.blocks.enumerated()), id: \.offset) { bi, b in
                        GuideBlockView(model: model, block: b, base: model.unitBase[bi])
                            .id(bi)
                    }
                }
                .foregroundStyle(Theme.shared.p.textDim)
                .padding(.trailing, 4)
                .padding(.bottom, 20)
            }
            .onChange(of: model.scrollTarget?.nonce) { _, _ in
                guard let t = model.scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(t.block, anchor: t.centre ? .center : .top)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "serverlife-guide" {
                model.scrollToAnchor("g-" + (url.fragment ?? ""))
                return .handled
            }
            return .systemAction
        })
    }
}

/// One block. `base` is the index of its first search unit.
private struct GuideBlockView: View {
    @ObservedObject var model: GuideModel
    let block: GuideMarkdown.Block
    let base: Int

    var body: some View {
        let p = Theme.shared.p
        switch block {
        case .heading(let level, let text, _):
            let size: CGFloat = [1: 16, 2: 14, 3: 12.5, 4: 12][level] ?? 12
            Text(rich(.plain(text), unit: base, weight: .semibold, size: size))
                .foregroundStyle(level == 4 ? p.textDim : p.text)
                .padding(.top, 18).padding(.bottom, 8)
                .textSelection(.enabled)
        case .para(let t):
            Text(rich(.markdown(t), unit: base))
                .lineSpacing(4)
                .modifier(LinkTip(text: t))
                .padding(.bottom, 10)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let t):
            ScrollView(.horizontal) {
                Text(rich(.code(t), unit: base))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            .padding(.bottom, 11)
        case .rule:
            p.borderSoft.frame(height: 1).padding(.vertical, 16)
        case .table(let head, let rows):
            table(head, rows, p)
        case .list(let ordered, let items):
            list(ordered, items, p)
        case .note(let tag, let t):
            HStack(spacing: 0) {
                p.amber.frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    if let tag {
                        Text(rich(.plain(tag.uppercased()), unit: base, weight: .bold, size: 10))
                            .kerning(0.9).foregroundStyle(p.amber)
                    }
                    Text(rich(.markdown(t), unit: base + (tag == nil ? 0 : 1)))
                        .lineSpacing(4).textSelection(.enabled).modifier(LinkTip(text: t))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(p.panel2)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private func table(_ head: [String], _ rows: [[String]], _ p: Palette) -> some View {
        let cols = max(head.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<cols, id: \.self) { c in
                    cell(c < head.count ? head[c] : "", unit: base + c, header: true, p)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                let rowBase = base + head.count + rows[..<ri].reduce(0) { $0 + $1.count }
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        cell(c < row.count ? row[c] : "", unit: c < row.count ? rowBase + c : -1, header: false, p)
                    }
                }
            }
        }
        .overlay(Rectangle().stroke(p.borderSoft))
        .padding(.bottom, 12)
    }

    private func cell(_ text: String, unit: Int, header: Bool, _ p: Palette) -> some View {
        Text(rich(.markdown(text), unit: unit, weight: header ? .semibold : .regular, size: 12))
            .foregroundStyle(header ? p.text : p.textDim)
            .textSelection(.enabled)
            .modifier(LinkTip(text: text))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(header ? p.panel2 : Color.clear)
            .border(p.borderSoft, width: 0.5)
    }

    @ViewBuilder private func list(_ ordered: Bool, _ items: [GuideMarkdown.ListItem], _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { n, it in
                let u = base + items[..<n].reduce(0) { $0 + 1 + $1.children.count }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(n + 1)." : "•").foregroundStyle(p.muted)
                            .frame(minWidth: 10, alignment: .trailing)
                        Text(rich(.markdown(it.text), unit: u)).lineSpacing(4)
                            .modifier(LinkTip(text: it.text))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(it.children.enumerated()), id: \.offset) { ci, child in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("◦").foregroundStyle(p.muted)
                            Text(rich(.markdown(child), unit: u + 1 + ci)).lineSpacing(4)
                                .modifier(LinkTip(text: child))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 18)
                    }
                }
            }
        }
        .padding(.leading, 4)
        .padding(.bottom, 10)
    }

    // MARK: Inline rendering with search marks

    private enum Source { case markdown(String), plain(String), code(String) }

    private func rich(_ src: Source, unit: Int, weight: Font.Weight = .regular, size: CGFloat = 12.5) -> AttributedString {
        let p = Theme.shared.p
        let spans: [GuideMarkdown.Span]
        switch src {
        case .markdown(let t): spans = GuideMarkdown.inline(t)
        case .plain(let t): spans = [.text(t)]
        case .code(let t): spans = [.text(t)]
        }
        let isCodeBlock: Bool = { if case .code = src { return true }; return false }()
        let marks = unit >= 0 ? model.marks(inUnit: unit) : []
        var out = AttributedString()
        var offset = 0
        for span in spans {
            let text = span.plain as NSString
            // Split the span at mark boundaries so each piece can be tinted.
            var cuts: Set<Int> = [0, text.length]
            for (r, _) in marks {
                let a = r.location - offset, b = r.location + r.length - offset
                if a > 0 && a < text.length { cuts.insert(a) }
                if b > 0 && b < text.length { cuts.insert(b) }
            }
            let sorted = cuts.sorted()
            for k in 0..<(sorted.count - 1) {
                let lo = sorted[k], hi = sorted[k + 1]
                guard hi > lo else { continue }
                var piece = AttributedString(text.substring(with: NSRange(location: lo, length: hi - lo)))
                var font = Font.system(size: size, weight: weight)
                var fg: Color? = nil
                switch span {
                case .code:
                    font = .system(size: 11.5, design: .monospaced)
                    fg = p.text
                    piece.backgroundColor = p.panel3
                case .bold:
                    font = .system(size: size, weight: .semibold); fg = p.text
                case .em:
                    font = .system(size: size, weight: weight).italic()
                case .link(_, let url):
                    fg = p.accent
                    if let u = URL(string: url) { piece.link = u }
                case .anchor(_, let id):
                    fg = p.accent
                    piece.link = URL(string: "serverlife-guide:#" + id)
                case .text:
                    if isCodeBlock { font = .system(size: 11.5, design: .monospaced); fg = p.text }
                }
                piece.font = font
                if let fg { piece.foregroundColor = fg }
                let absLo = offset + lo
                if let hit = marks.first(where: { absLo >= $0.0.location && absLo < $0.0.location + $0.0.length }) {
                    let on = hit.1 == model.current
                    piece.backgroundColor = on ? p.accent : p.amber
                    piece.foregroundColor = on ? .white : Color(hex: "#0d1117")
                }
                out.append(piece)
            }
            offset += text.length
        }
        return out
    }
}

/// A web link shows where it goes on hover (guide.js gave the anchor a
/// `title` of its href). SwiftUI text has no per-run tooltip, so the text
/// that holds links carries their addresses.
private struct LinkTip: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        let urls = GuideMarkdown.inline(text).compactMap { s -> String? in
            if case .link(_, let url) = s { return url }
            return nil
        }
        if urls.isEmpty { content } else { content.help(urls.joined(separator: "\n")) }
    }
}
