import SwiftUI
import AppKit

/// Devices mode body: the radial map on the left, the list and the selected device on the right.
struct DevicesView: View {
    /// The kill switch is on and local network traffic is not allowed through it.
    let lanBlocked: Bool
    var onOpenConnectionSettings: () -> Void = {}

    @EnvironmentObject private var devices: DeviceScanner
    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @State private var renaming: LANDevice?

    private static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    private var router: LANDevice? { devices.devices.first { $0.isRouter } }

    private var detailed: LANDevice? {
        if let s = devices.selected, let d = devices.devices.first(where: { $0.mac == s }) { return d }
        return router ?? devices.devices.first { $0.isThisMac }
    }

    private var offline: String? {
        if case .failed(let message) = devices.phase { return message }
        return nil
    }

    var body: some View {
        HStack(spacing: 16) {
            mapArea
            panel.frame(minWidth: 360, idealWidth: 380, maxWidth: 380)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .sheet(item: $renaming) { d in
            RenameSheet(name: d.name, onSave: { name in
                devices.rename(d.mac, to: name)
                renaming = nil
            }, onCancel: { renaming = nil })
                .environmentObject(l10n)
        }
    }

    // MARK: Map

    private var mapInput: DeviceMapView.Input {
        let others = devices.devices.filter { !$0.isRouter }
        let shown = Array(others.prefix(DeviceMapLayout.maxNodes))
        return DeviceMapView.Input(router: router, routerIP: devices.network?.router, nodes: shown,
                                   hidden: others.count - shown.count, selected: devices.selected,
                                   scanning: devices.phase == .scanning)
    }

    private var mapArea: some View {
        ZStack(alignment: .top) {
            if let message = offline {
                offlineCard(message)
            } else {
                DeviceMapView(input: mapInput, onSelect: { devices.select($0) }).equatable()
            }
            VStack(spacing: 8) {
                if lanBlocked {
                    BannerView(icon: .warning, text: l10n(.devLANBlocked), actionTitle: l10n(.settings),
                               action: onOpenConnectionSettings)
                }
                if devices.permissionDenied {
                    BannerView(icon: .warning, text: l10n(.devPermission), actionTitle: l10n(.devOpenSettings),
                               action: { NSWorkspace.shared.open(Self.privacyURL) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func offlineCard(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text(message).font(.mr(20, 800)).tracking(-0.3).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(l10n(.devOfflineBody)).font(.mr(13.5, 500)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            PillButton(size: 14, action: { Task { await devices.scan() } }) { Text(l10n(.devScanAgain)) }
                .padding(.top, 12)
        }
        .padding(.horizontal, 36).padding(.vertical, 26)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 4)
        .frame(maxWidth: 420, maxHeight: .infinity, alignment: .center)
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 10) {
            panelHeader
            if offline == nil, let d = detailed {
                DeviceDetailCard(device: d, checkingPorts: devices.checkingPorts.contains(d.mac),
                                 canRename: !devices.permissionDenied, now: Date(),
                                 onRename: { renaming = d },
                                 onCheckPorts: { Task { await devices.checkPorts(d.mac) } })
            }
            if offline == nil {
                DeviceList(devices: devices.devices, selected: devices.selected,
                           showNoOthers: devices.phase != .scanning && !devices.devices.isEmpty
                               && !devices.devices.contains { !$0.isRouter && !$0.isThisMac },
                           onSelect: { devices.select($0) })
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        if let message = offline { return message }
        if devices.phase == .scanning, devices.devices.isEmpty { return l10n(.devScanning) }
        return devices.devices.count == 1 ? l10n(.devicesCountOne) : l10n.format(.devicesCount, devices.devices.count)
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.mr(20, 800)).foregroundStyle(Theme.ink).lineLimit(2)
                if offline == nil, let last = devices.lastScan {
                    Text(l10n.format(.lastScanLine, DeviceFormat.relative(last, now: Date(), l10n: l10n)))
                        .font(.mr(12, 600)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
            let scanning = devices.phase == .scanning
            OutlinePill(action: { Task { await devices.scan() } }) {
                HStack(spacing: 6) {
                    if scanning {
                        AppSpinner().scaleEffect(0.8)
                        Text(l10n(.devScanning))
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .heavy))
                        Text(l10n(.devScan))
                    }
                }
            }
            .disabled(scanning)
        }
    }
}
