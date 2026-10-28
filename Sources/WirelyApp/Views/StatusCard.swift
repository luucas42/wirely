import SwiftUI
import WirelyCore

/// Bottom card: state, subline, four metrics and the primary button.
struct StatusCard: View {
    let tunnel: StoredTunnel
    @ObservedObject var controller: ConnectionController
    @ObservedObject var route: RouteModel
    let onEdit: () -> Void

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @State private var showDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(now: ctx.date)
        }
    }

    private func content(now: Date) -> some View {
        let status = controller.status
        let phase = RouteModel.phase(of: tunnel, status: status, now: now)
        let live = phase == .connected || phase == .noResponse
        let rates = controller.latestRates

        let stats: [(L, String)] = [
            (.distance, route.distanceKm.map { Formatters.distance($0, locale: l10n.locale) } ?? "—"),
            (.latency, live ? Formatters.latency(route.latencyMs) : "—"),
            (.download, live ? Formatters.rate(rates.rx, locale: l10n.locale) : "—"),
            (.upload, live ? Formatters.rate(rates.tx, locale: l10n.locale) : "—"),
        ]

        return HStack(spacing: 20) {
            titleBlock(phase: phase, status: status, now: now)
                .frame(width: 270, alignment: .leading)
            statsBlock(stats)
            trailing(phase: phase, status: status, now: now)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .frame(height: 136)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .shadow(color: Theme.hairline, radius: 0, x: 0, y: 1)
    }

    // MARK: Pieces

    private func title(for phase: RoutePhase) -> String {
        switch phase {
        case .connected: return l10n(.connected)
        case .connecting: return l10n(.connecting)
        case .noResponse: return l10n(.noResponse)
        case .failed: return l10n(.failed)
        case .idle, .invalid: return l10n(.notConnected)
        }
    }

    private func titleBlock(phase: RoutePhase, status: TunnelStatus, now: Date) -> some View {
        let (sub, isAlert) = subline(phase: phase, status: status, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title(for: phase))
                .font(.mr(30, 800))
                .tracking(-0.6)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sub)
                .font(.mr(14, 500))
                .foregroundStyle(isAlert ? Theme.coral : Theme.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
        }
    }

    private func subline(phase: RoutePhase, status: TunnelStatus, now: Date) -> (String, Bool) {
        let location = route.exit == nil && phase != .invalid
            ? (route.locating ? l10n(.locatingServer) : l10n(.serverLocationUnknown)) : nil
        func join(_ first: String) -> String { [first, location].compactMap { $0 }.joined(separator: " · ") }
        switch phase {
        case .connected:
            let elapsed = status.connectedAt.map { Formatters.elapsed(from: $0, to: now) } ?? "00:00:00"
            return (join(l10n.format(.connectedFor, elapsed)), false)
        case .noResponse: return (l10n(.noResponseHint), true)
        case .failed: return (status.message ?? controller.lastError ?? l10n(.genericError), true)
        case .invalid: return (configError, true)
        case .connecting, .idle: return (join(tunnel.name), false)
        }
    }

    private var configError: String {
        do { _ = try TunnelConfig.parse(tunnel.text); return l10n(.genericError) }
        catch { return l10n.message(for: error) }
    }

    /// Four equal columns, laid out at a natural width and scaled down together when space is short.
    private func statsBlock(_ stats: [(L, String)]) -> some View {
        let natural: CGFloat = 450
        return GeometryReader { geo in
            let scale = min(1, geo.size.width / natural)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    ForEach(stats.indices, id: \.self) { i in
                        Text(l10n(stats[i].0)).font(.mr(12, 600)).foregroundStyle(Theme.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GridRow {
                    ForEach(stats.indices, id: \.self) { i in
                        Text(stats[i].1).font(.mr(19, 700)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(width: natural, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 50)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func trailing(phase: RoutePhase, status: TunnelStatus, now: Date) -> some View {
        HStack(spacing: 10) {
            if let config = tunnel.config { infoButton(config, status: status, now: now) }
            primaryButton(phase: phase)
        }
    }

    private func infoButton(_ config: TunnelConfig, status: TunnelStatus, now: Date) -> some View {
        let glyph = Image(systemName: "info.circle")
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(Theme.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        return Group {
            if previewMode {
                glyph
            } else {
                Button { showDetails.toggle() } label: { glyph }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDetails, arrowEdge: .top) {
                        DetailsPopover(config: config,
                                       handshake: status.tunnelName == tunnel.name ? status.lastHandshake : nil,
                                       connected: status.tunnelName == tunnel.name && status.state == .connected,
                                       now: now)
                            .environmentObject(l10n)
                    }
            }
        }
        .accessibilityLabel(l10n(.moreInfo))
    }

    @ViewBuilder
    private func primaryButton(phase: RoutePhase) -> some View {
        let working = controller.busy || phase == .connecting
        let ready = controller.helperState == .ready
        if phase == .invalid {
            PillButton(action: onEdit) { Text(l10n(.edit)) }
        } else if working {
            AppSpinner()
                .foregroundStyle(Theme.cobalt)
                .frame(width: 120, height: 46)
                .background(Capsule().fill(Theme.cobalt.opacity(0.14)))
        } else if phase == .connected || phase == .noResponse {
            PillButton(kind: .outline, action: { Task { await controller.disconnect() } }) {
                Text(l10n(.disconnect))
            }
        } else {
            PillButton(action: { Task { await controller.connect(tunnel) } }) { Text(l10n(.connect)) }
                .disabled(!ready)
        }
    }
}
