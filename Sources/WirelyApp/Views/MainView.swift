import SwiftUI
import UniformTypeIdentifiers
import WirelyCore

/// The Route Map window: profile chips, the map, banners and the status card.
struct MainView: View {
    @ObservedObject var store: TunnelStore
    @ObservedObject var controller: ConnectionController
    @ObservedObject var route: RouteModel

    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var trace: TraceModel
    @EnvironmentObject private var devices: DeviceScanner
    @Environment(\.previewMode) private var previewMode
    @AppStorage(KillSwitchSettings.allowLANKey) private var allowLAN = true
    /// Previews decide whether the kill switch blocks the local network; nil reads the real setting.
    var lanBlockedOverride: Bool?
    @State private var importing = false
    @State private var editing: StoredTunnel?
    @State private var renaming: StoredTunnel?
    @State private var deleting: StoredTunnel?
    @State private var importErrors: [String] = []
    @State private var showImportErrors = false
    @State private var exportError: String?
    @State private var notesRelease: ReleaseInfo?
    @State private var escMonitor: Any?

    private var selected: StoredTunnel? { route.selected }

    var body: some View {
        Group {
            if router.showingSettings {
                SettingsPage(store: store, controller: controller,
                             actions: ProfileActions(onImport: { importing = true },
                                                     onEdit: { editing = $0 },
                                                     onRename: { renaming = $0 },
                                                     onDelete: { deleting = $0 },
                                                     onExport: export))
            } else {
                mapPage
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .background { if !previewMode { WindowDragArea() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { handleImport(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in handleImport([url]) }
                }
            }
            return true
        }
        .confirmationDialog(l10n.format(.deleteConfirm, deleting?.name ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { t in
            Button(l10n(.delete), role: .destructive) { delete(t) }
            Button(l10n(.cancel), role: .cancel) {}
        }
        .sheet(item: $editing) { t in
            EditConfigSheet(name: t.name, text: t.text, onSave: { text in
                try store.update(name: t.name, text: text)
                editing = nil
            }, onCancel: { editing = nil })
                .environmentObject(l10n)
        }
        .sheet(item: $renaming) { t in
            RenameSheet(name: t.name, onSave: { newName in
                let before = Set(store.tunnels.map(\.name))
                try store.rename(t.name, to: newName)
                if route.selectedName == t.name,
                   let renamed = store.tunnels.map(\.name).first(where: { !before.contains($0) }) {
                    route.selectedName = renamed
                }
                renaming = nil
            }, onCancel: { renaming = nil })
                .environmentObject(l10n)
        }
        .sheet(item: $notesRelease) { r in
            ReleaseNotesSheet(release: r)
                .environmentObject(l10n)
        }
        .alert(l10n(.importFailed), isPresented: $showImportErrors) {
            Button(l10n(.done)) {}
        } message: {
            Text(importErrors.joined(separator: "\n"))
        }
        .alert(l10n(.genericError), isPresented: Binding(get: { exportError != nil },
                                                        set: { if !$0 { exportError = nil } })) {
            Button(l10n(.done)) {}
        } message: {
            Text(exportError ?? "")
        }
        .onAppear {
            ensureSelection(preferConnected: true)
            if router.mode == .devices, !previewMode { devices.devicesOpened() }
        }
        .onChange(of: router.mode) { mode in
            guard mode == .devices else { return }
            if trace.active { trace.close() }
            if !previewMode { devices.devicesOpened() }
        }
        .onChange(of: store.tunnels) { _ in ensureSelection(preferConnected: false) }
        .onChange(of: controller.status.state) { _ in ensureSelection(preferConnected: true) }
        .onChange(of: route.selectedName) { _ in if trace.active { trace.close() } }
        .onChange(of: router.showingSettings) { showing in if showing, trace.active { trace.close() } }
        .onChange(of: trace.active) { active in
            if active { installEscMonitor() } else { removeEscMonitor() }
        }
        .onDisappear(perform: removeEscMonitor)
    }

    // MARK: Esc

    /// Esc leaves route mode. Same key-monitor approach as the Settings page; only one of the two is ever active
    /// because opening Settings closes route mode. A sheet or dialog gets the key first.
    private func installEscMonitor() {
        guard !previewMode, escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [trace] event in
            guard event.keyCode == 53, trace.active,
                  event.window?.attachedSheet == nil, event.window?.sheetParent == nil else { return event }
            trace.close()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    private static let importTypes: [UTType] =
        [UTType(filenameExtension: "conf") ?? .data, .zip]

    // MARK: Map page

    private var mapPage: some View {
        VStack(spacing: 0) {
            header
            switch router.mode {
            case .tunnel: tunnelBody
            case .devices:
                DevicesView(lanBlocked: lanBlockedOverride ?? (controller.status.killSwitch == true && !allowLAN),
                            onOpenConnectionSettings: { router.openSettings(.connection) })
            }
        }
    }

    /// Mode switch after the traffic lights, the profile chips or the network pill in the middle, the gear.
    private var header: some View {
        HStack(spacing: 0) {
            ModeSwitch(selection: $router.mode)
                .padding(.leading, 80)
            Group {
                switch router.mode {
                case .tunnel:
                    ProfileChips(tunnels: store.tunnels, selection: route.selectedName, status: controller.status,
                                 onSelect: { route.selectedName = $0 },
                                 onImport: { importing = true },
                                 onEdit: { editing = $0 },
                                 onRename: { renaming = $0 },
                                 onDelete: { deleting = $0 })
                case .devices:
                    NetworkPill(network: devices.network, scanning: devices.phase == .scanning)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            IconButton(symbol: "gearshape", label: l10n(.settings)) { router.openSettings() }
                .padding(.trailing, 18)
        }
        .frame(height: 58)
    }

    @ViewBuilder
    private var tunnelBody: some View {
        mapArea
            .padding(.horizontal, 40)
            .frame(maxHeight: .infinity)

        if trace.active {
            RouteStripCard(trace: trace, fallbackTitle: route.exit?.city ?? selected?.name ?? "")
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 4)
        } else if let t = selected {
            StatusCard(tunnel: t, controller: controller, route: route, onEdit: { editing = t })
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 4)
        }
    }

    // MARK: Map area

    private var mapArea: some View {
        ZStack(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                RouteMapView(home: route.home, exit: selected == nil ? nil : route.exit, exitIP: route.exitIP,
                             phase: RouteModel.phase(of: selected, status: controller.status, now: ctx.date),
                             lifted: store.tunnels.isEmpty, trace: traceOverlay)
                    .equatable()
            }
            if trace.active { TraceTargetPill(trace: trace).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            if store.tunnels.isEmpty { emptyCard }
            VStack(spacing: 8) { banners }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// What route mode draws over the map; nil in normal mode.
    private var traceOverlay: TraceOverlay? {
        guard trace.active else { return nil }
        let typed = trace.target.trimmingCharacters(in: .whitespaces)
        return TraceOverlay(stations: trace.stations, selected: trace.selected, running: trace.phase == .running,
                            targetName: typed, avoid: [TraceTargetPill.rect])
    }

    @ViewBuilder
    private var banners: some View {
        switch controller.helperState {
        case .ready: EmptyView()
        case .checking:
            BannerView(icon: .spinner, text: l10n(.serviceStarting))
        case .notInstalled:
            BannerView(text: l10n(.serviceExplain), actionTitle: l10n(.installService),
                       action: { Task { await controller.installHelper() } })
        case .outdated(let v):
            if v > HelperConstants.helperVersion {
                BannerView(icon: .warning, text: l10n(.serviceNewerApp))
            } else {
                BannerView(text: l10n(.serviceUpdateNeeded), actionTitle: l10n(.update),
                           action: { Task { await controller.installHelper() } })
            }
        }
        if let release = updates.bannerRelease {
            BannerView(text: l10n.format(.updateAvailableTitle, release.version.description),
                       actionTitle: l10n(.whatsNew), action: { notesRelease = release },
                       onClose: { updates.dismissBanner() })
        }
        if let msg = controller.lastError {
            BannerView(icon: .warning, text: msg, onClose: { controller.lastError = nil })
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Text(l10n(.importProfile)).font(.mr(20, 800)).tracking(-0.3).foregroundStyle(Theme.ink)
            Text(l10n(.dropHere)).font(.mr(13.5, 500)).foregroundStyle(Theme.secondary)
            PillButton(size: 14, action: { importing = true }) { Text(l10n(.chooseFile)) }
                .padding(.top, 12)
        }
        .padding(.horizontal, 36).padding(.vertical, 26)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 4)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.top, 70)
    }

    // MARK: Actions

    private func ensureSelection(preferConnected: Bool) {
        let names = store.tunnels.map(\.name)
        if preferConnected, let active = controller.status.tunnelName, controller.status.state == .connected,
           names.contains(active) {
            route.selectedName = active
        } else if route.selectedName == nil || !names.contains(route.selectedName ?? "") {
            route.selectedName = names.first
        }
    }

    private func handleImport(_ urls: [URL]) {
        let before = Set(store.tunnels.map(\.name))
        let errors = store.importFiles(urls)
        if let added = store.tunnels.first(where: { !before.contains($0.name) }) { route.selectedName = added.name }
        if !errors.isEmpty {
            importErrors = errors
            showImportErrors = true
        }
    }

    private func export(_ t: StoredTunnel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(t.name).conf"
        panel.allowedContentTypes = [UTType(filenameExtension: "conf")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(t.name, to: url) } catch { exportError = l10n.message(for: error) }
    }

    private func delete(_ t: StoredTunnel) {
        Task {
            if controller.isOn(t) { await controller.disconnect() }
            store.delete(t.name)
        }
    }
}

/// Single-field sheet for renaming a profile.
struct RenameSheet: View {
    @State private var text: String
    @State private var saveError: String?
    let onSave: (String) throws -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var l10n: L10n

    init(name: String, onSave: @escaping (String) throws -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: name)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n(.renameTitle)).font(.mr(16, 700))
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let saveError { Text(saveError).font(.mr(12, 500)).foregroundStyle(Theme.coral) }
            HStack {
                Spacer()
                Button(l10n(.cancel), action: onCancel).keyboardShortcut(.cancelAction)
                Button(l10n(.save), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.cobalt)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func save() {
        do { try onSave(text) } catch { saveError = l10n.message(for: error) }
    }
}
