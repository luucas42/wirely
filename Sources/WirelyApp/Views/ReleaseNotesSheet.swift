import SwiftUI
import AppKit

extension ReleaseInfo: Identifiable {
    var id: String { tag }
}

/// Sheet with a release's notes, rendered from GitHub markdown as simple blocks.
struct ReleaseNotesSheet: View {
    let release: ReleaseInfo
    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var downloader: UpdateDownloader
    @Environment(\.previewMode) private var previewMode
    @Environment(\.dismiss) private var dismiss

    private var blocks: [ReleaseNotes.Block] { ReleaseNotes.blocks(release.notes, language: l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                if previewMode {
                    notes
                } else {
                    ScrollView { notes }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
                .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 520, height: 560)
        .background(Theme.card)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l10n.format(.updateAvailableTitle, release.version.description))
                .font(.mr(18, 800)).foregroundStyle(Theme.ink)
            if let date = release.publishedAt {
                Text(date.formatted(.dateTime.year().month(.abbreviated).day().locale(l10n.locale)))
                    .font(.mr(12.5, 600)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            UpdateDownloadMessage(release: release)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if case .failed = downloader.state(for: release) {
                    OutlinePill(action: { NSWorkspace.shared.open(release.pageURL) }) { Text(l10n(.releasePage)) }
                }
                OutlinePill(action: { dismiss() }) { Text(l10n(.close)) }
                UpdateDownloadButton(release: release)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func view(for block: ReleaseNotes.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(.mr(level <= 2 ? 17 : 15, 800)).foregroundStyle(Theme.ink)
                .padding(.top, 6)
        case .bullet(let text):
            item("•", text)
        case .numbered(let n, let text):
            item("\(n).", text)
        case .paragraph(let text):
            markdown(text)
        case .code(let text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chipIdle))
        }
    }

    private func item(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).font(.mr(13.5, 700)).foregroundStyle(Theme.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            markdown(text)
        }
    }

    /// Inline markdown (bold, code, links); plain text when it doesn't parse.
    private func markdown(_ text: String) -> some View {
        let rendered = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(rendered)
            .font(.mr(13.5, 500))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
