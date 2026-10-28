import SwiftUI
import WirelyCore
import AppKit

/// The menu bar panel: status, one toggle per profile, a slim route line and window shortcuts.
struct MenuBarView: View {
    @ObservedObject var store: TunnelStore
    @ObservedObject var controller: ConnectionController
    @ObservedObject var route: RouteModel
    @EnvironmentObject private var l10n: L10n
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                statusLine(now: ctx.date)
            }
            .padding(.bottom, 10)

            if store.tunnels.isEmpty {
                Text(l10n(.noProfilesYet)).font(.mr(13, 500)).foregroundStyle(Theme.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(store.tunnels) { tunnel in row(tunnel) }

            if let line = routeLine {
                routeView(line)
                    .padding(.top, 8)
            }

            divider
            action(l10n(.openWirely)) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            action(l10n(.settingsEllipsis)) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            action(l10n(.quit)) { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.ground)
    }

    // MARK: Pieces

    private var activeTunnel: StoredTunnel? {
        guard let name = controller.status.tunnelName else { return nil }
        return store.tunnels.first { $0.name == name }
    }

    private func statusLine(now: Date) -> some View {
        let s = controller.status
        let (title, color): (String, Color) = {
            switch RouteModel.phase(of: activeTunnel, status: s, now: now) {
            case .connected: return (l10n(.connected), Theme.cobalt)
            case .connecting: return (l10n(.connecting), Theme.signal)
            case .noResponse: return (l10n(.noResponse), Theme.coral)
            case .failed: return (l10n(.failed), Theme.coral)
            case .idle, .invalid: return (l10n(.notConnected), Theme.secondary.opacity(0.6))
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.mr(15, 800)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            if s.state == .connected, let at = s.connectedAt {
                Text(Formatters.elapsed(from: at, to: now))
                    .font(.mr(13, 600)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
        }
    }

    private func row(_ tunnel: StoredTunnel) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.color(for: controller.state(for: tunnel))).frame(width: 7, height: 7)
            Text(tunnel.name).font(.mr(13.5, 600)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            AppSwitch(isOn: Binding(get: { controller.isOn(tunnel) },
                                    set: { _ in Task { await controller.toggle(tunnel) } }))
                .disabled(tunnel.config == nil || controller.busy || controller.helperState != .ready)
        }
        .frame(height: 28)
    }

    private struct RouteLine { var path: String; var latency: String; var rates: String }

    private var routeLine: RouteLine? {
        guard controller.status.state == .connected, let t = activeTunnel,
              route.selectedName == t.name, let home = route.home, let exit = route.exit else { return nil }
        let r = controller.latestRates
        return RouteLine(path: "\(home.city) → \(exit.city)",
                         latency: Formatters.latency(route.latencyMs),
                         rates: "↓ \(Formatters.rate(r.rx, locale: l10n.locale))   ↑ \(Formatters.rate(r.tx, locale: l10n.locale))")
    }

    private func routeView(_ line: RouteLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(line.path).font(.mr(12.5, 700)).foregroundStyle(Theme.cobalt).lineLimit(1)
                Spacer(minLength: 8)
                Text(line.latency).font(.mr(12.5, 600)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            Capsule().fill(Theme.cobalt).frame(height: 2)
            Text(line.rates).font(.mr(12, 500)).monospacedDigit().foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 10)
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Text(title)
            .font(.mr(13.5, 600))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: perform)
            .accessibilityAddTraits(.isButton)
    }
}
