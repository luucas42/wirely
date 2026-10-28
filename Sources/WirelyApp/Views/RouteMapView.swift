import SwiftUI
import AppKit
import WirelyCore

/// Land-dot grid cache: the dots only depend on the frame, so they are computed once per
/// (size, home, exit) and not on every animation tick or status poll.
private final class DotCache {
    private var key = ""
    private(set) var path = Path()

    fileprivate func path(for layout: MapLayout, key: String) -> Path {
        guard key != self.key else { return path }
        var p = Path()
        // 9 pt grid: dense enough for coastlines (Bosphorus, Adriatic) to read at window size.
        for pt in layout.frame.landDots(spacing: 9) {
            p.addEllipse(in: CGRect(x: pt.x - 1.8, y: pt.y - 1.8, width: 3.6, height: 3.6))
        }
        p = p.offsetBy(dx: 0, dy: -layout.dy)
        self.key = key
        path = p
        return p
    }
}

/// Dotted world map with the route arc from home to the exit.
/// Equatable on its inputs: the parent re-renders every second (status polling, elapsed time) and
/// redrawing thousands of dots and re-measuring labels each time cost several % CPU while idle.
struct RouteMapView: View, Equatable {
    let home: HomeLocation?
    let exit: ExitLocation?
    let exitIP: String?
    let phase: RoutePhase
    /// Moves a lone You marker into the upper part of the map (the empty state's card sits in the middle).
    var lifted = false

