import AppKit
import SwiftTerm

/// The terminal a pane draws: SwiftTerm's view with the behaviour term.js
/// gave xterm — font, size, scrollback and cursor from settings, the app's
/// terminal palette, links that ask before they open, OSC 52 to the
/// clipboard, search with a match count, and readers for the buffer (all
/// text, the bottom of the screen, the link under a point).
///
/// Byte transport is the pane's business: input leaves through `onInput`,
/// output arrives through `write`.
@MainActor
final class SessionTermView: TerminalView, TerminalViewDelegate {
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFocus: (() -> Void)?
    /// Builds the right-click menu for a point in this view.
    var menuProvider: ((NSPoint) -> NSMenu?)?
    var disposed = false

    private var resizeWork: DispatchWorkItem?

    init(fontSize: CGFloat? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        terminalDelegate = self
        optionAsMetaKey = true
        applySettings(fontSize: fontSize)
        applyTheme()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        // OSC 52 arrives through `clipboardCopy`; nothing else to register.
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Settings

    static func font(family: String, size: CGFloat) -> NSFont {
        for raw in family.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if name.isEmpty { continue }
            if name == "monospace" || name == "ui-monospace" { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @MainActor static var settingFontSize: CGFloat {
        let n = Store.shared.settingJSON("fontSize").double ?? 13
        return CGFloat(n > 0 ? n : 13)
    }

    private(set) var fontSize: CGFloat = 0

    /// Font, scrollback and cursor from settings. A pane's own zoom is kept
    /// unless `fontSize` is given.
    func applySettings(fontSize size: CGFloat? = nil) {
        let s = Store.shared
        if let size { fontSize = max(8, min(28, size)) } else if fontSize == 0 { fontSize = SessionTermView.settingFontSize }
        let family = s.settingJSON("fontFamily").string.flatMap { $0.trimmed.nilIfEmpty } ?? "SFMono-Regular, Menlo, monospace"
        let f = SessionTermView.font(family: family, size: fontSize)
        if font != f { font = f }
        let scrollback = s.settingJSON("scrollback").int ?? 10000
        getTerminal().changeHistorySize(scrollback > 0 ? scrollback : 10000)
        let blink = s.settingJSON("cursorBlink").bool ?? true
        getTerminal().setCursorStyle(blink ? .blinkBar : .steadyBar)
    }

    func setFontSize(_ px: CGFloat) {
        fontSize = max(8, min(28, px))
        font = SessionTermView.font(family: Store.shared.settingJSON("fontFamily").string.flatMap { $0.trimmed.nilIfEmpty }
                                    ?? "SFMono-Regular, Menlo, monospace", size: fontSize)
    }

    /// The palette: Theme.shared.terminal when a theme supplies one, else the
    /// original's dark or light set.
    func applyTheme() {
        let t = TermPalette.current()
        nativeBackgroundColor = NSColor(hex: t["background"] ?? "#0f1117")
        nativeForegroundColor = NSColor(hex: t["foreground"] ?? "#d8dee9")
        caretColor = NSColor(hex: t["cursor"] ?? "#4c8dff")
        if let sel = t["selectionBackground"] ?? t["selection"] {
            selectedTextBackgroundColor = TermPalette.nsColor(sel)
        }
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                     "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta",
                     "brightCyan", "brightWhite"]
        let colors: [SwiftTerm.Color] = names.map { n in
            let c = NSColor(hex: t[n] ?? "#888888").usingColorSpace(.sRGB) ?? .gray
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        }
        installColors(colors)
        needsDisplay = true
    }

    // MARK: Output

    func write(_ data: Data) {
        guard !disposed, !data.isEmpty else { return }
        feed(byteArray: ArraySlice([UInt8](data)))
    }

    func write(text: String) {
        guard !disposed else { return }
        feed(text: text)
    }

    func writeln(_ text: String) { write(text: text + "\r\n") }

    /// xterm's `clear()`: the scrollback and the screen go, the line the
    /// cursor is on stays at the top.
    func clearScreen() {
        let t = getTerminal()
        let line = screenLines()[safe: t.buffer.y] ?? ""
        feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H" + line)
    }

    // MARK: Reading the buffer

    var selectionText: String { getSelection() ?? "" }
    var hasSelection: Bool { selectionActive && !(getSelection() ?? "").isEmpty }

    /// Everything in the buffer, scrollback included, trailing blanks dropped.
    func allText() -> String {
        let data = getTerminal().getBufferAsData(kind: .active)
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The bottom of the content on screen, as text (activity detection).
    /// Is the view scrolled back from the bottom of the buffer?
    var scrolledBack: Bool { canScroll && scrollPosition < 0.999 }

    /// The rows of the screen — the bottom of the buffer, wherever the view
    /// happens to be scrolled to.
    func screenLines() -> [String] {
        let t = getTerminal()
        if !scrolledBack {
            return (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        }
        let all = String(decoding: t.getBufferAsData(kind: .active), as: UTF8.self).components(separatedBy: "\n")
        let body = all.last == "" ? Array(all.dropLast()) : all
        return Array(body.suffix(t.rows))
    }

    func screenTail(_ rows: Int = 16) -> String {
        guard !disposed else { return "" }
        var lines = screenLines()
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(rows).joined(separator: "\n")
    }

    /// The grid cell under a point in this view's coordinates.
    func cell(at point: NSPoint) -> (col: Int, row: Int)? {
        let t = getTerminal()
        guard bounds.width > 0, bounds.height > 0, t.cols > 0, t.rows > 0 else { return nil }
        let cellW = (bounds.width - (NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))) / CGFloat(t.cols)
        let cellH = bounds.height / CGFloat(t.rows)
        let yFromTop = isFlipped ? point.y : bounds.height - point.y
        let col = Int(point.x / max(cellW, 1))
        let row = Int(yFromTop / max(cellH, 1))
        guard row >= 0, row < t.rows, col >= 0 else { return nil }
        return (min(col, t.cols - 1), row)
    }

    /// Where a link under a point is drawn: the URL and the cells it covers
    /// (one span per row it wraps over).
    func linkSpan(_ point: NSPoint) -> (url: String, cells: [(row: Int, from: Int, to: Int)])? {
        guard !disposed, let hit = cell(at: point) else { return nil }
        let t = getTerminal()
        func full(_ r: Int) -> Bool { (t.getLine(row: r)?.translateToString(trimRight: true).count ?? 0) >= t.cols }
        var top = hit.row
        while top > 0 && full(top - 1) { top -= 1 }
        var bottom = hit.row
        while bottom + 1 < t.rows && full(bottom) { bottom += 1 }
        var joined = ""
        var starts: [Int] = []
        var index = -1
        for r in top...bottom {
            guard let line = t.getLine(row: r) else { continue }
            starts.append((joined as NSString).length)
            if r == hit.row {
                index = (joined as NSString).length
                    + (line.translateToString(trimRight: false, startCol: 0, endCol: hit.col, skipNullCellsFollowingWide: true) as NSString).length
            }
            joined += line.translateToString(trimRight: false, skipNullCellsFollowingWide: true)
        }
        guard index >= 0, let h = TermLinks.urlAt(joined, index) else { return nil }
        var cells: [(Int, Int, Int)] = []
        for (i, s) in starts.enumerated() {
            let e = i + 1 < starts.count ? starts[i + 1] : (joined as NSString).length
            let a = max(h.start, s), b = min(h.end, e)
            if a < b { cells.append((top + i, a - s, b - s)) }
        }
        return (h.url, cells)
    }

    private lazy var underline: LinkUnderlineView = {
        let v = LinkUnderlineView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        addSubview(v)
        return v
    }()

    /// Mark the link under the pointer, as the original's link addon did.
    func hoverLink(at point: NSPoint?) {
        guard let point, getTerminal().mouseMode == .off, let span = linkSpan(point) else {
            if !underline.segments.isEmpty { underline.segments = [] }
            return
        }
        let t = getTerminal()
        let cellW = (bounds.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)) / CGFloat(max(t.cols, 1))
        let cellH = bounds.height / CGFloat(max(t.rows, 1))
        underline.segments = span.cells.map { c in
            let yTop = CGFloat(c.row + 1) * cellH - 1.5
            let y = isFlipped ? yTop : bounds.height - yTop
            return NSRect(x: CGFloat(c.from) * cellW, y: y, width: CGFloat(c.to - c.from) * cellW, height: 1)
        }
        underline.color = nativeForegroundColor
        NSCursor.pointingHand.set()
    }

    /// The URL under a point, or nil. A wrapped line is several rows and one
    /// piece of text, so a row that fills the width is joined to the next.
    func linkAt(_ point: NSPoint) -> String? {
        guard !disposed, let hit = cell(at: point) else { return nil }
        let t = getTerminal()
        func full(_ r: Int) -> Bool {
            guard let l = t.getLine(row: r) else { return false }
            return l.translateToString(trimRight: true).count >= t.cols
        }
        var top = hit.row
        while top > 0 && full(top - 1) { top -= 1 }
        var bottom = hit.row
        while bottom + 1 < t.rows && full(bottom) { bottom += 1 }
        var joined = ""
        var index = -1
        for r in top...bottom {
            guard let line = t.getLine(row: r) else { continue }
            if r == hit.row {
                let prefix = line.translateToString(trimRight: false, startCol: 0, endCol: hit.col,
                                                    skipNullCellsFollowingWide: true)
                index = (joined as NSString).length + (prefix as NSString).length
            }
            joined += line.translateToString(trimRight: false, skipNullCellsFollowingWide: true)
        }
        guard index >= 0 else { return nil }
        return TermLinks.urlAt(joined, index)?.url
    }

    // MARK: Search

    /// The query being searched, its match count and which match is current.
    private(set) var searchQuery = ""
    private(set) var searchCount = 0
    private(set) var searchIndex = -1
    var onSearchResults: ((Int, Int) -> Void)?

    private func countMatches(_ q: String) -> Int {
        guard !q.isEmpty else { return 0 }
        let text = String(decoding: getTerminal().getBufferAsData(kind: .active), as: UTF8.self)
        var n = 0
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: q, options: [.caseInsensitive], range: range) {
            n += 1
            range = r.upperBound..<text.endIndex
            if n >= 2000 { break }
        }
        return n
    }

    /// Type-ahead: start again from the top with what has been typed so far.
    func findIncremental(_ q: String) {
        guard !q.isEmpty else { clearSearchState(); return }
        clearSearch()
        searchQuery = q
        searchCount = countMatches(q)
        let found = findNext(q, options: SearchOptions(caseSensitive: false))
        searchIndex = found && searchCount > 0 ? 0 : -1
        onSearchResults?(searchIndex, searchCount)
    }

    func findNextMatch(_ q: String) {
        guard !q.isEmpty else { clearSearchState(); return }
        if q != searchQuery { findIncremental(q); return }
        if findNext(q, options: SearchOptions(caseSensitive: false)), searchCount > 0 {
            searchIndex = (searchIndex + 1) % searchCount
        }
        onSearchResults?(searchIndex, searchCount)
    }

    func findPrevMatch(_ q: String) {
        guard !q.isEmpty else { clearSearchState(); return }
        if q != searchQuery {
            searchQuery = q
            searchCount = countMatches(q)
            searchIndex = searchCount
        }
        if findPrevious(q, options: SearchOptions(caseSensitive: false)), searchCount > 0 {
            searchIndex = (searchIndex - 1 + searchCount) % searchCount
        }
        onSearchResults?(searchIndex, searchCount)
    }

    func clearSearchState() {
        clearSearch()
        searchQuery = ""
        searchCount = 0
        searchIndex = -1
        onSearchResults?(-1, 0)
    }

    // MARK: Focus and menus

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        onFocus?()
        return menuProvider?(p)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        resizeWork?.cancel()
        onInput = nil; onResize = nil; onTitle = nil; onFocus = nil; menuProvider = nil
        removeFromSuperview()
    }

