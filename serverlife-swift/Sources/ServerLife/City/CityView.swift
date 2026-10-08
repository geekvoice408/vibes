import AppKit
import SceneKit
import SwiftUI

/// The SceneKit view: takes the keys, the pointer and the wheel, and hands
/// them to the controller.
final class CitySCNView: SCNView {
    weak var city: CityController?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func keyDown(with event: NSEvent) {
        let handled = MainActor.assumeIsolated { city?.keyDown(event) ?? false }
        if !handled { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { MainActor.assumeIsolated { city?.keyUp(event) } }
    override func flagsChanged(with event: NSEvent) { MainActor.assumeIsolated { city?.flagsChanged(event) } }
    override func resignFirstResponder() -> Bool {
        MainActor.assumeIsolated { city?.blur() }
        return super.resignFirstResponder()
    }
    override func mouseDown(with event: NSEvent) {
        // ⌃-click is the context click on a Mac, as right-click.
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        MainActor.assumeIsolated { city?.mouseDown(event, at: point(event)) }
    }
    override func mouseDragged(with event: NSEvent) { MainActor.assumeIsolated { city?.mouseDragged(event, at: point(event)) } }
    override func mouseUp(with event: NSEvent) { MainActor.assumeIsolated { city?.mouseUp(event, at: point(event)) } }
    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated {
            city?.mouseMoved(event, at: point(event))
            (city?.pointer == true ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { city?.mouseExited() }
        NSCursor.arrow.set()
    }
    override func rightMouseDown(with event: NSEvent) { MainActor.assumeIsolated { city?.rightMouseDown(event, at: point(event)) } }
    override func scrollWheel(with event: NSEvent) { MainActor.assumeIsolated { city?.scrollWheel(event) } }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

private struct CitySceneRep: NSViewRepresentable {
    let city: CityController
    func makeNSView(context: Context) -> CitySCNView { city.scnView }
    func updateNSView(_ nsView: CitySCNView, context: Context) {}
}

/// The overlay colours are the original's own (`.c3-*` in styles.css): the
/// HUD sits on a 3D scene, not on the theme.
private enum HUD {
    static let glass = Color(.sRGB, red: 12 / 255, green: 16 / 255, blue: 24 / 255, opacity: 0.66)
    static let text = Color(hex: "#e8edf5")
    static let dim = Color(hex: "#c4ccd8")
    static let edge = Color.white.opacity(0.12)
    static let hover = Color(.sRGB, red: 40 / 255, green: 60 / 255, blue: 100 / 255, opacity: 0.8)
}

private struct C3Button: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { C3Body(configuration: configuration) }
    private struct C3Body: View {
        let configuration: ButtonStyle.Configuration
        @StateObject private var hover = LocalFlag()
        var body: some View {
            configuration.label
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(HUD.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover.on ? HUD.hover : HUD.glass))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(HUD.edge))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .onHover { hover.on = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// Buttons that wrap onto a second line, right-aligned (`flex-wrap`).
private struct CityFlow: Layout {
    var spacing: CGFloat = 3
    var leading = false
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var rows: [CGFloat] = [0], heights: [CGFloat] = [0]
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if rows[rows.count - 1] > 0 && rows[rows.count - 1] + spacing + sz.width > maxW { rows.append(0); heights.append(0) }
            rows[rows.count - 1] += (rows[rows.count - 1] > 0 ? spacing : 0) + sz.width
            heights[heights.count - 1] = max(heights[heights.count - 1], sz.height)
        }
        return CGSize(width: min(maxW, rows.max() ?? 0), height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var lines: [[(Subviews.Element, CGSize)]] = [[]]
        var w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if !lines[lines.count - 1].isEmpty && w + spacing + sz.width > bounds.width { lines.append([]); w = 0 }
            w += (lines[lines.count - 1].isEmpty ? 0 : spacing) + sz.width
            lines[lines.count - 1].append((s, sz))
        }
        var y = bounds.minY
        for line in lines {
            let lw = line.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, line.count - 1))
            var x = leading ? bounds.minX : bounds.maxX - lw
            let lh = line.map(\.1.height).max() ?? 0
            for (s, sz) in line {
                s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
                x += sz.width + spacing
            }
            y += lh + spacing
        }
    }
}

/// The top of the HUD: where you are on the left, the buttons on the right,
/// sharing the width as the original's flex row does — the buttons wrap
/// before the left side is squeezed below about 40%.
private struct CityTopRow: Layout {
    let gap: CGFloat = 6
    func split(_ width: CGFloat, _ subviews: Subviews) -> (CGFloat, CGFloat) {
        guard subviews.count == 2 else { return (width, 0) }
        let leftIdeal = subviews[0].sizeThatFits(.unspecified).width
        let flowIdeal = subviews[1].sizeThatFits(.unspecified).width
        let avail = max(0, width - gap)
        let flowW = min(flowIdeal, max(avail * 0.6, avail - leftIdeal))
        return (max(0, avail - flowW), flowW)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        let (lw, fw) = split(w, subviews)
        let lh = subviews.first?.sizeThatFits(ProposedViewSize(width: lw, height: nil)).height ?? 0
        let fh = subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: fw, height: nil)).height : 0
        return CGSize(width: w, height: max(lh, fh))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lw, fw) = split(bounds.width, subviews)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: lw, height: nil))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.maxX - fw, y: bounds.minY), proposal: ProposedViewSize(width: fw, height: nil))
        }
    }
}

/// The city with its HUD: where you are, the buttons, the legend, the hover
/// card, the crosshair and the help.
struct CityView: View {
    let city: CityController

