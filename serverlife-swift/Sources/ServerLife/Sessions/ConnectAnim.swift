import SwiftUI

/// The little scene that plays while a session dials — connectanim.js.
///
/// Connecting is dead time; these fill it with a courier of some kind
/// crossing from this machine to the server, over a link drawn as a pipe, a
/// wire, rails or waves. Thirty of them rotate. The two machines are drawn;
/// the traveller is a glyph.
struct ConnectAnim: Identifiable, Hashable {
    let id: String
    let name: String
    let cast: [String]
    let motion: String
    let trail: String

    static let all: [ConnectAnim] = [
        .init(id: "robots", name: "Robots shaking hands", cast: ["🤖", "🦾"], motion: "march", trail: "dots"),
        .init(id: "tubes", name: "Pneumatic tubes", cast: ["📦"], motion: "shoot", trail: "pipe"),
        .init(id: "rocket", name: "Rocket post", cast: ["🚀"], motion: "slide", trail: "beam"),
        .init(id: "pigeon", name: "Carrier pigeon", cast: ["🐦"], motion: "flap", trail: "none"),
        .init(id: "satellite", name: "Satellite relay", cast: ["🛰️"], motion: "arc", trail: "arc"),
        .init(id: "train", name: "Freight train", cast: ["🚂", "🚃", "🚃"], motion: "convoy", trail: "rails"),
        .init(id: "submarine", name: "Undersea cable", cast: ["🚢"], motion: "bob", trail: "waves"),
        .init(id: "plane", name: "Paper plane", cast: ["✈️"], motion: "glide", trail: "dash"),
        .init(id: "ants", name: "Ants with packets", cast: ["🐜", "🐜", "🐜"], motion: "convoy", trail: "wire"),
        .init(id: "laser", name: "Laser link", cast: ["✨"], motion: "zip", trail: "beam"),
        .init(id: "conveyor", name: "Conveyor belt", cast: ["📦", "📦"], motion: "convoy", trail: "belt"),
        .init(id: "hamster", name: "Hamster-powered", cast: ["🐹"], motion: "roll", trail: "wire"),
        .init(id: "lightning", name: "Lightning link", cast: ["⚡"], motion: "zip", trail: "bolt"),
        .init(id: "teleport", name: "Teleporter", cast: ["🫠"], motion: "beamup", trail: "portal"),
        .init(id: "snail", name: "Snail mail", cast: ["🐌"], motion: "crawl", trail: "slime"),
        .init(id: "balloon", name: "Hot air balloon", cast: ["🎈"], motion: "drift", trail: "none"),
        .init(id: "bucket", name: "Bucket brigade", cast: ["🪣", "🪣"], motion: "convoy", trail: "wire"),
        .init(id: "zipline", name: "Zip line", cast: ["🧗"], motion: "shoot", trail: "wire"),
        .init(id: "morse", name: "Morse code", cast: ["•", "—", "•"], motion: "convoy", trail: "dash"),
        .init(id: "tincan", name: "Tin can telephone", cast: ["🥫"], motion: "slide", trail: "wire"),
        .init(id: "drone", name: "Drone delivery", cast: ["🛸"], motion: "hover", trail: "dots"),
        .init(id: "cat", name: "Cat chasing a packet", cast: ["🐈", "🧶"], motion: "chase", trail: "none"),
        .init(id: "wormhole", name: "Wormhole", cast: ["🌀"], motion: "beamup", trail: "portal"),
        .init(id: "bridge", name: "Bridge builder", cast: ["🔨"], motion: "build", trail: "planks"),
        .init(id: "bees", name: "Busy bees", cast: ["🐝", "🐝"], motion: "flap", trail: "dots"),
        .init(id: "traffic", name: "Rush hour", cast: ["🚚", "🚗"], motion: "convoy", trail: "road"),
        .init(id: "radio", name: "Radio waves", cast: ["📡"], motion: "pulse", trail: "ripple"),
        .init(id: "dolphin", name: "Dolphin express", cast: ["🐬"], motion: "bob", trail: "waves"),
        .init(id: "ghost", name: "Friendly packet ghost", cast: ["👻"], motion: "drift", trail: "none"),
        .init(id: "scooter", name: "Courier scooter", cast: ["🛵"], motion: "slide", trail: "road"),
    ]

