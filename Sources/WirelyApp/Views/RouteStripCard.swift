import SwiftUI
import WirelyCore

/// Bottom card of route mode: the trace summary, a metro-style strip of stations and the refresh / close buttons.
struct RouteStripCard: View {
    @ObservedObject var trace: TraceModel
    /// Title when the target field is empty: the VPN server's city.
    let fallbackTitle: String

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    private static let summaryWidth: CGFloat = 196
    private static let idealSpacing: CGFloat = 88
    private static let minSpacing: CGFloat = 56

    private var running: Bool { trace.phase == .running }

    var body: some View {
        HStack(spacing: 20) {
            summary.frame(width: Self.summaryWidth, alignment: .leading)
            strip.frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                RoundIconButton(symbol: "arrow.clockwise", label: l10n(.traceAgain)) { Task { await trace.run() } }
                    .disabled(running)
                RoundIconButton(symbol: "xmark", label: l10n(.traceClose)) { trace.close() }
            }
        }
        .padding(.leading, 28).padding(.trailing, 22)
        .frame(maxWidth: .infinity)
        .frame(height: 136)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .shadow(color: Theme.hairline, radius: 0, x: 0, y: 1)
    }

    // MARK: Summary

    private var title: String {
        let t = trace.target.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? fallbackTitle : t
    }

    private var summaryLine: String {
        let cities = Set(trace.stations.map(\.city)).count
        // No total (the target never answered): leave the milliseconds out instead of printing a bogus number.
        guard let ms = trace.totalMs else {
            return String(format: l10n(.traceSummary).replacingOccurrences(of: "%d ms", with: "—"),
                          locale: l10n.locale, trace.hopCount, cities)
        }
        return l10n.format(.traceSummary, trace.hopCount, cities, ms)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.mr(26, 800))
                .tracking(-0.5)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            switch trace.phase {
            case .running:
                HStack(spacing: 8) {
                    AppSpinner().foregroundStyle(Theme.cobalt)
                    Text(l10n(.traceRunning)).font(.mr(13.5, 500)).foregroundStyle(Theme.secondary)
                }
            case .failed(let message):
                Text(message).font(.mr(13.5, 500)).foregroundStyle(Theme.coral).lineLimit(3)
            case .done:
                Text(summaryLine).font(.mr(13.5, 500)).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
                if !trace.reached {
                    Text(l10n(.traceTargetSilent)).font(.mr(12, 500)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: Strip

    private static let nameH: CGFloat = 16
    private static let dotRowH: CGFloat = 18
    private static let msH: CGFloat = 15
    private static let gap: CGFloat = 6
    private static let pillH: CGFloat = 20
    /// Every row has a fixed height, so all dots (and the line through them) share one y.
    private static let lineY = nameH + gap + dotRowH / 2
    private static let msY = nameH + gap + dotRowH + gap
    private static let stripH = msY + msH + gap + pillH

    @ViewBuilder
    private var strip: some View {
        if trace.phase == .done, !trace.stations.isEmpty {
            GeometryReader { geo in
                let n = CGFloat(trace.stations.count)
                let spacing = min(120, max(Self.minSpacing, geo.size.width / n))
                let content = stripContent(spacing: spacing)
                    .frame(width: spacing * n, height: Self.stripH)
                if spacing * n > geo.size.width + 0.5 && !previewMode {
                    ScrollView(.horizontal, showsIndicators: false) { content }
                        .frame(height: geo.size.height)
                } else {
                    content.frame(width: geo.size.width, height: geo.size.height)
                }
            }
        } else {
            Color.clear
        }
    }

    private func stripContent(spacing: CGFloat) -> some View {
        let stations = trace.stations
        return ZStack(alignment: .topLeading) {
            // One continuous line behind the stations: cobalt 3 pt inside the tunnel, secondary 2 pt outside.
            ForEach(Array(stations.enumerated()).dropFirst(), id: \.offset) { i, st in
                let h: CGFloat = st.leg == .tunnel ? 3 : 2
                Rectangle()
                    .fill(st.leg == .tunnel ? Theme.cobalt : Theme.secondary)
                    .frame(width: spacing, height: h)
                    .offset(x: (CGFloat(i) - 0.5) * spacing, y: Self.lineY - h / 2)
            }
            HStack(spacing: 0) {
                ForEach(Array(stations.enumerated()), id: \.offset) { _, st in
                    station(st, spacing: spacing)
                }
            }
            // Centered under the midpoint between the jump station and the one before it.
            if let i = stations.firstIndex(where: { $0.jumpMs != nil }), i > 0, let j = stations[i].jumpMs {
                jumpPill(j)
                    .frame(width: spacing * 2)
                    .offset(x: CGFloat(i - 1) * spacing, y: Self.msY + Self.msH + Self.gap)
            }
        }
    }

    private func name(_ st: TraceStation) -> String { (st.locationNearPrevious ? "≈ " : "") + st.city }

    private func station(_ st: TraceStation, spacing: CGFloat) -> some View {
        let selected = trace.selected == st.id
        let ms = st.rttMs.map { "\(Int($0.rounded())) ms" } ?? "—"
        let face = VStack(spacing: Self.gap) {
            Text(name(st))
                .font(.mr(12.5, 800))
                .foregroundStyle(selected ? Theme.ink : Theme.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: spacing - 6, height: Self.nameH)
            dot(st, selected: selected).frame(height: Self.dotRowH)
            Text(ms)
                .font(.mr(12, 600))
                .foregroundStyle(st.jumpMs != nil ? Theme.signal : Theme.secondary)
                .monospacedDigit().lineLimit(1)
                .frame(height: Self.msH)
            Color.clear.frame(height: Self.pillH)
        }
        .frame(width: spacing, height: Self.stripH, alignment: .top)
        .contentShape(Rectangle())
        return Group {
            if previewMode {
                face
            } else {
                Button { trace.selected = st.id } label: { face }.buttonStyle(.plain).help(name(st))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name(st)), \(ms)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func dot(_ st: TraceStation, selected: Bool) -> some View {
        if selected {
            Circle().fill(Theme.signal).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Theme.signal.opacity(0.35), lineWidth: 2).padding(-4))
        } else {
            let color: Color = st.kind == .vpn ? Theme.cobalt : (st.kind == .hop ? Theme.card : Theme.ink)
            Circle().fill(color).frame(width: 10, height: 10)
                .overlay { if st.kind == .hop { Circle().strokeBorder(st.leg == .tunnel ? Theme.cobalt : Theme.secondary, lineWidth: 2) } }
        }
    }

    private func jumpPill(_ ms: Double) -> some View {
        Text("+\(Int(ms.rounded())) ms")
            .font(.mr(11.5, 800))
            .foregroundStyle(Theme.signal)
            .monospacedDigit().lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Theme.signal.opacity(0.16)))
    }
}

/// 38 pt round symbol button on the route card (preview-safe: a plain view in `previewMode`).
private struct RoundIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.previewMode) private var previewMode
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if previewMode {
            face
        } else {
            Button(action: action) { face }.buttonStyle(.plain)
        }
    }

    private var face: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.chipIdleText)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Theme.chipIdle))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}
