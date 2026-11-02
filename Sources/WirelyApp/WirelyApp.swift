import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `WirelyApp` once the store exists, so Finder "open with" can import.
    @MainActor static var store: TunnelStore?
    /// Set by `WirelyApp`; started at launch so reconnect and connect-on-launch work with no window.
    @MainActor static var controller: ConnectionController?
    /// Set by `WirelyApp`; checked at launch and hourly (never while rendering previews).
    @MainActor static var updates: UpdateChecker?
    private var updateTimer: Timer?

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppFonts.register()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = PreviewRenderer.requestedDirectory() {
            PreviewRenderer.run(into: dir)
            NSApp.terminate(nil)
            return
        }
        AppDelegate.controller?.start()
        if let updates = AppDelegate.updates {
            Task { await updates.checkIfDue() }
            updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task { @MainActor in await updates.checkIfDue() }
            }
        }
        // Evaluated here so the launch Apple event is still current; starts menu-bar only.
        if LoginItem.launchedAtLogin {
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.identifier?.rawValue == "main" }.forEach { $0.close() }
            }
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
    @StateObject private var trace: TraceModel
    @StateObject private var l10n = L10n.shared
    @StateObject private var router = AppRouter()
    @StateObject private var updates: UpdateChecker

    public init() {
        let s = TunnelStore()
        let c = ConnectionController()
        _store = StateObject(wrappedValue: s)
        _controller = StateObject(wrappedValue: c)
        let r = RouteModel(store: s, controller: c)
        c.exitCity = { [weak r] in MainActor.assumeIsolated { r?.exit?.city } }
        c.tunnelNamed = { [weak s] name in MainActor.assumeIsolated { s?.tunnels.first { $0.name == name } } }
        _route = StateObject(wrappedValue: r)
        let locator = ExitLocator(http: URLSessionHTTPFetcher())
        let t = TraceModel(
            trace: { [weak c] target in
                guard let c else { return .failure(TraceFailure(code: nil, message: L10n.shared(.genericError))) }
                return await c.trace(target)
            },
            locate: { await locator.location(for: $0) },
            context: { [weak r, weak c] in
                MainActor.assumeIsolated {
                    (home: r?.home, vpn: r?.exit, endpointHost: TraceModel.endpointHost(c?.status.endpoint),
                     connected: c?.status.state == .connected, latencyMs: r?.latencyMs)
                }
            })
        _trace = StateObject(wrappedValue: t)
        let current = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            ?? AppVersion("0.0.0")!
        let u = UpdateChecker(current: current)
        let notifier = Notifier()
        u.onNewRelease = { notifier.postUpdate($0, l10n: .shared) }
        _updates = StateObject(wrappedValue: u)
        AppDelegate.store = s
        AppDelegate.controller = c
        AppDelegate.updates = u
    }

    public var body: some Scene {
        Window("Wirely", id: "main") {
            MainView(store: store, controller: controller, route: route)
                .frame(minWidth: 820, minHeight: 560)
                .environmentObject(l10n)
                .environmentObject(router)
                .environmentObject(updates)
                .environmentObject(trace)
                .onAppear { controller.start() }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommandButton(router: router)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 920, height: 600)

        MenuBarExtra {
            MenuBarView(store: store, controller: controller, route: route)
                .environmentObject(l10n)
                .environmentObject(router)
                .environmentObject(updates)
                .onAppear { controller.start() }
        } label: {
            Image(nsImage: MenuBarIcon.image(connected: controller.status.state == .connected))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The app menu's "Settings…" item (⌘,): opens the main window on the Settings page.
private struct SettingsCommandButton: View {
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.shared(.settingsEllipsis)) {
            openWindow(id: "main")
            router.openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