    static func byId(_ id: String) -> ConnectAnim? { all.first { $0.id == id } }

    /// Where the rotation is up to. Per machine, not per session.
    private static let rotateKey = "serverlife.connectAnim"

    @MainActor static func nextInRotation() -> ConnectAnim {
        let i = UserDefaults.standard.integer(forKey: rotateKey)
        let n = all.count
        let a = all[((i % n) + n) % n]
        UserDefaults.standard.set((i + 1) % n, forKey: rotateKey)
        return a
    }

    /// The setting, resolved: nothing when off, the pinned one, or the next up.
    @MainActor static func pick() -> ConnectAnim? {
        let pref = Store.shared.settingJSON("connectAnim").string ?? "rotate"
        if pref == "off" { return nil }
        if pref != "rotate", let a = byId(pref) { return a }
        return nextInRotation()
    }

    // MARK: Motion

    /// Seconds per crossing, and the easing, by motion (the CSS keyframes).
    var duration: Double {
        switch motion {
        case "flap": return 3; case "arc": return 3.2; case "bob": return 3.4; case "shoot": return 2.2
        case "zip": return 1.6; case "crawl": return 9; case "drift": return 5; case "hover": return 3.6
        case "roll": return 3; case "beamup": return 3; case "pulse": return 1.8; case "build": return 2.6
        case "convoy": return 3.4; case "march": return 4; case "chase": return 2.4
        default: return 2.8
        }
    }

    struct Frame { var x: Double; var y: Double; var rotation: Double = 0; var scale: Double = 1; var opacity: Double = 1; var scaleX: Double = 1 }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

    /// Interpolate keyframes [(at, x, y, rot, scale, opacity)].
    private static func keys(_ t: Double, _ k: [(Double, Double, Double, Double, Double, Double)], ease: Bool = false) -> Frame {
        var i = 0
        while i < k.count - 2 && t > k[i + 1].0 { i += 1 }
        let a = k[i], b = k[min(i + 1, k.count - 1)]
        let span = max(b.0 - a.0, 0.0001)
        var u = min(max((t - a.0) / span, 0), 1)
        if ease { u = easeInOut(u) }
        return Frame(x: lerp(a.1, b.1, u), y: lerp(a.2, b.2, u), rotation: lerp(a.3, b.3, u),
                     scale: lerp(a.4, b.4, u), opacity: lerp(a.5, b.5, u))
    }

