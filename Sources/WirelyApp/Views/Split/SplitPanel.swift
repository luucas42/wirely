import SwiftUI
import WirelyCore

/// Summary pill on the status card ("Split, 4 targets"); toggles the split panel.
struct SplitPill: View {
    let tunnel: StoredTunnel
    @ObservedObject var store: SplitStore
    let open: Bool
    let action: () -> Void
    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        if previewMode {
            face
        } else {
            Button(action: action) { face }
                .buttonStyle(.plain)
                .accessibilityAddTraits(open ? .isSelected : [])
        }
    }

    /// Split mode stands out in cobalt; "All traffic" stays quiet.
    private var active: Bool { store.settings(for: tunnel.name).mode == .selected }

    private var face: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .bold))
            Text(SplitRows.summary(settings: store.settings(for: tunnel.name), l10n: l10n))
                .font(.mr(12.5, 800))
                .lineLimit(1)
        }
        .foregroundStyle(active ? Theme.cobalt : Theme.chipIdleText)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(active ? Theme.cobalt.opacity(open ? 0.26 : 0.16) : Theme.chipIdle))
        .overlay { if open && !active { Capsule().strokeBorder(Theme.chipOutline, lineWidth: 1) } }
        .fixedSize()
        .contentShape(Capsule())
    }
}

/// Right-hand panel of the Tunnel page: mode, the list of sites and IPs, and how it applies.
struct SplitPanel: View {
    let tunnel: StoredTunnel
    @ObservedObject var controller: ConnectionController
    @ObservedObject var store: SplitStore
    let onClose: () -> Void

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @State private var draft = ""
    @State private var error: String?

    private var settings: SplitSettings { store.settings(for: tunnel.name) }
    private var connected: Bool { controller.state(for: tunnel) == .connected }
    private var selectedMode: Bool { settings.mode == .selected }

    private var rows: [SplitRow] {
        SplitRows.rows(settings: settings, config: tunnel.config,
                       counts: controller.status.tunnelName == tunnel.name ? controller.splitCounts : [:],
                       connected: connected, splitDNS: controller.splitDNSActive, l10n: l10n)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if connected, controller.status.split != nil, controller.splitDNSActive == false {
                BannerView(icon: .warning, text: l10n(.splitBannerDNS))
            }
            SegmentedPills(options: [(SplitMode.all, l10n(.splitModeAll)), (SplitMode.selected, l10n(.splitModeSelected))],
                           selection: Binding(get: { settings.mode },
                                              set: { mode in Task { await controller.setSplitMode(mode, for: tunnel) } }),
                           fill: true)
            Text(l10n(selectedMode ? .splitHintSelected : .splitHintAll))
                .font(.mr(12.5, 600))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            inputRow
            if let error {
                Text(error).font(.mr(12, 700)).foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            list
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n(.splitTitle)).font(.mr(20, 800)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(l10n.format(.splitProfileLine, tunnel.name))
                    .font(.mr(12, 600)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", label: l10n(.close), action: onClose)
                .background(Circle().fill(Theme.chipIdle))
                .frame(width: 36, height: 36)
        }
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            field
            addButton
        }
    }

    private var field: some View {
        Group {
            if previewMode {
                Text(draft.isEmpty ? l10n(.splitPlaceholder) : draft)
                    .font(.mr(13.5, 600))
                    .foregroundStyle(draft.isEmpty ? Theme.secondary.opacity(0.8) : Theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $draft,
                          prompt: Text(l10n(.splitPlaceholder)).foregroundColor(Theme.secondary.opacity(0.8)))
                    .textFieldStyle(.plain)
                    .font(.mr(13.5, 600))
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                    .onChange(of: draft) { _ in error = nil }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.chipIdle))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var addButton: some View {
        let face = HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 12, weight: .heavy))
            Text(l10n(.splitAddAction)).font(.mr(13, 800)).lineLimit(1)
        }
        .foregroundStyle(Theme.onCobalt)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cobaltFill))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        return Group {
            if previewMode { face } else { Button(action: submit) { face }.buttonStyle(.plain) }
        }
        .fixedSize()
    }

    private func submit() {
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        Task {
            if let failure = await controller.addSplitRule(input, for: tunnel) {
                error = failure.message(l10n)
                return
            }
            draft = ""
            error = nil
            if settings.mode == .all { await controller.setSplitMode(.selected, for: tunnel) }
        }
    }

    // MARK: List

    private var list: some View {
        let content = VStack(spacing: 0) {
            if settings.rules.isEmpty {
                Text(l10n(.splitEmpty))
                    .font(.mr(12.5, 600)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 26)
            }
            ForEach(rows) { row in
                SplitRowView(row: row, last: row.id == rows.last?.id) {
                    if let rule = row.rule { Task { await controller.removeSplitRule(rule, for: tunnel) } }
                }
            }
        }
        .padding(4)
        return Group {
            if previewMode {
                // No scrolling in previews: fill the space that is left and clip.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { content }
                    .clipped()
            } else {
                ScrollView { content }
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
        .opacity(selectedMode ? 1 : 0.45)
        .layoutPriority(-1)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(Theme.cobalt).frame(width: 7, height: 7)
                Text(l10n(connected ? .splitAppliedNow : .splitAppliedOnConnect))
            }
            .font(.mr(11.5, 600))
            if connected {
                Text(l10n(.splitModeReconnects)).font(.mr(11.5, 600)).padding(.leading, 14)
            }
            Text(l10n(.splitBrowserNote)).font(.mr(11, 600)).padding(.top, 2)
        }
        .foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
    }
}

/// One line of the list: kind icon, value, sub-line, optional warning and the remove button.
private struct SplitRowView: View {
    let row: SplitRow
    let last: Bool
    let onRemove: () -> Void
    @EnvironmentObject private var l10n: L10n

    private var symbol: String {
        switch row.kind {
        case .domain: return "globe"
        case .address: return "server.rack"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .profile: return "lock.shield"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.removable ? Theme.cobalt : Theme.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.chipIdle))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.value)
                    .font(.mr(13.5, 800))
                    .foregroundStyle(row.removable ? Theme.ink : Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.subtitle)
                    .font(.mr(11.5, 600)).foregroundStyle(Theme.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let warning = row.warning {
                    Text(warning)
                        .font(.mr(11.5, 700)).foregroundStyle(Theme.coral)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.removable {
                IconButton(symbol: "xmark", label: l10n.format(.splitRemove, row.value), tint: Theme.secondary,
                           action: onRemove)
                    .scaleEffect(0.8)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if !last { Theme.hairline.frame(height: 1).padding(.leading, 12) }
        }
    }
}
