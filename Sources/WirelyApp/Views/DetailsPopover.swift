import SwiftUI
import WirelyCore

/// Address, DNS, routes, MTU, key and handshake of the selected profile.
struct DetailsPopover: View {
    let config: TunnelConfig
    let handshake: Date?
    let connected: Bool
    let now: Date

    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(.address, config.interface.addresses.map(\.description).joined(separator: ", "), mono: true)
            row(.dns, config.interface.dnsServers.isEmpty
                ? "—" : config.interface.dnsServers.map(\.description).joined(separator: ", "), mono: true)
            row(.routes, config.routesAllTraffic
                ? l10n(.allTraffic) : config.peers.flatMap(\.allowedIPs).map(\.description).joined(separator: ", "),
                mono: !config.routesAllTraffic)
            row(.mtu, config.interface.mtu.map(String.init) ?? l10n(.mtuAuto))
            row(.publicKey, config.interfacePublicKey.base64EncodedString(), mono: true, truncate: true)
            if connected {
                row(.lastHandshake, Formatters.ago(handshake, now: now, l10n: l10n))
            }
            if !config.ignoredKeys.isEmpty {
                Text(l10n(.ignoredKeysNote))
                    .font(.mr(11.5, 500)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func row(_ key: L, _ value: String, mono: Bool = false, truncate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(l10n(key)).font(.mr(11.5, 600)).foregroundStyle(Theme.secondary)
            Text(value)
                .font(mono ? .system(size: 12.5, design: .monospaced) : .mr(13.5, 600))
                .foregroundStyle(Theme.ink)
                .lineLimit(truncate ? 1 : 3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
