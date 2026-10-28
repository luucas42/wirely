import SwiftUI
import WirelyCore

/// The capsule row on top: one chip per profile plus "Import".
struct ProfileChips: View {
    let tunnels: [StoredTunnel]
    let selection: String?
    let status: TunnelStatus
    let onSelect: (String) -> Void
    let onImport: () -> Void
    let onEdit: (StoredTunnel) -> Void
    let onRename: (StoredTunnel) -> Void
    let onDelete: (StoredTunnel) -> Void

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        GeometryReader { geo in
            if previewMode {
                row.frame(width: geo.size.width, height: geo.size.height)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    row.frame(minWidth: geo.size.width).frame(height: geo.size.height)
                }
            }
        }
        .frame(height: 58)
    }

    private var row: some View {
        HStack(spacing: 8) {
            ForEach(tunnels) { t in chip(t) }
            importChip
        }
        .padding(.horizontal, 2)
    }

    private func dotColor(for t: StoredTunnel, selected: Bool) -> Color? {
        guard status.tunnelName == t.name else { return nil }
        switch status.state {
        case .disconnected: return nil
        case .connected: return selected ? Theme.onCobalt : Theme.cobalt
        case .connecting: return Theme.signal
        case .failed: return Theme.coral
        }
    }

    private func chip(_ t: StoredTunnel) -> some View {
        let selected = t.name == selection
        return HStack(spacing: 7) {
            if let c = dotColor(for: t, selected: selected) {
                Circle().fill(c).frame(width: 6, height: 6)
            }
            Text(t.name).lineLimit(1)
        }
        .font(.mr(13, selected ? 700 : 600))
        .foregroundStyle(selected ? Theme.onCobalt : Theme.chipIdleText)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(selected ? Theme.cobaltFill : Theme.chipIdle))
        .contentShape(Capsule())
        .onTapGesture { onSelect(t.name) }
        .contextMenu {
            Button(l10n(.edit) + "…") { onEdit(t) }
            Button(l10n(.rename) + "…") { onRename(t) }
            Button(l10n(.delete) + "…", role: .destructive) { onDelete(t) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var importChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 10.5, weight: .heavy))
            Text(l10n(.importAction))
        }
        .font(.mr(13, 600))
        .foregroundStyle(Theme.chipIdleText)
        .padding(.horizontal, 13).padding(.vertical, 6)
        .background(Capsule().strokeBorder(Theme.chipOutline, lineWidth: 1.5))
        .contentShape(Capsule())
        .onTapGesture(perform: onImport)
        .accessibilityAddTraits(.isButton)
    }
}