    @EnvironmentObject private var l10n: L10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewMode) private var previewMode
    @State private var cache = DotCache()
    @State private var windowVisible = true
    /// Read in `body` so a light/dark switch still redraws the canvases despite `.equatable()`.
    @Environment(\.colorScheme) private var colorScheme

    static func == (a: RouteMapView, b: RouteMapView) -> Bool {
        a.home == b.home && a.exit == b.exit && a.exitIP == b.exitIP && a.phase == b.phase && a.lifted == b.lifted
    }

    var body: some View {
        let _ = colorScheme
        GeometryReader { geo in
            let layout = MapLayout(size: geo.size, home: home?.point, exit: exit?.point, lift: lifted)
            let dots = cache.path(for: layout, key: layout.key)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in ctx.fill(dots, with: .color(Theme.dot)) }
                arcLayer(layout)
                Canvas { ctx, _ in drawMarkers(ctx, layout) }
                labels(layout)
            }
            .clipped()
        }
        .background {
            // AppKit probe; ImageRenderer (preview renders) can't draw NSViews, and has no window anyway.
            if !previewMode { WindowVisibilityReader(visible: $windowVisible) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Arc

    private var animates: Bool {
        (phase == .connected || phase == .connecting) && !reduceMotion && !previewMode
    }

    @ViewBuilder
    private func arcLayer(_ layout: MapLayout) -> some View {
        if layout.hasRoute {
            if animates {
                // 30 fps is plenty for a few dots gliding along the arc (the display may run at 120 Hz),
                // and nothing needs to move while the window isn't on screen.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !windowVisible)) { tl in
                    Canvas { ctx, _ in drawArc(ctx, layout, time: tl.date.timeIntervalSinceReferenceDate) }
                }
            } else {
                Canvas { ctx, _ in drawArc(ctx, layout, time: nil) }
            }
        }
    }

    private var arcColor: Color {
        switch phase {
        case .connected: return Theme.cobalt
        case .connecting: return Theme.signal
        case .noResponse, .failed: return Theme.coral
        case .idle, .invalid: return Theme.secondary
        }
    }

    private func drawArc(_ ctx: GraphicsContext, _ l: MapLayout, time: Double?) {
        guard let path = l.arcPath else { return }
        switch phase {
        case .connected, .connecting:
            ctx.stroke(path, with: .color(arcColor.opacity(0.18)),
                       style: StrokeStyle(lineWidth: 10, lineCap: .round))
            ctx.stroke(path, with: .color(arcColor), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            drawPackets(ctx, l, time: time)
        case .noResponse:
            let style = StrokeStyle(lineWidth: 2.6, lineCap: .round)
            ctx.stroke(path.trimmedPath(from: 0, to: 1.0 / 3), with: .color(arcColor), style: style)
            ctx.stroke(path.trimmedPath(from: 2.0 / 3, to: 1), with: .color(arcColor), style: style)
        case .failed:
            ctx.stroke(path, with: .color(arcColor),
                       style: StrokeStyle(lineWidth: 2.6, lineCap: .butt, dash: [6, 6]))
        case .idle, .invalid:
            ctx.stroke(path, with: .color(arcColor.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 2.6, lineCap: .butt, dash: [6, 6]))
        }
    }

    private func drawPackets(_ ctx: GraphicsContext, _ l: MapLayout, time: Double?) {
        let connecting = phase == .connecting
        let offsets: [Double]
        if let time {
            let period = connecting ? 5.0 : 3.2
            let base = (time / period).truncatingRemainder(dividingBy: 1)
            offsets = connecting ? [base] : [base, base + 1.0 / 3, base + 2.0 / 3]
        } else {
            offsets = [0.42]   // reduce motion / previews: a single parked packet, as in the mockup
        }
        for o in offsets {
            let t = o.truncatingRemainder(dividingBy: 1)
            let fade = time == nil ? 1 : min(1, min(t, 1 - t) * 10)
            let pt = l.point(at: t)
            let r: CGFloat = 4.5
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(fade)))
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 1.25, dy: 1.25)),
                       with: .color(arcColor.opacity(fade)), lineWidth: 2.5)
        }
    }

    // MARK: Markers and labels

    private var exitColor: Color { phase == .noResponse || phase == .failed ? Theme.coral : phase == .connecting ? Theme.signal : Theme.cobalt }

    private func drawMarkers(_ ctx: GraphicsContext, _ l: MapLayout) {
        if let h = l.homePt {
            ctx.fill(Path(ellipseIn: CGRect(x: h.x - 6, y: h.y - 6, width: 12, height: 12)), with: .color(Theme.ink))
        }
        if let e = l.exitPt {
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 15, y: e.y - 15, width: 30, height: 30)),
                     with: .color(exitColor.opacity(0.16)))
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 7, y: e.y - 7, width: 14, height: 14)), with: .color(exitColor))
        }
    }

    private struct Label {
        var title: String
        var subtitle: String
        var color: Color
        var rect: CGRect
        var trailing: Bool
    }

    private func makeLabels(_ l: MapLayout) -> [Label] {
        var out: [Label] = []
        var homeLabel: Label?
        if let h = l.homePt, let home {
            let w = Self.width(title: home.city, subtitle: l10n(.you))
            // To the right of You unless that overflows (or the exit lies to the right of it and a left label is clearer).
            let overflow = h.x + 14 + w > l.size.width - 4
            let x = overflow ? h.x - 14 - w : h.x + 14
            homeLabel = Label(title: home.city, subtitle: l10n(.you), color: Theme.ink,
                              rect: CGRect(x: x, y: h.y - 12, width: w, height: 38), trailing: overflow)
        }
        if let e = l.exitPt, let exit {
            let sub = exitIP.map { l10n.format(.exitServer, $0) } ?? exit.countryCode
            let w = Self.width(title: exit.city, subtitle: sub)
            // On the side away from You.
            var left = (l.homePt.map { $0.x > e.x } ?? false)
            if !left, e.x + 22 + w > l.size.width - 4 { left = true }
            if left, e.x - 22 - w < 4 { left = false }
            var x = left ? e.x - 22 - w : e.x + 22
            var y = e.y - 12
            if let hl = homeLabel, hl.rect.insetBy(dx: -4, dy: -4).intersects(CGRect(x: x, y: y, width: w, height: 38)) {
                y = e.y + 14      // crowded: drop the exit label below its marker
                if hl.rect.insetBy(dx: -4, dy: -4).intersects(CGRect(x: x, y: y, width: w, height: 38)) {
                    y = e.y - 50
                }
            }
            x = max(4, min(x, l.size.width - w - 4))
            y = max(2, min(y, l.size.height - 40))
            out.append(Label(title: exit.city, subtitle: sub, color: phase == .connecting ? Theme.ink : exitColor,
                             rect: CGRect(x: x, y: y, width: w, height: 38), trailing: left))
        }
        if var hl = homeLabel {
            hl.rect.origin.y = max(2, min(hl.rect.origin.y, l.size.height - 40))
            out.append(hl)
        }
        return out
    }

    private func labels(_ l: MapLayout) -> some View {
        ForEach(Array(makeLabels(l).enumerated()), id: \.offset) { _, lb in
            VStack(alignment: lb.trailing ? .trailing : .leading, spacing: 1) {
                Text(lb.title).font(.mr(15, 700)).foregroundStyle(lb.color)
                Text(lb.subtitle).font(.mr(12, 500)).foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            .frame(width: lb.rect.width, alignment: lb.trailing ? .trailing : .leading)
            .offset(x: lb.rect.minX, y: lb.rect.minY)
        }
        .allowsHitTesting(false)
    }

    private static func width(title: String, subtitle: String) -> CGFloat {
        let a = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold)]).width
        let b = (subtitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return ceil(max(a, b) * 1.1) + 6
    }

    private var accessibilitySummary: String {
        switch (home, exit) {
        case let (h?, e?): return "\(h.city) → \(e.city)"
        case let (h?, nil): return h.city
        case let (nil, e?): return e.city
        default: return ""
        }
    }
}

