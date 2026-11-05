import SwiftUI
import WirelyCore

/// Bottom card: state, subline, four metrics and the primary button.
struct StatusCard: View {
    let tunnel: StoredTunnel
    @ObservedObject var controller: ConnectionController
    @ObservedObject var route: RouteModel
    let onEdit: () -> Void
    /// The split panel is open beside the card: no stats, buttons rearranged for the narrower width.
    var compact = false

    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var trace: TraceModel
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

        // Blocked by the kill switch: every stat is "—", so give the space to the explanation and actions.
        let reconnecting = controller.reconnectStatus?.name == tunnel.name
        let blocked = status.isBlockedByKillSwitch || reconnecting
        return Group {
            if compact {
                compactBody(phase: phase, status: status, now: now, blocked: blocked)
            } else {
                HStack(spacing: 20) {
                    titleBlock(phase: phase, status: status, now: now, pill: true)
                        .frame(width: blocked ? nil : 270, alignment: .leading)
                        .frame(maxWidth: blocked ? .infinity : nil, alignment: .leading)
                    if !blocked { statsBlock(stats) }
                    trailing(phase: phase, status: status, now: now)
                }
            }
        }
        .padding(.horizontal, compact ? 20 : 28)
        .frame(maxWidth: .infinity)
        .frame(height: 136)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .shadow(color: Theme.hairline, radius: 0, x: 0, y: 1)
    }

    // MARK: Pieces

    private func title(for phase: RoutePhase) -> String {
        if isReconnecting { return l10n(.reconnecting) }
        switch phase {
        case .connected: return l10n(.connected)
        case .connecting: return l10n(.connecting)
        case .noResponse: return l10n(.noResponse)
        case .failed: return controller.status.isBlockedByKillSwitch ? l10n(.internetBlocked) : l10n(.failed)
        case .idle, .invalid: return l10n(.notConnected)
        }
    }

    private var isReconnecting: Bool { controller.reconnectStatus?.name == tunnel.name }

    /// The split pill needs a profile that can connect and a running service.
    private var showsSplitPill: Bool { tunnel.config != nil && controller.helperState == .ready }

    private var splitPill: some View {
        SplitPill(tunnel: tunnel, store: controller.splitStore, open: router.splitPanel) {
            router.splitPanel.toggle()
        }
    }

    /// Narrow layout beside the split panel: title and primary button, then the pill and the small buttons.
    @ViewBuilder
    private func compactBody(phase: RoutePhase, status: TunnelStatus, now: Date, blocked: Bool) -> some View {
        if blocked {
            VStack(alignment: .leading, spacing: 10) {
                titleBlock(phase: phase, status: status, now: now, pill: false)
                HStack { Spacer(minLength: 0); primaryButton(phase: phase) }
            }
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    titleBlock(phase: phase, status: status, now: now, pill: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    primaryButton(phase: phase)
                }
                HStack(spacing: 6) {
                    if showsSplitPill { splitPill }
                    Spacer(minLength: 0)
                    routeButton(phase: phase)
                    if let config = tunnel.config { infoButton(config, status: status, now: now) }
                }
            }
        }
    }

    private func titleBlock(phase: RoutePhase, status: TunnelStatus, now: Date, pill: Bool) -> some View {
        let (sub, isAlert) = isReconnecting ? (reconnectLine(now: now), false) : subline(phase: phase, status: status, now: now)
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
            if pill, showsSplitPill { splitPill.padding(.top, 4) }
        }
    }

    private func reconnectLine(now: Date) -> String {
        guard let at = controller.reconnectStatus?.nextAt, at > now else { return l10n(.connecting) }
        let seconds = Int(at.timeIntervalSince(now).rounded(.up))
        return l10n.format(.reconnectingIn, l10n.format(.secondsShort, seconds))
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
        case .failed:
            if status.isBlockedByKillSwitch {
                let mode = controller.splitStore.settings(for: tunnel.name).mode
                return (l10n(mode == .selected ? .splitBlockedHint : mode == .excluded ? .splitBlockedExcluded : .internetBlockedHint), true)
            }
            return (status.message ?? controller.lastError ?? l10n(.genericError), true)
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
            routeButton(phase: phase)
            if let config = tunnel.config { infoButton(config, status: status, now: now) }
            primaryButton(phase: phase)
        }
    }

    /// Opens route mode; needs a connected or idle tunnel and a running helper (the trace goes through it).
    private func routeButton(phase: RoutePhase) -> some View {
        IconButton(symbol: "point.topleft.down.curvedto.point.bottomright.up", label: l10n(.traceRoute)) { trace.open() }
            .disabled(!(phase == .connected || phase == .idle) || controller.helperState != .ready)
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
        } else if isReconnecting {
            HStack(spacing: 10) {
                if controller.status.isBlockedByKillSwitch {
                    PillButton(kind: .outline, action: { Task { await controller.disconnect() } }) {
                        Text(l10n(.allowInternet)).lineLimit(1).fixedSize()
                    }
                } else {
                    PillButton(kind: .outline, action: { controller.cancelReconnect() }) {
                        Text(l10n(.stop)).lineLimit(1).fixedSize()
                    }
                }
                PillButton(action: { controller.reconnectNow() }) {
                    Text(l10n(.tryNow)).lineLimit(1).fixedSize()
                }
                .disabled(!ready)
            }
        } else if phase == .failed && controller.status.isBlockedByKillSwitch {
            HStack(spacing: 10) {
                PillButton(kind: .outline, action: { Task { await controller.disconnect() } }) {
                    Text(l10n(.allowInternet)).lineLimit(1).fixedSize()
                }
                PillButton(action: { Task { await controller.connect(tunnel) } }) {
                    Text(l10n(.reconnect)).lineLimit(1).fixedSize()
                }
                .disabled(!ready)
            }
        } else if phase == .connected || phase == .noResponse {
            PillButton(kind: .outline, action: { Task { await controller.disconnect() } }) {
                Text(l10n(.disconnect)).lineLimit(1).fixedSize()
            }
        } else {
            PillButton(action: { Task { await controller.connect(tunnel) } }) { Text(l10n(.connect)).lineLimit(1).fixedSize() }
                .disabled(!ready)
        }
    }
}