    // MARK: TerminalViewDelegate

    /// A fit at the end of a resize, not on every frame of one: each size the
    /// pty is told is a SIGWINCH, and a full-screen program redraws on each.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resizeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.disposed else { return }
                let t = self.getTerminal()
                self.onResize?(t.cols, t.rows)
            }
        }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput?(Data(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// An OSC 8 link, cmd-clicked: the same guarded path as any other link.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let w = WindowManager.shared.model(for: window)
        Task { await TermLinks.openLink(link, window: w) }
    }

    func bell(source: TerminalView) {
        if Store.shared.settingJSON("bellSound").bool == true { NSSound.beep() }
    }

    /// OSC 52: a remote program asking for the system clipboard. Capped, so a
    /// runaway remote cannot stuff megabytes into it on every redraw.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard !content.isEmpty, content.count <= 150_000 else { return }
        Clipboard.write(String(decoding: content, as: UTF8.self))
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// The terminal's sixteen colours plus background, foreground, cursor and
/// selection (term.js `DARK_THEME` / `LIGHT_THEME`, or the theme's own).
@MainActor
enum TermPalette {
    static let dark: [String: String] = [
        "background": "#0f1117", "foreground": "#d8dee9", "cursor": "#4c8dff", "cursorAccent": "#0f1117",
        "selectionBackground": "#4c8dff47",
        "black": "#1c202b", "brightBlack": "#4a5266", "red": "#f85149", "brightRed": "#ff7b72",
        "green": "#3fb950", "brightGreen": "#56d364", "yellow": "#d29922", "brightYellow": "#e3b341",
        "blue": "#4c8dff", "brightBlue": "#79b8ff", "magenta": "#a371f7", "brightMagenta": "#bc8cff",
        "cyan": "#39c5cf", "brightCyan": "#56d4dd", "white": "#b1bac4", "brightWhite": "#f0f6fc",
    ]
    static let light: [String: String] = [
        "background": "#ffffff", "foreground": "#1c2128", "cursor": "#1f6feb", "cursorAccent": "#ffffff",
        "selectionBackground": "#1f6feb38",
        "black": "#24292f", "brightBlack": "#57606a", "red": "#cf222e", "brightRed": "#a40e26",
        "green": "#116329", "brightGreen": "#1a7f37", "yellow": "#4d2d00", "brightYellow": "#633c01",
        "blue": "#0969da", "brightBlue": "#218bff", "magenta": "#8250df", "brightMagenta": "#a475f9",
        "cyan": "#1b7c83", "brightCyan": "#3192aa", "white": "#6e7781", "brightWhite": "#8c959f",
    ]

    static func current() -> [String: String] {
        let base = Theme.shared.p.tone == .light ? light : dark
        var out = base
        for (k, v) in Theme.shared.terminal { out[k] = v }
        if Theme.shared.terminal["selection"] != nil && Theme.shared.terminal["selectionBackground"] == nil {
            out["selectionBackground"] = Theme.shared.terminal["selection"]
        }
        return out
    }

    /// "#rrggbb" or "#rrggbbaa" (or rgba()) as an NSColor with alpha.
    static func nsColor(_ s: String) -> NSColor {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("rgba(") {
            let parts = h.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 {
                return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3])
            }
        }
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        if h.count == 8 {
            return NSColor(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                           blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
        }
        return NSColor(hex: s)
    }
}