/// Projection of home/exit into the map view plus the arc geometry.
private struct MapLayout {
    let size: CGSize
    let frame: MapFrame
    let homePt: CGPoint?
    let exitPt: CGPoint?
    let control: CGPoint?
    let key: String
    /// Vertical shift between the (taller) projection frame and the visible canvas.
    let dy: CGFloat

    var hasRoute: Bool { homePt != nil && exitPt != nil }

    init(size: CGSize, home: GeoPoint?, exit: GeoPoint?, lift: Bool = false) {
        self.size = size
        let pts = [home, exit].compactMap { $0 }
        // The projection frame is taller than the canvas so the markers sit off-centre: a lone You marker
        // moves up (the empty state's card covers the middle), a route moves down a little so banners
        // at the top of the map don't cover the exit label.
        let off: CGFloat = pts.count == 1 ? (lift ? -size.height * 0.25 : 0) : 16
        let shift = abs(off)
        dy = off < 0 ? 2 * shift : 0
        // One point on its own (empty state, unknown exit) gets a wider, regional view.
        let f = MapFrame(points: pts.isEmpty ? [GeoPoint(lat: 42, lon: 15)] : pts,
                         size: CGSize(width: size.width, height: size.height + 2 * shift),
                         paddingFraction: 0.6, minSpanLon: 40)
        let up = dy
        frame = f
        homePt = home.map { p in let q = f.project(p); return CGPoint(x: q.x, y: q.y - up) }
        exitPt = exit.map { p in let q = f.project(p); return CGPoint(x: q.x, y: q.y - up) }
        key = "\(Int(size.width))x\(Int(size.height))|\(lift)|\(String(describing: home))|\(String(describing: exit))"
        if let h = homePt, let e = exitPt {
            let dx = e.x - h.x, dy = e.y - h.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            var nx = -dy / len, ny = dx / len
            if ny > 0 || (ny == 0 && nx < 0) { nx = -nx; ny = -ny }      // lift toward the top
            let lift = 0.22 * len
            control = CGPoint(x: (h.x + e.x) / 2 + nx * lift, y: (h.y + e.y) / 2 + ny * lift)
        } else {
            control = nil
        }
    }

    var arcPath: Path? {
        guard let h = homePt, let e = exitPt, let c = control else { return nil }
        var p = Path()
        p.move(to: h)
        p.addQuadCurve(to: e, control: c)
        return p
    }

    func point(at t: Double) -> CGPoint {
        guard let h = homePt, let e = exitPt, let c = control else { return .zero }
        let u = 1 - t
        return CGPoint(x: u * u * h.x + 2 * u * t * c.x + t * t * e.x,
                       y: u * u * h.y + 2 * u * t * c.y + t * t * e.y)
    }
}
