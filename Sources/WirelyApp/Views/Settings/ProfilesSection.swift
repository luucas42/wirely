import SwiftUI
import WirelyCore

/// Closures the Profiles section calls; the main window owns the sheets and dialogs behind them.
struct ProfileActions {
    var onImport: () -> Void = {}
    var onEdit: (StoredTunnel) -> Void = { _ in }
    var onRename: (StoredTunnel) -> Void = { _ in }
    var onDelete: (StoredTunnel) -> Void = { _ in }
    var onExport: (StoredTunnel) -> Void = { _ in }
}

/// Settings → Profiles: every profile with its status and edit, rename, export and delete actions.
struct ProfilesSection: View {
    @ObservedObject var store: TunnelStore
    @ObservedObject var controller: ConnectionController
    let actions: ProfileActions
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: l10n(.profiles), hint: l10n(.dropHereShort)) {
                if !store.tunnels.isEmpty { importPill }
            }
            if store.tunnels.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(store.tunnels) { t in
                        ProfileRow(tunnel: t, state: controller.state(for: t), actions: actions)
                    }
                }
                Text(l10n(.exportHint)).font(.mr(12.5, 500)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var importPill: some View {
        OutlinePill(action: actions.onImport) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .heavy))
                Text(l10n(.importAction))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text(l10n(.noProfilesYet)).font(.mr(14.5, 700)).foregroundStyle(Theme.secondary)
            importPill
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.chipIdle))
    }
}

/// One profile in the list: status dot, name, endpoint (or the config error) and action buttons.
private struct ProfileRow: View {
    let tunnel: StoredTunnel
    let state: TunnelState
    let actions: ProfileActions
    @EnvironmentObject private var l10n: L10n

    private var dotColor: Color {
        switch state {
        case .connected: return Theme.cobalt
        case .connecting: return Theme.signal
        case .failed: return Theme.coral
        case .disconnected: return Theme.dot
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(tunnel.name).font(.mr(15, 800)).foregroundStyle(Theme.ink).lineLimit(1)
                    if state == .connected {
                        Text(l10n(.connected)).font(.mr(11.5, 700)).foregroundStyle(Theme.cobalt)
                    }
                }
                detail
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(symbol: "pencil", label: "\(l10n(.edit)) \(tunnel.name)") { actions.onEdit(tunnel) }
                IconButton(symbol: "character.cursor.ibeam", label: "\(l10n(.rename)) \(tunnel.name)") {
                    actions.onRename(tunnel)
                }
                IconButton(symbol: "square.and.arrow.up", label: "\(l10n(.exportAction)) \(tunnel.name)") {
                    actions.onExport(tunnel)
                }
                IconButton(symbol: "trash", label: "\(l10n(.delete)) \(tunnel.name)", tint: Theme.coral) {
                    actions.onDelete(tunnel)
                }
            }
        }
        .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.chipIdle))
    }

    /// `host:port` of the first peer; built as a `String` so the port is not locale-grouped.
    private var endpointText: String {
        guard let e = tunnel.config?.peers.first?.endpoint else { return "—" }
        return String(e.host) + ":" + String(e.port)
    }

    @ViewBuilder
    private var detail: some View {
        if let error = tunnel.error, tunnel.config == nil {
            Text(error).font(.mr(12.5, 600)).foregroundStyle(Theme.coral)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(verbatim: endpointText)
                .font(.mr(12.5, 600)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }
}
