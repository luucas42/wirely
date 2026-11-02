import SwiftUI
import AppKit

/// Settings → About: identity, update check, links and credits.
struct AboutSection: View {
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @State private var notesRelease: ReleaseInfo?

    private static let repoURL = URL(string: "https://github.com/luucas42/wirely")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var icon: NSImage? {
        previewMode ? NSImage(named: NSImage.applicationIconName) : NSApp.applicationIconImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            identity
            SettingsGroup {
                updateRow
                ToggleRow(title: l10n(.checkAutomatically),
                          isOn: Binding(get: { updates.autoCheck }, set: { updates.autoCheck = $0 }))
            }
            HStack(spacing: 10) {
                OutlinePill(action: { open(Self.repoURL.appendingPathComponent("releases")) }) {
                    Text(l10n(.releaseNotes))
                }
                OutlinePill(action: { open(Self.repoURL) }) { Text(l10n(.github)) }
            }
            credits
        }
        .sheet(item: $notesRelease) { r in
            ReleaseNotesSheet(release: r).environmentObject(l10n)
        }
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: 18) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 76, height: 76)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Wirely").font(.mr(24, 800)).foregroundStyle(Theme.ink)
                Text(l10n.format(.currentVersion, version))
                    .font(.mr(13, 600)).foregroundStyle(Theme.secondary).padding(.top, 2)
                Text(l10n(.tagline))
                    .font(.mr(13, 500)).foregroundStyle(Theme.chipIdleText).padding(.top, 6)
            }
        }
    }

    // MARK: Update row

    private var updateRow: some View {
        HStack(spacing: 12) {
            stateLabel
            Spacer(minLength: 12)
            controls
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch updates.state {
        case .idle:
            label(l10n.format(.currentVersion, version), Theme.ink, 700)
        case .checking:
            HStack(spacing: 8) {
                AppSpinner().foregroundStyle(Theme.secondary)
                label(l10n(.checkingForUpdates), Theme.ink, 700)
            }
        case .upToDate:
            label(l10n(.upToDate), Theme.ink, 700)
        case .failed:
            label(l10n(.updateCheckFailed), Theme.coral, 700)
        case .available(let r):
            label(l10n.format(.updateAvailableTitle, r.version.description), Theme.cobalt, 800)
        }
    }

    private func label(_ text: String, _ color: Color, _ weight: CGFloat) -> some View {
        Text(text).font(.mr(14.5, weight)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var controls: some View {
        if case .available(let r) = updates.state {
            HStack(spacing: 10) {
                OutlinePill(action: { notesRelease = r }) { Text(l10n(.whatsNew)) }
                PillButton(size: 13, action: { open(r.dmgURL ?? r.pageURL) }) { Text(l10n(.downloadUpdate)) }
            }
        } else {
            OutlinePill(action: { Task { await updates.checkNow() } }) { Text(l10n(.checkForUpdates)) }
                .disabled(updates.state == .checking)
        }
    }

    // MARK: Credits

    private var credits: some View {
        Text(l10n(.creditsLines))
            .font(.mr(12.5, 500)).foregroundStyle(Theme.secondary)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.chipIdle))
    }

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
