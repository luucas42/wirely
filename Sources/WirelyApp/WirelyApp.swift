import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `WirelyApp` once the store exists, so Finder "open with" can import.
    @MainActor static var store: TunnelStore?

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppFonts.register()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = PreviewRenderer.requestedDirectory() {
            PreviewRenderer.run(into: dir)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        let confs = urls.filter { ["conf", "zip"].contains($0.pathExtension.lowercased()) }
        guard !confs.isEmpty, let store = AppDelegate.store else { return }
        let errors = store.importFiles(confs)
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.shared(.importFailed)
            alert.informativeText = errors.joined(separator: "\n")
            alert.runModal()
        }
    }
}

public struct WirelyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: TunnelStore
    @StateObject private var controller: ConnectionController
    @StateObject private var route: RouteModel
    @StateObject private var l10n = L10n.shared

    public init() {
        let s = TunnelStore()
        let c = ConnectionController()
        _store = StateObject(wrappedValue: s)
        _controller = StateObject(wrappedValue: c)
        let r = RouteModel(store: s, controller: c)
        c.exitCity = { [weak r] in MainActor.assumeIsolated { r?.exit?.city } }
        _route = StateObject(wrappedValue: r)
        AppDelegate.store = s
    }

    public var body: some Scene {
        Window("Wirely", id: "main") {
            MainView(store: store, controller: controller, route: route)
                .frame(minWidth: 820, minHeight: 560)
                .environmentObject(l10n)
                .onAppear { controller.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 920, height: 600)

        MenuBarExtra {
            MenuBarView(store: store, controller: controller, route: route)
                .environmentObject(l10n)
                .onAppear { controller.start() }
        } label: {
            Image(nsImage: MenuBarIcon.image(connected: controller.status.state == .connected))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
                .environmentObject(l10n)
        }
    }
}
