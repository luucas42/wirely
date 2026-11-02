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

    static let notifyNewDevicesKey = "notifyNewDevices"
    static let devicesOpenedKey = "devicesOpened"

    /// Notify (and scan in the background) when an unknown device joins the network. Default on.
    static var notifyNewDevices: Bool {
        get { notifyNewDevices(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: notifyNewDevicesKey) }
    }

    /// Set once the user has opened Devices; background scans never start before that.
    static var devicesOpened: Bool {
        get { devicesOpened(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: devicesOpenedKey) }
    }

    static func notifyNewDevices(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: notifyNewDevicesKey) as? Bool ?? true
    }

    static func devicesOpened(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: devicesOpenedKey) as? Bool ?? false
    }

    /// The profile last connected, used by connect-on-launch.
    static var lastProfile: String? {
        get { UserDefaults.standard.string(forKey: lastProfileKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastProfileKey) }
    }
}
