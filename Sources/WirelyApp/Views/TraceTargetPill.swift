import SwiftUI

/// Floating pill at the map's top-left in route mode: magnifier, target field and the Trace button.
struct TraceTargetPill: View {
    @ObservedObject var trace: TraceModel

    @EnvironmentObject private var l10n: L10n
    @Environment(\.previewMode) private var previewMode

    static let inset: CGFloat = 12
    static let size = CGSize(width: 270, height: 40)
    /// Where the pill sits in map coordinates; the label placer keeps off it.
    static let rect = CGRect(x: inset, y: inset, width: size.width, height: size.height)

    private var running: Bool { trace.phase == .running }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            field
            PillButton(size: 12.5, action: run) { Text(l10n(.traceRun)).lineLimit(1) }
                .disabled(running)
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(Self.inset)
    }

    @ViewBuilder
    private var field: some View {
        if previewMode {
            let empty = trace.target.isEmpty
            Text(empty ? l10n(.traceTarget) : trace.target)
                .font(.mr(13.5, 600))
                .foregroundStyle(empty ? Theme.secondary : Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(l10n(.traceTarget), text: $trace.target)
                .textFieldStyle(.plain)
                .font(.mr(13.5, 600))
                .foregroundStyle(Theme.ink)
                .disabled(running)
                .onSubmit(run)
        }
    }

    private func run() {
        guard !running else { return }
        Task { await trace.run() }
    }
}
