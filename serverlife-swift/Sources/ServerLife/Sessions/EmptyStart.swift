import SwiftUI

/// The start page: nodes orbiting a core with packets in flight, the name,
/// and the ways in. It runs until the first session takes over the view.
struct EmptyStartView: View {
    let window: WindowModel

    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 0) {
            Orbiter().frame(width: 210, height: 210).padding(.bottom, 10)
            Text("ServerLife").font(.system(size: 26, weight: .light)).kerning(0.5).padding(.bottom, 6)
            HStack(spacing: 6) {
                Text("servers are life")
                Text("·")
                Text("life is servers")
            }
            .font(.system(size: 13)).foregroundStyle(p.muted).padding(.bottom, 18)
            HStack(spacing: 9) {
                BigButton(icon: "terminal", label: "New session", primary: true) { act("new-session") }
                BigButton(icon: "bolt", label: "Quick connect") { act("quick-connect") }
                BigButton(icon: "chevron.right", label: "Local shell") { act("new-local") }
                BigButton(icon: "globe", label: "Network tools") { act("nettools") }
                BigButton(icon: "book", label: "Guide") { act("guide") }
                BigButton(icon: "macwindow.on.rectangle", label: "New window") { act("new-window") }
            }
            .padding(.bottom, 22)
            HintsRow()
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func act(_ id: String) { Actions.shared.perform(id, window: window) }
}

private struct HintsRow: View {
    var body: some View {
        let p = Theme.shared.p
        let hints = [("⌘N", "new session"), ("⌘⌥C", "quick connect"), ("⌘⇧D", "split right"), ("⌘⇧M", "multi-exec"),
                     ("⌘E", "file browser"), ("⌘⇧T", "network tools"), ("⌘⌥N", "new window")]
        HStack(spacing: 16) {
            ForEach(hints, id: \.0) { h in
                (Text(h.0).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundColor(p.textDim)
                 + Text(" " + h.1).font(.system(size: 11.5)).foregroundColor(p.muted))
            }
        }
    }
}

private struct BigButton: View {
    let icon: String
    let label: String
    var primary = false
    let action: () -> Void
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 19, weight: .light)).frame(height: 22)
                    .opacity(hover.on ? 1 : 0.85)
                Text(label).font(.system(size: 12))
            }
            .frame(minWidth: 104)
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 11)
            .foregroundStyle(primary ? Color.white : p.text)
            .background(RoundedRectangle(cornerRadius: 9).fill(primary ? p.accent : (hover.on ? p.panel3 : p.panel2)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(primary ? Color.clear : p.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// Nodes orbiting a glowing core, packets crossing between the rings.
private struct Orbiter: View {
    var body: some View {
        let p = Theme.shared.p
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let k = min(size.width, size.height) / 240
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                func pt(_ r: Double, _ deg: Double) -> CGPoint {
                    let a = deg * .pi / 180
                    return CGPoint(x: c.x + CGFloat(r * sin(a)) * k, y: c.y - CGFloat(r * cos(a)) * k)
                }
                // Rings, dashed and turning slowly.
                for (r, period, rev) in [(54.0, 26.0, false), (78.0, 38.0, true), (102.0, 52.0, false)] {
                    var ring = ctx
                    ring.translateBy(x: c.x, y: c.y)
                    ring.rotate(by: .degrees((rev ? -1 : 1) * t / period * 360))
                    ring.stroke(Path(ellipseIn: CGRect(x: -r * k, y: -r * k, width: 2 * r * k, height: 2 * r * k)),
                                with: .color(p.border), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
                // The glow and the core.
                let pulse = 0.85 + 0.15 * sin(t * 2 * .pi / 3.2)
                let g = 46 * k * pulse
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)),
                         with: .radialGradient(Gradient(colors: [p.accent.opacity(0.9), p.accent.opacity(0.15), p.accent.opacity(0)]),
                                               center: c, startRadius: 0, endRadius: g))
                for (i, y) in [108.0, 120.0].enumerated() {
                    let r = Path(roundedRect: CGRect(x: c.x - 15 * k, y: c.y + (y - 120) * k, width: 30 * k, height: 9 * k), cornerRadius: 2 * k)
                    ctx.fill(r, with: .color(p.panel3)); ctx.stroke(r, with: .color(p.accent), lineWidth: 1.2)
                    let lit = 0.5 + 0.5 * sin(t * 2 * .pi / 1.7 + Double(i) * .pi)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9 * k - 1.6 * k, y: c.y + (y - 120 + 4.5) * k - 1.6 * k,
                                                    width: 3.2 * k, height: 3.2 * k)),
                             with: .color((i == 0 ? p.green : p.accent).opacity(0.3 + 0.7 * lit)))
                }
                // Nodes on their orbits.
                let nodes: [(Double, Double, Double, Bool)] = [(54, 0, 14, false), (78, 90, 22, true), (78, 270, 22, true),
                                                               (102, 0, 30, false), (102, 180, 30, false)]
                for (i, n) in nodes.enumerated() {
                    let deg = n.1 + (n.3 ? -1 : 1) * t / n.2 * 360
                    let q = pt(n.0, deg)
                    let r = Path(roundedRect: CGRect(x: q.x - 9 * k, y: q.y - 6 * k, width: 18 * k, height: 12 * k), cornerRadius: 2 * k)
                    ctx.fill(r, with: .color(p.panel2)); ctx.stroke(r, with: .color(p.muted), lineWidth: 1)
                    let lit = 0.5 + 0.5 * sin(t * 2 * .pi / 1.7 + Double(i))
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4 * k - 1.4 * k, y: q.y - 1.4 * k, width: 2.8 * k, height: 2.8 * k)),
                             with: .color((i % 2 == 0 ? p.green : p.accent).opacity(0.3 + 0.7 * lit)))
                }
                // Packets in flight between the core and the rings.
                for (i, (period, delay, r)) in [(2.8, 0.0, 54.0), (3.6, 0.6, 78.0), (4.4, 1.2, 102.0)].enumerated() {
                    let u = ((t - delay) / period).truncatingRemainder(dividingBy: 1)
                    let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
                    let dist = r * (u < 0.5 ? e * 2 : 2 - e * 2) * 0.5 + 10
                    let q = pt(dist, Double(i) * 120 + 40)
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2.4 * k, y: q.y - 2.4 * k, width: 4.8 * k, height: 4.8 * k)),
                             with: .color(p.accent))
                }
            }
        }
    }
}
