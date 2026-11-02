import SwiftUI

/// Settings → Connection: kill switch options and automatic reconnect.
struct ConnectionSection: View {
    @ObservedObject var controller: ConnectionController
    @EnvironmentObject private var l10n: L10n
    @AppStorage(KillSwitchSettings.enabledKey) private var killSwitch = true
    @AppStorage(KillSwitchSettings.allowLANKey) private var allowLAN = true
    @AppStorage(AppPreferences.autoReconnectKey) private var autoReconnect = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: l10n(.connection))
            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup {
                    ToggleRow(title: l10n(.killSwitch), hint: l10n(.killSwitchHint), isOn: $killSwitch)
                    ToggleRow(title: l10n(.allowLAN), hint: l10n(.allowLANHint), isOn: $allowLAN)
                        .disabled(!killSwitch)
                }
                Text(l10n(.appliesNextConnect)).font(.mr(12.5, 500)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
            }
            SettingsGroup {
                ToggleRow(title: l10n(.autoReconnect), hint: l10n(.autoReconnectHint), isOn: $autoReconnect)
            }
        }
        .onChange(of: autoReconnect) { on in
            if !on { controller.cancelReconnect() }
        }
    }
}
