import SwiftUI

/// Title block at the top of a Settings section: heading, optional hint and an optional trailing control.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.mr(22, 800)).foregroundStyle(Theme.ink)
                if let hint {
                    Text(hint).font(.mr(13, 500)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, hint: String? = nil) {
        self.init(title: title, hint: hint, trailing: { EmptyView() })
    }
}

/// A `SettingRow` whose accessory is a pill toggle; dims itself when disabled.
struct ToggleRow: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        SettingRow(title: title, hint: hint) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(PillToggleStyle())
                .accessibilityLabel(title)
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}
