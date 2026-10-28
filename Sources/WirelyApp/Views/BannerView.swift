import SwiftUI

/// Card-style notice at the top of the map: service setup or the last error.
struct BannerView: View {
    enum Icon { case info, warning, spinner }

    var icon: Icon = .info
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onClose: (() -> Void)?

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        HStack(spacing: 12) {
            switch icon {
            case .info:
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18)).foregroundStyle(Theme.cobalt)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(Theme.coral)
            case .spinner:
                AppSpinner().foregroundStyle(Theme.secondary)
            }
            Text(text)
                .font(.mr(13, 600))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                PillButton(size: 12.5, action: action) { Text(actionTitle) }
            }
            if let onClose {
                Group {
                    if previewMode {
                        closeGlyph
                    } else {
                        Button(action: onClose) { closeGlyph }.buttonStyle(.plain)
                    }
                }
                .accessibilityLabel(l10n(.close))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 640)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var closeGlyph: some View {
        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
            .frame(width: 22, height: 22).contentShape(Rectangle())
    }
}
