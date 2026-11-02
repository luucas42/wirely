import Foundation

/// General preferences (Settings → General) for reconnecting and launch behavior.
enum AppPreferences {
    static let autoReconnectKey = "autoReconnect"
    static let connectOnLaunchKey = "connectOnLaunch"
    static let lastProfileKey = "lastProfile"

    static var autoReconnect: Bool {
        get { UserDefaults.standard.object(forKey: autoReconnectKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoReconnectKey) }
    }

    static var connectOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: connectOnLaunchKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: connectOnLaunchKey) }
    }

    /// The profile last connected, used by connect-on-launch.
    static var lastProfile: String? {
        get { UserDefaults.standard.string(forKey: lastProfileKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastProfileKey) }
    }
}
