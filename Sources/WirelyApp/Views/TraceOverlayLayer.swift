import SwiftUI
import WirelyCore

/// What route mode draws on top of the map: the stations of a trace and which one is selected.
struct TraceOverlay: Equatable {
    var stations: [TraceStation]
    var selected: Int?
    var running: Bool
    /// What the user typed (or the resolved host); the target station's sub-line.
    var targetName: String = ""
}

/// Legs, markers, labels, legend and detail chip of a route trace. Static: no per-frame work.
struct TraceOverlayLayer: View {
    let trace: TraceOverlay
    let frame: MapFrame
    let size: CGSize

    @EnvironmentObject private var l10n: L10n

    private static let bend: CGFloat = 0.10
    private static let chipSize = CGSize(width: 196, height: 88)
    private static let legendSize = CGSize(width: 262, height: 58)

    private var points: [CGPoint] { trace.stations.map { frame.project($0.point) } }
    private var showsLegend: Bool {
        let legs = Set(trace.stations.dropFirst().map(\.leg))
        return legs.contains(.tunnel) && legs.contains(.open)
    }
    private var legendRect: CGRect {
        CGRect(x: size.width - 16 - Self.legendSize.width, y: 16,
               width: Self.legendSize.width, height: Self.legendSize.height)
    }