    /// Where the traveller is at phase t (0…1): x as a fraction of the track
    /// (−0.1 … 1.1), y as a fraction of the actor's height (−0.5 is centred).
    func frame(_ t: Double) -> Frame {
        let end = 1.08
        switch motion {
        case "glide":
            return Self.keys(t, [(0, -0.1, -0.5, -8, 1, 1), (0.5, 0.45, -1.2, 4, 1, 1), (1, end, -0.5, -8, 1, 1)], ease: true)
        case "flap":
            var f = Self.keys(t, [(0, -0.1, -0.5, 0, 1, 1), (0.25, 0.22, -1.3, 0, 1, 1), (0.5, 0.5, -0.3, 0, 1, 1),
                                  (0.75, 0.76, -1.2, 0, 1, 1), (1, end, -0.5, 0, 1, 1)], ease: true)
            f.scaleX = (t.truncatingRemainder(dividingBy: 0.25) < 0.125) ? 1 : 0.92
            return f
        case "arc":
            return Self.keys(t, [(0, -0.1, -0.5, 0, 1, 1), (0.5, 0.45, -2.1, 0, 1, 1), (1, end, -0.5, 0, 1, 1)], ease: true)
        case "bob":
            return Self.keys(t, [(0, -0.1, -0.5, -4, 1, 1), (0.5, 0.45, -0.85, 5, 1, 1), (0.99, end, -0.5, -4, 1, 1), (1, end, -0.5, -4, 1, 1)], ease: true)
        case "shoot":
            let u = t < 0.12 ? 0 : t > 0.6 ? 1 : Self.easeInOut((t - 0.12) / 0.48)
            return Frame(x: Self.lerp(-0.1, end, u), y: -0.5, opacity: t > 0.6 ? 1 - (t - 0.6) / 0.4 : 1)
        case "zip":
            if t < 0.45 {
                let u = t / 0.45
                return Frame(x: Self.lerp(-0.1, end, u), y: -0.5, scale: Self.lerp(0.6, 1.1, u), opacity: t < 0.2 ? t / 0.2 : 1)
            }
            return Frame(x: end, y: -0.5, opacity: t < 0.55 ? 1 - (t - 0.45) / 0.1 : 0)
        case "drift":
            return Self.keys(t, [(0, -0.1, -0.4, 0, 1, 1), (0.33, 0.3, -0.8, 0, 1, 1), (0.66, 0.65, -0.25, 0, 1, 1), (1, end, -0.6, 0, 1, 1)], ease: true)
        case "hover":
            return Self.keys(t, [(0, -0.1, -0.5, 0, 1, 1), (0.2, 0.18, -0.9, 0, 1, 1), (0.5, 0.5, -0.5, 0, 1, 1),
                                 (0.8, 0.8, -0.95, 0, 1, 1), (1, end, -0.5, 0, 1, 1)], ease: true)
        case "roll":
            return Frame(x: Self.lerp(-0.1, end, t), y: -0.5, rotation: 720 * t)
        case "beamup":
            return Self.keys(t, [(0, -0.1, -0.5, 0, 1, 1), (0.25, 0.15, -0.5, 0, 0.2, 0), (0.5, 0.5, -0.5, 0, 0.2, 0),
                                 (0.75, 0.85, -0.5, 0, 1, 1), (1, end, -0.5, 0, 1, 1)])
        case "pulse":
            let s = 0.9 + 0.35 * (0.5 - 0.5 * cos(2 * .pi * t))
            return Frame(x: 0.4, y: -0.5, scale: s)
        case "build":
            return t < 0.85 ? Frame(x: Self.lerp(-0.1, end, t / 0.85), y: -0.5) : Frame(x: end, y: -0.5, opacity: 1 - (t - 0.85) / 0.15)
        case "march":
            let steps = 14.0
            return Frame(x: Self.lerp(-0.1, end, (t * steps).rounded(.down) / steps), y: -0.5)
        case "chase":
            return Frame(x: Self.lerp(-0.1, end, Self.easeInOut(t)), y: -0.5)
        default: // slide, convoy, crawl
            return Frame(x: Self.lerp(-0.1, end, t), y: -0.5)
        }
    }
}

/// The scene: this machine, the link, the far end, and the cast crossing.
struct ConnectSceneView: View {
    let anim: ConnectAnim

    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                MachineIcon(rack: false).frame(width: 38, height: 38)
                GeometryReader { g in
                    TimelineView(.animation) { tl in
                        let now = tl.date.timeIntervalSinceReferenceDate
                        ZStack(alignment: .leading) {
                            ConnectTrail(trail: anim.trail, time: now).frame(width: g.size.width, height: g.size.height)
                            ForEach(Array(anim.cast.enumerated()), id: \.offset) { i, glyph in
                                let delay = Double(i) * 0.55
                                let phase = ((now - delay) / anim.duration).truncatingRemainder(dividingBy: 1)
                                let f = anim.frame(phase < 0 ? phase + 1 : phase)
                                Text(glyph)
                                    .font(.system(size: 19))
                                    .scaleEffect(x: f.scale * f.scaleX, y: f.scale)
                                    .rotationEffect(.degrees(f.rotation))
                                    .opacity(f.opacity)
                                    .position(x: CGFloat(f.x) * g.size.width + 10,
                                              y: g.size.height / 2 + CGFloat(f.y + 0.5) * 22)
                            }
                        }
                    }
                }
                .frame(minWidth: 60)
                .clipped()
                MachineIcon(rack: true).frame(width: 38, height: 38)
            }
            .frame(maxWidth: 320)
            .frame(height: 76)
            Text(anim.name).font(.system(size: 10.5)).kerning(0.4).foregroundStyle(p.muted)
        }
        .padding(.top, 2).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }
}

