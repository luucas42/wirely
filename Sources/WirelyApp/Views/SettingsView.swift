import SwiftUI
import AppKit
import WirelyCore

struct SettingsView: View {
    @ObservedObject var controller: ConnectionController
    @EnvironmentObject private var l10n: L10n
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var working = false
    @State private var message: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        TabView {
            general.tabItem { Label(l10n(.general), systemImage: "gearshape") }
            service.tabItem { Label(l10n(.service), systemImage: "shield.lefthalf.filled") }
            about.tabItem { Label(l10n(.about), systemImage: "info.circle") }
        }
        .frame(width: 440, height: 230)
    }

    private var general: some View {
        Form {
            Picker(l10n(.language), selection: $l10n.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle(l10n(.notifications), isOn: $notificationsEnabled)
        }
        .formStyle(.grouped)
    }

    private var service: some View {
        Form {
            LabeledContent(l10n(.serviceStatus)) { Text(stateText) }
            HStack {
                Button(l10n(.uninstallService)) { uninstall() }
                    .disabled(working || controller.helperState == .notInstalled)
                Button(l10n(.openLog)) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: HelperConstants.logPath))
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 6) {
            Text("Wirely").font(.mr(22, 800))
            Text("\(l10n(.version)) \(version)").font(.mr(13, 600)).foregroundStyle(.secondary)
            Text(l10n(.credits)).font(.mr(12, 500)).foregroundStyle(.secondary).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stateText: String {
        switch controller.helperState {
        case .ready: return l10n(.serviceReady)
        case .notInstalled: return l10n(.serviceNotInstalled)
        case .outdated: return l10n(.serviceOutdatedState)
        case .checking: return l10n(.serviceChecking)
        }
    }

    private func uninstall() {
        working = true
        message = nil
        Task {
            do {
                try await Task.detached { try HelperInstaller.uninstall() }.value
            } catch {
                message = l10n.message(for: error)
            }
            await controller.checkHelper()
            working = false
        }
    }
}
