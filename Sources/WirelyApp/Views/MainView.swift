import SwiftUI
import UniformTypeIdentifiers
import WirelyCore

/// The Route Map window: profile chips, the map, banners and the status card.
struct MainView: View {
    @ObservedObject var store: TunnelStore
    @ObservedObject var controller: ConnectionController
    @ObservedObject var route: RouteModel

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @State private var importing = false
    @State private var editing: StoredTunnel?
    @State private var renaming: StoredTunnel?
    @State private var deleting: StoredTunnel?
    @State private var importErrors: [String] = []
    @State private var showImportErrors = false

    private var selected: StoredTunnel? { route.selected }

    var body: some View {
        VStack(spacing: 0) {
            ProfileChips(tunnels: store.tunnels, selection: route.selectedName, status: controller.status,
                         onSelect: { route.selectedName = $0 },
                         onImport: { importing = true },
                         onEdit: { editing = $0 },
                         onRename: { renaming = $0 },
                         onDelete: { deleting = $0 })
                .padding(.horizontal, 80)

            mapArea
                .padding(.horizontal, 40)
                .frame(maxHeight: .infinity)

            if let t = selected {
                StatusCard(tunnel: t, controller: controller, route: route, onEdit: { editing = t })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, 4)
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
        .alert(l10n(.importFailed), isPresented: $showImportErrors) {
            Button(l10n(.done)) {}
        } message: {
            Text(importErrors.joined(separator: "\n"))
        }
        .onAppear { ensureSelection(preferConnected: true) }
        .onChange(of: store.tunnels) { _ in ensureSelection(preferConnected: false) }
        .onChange(of: controller.status.state) { _ in ensureSelection(preferConnected: true) }
    }

    private static let importTypes: [UTType] =
        [UTType(filenameExtension: "conf") ?? .data, .zip]

    // MARK: Map area

    private var mapArea: some View {
        ZStack(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                RouteMapView(home: route.home, exit: selected == nil ? nil : route.exit, exitIP: route.exitIP,
                             phase: RouteModel.phase(of: selected, status: controller.status, now: ctx.date),
                             lifted: store.tunnels.isEmpty)
                    .equatable()
            }
            if store.tunnels.isEmpty { emptyCard }
            VStack(spacing: 8) { banners }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .top)
        }
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