/// The two machines: a laptop with its lid open, and a rack whose lights
/// blink out of step with ours.
private struct MachineIcon: View {
    let rack: Bool
    var body: some View {
        let p = Theme.shared.p
        TimelineView(.periodic(from: .now, by: 0.8)) { tl in
            let on = Int(tl.date.timeIntervalSinceReferenceDate / 0.8) % 2 == 0
            Canvas { ctx, size in
                let s = min(size.width / 40, size.height / 32)
                func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ rad: Double) -> Path {
                    Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: rad * s)
                }
                func led(_ x: Double, _ y: Double, _ lit: Bool) {
                    ctx.fill(Path(ellipseIn: CGRect(x: (x - 1.4) * s, y: (y - 1.4) * s, width: 2.8 * s, height: 2.8 * s)),
                             with: .color(p.accent.opacity(lit ? 1 : 0.2)))
                }
                if rack {
                    let body = r(8, 2, 24, 28, 2.5)
                    ctx.fill(body, with: .color(p.panel3)); ctx.stroke(body, with: .color(p.border), lineWidth: 1.2)
                    for (i, y) in [6.0, 14, 22].enumerated() {
                        let scr = r(11, y, 18, 5, 1)
                        ctx.fill(scr, with: .color(p.bg)); ctx.stroke(scr, with: .color(p.accentDim), lineWidth: 0.8)
                        led(14, y + 2.5, i == 1 ? !on : on)
                    }
                } else {
                    let body = r(7, 4, 26, 17, 2)
                    ctx.fill(body, with: .color(p.panel3)); ctx.stroke(body, with: .color(p.border), lineWidth: 1.2)
                    let scr = r(10, 7, 20, 11, 1)
                    ctx.fill(scr, with: .color(p.bg)); ctx.stroke(scr, with: .color(p.accentDim), lineWidth: 0.8)
                    var base = Path()
                    base.move(to: CGPoint(x: 3 * s, y: 24 * s)); base.addLine(to: CGPoint(x: 37 * s, y: 24 * s))
                    base.addLine(to: CGPoint(x: 35 * s, y: 28 * s)); base.addLine(to: CGPoint(x: 5 * s, y: 28 * s)); base.closeSubpath()
                    ctx.fill(base, with: .color(p.panel3)); ctx.stroke(base, with: .color(p.border), lineWidth: 1.2)
                    led(13, 12.5, on)
                }
            }
        }
        .opacity(0.9)
    }
}

/// The link itself, by trail.
private struct ConnectTrail: View {
    let trail: String
    let time: Double