    private static let helpRows: [(String, String)] = [
        ("Drag", "look around"),
        ("W A S D / arrows", "move"),
        ("Space", "up (fly) · jump (walk)"),
        ("X", "down (fly)"),
        ("Shift", "faster"),
        ("Scroll", "glide forward and back"),
        ("G", "walk ⇄ fly"),
        ("Click", "select · ⌘-click adds"),
        ("Double-click / Enter", "go in, or open the file"),
        ("Backspace", "go out"),
        ("/ or ⌘F", "filter by name"),
        ("Right-click", "the usual file menu"),
    ]

    var body: some View { scene }

    private var scene: some View {
        ZStack(alignment: .topLeading) {
            CitySceneRep(city: city)
            if !city.flying {
                // Walking: a dot where Enter will reach.
                Circle().fill(Color.white.opacity(0.85)).frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            top
            legend
            if let tip = city.tip { tipCard(tip) }
            if city.helpShown { help }
        }
        .frame(minHeight: 160)
        .background(Color(hex: "#0a1324"))
        .clipped()
    }

    private func btn(_ text: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(text) { action(); city.focus() }.buttonStyle(C3Button()).help(title)
    }

    private var top: some View {
        CityTopRow {
            VStack(alignment: .leading, spacing: 4) {
                note(city.whereText, mono: true).help(city.whereTitle)
                if !city.measureNote.isEmpty { note(city.measureNote, small: true) }
                if !city.trafficNote.isEmpty { note(city.trafficNote, small: true) }
                if city.approveShown {
                    Button("Measure folders (approve MFA)") { city.approveMeasuring() }.buttonStyle(C3Button())
                }
            }
            .frame(minWidth: 0, alignment: .leading)
            CityFlow {
                styleMenu
                btn(city.trafficOn ? "🚦 Processes on" : "🚦 Processes",
                    "Show this machine’s processes as traffic — cars for CPU, boats for memory, rockets for the biggest") {
                    city.setTraffic(!city.trafficOn)
                }
                if !city.outHidden { btn(city.outText, city.outTitle) { city.out() } }
                if !city.hereHidden { btn("🏙 City of here", "See this folder’s own folders as a city") { city.cityOfHere() } }
                btn(city.flying ? "✈ Flying" : "🚶 Walking", "Walk on the ground, or fly (G)") { city.setFlying(!city.flying) }
                btn("⌂", "Back to the overview") { city.spawn() }
                btn(city.maximized ? "⤡" : "⤢", "Fill the window (Esc to come back)") { city.toggleMax() }
                btn("?", "How to move around") { city.helpShown.toggle() }
                Button("☰ List") { city.backToList() }.buttonStyle(C3Button()).help("Back to the file list (or press 3D again)")
            }
        }
        .padding(6)
    }

    /// What the town is built in.
    private var styleMenu: some View {
        Menu {
            ForEach(CityStyle.groups, id: \.self) { g in
                Section(g) {
                    ForEach(CityStyle.all.filter { $0.group == g }, id: \.id) { s in
                        Button { city.setStyle(s.id) } label: {
                            if s.id == city.style { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                    }
                }
            }
        } label: {
            Text(CityStyle.byId(city.style).label).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(HUD.text)
        .fixedSize()
        .frame(maxWidth: 210)
        .foregroundStyle(HUD.text)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5).fill(HUD.glass))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(HUD.edge))
        .help("Architecture — the shapes change, the heights and colours never do")
    }

    private func note(_ text: String, mono: Bool = false, small: Bool = false) -> some View {
        Text(text)
            .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: small ? 10.5 : 11.5))
            .foregroundStyle(small ? HUD.dim : HUD.text)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(HUD.glass))
    }

    private var legend: some View {
        VStack {
            Spacer()
            CityFlow(spacing: 4, leading: true) {
                ForEach(city.legend, id: \.self) { k in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: cityColor(CityKinds.colors[k] ?? 0x8b95a5))).frame(width: 9, height: 9)
                        Text(CityKinds.labels[k] ?? k).font(.system(size: 10.5))
                    }
                    .foregroundStyle(Color(hex: "#dfe5ee"))
                    .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color(.sRGB, red: 12 / 255, green: 16 / 255, blue: 24 / 255, opacity: 0.62)))
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .allowsHitTesting(false)
    }

    private func tipCard(_ tip: CityTip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tip.lines.enumerated()), id: \.offset) { _, l in
                switch l.cls {
                case "n": Text(l.text).font(.system(size: 11.5, weight: .semibold))
                case "m": Text(l.text).font(.system(size: 11.5)).opacity(0.85).padding(.top, 2)
                case "k": Text(l.text).font(.system(size: 10.5)).opacity(0.75).padding(.top, 2)
                default: Text(l.text).font(.system(size: 10)).opacity(0.55).padding(.top, 4)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260, alignment: .leading)
        .foregroundStyle(HUD.text)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.sRGB, red: 12 / 255, green: 16 / 255, blue: 24 / 255, opacity: 0.88)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
        .offset(x: tip.at.x, y: tip.at.y)
        .allowsHitTesting(false)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Getting around").font(.system(size: 11.5, weight: .semibold)).padding(.bottom, 6)
            ForEach(Self.helpRows, id: \.0) { k, v in
                HStack {
                    Text(k).font(.system(size: 10.5, design: .monospaced))
                        .padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)))
                    Spacer(minLength: 10)
                    Text(v).font(.system(size: 11.5))
                }
                .padding(.vertical, 2)
            }
            Text("Height is the data under a folder; width is how many files; colours are what kind.")
                .font(.system(size: 10.5)).opacity(0.7).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .foregroundStyle(HUD.text)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 270)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.sRGB, red: 12 / 255, green: 16 / 255, blue: 24 / 255, opacity: 0.92)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .padding(.top, 36).padding(.trailing, 6)
    }
}
