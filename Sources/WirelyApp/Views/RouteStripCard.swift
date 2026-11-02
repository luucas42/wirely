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

    @ViewBuilder
    private var strip: some View {
        if trace.phase == .done, !trace.stations.isEmpty {
            GeometryReader { geo in
                let n = CGFloat(trace.stations.count)
                let spacing = max(Self.minSpacing, min(Self.idealSpacing, geo.size.width / n))
                let content = HStack(spacing: 0) {
                    ForEach(Array(trace.stations.enumerated()), id: \.offset) { i, st in
                        station(i, st, spacing: spacing)
                    }
                }
                .frame(height: geo.size.height)
                if spacing * n > geo.size.width + 0.5 && !previewMode {
                    ScrollView(.horizontal, showsIndicators: false) { content }
                } else {
                    content.frame(width: geo.size.width, alignment: .leading)
                }
            }
        } else {
            Color.clear
        }
    }

    private func station(_ i: Int, _ st: TraceStation, spacing: CGFloat) -> some View {
        let selected = trace.selected == st.id
        let stations = trace.stations
        let prevLeg = i > 0 ? st.leg : nil
        let nextLeg = i + 1 < stations.count ? stations[i + 1].leg : nil
        let ms = st.rttMs.map { "\(Int($0.rounded())) ms" } ?? "—"
        let face = VStack(spacing: 6) {
            Text(st.city)
                .font(.mr(12.5, 800))
                .foregroundStyle(selected ? Theme.ink : Theme.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
            ZStack {
                HStack(spacing: 0) {
                    line(prevLeg)
                    line(nextLeg)
                }
                dot(st, selected: selected)
            }
            .frame(height: 18)
            Text(ms)
                .font(.mr(12, 600))
                .foregroundStyle(st.jumpMs != nil ? Theme.signal : Theme.secondary)
                .monospacedDigit().lineLimit(1)
                .padding(.horizontal, 4)
            // Reserved so every column lines up whether or not it carries a pill.
            Color.clear.frame(height: 20)
        }
        .frame(width: spacing)
        .overlay(alignment: .bottomLeading) {
            if let j = st.jumpMs, i > 0 { jumpPill(j).offset(x: -spacing / 2 + 2) }
        }
        .contentShape(Rectangle())
        return Group {
            if previewMode {
                face
            } else {
                Button { trace.selected = st.id } label: { face }.buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(st.city), \(ms)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Half of the line through a station: cobalt 3 pt inside the tunnel, secondary 2 pt outside; empty at the ends.
    @ViewBuilder
    private func line(_ leg: TraceLegKind?) -> some View {
        if let leg {
            Rectangle()
                .fill(leg == .tunnel ? Theme.cobalt : Theme.secondary)
                .frame(height: leg == .tunnel ? 3 : 2)
        } else {
            Color.clear.frame(height: 2)
        }
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
