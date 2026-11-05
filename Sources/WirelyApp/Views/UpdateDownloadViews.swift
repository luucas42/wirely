import SwiftUI

/// The update "Download" pill; it follows the downloader's state for `release`.
struct UpdateDownloadButton: View {
    let release: ReleaseInfo
    @EnvironmentObject private var downloader: UpdateDownloader
    @EnvironmentObject private var l10n: L10n

    private var state: UpdateDownloader.State { downloader.state(for: release) }

    var body: some View {
        PillButton(size: 13, action: act) { Text(title) }
            .disabled(busy)
    }

    private var busy: Bool {
        switch state {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    private var title: String {
        switch state {
        case .idle: return l10n(.downloadUpdate)
        case .downloading(_, let fraction):
            guard let fraction else { return l10n(.downloadingEllipsis) }
            return l10n.format(.downloadingPercent, Int((fraction * 100).rounded()))
        case .verifying: return l10n(.verifyingDownload)
        case .done: return l10n(.openDownload)
        case .failed: return l10n(.tryAgain)
        }
    }

    private func act() {
        if case .done(_, let file) = state { downloader.open(file) } else { downloader.start(release) }
    }
}

/// One-line hint (finished) or error (failed) under the download button; nothing otherwise.
struct UpdateDownloadMessage: View {
    let release: ReleaseInfo
    @EnvironmentObject private var downloader: UpdateDownloader
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        switch downloader.state(for: release) {
        case .done:
            line(l10n(.downloadHint), Theme.secondary)
        case .failed(_, let failure):
            switch failure {
            case .network: line(l10n(.downloadFailedNetwork), Theme.coral)
            case .checksum: line(l10n(.downloadFailedChecksum), Theme.coral)
            case .save: line(l10n(.downloadFailedSave), Theme.coral)
            }
        default:
            EmptyView()
        }
    }

    private func line(_ text: String, _ color: Color) -> some View {
        Text(text).font(.mr(12.5, 600)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
