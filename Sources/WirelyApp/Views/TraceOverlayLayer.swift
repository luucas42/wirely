import SwiftUI
import WirelyCore

/// What route mode draws on top of the map: the stations of a trace and which one is selected.
struct TraceOverlay: Equatable {
    var stations: [TraceStation]
    var selected: Int?
    var running: Bool
    /// What the user typed (or the resolved host); the target station's sub-line.
    var targetName: String = ""
    /// Overlay cards floating over the map (the target pill), in map coordinates; labels keep off them.
    var avoid: [CGRect] = []
}

/// Legs, markers, labels, legend and detail chip of a route trace. Static: no per-frame work.
struct TraceOverlayLayer: View {
    let trace: TraceOverlay
    let frame: MapFrame
    let size: CGSize

    @EnvironmentObject private var l10n: L10n

    private static let bend: CGFloat = 0.10
    private static let chipMaxWidth: CGFloat = 240
    private static let chipPad = CGSize(width: 14, height: 11)
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
        let hidden = hiddenLabels(pts)
        let labels = placeLabels(pts, hidden: hidden)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in draw(ctx, pts) }
            ForEach(Array(trace.stations.enumerated()), id: \.offset) { i, st in
                if hidden.contains(i) == false { label(st, anchor: pts[i], rect: labels[i]) }
            }
            if let sel = trace.selected, trace.stations.indices.contains(sel) {
                let content = chipContent(trace.stations[sel])
                chip(content, rect: LabelPlacer.placeChip(
                    anchor: pts[sel], size: content.size, allAnchors: pts, bounds: bounds,
                    obstacles: labels + trace.avoid + (showsLegend ? [legendRect] : []) + legBoxes(pts)))
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

    /// Stations whose label is skipped: an earlier labelled station with the same city lies within 48 pt
    /// (the route leaves a city and comes back). The home label always stays.
    private func hiddenLabels(_ pts: [CGPoint]) -> Set<Int> {
        var hidden = Set<Int>()
        for i in pts.indices where trace.stations[i].kind != .home {
            let twin = (0..<i).contains { j in
                !hidden.contains(j) && trace.stations[j].city == trace.stations[i].city
                    && hypot(pts[j].x - pts[i].x, pts[j].y - pts[i].y) < 48
            }
            if twin { hidden.insert(i) }
        }
        return hidden
    }

    private func placeLabels(_ pts: [CGPoint], hidden: Set<Int>) -> [CGRect] {
        let sizes = trace.stations.enumerated().map { i, s in
            hidden.contains(i) ? CGSize.zero : LabelPlacer.estimate(title: s.city, subtitle: subtitle(s))
        }
        return LabelPlacer.place(anchors: pts, sizes: sizes, bounds: bounds,
                                 avoid: trace.avoid + (showsLegend ? [legendRect] : []) + legBoxes(pts))
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

    private struct ChipLine: Identifiable {
        enum Style { case title, detail, jump, ms, note }
        let id: Int
        let text: String
        let style: Style
        var size: CGFloat {
            switch style { case .title: return 13.5; case .detail, .ms, .jump: return 12; case .note: return 11 }
        }
    }

    private struct ChipContent {
        var lines: [ChipLine]
        var size: CGSize
    }

    /// The chip's text lines and an estimated size: lines wrap (never truncate), so the height follows the wrapped count.
    private func chipContent(_ s: TraceStation) -> ChipContent {
        var texts: [(String, ChipLine.Style)] = []
        var title = (s.kind == .hop ? "≈ " : "") + s.city
        if let c = countryName(s.countryCode) { title += ", " + c }
        texts.append((title, .title))
        switch s.kind {
        case .home: if s.hopCount > 0 { texts.append((l10n.format(.traceStopsHere, s.hopCount), .detail)) }
        case .vpn:
            texts.append((l10n(.traceVPNServer), .detail))
            if let a = s.address { texts.append((a, .detail)) }
        case .target, .lastAnswer:
            if !trace.targetName.isEmpty { texts.append((trace.targetName, .detail)) }
            if let a = s.address { texts.append((a, .detail)) }
        case .hop: if let a = s.address { texts.append((a, .detail)) }
        }
        if let ms = s.rttMs {
            if let j = s.jumpMs { texts.append((l10n.format(.traceJump, Int(ms.rounded()), Int(j.rounded())), .jump)) }
            else { texts.append(("\(Int(ms.rounded())) ms", .ms)) }
        }
        if s.kind == .lastAnswer { texts.append((l10n(.traceTargetSilent), .note)) }
        let lines = texts.enumerated().map { ChipLine(id: $0.offset, text: $0.element.0, style: $0.element.1) }

        func charWidth(_ l: ChipLine) -> CGFloat { l.size * 0.58 }
        let widest = lines.map { CGFloat($0.text.count) * charWidth($0) }.max() ?? 0
        let width = min(Self.chipMaxWidth, max(150, ceil(widest) + 2 * Self.chipPad.width + 4))
        let textWidth = width - 2 * Self.chipPad.width
        var height = 2 * Self.chipPad.height
        for l in lines {
            let perLine = max(1, floor(textWidth / charWidth(l)))
            let count = max(1, ceil(CGFloat(l.text.count) / perLine))
            height += count * (l.size + 5)
        }
        height += CGFloat(max(0, lines.count - 1)) * 3
        return ChipContent(lines: lines, size: CGSize(width: width, height: ceil(height) + 4))
    }

    private func chip(_ c: ChipContent, rect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(c.lines) { l in
                Text(l.text)
                    .font(.mr(l.size, l.style == .title ? 800 : l.style == .note ? 600 : 700))
                    .foregroundStyle(l.style == .title ? Theme.ink : l.style == .jump ? Theme.signal
                                     : l.style == .ms ? Theme.chipIdleText : Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Self.chipPad.width).padding(.vertical, Self.chipPad.height)
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
