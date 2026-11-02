import SwiftUI
import AppKit

/// The in-window Settings page: header with Done, a section rail and a content card.
struct SettingsPage: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @State private var escMonitor: Any?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 20) {
                rail
                card
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onAppear(perform: installEscMonitor)
        .onDisappear(perform: removeEscMonitor)
    }

    // MARK: Esc

    /// Esc closes the page. `onExitCommand` needs a focused responder, so a local key monitor is used;
    /// it stays out of the way while a sheet or dialog is up so Esc still dismisses that first.
    private func installEscMonitor() {
        guard !previewMode, escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [router] event in
            guard event.keyCode == 53, router.showingSettings,
                  event.window?.attachedSheet == nil, event.window?.sheetParent == nil else { return event }
            router.closeSettings()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Color.clear.frame(width: 90, height: 1)
            Text(l10n(.settings))
                .font(.mr(15, 800))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
            HStack {
                Spacer(minLength: 0)
                done
            }
            .frame(width: 90)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    @ViewBuilder
    private var done: some View {
        if previewMode {
            doneFace
        } else {
            Button { router.closeSettings() } label: { doneFace }
                .buttonStyle(.plain)
        }
    }

    private var doneFace: some View {
        Text(l10n(.done))
            .font(.mr(13, 700))
            .foregroundStyle(Theme.onCobalt)
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(Capsule().fill(Theme.cobaltFill))
            .contentShape(Capsule())
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases) { s in
                RailButton(symbol: s.symbol, title: s.title(l10n), selected: s == router.section) {
                    router.section = s
                }
            }
            Spacer(minLength: 0)
            Text("Wirely \(version)")
                .font(.mr(12, 600))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
        }
        .padding(.top, 4)
        .frame(width: 188)
    }

    // MARK: Content card

    @ViewBuilder
    private var card: some View {
        Group {
            if previewMode {
                content
            } else {
                ScrollView { content }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
    }

    private var content: some View {
        SectionPlaceholder(section: router.section)
            .padding(.horizontal, 28).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Stand-in for a section's content until the real sections land.
private struct SectionPlaceholder: View {
    let section: SettingsSection
    @EnvironmentObject private var l10n: L10n

    private var line: String {
        switch section {
        case .profiles: return l10n(.dropHere)
        case .connection: return l10n(.killSwitchHint)
        case .general: return l10n(.notifications)
        case .service: return l10n(.serviceExplain)
        case .about: return l10n(.credits)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title(l10n)).font(.mr(22, 800)).foregroundStyle(Theme.ink)
            Text(line).font(.mr(13, 500)).foregroundStyle(Theme.secondary)
        }
    }
}
