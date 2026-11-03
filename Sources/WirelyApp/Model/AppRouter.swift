import Foundation

/// One entry in the Settings page's left rail.
enum SettingsSection: String, CaseIterable, Identifiable {
    case profiles, connection, general, service, about

    var id: String { rawValue }

    func title(_ l10n: L10n) -> String {
        switch self {
        case .profiles: return l10n(.profiles)
        case .connection: return l10n(.connection)
        case .general: return l10n(.general)
        case .service: return l10n(.service)
        case .about: return l10n(.about)
        }
    }

    /// SF Symbol shown in the rail.
    var symbol: String {
        switch self {
        case .profiles: return "list.bullet"
        case .connection: return "shield"
        case .general: return "slider.horizontal.3"
        case .service: return "server.rack"
        case .about: return "info.circle"
        }
    }
}

/// What the main window is about: the VPN tunnel or the devices on the local network.
enum AppMode: String {
    case tunnel, devices
}

/// Which page the main window shows: the route map or Settings (and which Settings section).
@MainActor
final class AppRouter: ObservableObject {
    static let modeKey = "appMode"

    @Published var showingSettings = false
    @Published var section: SettingsSection = .profiles
    /// Saved in `defaults` when the router was created with one (previews pass nil).
    @Published var mode: AppMode {
        didSet {
            guard mode != oldValue else { return }
            defaults?.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .devices { splitPanel = false }
        }
    }
    /// The split-tunnel side panel on the Tunnel page. Not persisted; exclusive with route mode.
    @Published var splitPanel = false

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        mode = defaults?.string(forKey: Self.modeKey).flatMap(AppMode.init(rawValue:)) ?? .tunnel
    }

    func openSettings(_ section: SettingsSection? = nil) {
        if let section { self.section = section }
        splitPanel = false
        showingSettings = true
    }

    func closeSettings() {
        showingSettings = false
    }
}
