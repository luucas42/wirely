import AppKit
import ServiceManagement

/// Launch-at-login registration for the app bundle, via `SMAppService`.
enum LoginItem {
    enum Status { case enabled, requiresApproval, disabled, unavailable }

    /// Login items only work for a bundled `.app` (not `swift run` builds).
    private static var isBundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static var status: Status {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .disabled
        }
    }

    static func set(_ on: Bool) throws {
        guard isBundled else { return }
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether this launch was started by the login-items mechanism. The Apple event is
    /// only available during launch, so this is evaluated once, early, in the app delegate.
    static let launchedAtLogin: Bool = {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }()
}
