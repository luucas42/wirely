import SwiftUI

/// The radial map: the router in the middle, every other device on a ring around it.
/// Equatable on its input so it only redraws when the data changes.
struct DeviceMapView: View, Equatable {
    struct Input: Equatable {
        var router: LANDevice?
        var routerIP: String?
        /// Devices to draw, already capped; this Mac first.
        var nodes: [LANDevice]
        /// Devices that did not fit on the map.
        var hidden = 0
        var selected: MACAddress?
        var scanning = false
    }

    let input: Input
    var onSelect: (MACAddress) -> Void = { _ in }

    static func == (l: DeviceMapView, r: DeviceMapView) -> Bool { l.input == r.input }

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let points = DeviceMapLayout.positions(count: input.nodes.count, in: size)
            let widths = DeviceMapLayout.labelWidths(count: input.nodes.count, in: size)
            let crowded = DeviceMapLayout.ringSizes(count: input.nodes.count).outer > 0
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ZStack {
                rings(size: size, points: points)
                if input.scanning { sweep(size: size) }
                centerNode(label: DeviceMapLayout.showsCenterLabel(count: input.nodes.count, in: size)).position(center)
                ForEach(Array(input.nodes.enumerated()), id: \.element.mac) { i, d in
                    if i < points.count, hasLabel(d, crowded: crowded) {
                        // 20 pt radius + 9 pt gap (the halo reaches 8) below the centre.
                        label(d, width: crowded ? 96 : widths[i], crowded: crowded)
                            .position(x: points[i].x, y: points[i].y + 29 + Self.labelHeight / 2)
                    }
                }
                ForEach(Array(input.nodes.enumerated()), id: \.element.mac) { i, d in
                    if i < points.count { circle(d).position(points[i]) }
                }
            }
        }
    }

    // MARK: Layers

    private func rings(size: CGSize, points: [CGPoint]) -> some View {
        let nodes = input.nodes
        let selected = input.selected
        return Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let half = DeviceMapLayout.half(in: size)
            let dash = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 9])
            for (i, f) in DeviceMapLayout.decorationRings.enumerated() {
                let r = half * f
                let color = i == DeviceMapLayout.decorationRings.count - 1 ? Theme.hairline : Theme.dot
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), style: dash)
            }
            for (i, p) in points.enumerated() where i < nodes.count && nodes[i].mac != selected {
                var line = Path(); line.move(to: c); line.addLine(to: p)
                ctx.stroke(line, with: .color(Theme.hairline), lineWidth: 1.5)
            }
            if let i = nodes.firstIndex(where: { $0.mac == selected }), i < points.count {
                var line = Path(); line.move(to: c); line.addLine(to: points[i])
                ctx.stroke(line, with: .color(Theme.cobalt), lineWidth: 2)
            }
        }
    }

    /// A 40° wedge, bright at its leading edge, turning once per 2 s. Static in previews.
    @ViewBuilder
    private func sweep(size: CGSize) -> some View {
        if previewMode {
            sweepCanvas(angle: 30)
        } else {
            TimelineView(.animation) { ctx in
                sweepCanvas(angle: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * 180)
            }
        }
    }

    private func sweepCanvas(angle: Double) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = DeviceMapLayout.half(in: size) * 0.98
            var wedge = Path()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: r, startAngle: .degrees(angle - 40), endAngle: .degrees(angle), clockwise: false)
            wedge.closeSubpath()
            let g = Gradient(stops: [.init(color: Theme.cobalt.opacity(0), location: 0),
                                     .init(color: Theme.cobalt.opacity(0.25), location: 40.0 / 360)])
            ctx.fill(wedge, with: .conicGradient(g, center: c, angle: .degrees(angle - 40)))
        }
        .allowsHitTesting(false)
    }

    private func centerNode(label: Bool) -> some View {
        let selected = input.router != nil && input.router?.mac == input.selected
        return ZStack {
            Circle().fill(Theme.cobalt.opacity(selected ? 0.22 : 0.10)).frame(width: 80, height: 80)
            Circle().fill(Theme.chipIdle).frame(width: 58, height: 58)
                .overlay(Circle().strokeBorder(Theme.cobalt, lineWidth: 2))
            Image(systemName: DeviceKind.router.symbol)
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
            if label || input.hidden > 0 { centerCaption(label: label) }
        }
        .frame(width: 110, height: 80)
        .contentShape(Rectangle())
        .onTapGesture { if let r = input.router { onSelect(r.mac) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(l10n(.kindRouter)), \(input.router?.ip ?? input.routerIP ?? "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Router", its address and the "+N" capsule under the centre.
    private func centerCaption(label: Bool) -> some View {
        VStack(spacing: 1) {
            if label {
                Text(l10n(.kindRouter)).font(.mr(12.5, 800)).foregroundStyle(Theme.ink)
                if let ip = input.router?.ip ?? input.routerIP {
                    Text(ip).font(.mr(11, 600)).foregroundStyle(Theme.secondary)
                }
            }
            if input.hidden > 0 {
                Text("+\(input.hidden)").font(.mr(11, 800)).foregroundStyle(Theme.chipIdleText)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.chipIdle))
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ground))
        .frame(width: 110)
        .offset(y: input.hidden > 0 && label ? 62 : 54)
    }

    /// The circle with its icon and halo. Drawn above every label so a long name never covers a neighbour.
    private func circle(_ d: LANDevice) -> some View {
        let sel = d.mac == input.selected
        let accent: Color = d.isNew ? Theme.signal : (d.isThisMac ? Theme.cobalt : Theme.chipOutline)
        let halo: Color = d.isNew ? Theme.signal : Theme.cobalt
        return ZStack {
            if sel || d.isNew { Circle().fill(halo.opacity(0.22)).frame(width: 56, height: 56) }
            Circle().fill(Theme.card).frame(width: 40, height: 40)
            if d.isThisMac { Circle().fill(Theme.cobaltFill.opacity(0.22)).frame(width: 40, height: 40) }
            Circle().strokeBorder(sel ? Theme.cobalt : accent, lineWidth: 2).frame(width: 44, height: 44)
            Image(systemName: d.kind.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(d.iconColor)
        }
        .frame(width: 56, height: 56)
        .contentShape(Circle())
        .onTapGesture { onSelect(d.mac) }
        .help(previewMode ? "" : d.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(d.name), \(d.ip)")
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
    }

    /// One ring: every name, up to two lines. Two rings: only the selected, new and this Mac, one line,
    /// so names never pile onto halos and spokes (the others show their name as a tooltip).
    private func hasLabel(_ d: LANDevice, crowded: Bool) -> Bool {
        !crowded || d.mac == input.selected || d.isNew || d.isThisMac
    }

    private func label(_ d: LANDevice, width: CGFloat, crowded: Bool) -> some View {
        let sel = d.mac == input.selected
        return Text(d.name)
            .font(.mr(12, 800))
            .foregroundStyle(sel ? Theme.ink : Theme.chipIdleText)
            .lineLimit(crowded ? 1 : 2).truncationMode(.tail)
            .multilineTextAlignment(.center)
            .frame(maxWidth: width)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ground))
            .frame(width: 104, height: Self.labelHeight, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(d.mac) }
            .accessibilityHidden(true)
    }

    /// Two lines of 12 pt text.
    private static let labelHeight: CGFloat = 34
}
