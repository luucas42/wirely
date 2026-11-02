import SwiftUI

/// Settings → General: language, notifications, open at login and connect on launch.
struct GeneralSection: View {
    @EnvironmentObject private var l10n: L10n
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage(AppPreferences.connectOnLaunchKey) private var connectOnLaunch = false
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?

    private var languages: [(value: AppLanguage, label: String)] {
        AppLanguage.allCases.map { (value: $0, label: $0.displayName) }
    }

    private var loginOn: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { on in
                do {
                    try LoginItem.set(on)
                    loginError = nil
                } catch {
                    loginError = l10n.message(for: error)
                }
                loginStatus = LoginItem.status
            })
    }

    private var loginHint: String {
        switch loginStatus {
        case .unavailable: return l10n(.openAtLoginUnavailable)
        case .requiresApproval: return l10n(.loginItemApproval)
        case .enabled, .disabled: return l10n(.openAtLoginHint)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: l10n(.general))
            SettingsGroup {
                SettingRow(title: l10n(.language)) {
                    SegmentedPills(options: languages, selection: $l10n.language)
                }
                ToggleRow(title: l10n(.notifications), hint: l10n(.notificationsHint), isOn: $notifications)
                loginRow
                ToggleRow(title: l10n(.connectOnLaunch),
                          hint: AppPreferences.lastProfile.map { l10n.format(.connectOnLaunchHint, $0) }
                              ?? l10n(.connectOnLaunchHintNone),
                          isOn: $connectOnLaunch)
            }
        }
        .onAppear { loginStatus = LoginItem.status }
    }

    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: l10n(.openAtLogin), hint: loginHint) {
                HStack(spacing: 12) {
                    if loginStatus == .requiresApproval {
                        OutlinePill(action: LoginItem.openSystemSettings) { Text(l10n(.openLoginItems)) }
                    }
                    Toggle(l10n(.openAtLogin), isOn: loginOn)
                        .labelsHidden()
                        .toggleStyle(PillToggleStyle())
                        .accessibilityLabel(l10n(.openAtLogin))
                }
            }
            if let loginError {
                Text(loginError).font(.mr(12.5, 600)).foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }
        }
        .disabled(loginStatus == .unavailable)
        .opacity(loginStatus == .unavailable ? 0.4 : 1)
    }
}
