import SwiftUI

/// Every device, one row each.
struct DeviceList: View {
    let devices: [LANDevice]
    let selected: MACAddress?
    var showNoOthers = false
    var onSelect: (MACAddress) -> Void = { _ in }
    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        Group {
            if previewMode {
                GeometryReader { geo in
                    rows.frame(width: geo.size.width, height: geo.size.height, alignment: .top).clipped()
                }
            } else {
                ScrollView { rows }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(devices) { d in row(d) }
            if showNoOthers {
                Text(l10n(.devNoOthers)).font(.mr(12, 600)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 10)
            }
        }
    }

    private func row(_ d: LANDevice) -> some View {
        let sel = d.mac == selected
        return HStack(spacing: 10) {
            Image(systemName: d.kind.symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(d.iconColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(d.name).font(.mr(13, 800)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                Text("\(d.vendorText(l10n)), \(d.ip)").font(.mr(11.5, 600)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let b = deviceBadge(d, l10n) { Text(b.text).font(.mr(11, 800)).foregroundStyle(b.color) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(sel ? Theme.chipIdle : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onSelect(d.mac) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
    }
}