    var body: some View {
        let pts = points
        let labels = placeLabels(pts)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in draw(ctx, pts) }
            ForEach(Array(trace.stations.enumerated()), id: \.offset) { i, st in
                label(st, anchor: pts[i], rect: labels[i])
            }
            if let sel = trace.selected, trace.stations.indices.contains(sel) {
                chip(trace.stations[sel], rect: LabelPlacer.placeChip(
                    anchor: pts[sel], size: Self.chipSize, allAnchors: pts, bounds: bounds,
                    obstacles: labels + (showsLegend ? [legendRect] : []) + legBoxes(pts)))
            }
            if showsLegend { legend.offset(x: legendRect.minX, y: legendRect.minY) }
        }
        .allowsHitTesting(false)
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6) }

    // MARK: Drawing

    private func legColor(_ leg: TraceLegKind) -> Color { leg == .tunnel ? Theme.cobalt : Theme.secondary }

    private func segment(_ a: CGPoint, _ b: CGPoint) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let control = CGPoint(x: (a.x + b.x) / 2 + dy * Self.bend, y: (a.y + b.y) / 2 - dx * Self.bend)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: control)
        return p
    }

    /// Small boxes along every leg, so labels and the chip keep off the lines where they can.
    private func legBoxes(_ pts: [CGPoint]) -> [CGRect] {
        var out: [CGRect] = []
        for i in pts.indices.dropFirst() {
            let a = pts[i - 1], b = pts[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let c = CGPoint(x: (a.x + b.x) / 2 + dy * Self.bend, y: (a.y + b.y) / 2 - dx * Self.bend)
            for k in 1..<12 {
                let t = CGFloat(k) / 12, u = 1 - t
                let x = u * u * a.x + 2 * u * t * c.x + t * t * b.x
                let y = u * u * a.y + 2 * u * t * c.y + t * t * b.y
                out.append(CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
            }
        }
        return out
    }

    private func draw(_ ctx: GraphicsContext, _ pts: [CGPoint]) {
        let st = trace.stations
        guard st.count > 1 else { drawMarkers(ctx, pts); return }
        // Open legs first so a cobalt leg and its glow stay on top where they meet.
        for pass in [false, true] {
            for i in 1..<st.count where (st[i].leg == .tunnel) == pass {
                let path = segment(pts[i - 1], pts[i])
                if pass {
                    ctx.stroke(path, with: .color(Theme.cobalt.opacity(0.2)),
                               style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    ctx.stroke(path, with: .color(Theme.cobalt), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                } else {
                    ctx.stroke(path, with: .color(Theme.secondary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        drawMarkers(ctx, pts)
    }

    private func drawMarkers(_ ctx: GraphicsContext, _ pts: [CGPoint]) {
        func dot(_ c: CGPoint, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        for (i, s) in trace.stations.enumerated() {
            let c = pts[i]
            if i == trace.selected { ctx.fill(dot(c, 14), with: .color(Theme.signal.opacity(0.28))) }
            switch s.kind {
            case .home:
                ctx.fill(dot(c, 5.5), with: .color(Theme.ink))
            case .hop:
                ctx.fill(dot(c, 4.5), with: .color(Theme.ground))
                ctx.stroke(dot(c, 3.5), with: .color(legColor(s.leg)), lineWidth: 2)
            case .vpn:
                ctx.fill(dot(c, 12), with: .color(Theme.cobalt.opacity(0.22)))
                ctx.fill(dot(c, 6.5), with: .color(Theme.cobalt))
            case .target, .lastAnswer:
                ctx.fill(dot(c, 6), with: .color(Theme.ink))
            }
        }
    }

    // MARK: Labels

    private func subtitle(_ s: TraceStation) -> String? {
        switch s.kind {
        case .home: return l10n(.you)
        case .vpn: return l10n(.traceVPNServer)
        case .target, .lastAnswer: return trace.targetName.isEmpty ? nil : trace.targetName
        case .hop: return nil
        }
    }

    private func placeLabels(_ pts: [CGPoint]) -> [CGRect] {
        let sizes = trace.stations.map { LabelPlacer.estimate(title: $0.city, subtitle: subtitle($0)) }
        return LabelPlacer.place(anchors: pts, sizes: sizes, bounds: bounds,
                                 avoid: (showsLegend ? [legendRect] : []) + legBoxes(pts))
    }

    private func label(_ s: TraceStation, anchor: CGPoint, rect: CGRect) -> some View {
        let align: HorizontalAlignment = abs(rect.midX - anchor.x) < 1 ? .center : rect.midX > anchor.x ? .leading : .trailing
        let frameAlign: Alignment = align == .center ? .center : align == .leading ? .leading : .trailing
        return VStack(alignment: align, spacing: 1) {
            Text(s.city).font(.mr(14, 800)).foregroundStyle(s.kind == .vpn ? Theme.cobalt : Theme.ink)
            if let sub = subtitle(s) { Text(sub).font(.mr(12, 600)).foregroundStyle(Theme.secondary) }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: rect.width, height: rect.height, alignment: frameAlign)
        .offset(x: rect.minX, y: rect.minY)
    }

    // MARK: Chip and legend

    private func countryName(_ code: String?) -> String? {
        guard let code else { return nil }
        return Locale(identifier: l10n.locale.identifier).localizedString(forRegionCode: code)
    }

    private func chip(_ s: TraceStation, rect: CGRect) -> some View {
        var title = (s.kind == .hop ? "≈ " : "") + s.city
        if let c = countryName(s.countryCode) { title += ", " + c }
        let line1: String?
        switch s.kind {
        case .home: line1 = s.hopCount > 0 ? l10n.format(.traceStopsHere, s.hopCount) : nil
        case .vpn: line1 = [l10n(.traceVPNServer), s.address].compactMap { $0 }.joined(separator: ", ")
        case .target, .lastAnswer: line1 = [trace.targetName, s.address ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        case .hop: line1 = s.address
        }
        var line2: String?
        var jump = false
        if let ms = s.rttMs {
            if let j = s.jumpMs { line2 = l10n.format(.traceJump, Int(ms.rounded()), Int(j.rounded())); jump = true }
            else { line2 = "\(Int(ms.rounded())) ms" }
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.mr(13.5, 800)).foregroundStyle(Theme.ink)
            if let line1, !line1.isEmpty { Text(line1).font(.mr(12, 600)).foregroundStyle(Theme.secondary) }
            if let line2 {
                Text(line2).font(.mr(12, 700)).foregroundStyle(jump ? Theme.signal : Theme.chipIdleText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if s.kind == .lastAnswer {
                Text(l10n(.traceTargetSilent)).font(.mr(11, 600)).foregroundStyle(Theme.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(width: rect.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .offset(x: rect.minX, y: rect.minY)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(Theme.cobalt, glow: true, l10n(.traceEncryptedLeg))
            legendRow(Theme.secondary, glow: false, l10n(.traceOpenLeg))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: Self.legendSize.width, height: Self.legendSize.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func legendRow(_ color: Color, glow: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(color).frame(width: 18, height: glow ? 3 : 2)
            Text(text).font(.mr(12, 600)).foregroundStyle(Theme.ink).lineLimit(1)
        }
    }
}