/// A plain click on a link in a terminal opens it (asking first). SwiftTerm
/// only knows OSC 8 links and keeps its mouse handlers to itself, so the
/// click is watched for at the application level instead.
@MainActor
enum TermClickWatcher {
    private static var installed = false
    private static var downAt: (view: SessionTermView, point: NSPoint)?
    private static weak var hovering: SessionTermView?
    /// A terminal whose mouse reporting is held off for an Option-drag.
    private static weak var forcedSelection: SessionTermView?

    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated { handle(event) }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited]) { event in
            MainActor.assumeIsolated {
                let t = termView(for: event)
                if hovering !== t { hovering?.hoverLink(at: nil) }
                hovering = t
                if let t, event.type == .mouseMoved { t.hoverLink(at: t.convert(event.locationInWindow, from: nil)) }
            }
            return event
        }
    }

    private static func termView(for event: NSEvent) -> SessionTermView? {
        guard let w = event.window, let content = w.contentView else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        var v = content.hitTest(p)
        while let cur = v {
            if let t = cur as? SessionTermView { return t }
            v = cur.superview
        }
        return nil
    }

    private static func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            if let t = termView(for: event) {
                // Clicking a terminal makes its pane the focused one.
                t.onFocus?()
                // Option-drag selects locally even while the program has
                // mouse reporting on (tmux `mouse on`, vim `mouse=a`).
                if event.modifierFlags.contains(.option), t.getTerminal().mouseMode != .off {
                    t.allowMouseReporting = false
                    forcedSelection = t
                }
                downAt = (t, event.locationInWindow)
            } else {
                downAt = nil
            }
            return
        }
        if let f = forcedSelection {
            forcedSelection = nil
            DispatchQueue.main.async { f.allowMouseReporting = true }
        }
        guard let d = downAt, event.clickCount == 1 else { downAt = nil; return }
        downAt = nil
        guard let t = termView(for: event), t === d.view else { return }
        if event.modifierFlags.contains(.command) { return }   // SwiftTerm's own OSC 8 path
        let dx = event.locationInWindow.x - d.point.x, dy = event.locationInWindow.y - d.point.y
        guard dx * dx + dy * dy < 9 else { return }
        guard t.getTerminal().mouseMode == .off, !t.hasSelection else { return }
        let p = t.convert(event.locationInWindow, from: nil)
        guard let link = t.linkAt(p) else { return }
        let w = WindowManager.shared.model(for: t.window)
        Task { await TermLinks.openLink(link, window: w) }
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

/// The underline drawn under a link while the pointer is over it.
final class LinkUnderlineView: NSView {
    var segments: [NSRect] = [] { didSet { needsDisplay = true } }
    var color: NSColor = .white
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        for s in segments { s.fill() }
    }
}
