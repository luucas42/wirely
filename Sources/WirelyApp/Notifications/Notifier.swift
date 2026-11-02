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

    /// New devices found by a scan: one notification each, or a single summary when there are more than three.
    func postNewDevices(_ devices: [LANDevice], network: String, l10n: L10n) {
        guard available, enabled, !devices.isEmpty else { return }
        let center = requestAuthorizationIfNeeded()
        if devices.count > 3 {
            let content = UNMutableNotificationContent()
            content.sound = .default
            content.title = l10n.format(.newDevicesTitle, devices.count, network)
            content.body = devices.map { Self.label(for: $0, l10n: l10n) }.prefix(3).joined(separator: ", ") + "…"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } else {
            devices.forEach { postNewDevice($0, network: network, l10n: l10n) }
        }
    }

    /// "New device on home-wifi": body is the device's name (or vendor, or "Unknown device") and address.
    func postNewDevice(_ device: LANDevice, network: String, l10n: L10n) {
        guard available, enabled else { return }
        let center = requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = l10n.format(.newDeviceTitle, network)
        content.body = "\(Self.label(for: device, l10n: l10n)), \(device.ip)"
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func requestAuthorizationIfNeeded() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        return center
    }

    static func label(for device: LANDevice, l10n: L10n) -> String {
        !device.name.isEmpty ? device.name : device.vendor ?? l10n(.unknownDevice)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
