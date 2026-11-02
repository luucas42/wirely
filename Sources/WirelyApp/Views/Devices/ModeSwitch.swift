import SwiftUI

/// Header switch between Tunnel and Devices.
struct ModeSwitch: View {
    @Binding var selection: AppMode
    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    private var options: [(mode: AppMode, symbol: String, label: String)] {
        [(.tunnel, "shield", l10n(.modeTunnel)),
         (.devices, "point.3.connected.trianglepath.dotted", l10n(.modeDevices))]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.mode) { option in
                let selected = option.mode == selection
                if previewMode {
                    face(option.symbol, option.label, selected: selected)
                } else {
                    Button { selection = option.mode } label: { face(option.symbol, option.label, selected: selected) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.ground))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .fixedSize()
    }

    private func face(_ symbol: String, _ label: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .bold))
            Text(label)
        }
        .font(.mr(12.5, 700))
        .foregroundStyle(selected ? Theme.onCobalt : Theme.chipIdleText)
        .padding(.horizontal, 13).padding(.vertical, 5)
        .background { if selected { Capsule().fill(Theme.cobaltFill) } }
        .contentShape(Capsule())
    }
}

/// Header pill in Devices mode: the network's name and subnet.
struct NetworkPill: View {
    let network: NetworkInfo?
    let scanning: Bool
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: network == nil ? "wifi.slash" : (network?.isWiFi == false ? "cable.connector" : "wifi"))
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Theme.cobalt)
            if let network {
                Text(network.name).font(.mr(13, 700)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(network.subnetString).font(.mr(13, 600)).foregroundStyle(Theme.secondary).lineLimit(1)
            } else {
                Text(scanning ? l10n(.devScanning) : l10n(.devicesOffline))
                    .font(.mr(13, 700)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Capsule().fill(Theme.chipIdle))
    }
}
