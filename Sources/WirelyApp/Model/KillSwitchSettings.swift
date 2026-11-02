import Foundation

/// The kill switch preferences (Settings → General), read when connecting.
enum KillSwitchSettings {
    static let enabledKey = "killSwitch"
    static let allowLANKey = "killSwitchAllowLAN"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var allowLAN: Bool { UserDefaults.standard.object(forKey: allowLANKey) as? Bool ?? true }
}
