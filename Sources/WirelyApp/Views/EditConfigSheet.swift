import SwiftUI
import WirelyCore

struct EditConfigSheet: View {
    let name: String
    @State private var text: String
    @State private var saveError: String?
    let onSave: (String) throws -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var l10n: L10n

    init(name: String, text: String, onSave: @escaping (String) throws -> Void, onCancel: @escaping () -> Void) {
        self.name = name
        _text = State(initialValue: text)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var parseError: String? {
        do { _ = try TunnelConfig.parse(text); return nil } catch { return l10n.message(for: error) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.format(.editConfigTitle, name)).font(.mr(16, 700))
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 520, minHeight: 320)
                .border(Color.secondary.opacity(0.3))
            Text(saveError ?? parseError ?? " ")
                .font(.callout)
                .foregroundStyle(Theme.coral)
                .lineLimit(2)
            HStack {
                Spacer()
                Button(l10n(.cancel), action: onCancel).keyboardShortcut(.cancelAction)
                Button(l10n(.save)) {
                    do { try onSave(text) } catch { saveError = l10n.message(for: error) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.cobalt)
                .disabled(parseError != nil)
            }
        }
        .padding(20)
    }
}
