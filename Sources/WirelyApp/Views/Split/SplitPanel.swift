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

    /// Split mode stands out (cobalt, amber when the list is excluded); "All traffic" stays quiet.
    private var active: Bool { store.settings(for: tunnel.name).mode != .all }
    private var excluded: Bool { store.settings(for: tunnel.name).mode == .excluded }

    private var face: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .bold))
            Text(SplitRows.summary(settings: store.settings(for: tunnel.name), l10n: l10n))
                .font(.mr(12.5, 800))
                .lineLimit(1)
        }
        .foregroundStyle(active ? (excluded ? Theme.bypass : Theme.cobalt) : Theme.chipIdleText)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(active
                                    ? (excluded ? (open ? Theme.bypass.opacity(0.26) : Theme.bypassTint) : Theme.cobalt.opacity(open ? 0.26 : 0.16))
                                    : Theme.chipIdle))
        .overlay { if open && !active { Capsule().strokeBorder(Theme.chipOutline, lineWidth: 1) } }
        .fixedSize()
        .contentShape(Capsule())
    }
}

/// The status card's quiet line about the list ("YouTube and Spotify skip the tunnel"); nothing when there is none.
struct SplitStatusLine: View {
    let tunnel: StoredTunnel
    @ObservedObject var store: SplitStore
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        if let line = SplitRows.statusLine(settings: store.settings(for: tunnel.name), l10n: l10n) {
            Text(line)
                .font(.mr(12, 600))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Preview-only stand-ins for the panel's typing and expansion state, which previews cannot drive.
struct SplitPreviewState: Equatable {
    var draft = ""
    /// Row id (`service:youtube`) shown expanded.
    var expanded: String?
}

private struct SplitPreviewKey: EnvironmentKey { static let defaultValue = SplitPreviewState() }

extension EnvironmentValues {
    var splitPreview: SplitPreviewState {
        get { self[SplitPreviewKey.self] }
        set { self[SplitPreviewKey.self] = newValue }
    }
}

/// Button that is only its face in previews (ImageRenderer cannot draw AppKit-backed buttons).
private struct TapFace<Face: View>: View {
    let action: () -> Void
    @ViewBuilder let face: () -> Face
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        if previewMode { face() } else { Button(action: action) { face() }.buttonStyle(.plain) }
    }
}

/// Wraps its children into rows, left to right.
private struct FlowLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + hSpacing
            maxX = max(maxX, x - hSpacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(subviews, width: bounds.width)
        for (sub, p) in zip(subviews, laid.positions) {
            sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// Right-hand panel of the Tunnel page: mode, direction, the list of sites, IPs and service groups, and how it applies.
struct SplitPanel: View {
    let tunnel: StoredTunnel
    @ObservedObject var controller: ConnectionController
    @ObservedObject var store: SplitStore
    let onClose: () -> Void

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @Environment(\.splitPreview) private var preview
    @State private var typed = ""
    @State private var error: String?
    @State private var note: String?
    @State private var expandedRows: Set<String> = []

    private var settings: SplitSettings { store.settings(for: tunnel.name) }
    private var connected: Bool { controller.state(for: tunnel) == .connected }
    private var split: Bool { settings.mode != .all }
    /// The list on screen: the active direction, or the remembered one while the mode is "all".
    private var excluded: Bool { settings.activeMode == .excluded }
    private var accent: Color { excluded ? Theme.bypass : Theme.cobalt }
    private var accentTint: Color { excluded ? Theme.bypassTint : Theme.cobalt.opacity(0.16) }
    private var draft: String { previewMode ? preview.draft : typed }

    private func isExpanded(_ row: SplitRow) -> Bool {
        previewMode ? preview.expanded == row.id : expandedRows.contains(row.id)
    }

    private var rows: [SplitRow] {
        SplitRows.rows(settings: settings, config: tunnel.config,
                       counts: controller.status.tunnelName == tunnel.name && split ? controller.splitCounts : [:],
                       // The dimmed list of "all traffic" shows idle sub-lines: nothing is applied.
                       connected: connected && split, splitDNS: controller.splitDNSActive, l10n: l10n)
    }

    private var hint: L {
        switch settings.mode {
        case .all: return .splitHintAllLists
        case .selected: return .splitHintSelected
        case .excluded: return .splitHintExcluded
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if connected, controller.status.split != nil, controller.splitDNSActive == false {
                BannerView(icon: .warning, text: l10n(.splitBannerDNS))
            }
            SegmentedPills(options: [(SplitMode.all, l10n(.splitModeAll)), (SplitMode.selected, l10n(.splitTopSplit))],
                           selection: Binding(get: { split ? .selected : .all },
                                              set: { top in
                                                  let target = top == .all ? SplitMode.all : settings.lastSplit
                                                  Task { await controller.setSplitMode(target, for: tunnel) }
                                              }),
                           fill: true)
            if split { directionRow }
            Text(l10n(hint))
                .font(.mr(12.5, 600))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            inputRow
            if let group = settings.suggestion(for: draft) { suggestionBar(group) }
            if let error {
                Text(error).font(.mr(12, 700)).foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            } else if let note {
                Text(note).font(.mr(12, 700)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            if settings.suggestion(for: draft) == nil { presets }
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

    // MARK: Direction

    /// "Listed items [use the tunnel | skip the tunnel]"; only while the mode is a split.
    private var directionRow: some View {
        HStack(spacing: 10) {
            Text(l10n(.splitDirLabel))
                .font(.mr(12.5, 700)).foregroundStyle(Theme.chipIdleText)
                .lineLimit(1).fixedSize()
            HStack(spacing: 2) {
                directionOption(.selected, l10n(.splitDirInclude), color: Theme.cobalt)
                directionOption(.excluded, l10n(.splitDirExclude), color: Theme.bypass)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func directionOption(_ mode: SplitMode, _ label: String, color: Color) -> some View {
        let on = settings.activeMode == mode
        let face = Text(label)
            .font(.mr(12.5, 800))
            .foregroundStyle(on ? color : Theme.secondary)
            .lineLimit(1).minimumScaleFactor(0.85)
            .padding(.vertical, 5).padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background { if on { RoundedRectangle(cornerRadius: 8).fill(Theme.chipIdle) } }
            .overlay { if on { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chipOutline, lineWidth: 1) } }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        return TapFace(action: { Task { await controller.setSplitMode(mode, for: tunnel) } }) { face }
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            field
            addButton
        }
    }

    private var placeholder: String { l10n(excluded ? .splitPlaceholderExcluded : .splitPlaceholder) }

    private var field: some View {
        Group {
            if previewMode {
                Text(draft.isEmpty ? placeholder : draft)
                    .font(.mr(13.5, 600))
                    .foregroundStyle(draft.isEmpty ? Theme.secondary.opacity(0.8) : Theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $typed,
                          prompt: Text(placeholder).foregroundColor(Theme.secondary.opacity(0.8)))
                    .textFieldStyle(.plain)
                    .font(.mr(13.5, 600))
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                    .onChange(of: typed) { text in
                        // Typing clears the last message; emptying the field after an add keeps its note.
                        if !text.isEmpty { error = nil; note = nil }
                    }
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
        return TapFace(action: submit) { face }.fixedSize()
    }

    private func submit() {
        let input = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        Task {
            let outcome = await controller.addSplitEntry(input, for: tunnel)
            if let failure = outcome.error {
                error = failure.message(l10n, list: settings.activeMode)
                note = nil
                return
            }
            typed = ""
            error = nil
            note = outcome.note(l10n)
        }
    }

    // MARK: Suggestion and presets

    /// "**YouTube** group: the 9 domains ..." with an "Add group" button, under the input.
    private func suggestionBar(_ group: ServiceGroup) -> some View {
        let sentence = Text(group.name).font(.mr(12, 800)).foregroundColor(Theme.ink)
            + Text(" " + l10n.format(.splitSuggestionTail, group.domains.count)).font(.mr(12, 600)).foregroundColor(Theme.chipIdleText)
        let button = Text(l10n(.splitAddGroup))
            .font(.mr(12, 800)).foregroundStyle(accent).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(accentTint))
            .contentShape(Capsule())
        return HStack(spacing: 10) {
            sentence
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TapFace(action: { toggle(group) }) { button }.fixedSize()
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func toggle(_ group: ServiceGroup) {
        Task {
            switch await controller.toggleGroup(group.id, for: tunnel) {
            case .added:
                if ServiceGroups.suggestion(for: typed)?.id == group.id { typed = "" }
                error = nil; note = nil
            case .removed:
                error = nil; note = nil
            case .failed(let failure):
                error = failure.message(l10n, list: settings.activeMode)
            }
        }
    }

    private var presets: some View {
        FlowLayout(hSpacing: 3, vSpacing: 5) {
            Text(l10n(.splitPresets))
                .font(.mr(11.5, 700)).foregroundStyle(Theme.secondary)
            ForEach(ServiceGroups.all) { group in
                let on = settings.hasGroup(group.id, in: settings.activeMode)
                let face = HStack(spacing: 3) {
                    Image(systemName: on ? "checkmark" : "plus").font(.system(size: 9, weight: .heavy))
                    Text(group.name).font(.mr(11.5, 800)).lineLimit(1)
                }
                .foregroundStyle(on ? accent : Theme.chipIdleText)
                .padding(.leading, 6).padding(.trailing, 7).padding(.vertical, 5)
                .background(Capsule().fill(on ? accentTint : Theme.chipIdle))
                .contentShape(Capsule())
                TapFace(action: { toggle(group) }) { face }
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    // MARK: List

    private var list: some View {
        let content = VStack(spacing: 0) {
            if settings.current.isEmpty {
                Text(l10n(excluded ? .splitEmptyExcluded : .splitEmpty))
                    .font(.mr(12.5, 600)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 26)
            }
            ForEach(rows) { row in
                SplitRowView(row: row, last: row.id == rows.last?.id, excluded: excluded, expanded: isExpanded(row),
                             onToggle: { toggleExpanded(row) }) {
                    if let entry = row.entry {
                        expandedRows.remove(row.id)
                        Task { await controller.removeSplitEntry(entry, for: tunnel) }
                    }
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
        .opacity(split ? 1 : 0.45)
        .layoutPriority(-1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n(excluded ? .splitListLabelExclude : .splitListLabelInclude))
    }

    private func toggleExpanded(_ row: SplitRow) {
        if expandedRows.contains(row.id) { expandedRows.remove(row.id) } else { expandedRows.insert(row.id) }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(l10n(connected ? .splitAppliedReconnects : .splitAppliedOnConnect))
            }
            .font(.mr(11.5, 600))
            if settings.mode == .excluded {
                Text(l10n(.splitExcludeFooter)).font(.mr(11.5, 600)).padding(.leading, 14)
            }
            Text(l10n(.splitBrowserShort)).font(.mr(11, 600)).lineLimit(1).truncationMode(.tail).padding(.top, 2)
                .help(l10n(.splitBrowserNote))
        }
        .foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
    }
}

/// One line of the list: kind icon, value, sub-line, optional warning, the group disclosure and the remove button.
private struct SplitRowView: View {
    let row: SplitRow
    let last: Bool
    let excluded: Bool
    let expanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    @EnvironmentObject private var l10n: L10n

    private var symbol: String {
        switch row.kind {
        case .domain: return "globe"
        case .address: return "server.rack"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .profile: return "lock.shield"
        case .group: return "square.stack.3d.up"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(row.removable ? (excluded ? Theme.bypass : Theme.cobalt) : Theme.secondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(excluded && row.removable ? Theme.bypassTint : Theme.chipIdle))
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
                if row.kind == .group {
                    IconButton(symbol: "chevron.right",
                               label: l10n.format(expanded ? .splitGroupHide : .splitGroupShow, row.value),
                               tint: Theme.secondary, action: onToggle)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .scaleEffect(0.8)
                        .frame(width: 30, height: 30)
                }
                if row.removable {
                    IconButton(symbol: "xmark", label: l10n.format(.splitRemove, row.value), tint: Theme.secondary,
                               action: onRemove)
                        .scaleEffect(0.8)
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 9)
            if row.kind == .group, expanded {
                FlowLayout(hSpacing: 5, vSpacing: 5) {
                    ForEach(row.domains, id: \.self) { domain in
                        Text(domain)
                            .font(.mr(11.5, 700)).foregroundStyle(Theme.chipIdleText)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chipIdle))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 58).padding(.trailing, 12).padding(.bottom, 11)
            }
        }
        .overlay(alignment: .bottom) {
            if !last { Theme.hairline.frame(height: 1).padding(.leading, 12) }
        }
    }
}
