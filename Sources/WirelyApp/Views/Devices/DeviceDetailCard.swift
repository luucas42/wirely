import SwiftUI

/// The selected device: kind, name, badges and its facts.
struct DeviceDetailCard: View {
    let device: LANDevice
    let checkingPorts: Bool
    let canRename: Bool
    let now: Date
    var onRename: () -> Void = {}
    var onCheckPorts: () -> Void = {}
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    fact(l10n(.devIP), device.ip)
                    fact(l10n(.devVendor), device.vendorText(l10n))
                }
                GridRow {
                    fact(l10n(.devMAC), device.mac.description)
                    fact(l10n(.devFirstSeen), DeviceFormat.relative(device.firstSeen, now: now, l10n: l10n))
                }
            }
            ports
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12).fill(Theme.chipIdle).frame(width: 40, height: 40)
                .overlay(Image(systemName: device.kind.symbol).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(device.iconColor))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(device.name).font(.mr(16, 800)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    if let b = deviceBadge(device, l10n) { DeviceBadge(text: b.text, color: b.color) }
                }
                Text(subtitle).font(.mr(13, 600)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            if canRename { IconButton(symbol: "pencil", label: l10n(.rename), action: onRename) }
        }
    }

    /// The kind, unless that just repeats the name ("Router" / "Router"): then the vendor.
    private var subtitle: String {
        let kind = device.kind.title(l10n)
        guard kind.caseInsensitiveCompare(device.name) == .orderedSame else { return kind }
        return device.vendor ?? kind
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.mr(12, 700)).foregroundStyle(Theme.secondary)
            Text(value).font(.mr(12, 700)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(l10n(.devOpenPorts)).font(.mr(12, 700)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                if checkingPorts {
                    HStack(spacing: 6) {
                        AppSpinner().foregroundStyle(Theme.secondary).scaleEffect(0.8)
                        Text(l10n(.devChecking)).font(.mr(12, 700)).foregroundStyle(Theme.secondary)
                    }
                } else if let open = device.openPorts {
                    Text(open.isEmpty ? l10n(.devNone) : open.map(String.init).joined(separator: ", "))
                        .font(.mr(12, 700)).foregroundStyle(Theme.ink)
                } else {
                    OutlinePill(action: onCheckPorts) { Text(l10n(.devCheck)) }
                        .font(.mr(12, 700))
                }
            }
            if device.openPorts == nil, !checkingPorts {
                Text(l10n(.devPortsHint)).font(.mr(11, 600)).foregroundStyle(Theme.secondary)
            }
        }
    }
}