    var body: some View {
        let p = Theme.shared.p
        Canvas { ctx, size in
            let midY = size.height / 2
            let w = size.width
            func band(_ h: CGFloat) -> CGRect { CGRect(x: 0, y: midY - h / 2, width: w, height: h) }
            let flow = CGFloat(time.truncatingRemainder(dividingBy: 1))
            switch trail {
            case "wire":
                ctx.fill(Path(band(2)), with: .color(p.border))
            case "pipe":
                let r = Path(roundedRect: band(16), cornerRadius: 8)
                ctx.fill(r, with: .color(p.panel2)); ctx.stroke(r, with: .color(p.border))
            case "beam":
                let a = 0.65 + 0.35 * cos(time * 2 * .pi / 1.6)
                ctx.fill(Path(roundedRect: band(3), cornerRadius: 2),
                         with: .linearGradient(Gradient(colors: [.clear, p.accent.opacity(a), .clear]),
                                               startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: w, y: midY)))
            case "dots":
                var x = flow * 12
                while x < w { ctx.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: midY - 1.6, width: 3.2, height: 3.2)), with: .color(p.accent)); x += 12 }
            case "dash":
                var x = flow * 14 / 1.1 - 14
                while x < w { ctx.fill(Path(CGRect(x: x, y: midY - 1, width: 7, height: 2)), with: .color(p.muted)); x += 14 }
            case "rails":
                ctx.fill(Path(CGRect(x: 0, y: midY - 5, width: w, height: 2)), with: .color(p.border))
                ctx.fill(Path(CGRect(x: 0, y: midY + 3, width: w, height: 2)), with: .color(p.border))
                var x: CGFloat = 0
                while x < w { ctx.fill(Path(CGRect(x: x, y: midY - 5, width: 2, height: 10)), with: .color(p.border)); x += 9 }
            case "belt":
                let r = Path(roundedRect: band(12), cornerRadius: 3)
                ctx.fill(r, with: .color(p.panel2))
                var x = flow / 0.7 * 11 - 11
                while x < w { ctx.fill(Path(CGRect(x: x, y: midY - 6, width: 3, height: 12)), with: .color(p.border)); x += 11 }
            case "road":
                ctx.fill(Path(roundedRect: band(14), cornerRadius: 2), with: .color(p.panel2))
                var x: CGFloat = 0
                while x < w { ctx.fill(Path(CGRect(x: x, y: midY - 1, width: 7, height: 2)), with: .color(p.muted)); x += 18 }
            case "waves":
                var path = Path()
                var x = -12 + flow / 1.4 * 12
                path.move(to: CGPoint(x: x, y: midY + 4))
                while x < w { path.addQuadCurve(to: CGPoint(x: x + 12, y: midY + 4), control: CGPoint(x: x + 6, y: midY - 4)); x += 12 }
                ctx.stroke(path, with: .color(p.accentDim.opacity(0.5)), lineWidth: 1)
            case "arc":
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                path.addQuadCurve(to: CGPoint(x: w, y: midY), control: CGPoint(x: w / 2, y: midY - 34))
                ctx.stroke(path, with: .color(p.border), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            case "bolt":
                if Int(time / 0.25) % 2 == 0 {
                    var x: CGFloat = 0
                    while x < w { ctx.fill(Path(CGRect(x: x, y: midY - 1, width: 6, height: 2)), with: .color(p.amber)); x += 10 }
                }
            case "slime":
                ctx.fill(Path(roundedRect: band(5), cornerRadius: 3),
                         with: .linearGradient(Gradient(colors: [p.green.opacity(0.35), .clear]),
                                               startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: w, y: midY)))
            case "planks":
                let reach = w * (0.08 + 0.92 * CGFloat((time / 2.6).truncatingRemainder(dividingBy: 1)))
                var x: CGFloat = 0
                while x < reach { ctx.fill(Path(CGRect(x: x, y: midY - 4, width: 7, height: 8)), with: .color(p.border)); x += 11 }
            case "portal":
                var c = ctx
                c.translateBy(x: w / 2, y: midY)
                c.rotate(by: .degrees(time / 3 * 360))
                c.stroke(Path(ellipseIn: CGRect(x: -20, y: -20, width: 40, height: 40)), with: .color(p.accent),
                         style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            case "ripple":
                let u = (time / 1.8).truncatingRemainder(dividingBy: 1)
                let d = 30 * (0.3 + 1.9 * u)
                ctx.stroke(Path(ellipseIn: CGRect(x: w / 2 - d / 2, y: midY - d / 2, width: d, height: d)),
                           with: .color(p.accent.opacity(0.9 * (1 - u))), lineWidth: 2)
            default:
                break
            }
        }
    }
}
