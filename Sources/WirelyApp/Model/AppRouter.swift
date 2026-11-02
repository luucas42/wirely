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

/// Which page the main window shows: the route map or Settings (and which Settings section).
@MainActor
final class AppRouter: ObservableObject {
    @Published var showingSettings = false
    @Published var section: SettingsSection = .profiles

    func openSettings(_ section: SettingsSection? = nil) {
        if let section { self.section = section }
        showingSettings = true
    }

    func closeSettings() {
        showingSettings = false
    }
}
