import SwiftUI
import AppKit
import WirelyCore

/// Settings → Service: helper status, open log, reinstall and uninstall.
struct ServiceSection: View {
    @ObservedObject var controller: ConnectionController
    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode
    @State private var working = false
    @State private var message: String?
    @State private var confirmUninstall = false

    private var notInstalled: Bool { controller.helperState == .notInstalled }

    private var stateText: String {
        switch controller.helperState {
        case .ready: return l10n(.serviceReady)
        case .notInstalled: return l10n(.serviceNotInstalled)
        case .outdated: return l10n(.serviceOutdatedState)
        case .checking: return l10n(.serviceChecking)
        }
    }

    private var dotColor: Color {
        switch controller.helperState {
        case .ready: return Theme.cobalt
        case .checking, .outdated: return Theme.signal
        case .notInstalled: return Theme.coral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: l10n(.backgroundService), hint: l10n(.serviceDescription))
            statusCard
            HStack(spacing: 10) {
                OutlinePill(action: openLog) { Text(l10n(.openLog)) }
                OutlinePill(action: reinstall) { Text(notInstalled ? l10n(.installService) : l10n(.reinstall)) }
                    .disabled(working)
                OutlinePill(destructive: true, action: { confirmUninstall = true }) {
                    Text(l10n(.uninstallService))
                }
                .disabled(working || notInstalled)
                if working && !previewMode { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.mr(12.5, 600)).foregroundStyle(Theme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(l10n(.uninstallConfirm), isPresented: $confirmUninstall) {
            Button(l10n(.uninstallService), role: .destructive, action: uninstall)
            Button(l10n(.cancel), role: .cancel) {}
        }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
                .overlay(Circle().stroke(dotColor.opacity(0.18), lineWidth: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(stateText).font(.mr(15, 800)).foregroundStyle(Theme.ink)
                Text(l10n.format(.serviceVersionLine, HelperConstants.helperVersion))
                    .font(.mr(12.5, 600)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.chipIdle))
    }

    private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: HelperConstants.logPath))
    }

    private func reinstall() {
        working = true
        message = nil
        Task {
            await controller.installHelper()
            working = false
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
