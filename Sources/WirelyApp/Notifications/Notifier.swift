import Foundation
import UserNotifications

/// Posts connection events as macOS notifications. A no-op unless Wirely runs as a .app
/// (bare binaries in tests and preview renders crash on `UNUserNotificationCenter.current()`)
/// and the Settings toggle is on.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorizationRequested = false

    private var available: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    /// `reconnecting` appends the "retrying automatically" note to drop / block bodies.
    func post(_ e: ConnectionEvent, l10n: L10n, reconnecting: Bool = false) {
        guard available, enabled else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.sound = .default
        switch e {
        case .connected(let name, let city):
            content.title = l10n.format(.notifyConnectedTitle, name)
            if let city { content.body = city }
        case .dropped(let name):
            content.title = l10n(.notifyDroppedTitle)
            content.body = name
            if reconnecting { content.body += " " + l10n(.reconnectingAutomatically) }
        case .noResponse(let name):
            content.title = l10n(.noResponse)
            content.body = "\(name) — \(l10n(.noResponseHint))"
        case .recovered(let name):
            content.title = l10n(.notifyRestoredTitle)
            content.body = name
        case .blocked(let name):
            content.title = l10n(.internetBlocked)
            content.body = "\(name) — \(l10n(.notifyBlockedBody))"
            if reconnecting { content.body += " " + l10n(.reconnectingAutomatically) }
        case .failed(let name, let message):
            content.title = l10n(.notifyFailedTitle)
            content.body = message.isEmpty ? name : "\(name) — \(message)"
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// "Wirely x.y.z is available" — posted once per version by `UpdateChecker.onNewRelease`.
    func postUpdate(_ release: ReleaseInfo, l10n: L10n) {
        guard available, enabled else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = l10n.format(.updateAvailableTitle, release.version.description)
        content.body = l10n(.updateAvailableBody)
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
