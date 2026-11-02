import SwiftUI

/// Toggle drawn as a 44×26 capsule with a sliding knob; shapes only, so it also renders in previews.
struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Capsule()
            .fill(on ? Theme.cobaltFill : Theme.chipOutline)
            .frame(width: 44, height: 26)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 20, height: 20).padding(3)
            }
            .animation(.easeOut(duration: 0.15), value: on)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? "1" : "0")
            .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// Capsule segmented control; the selected pill is filled cobalt.
struct SegmentedPills<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                if previewMode {
                    face(option.label, selected: option.value == selection)
                } else {
                    Button { selection = option.value } label: {
                        face(option.label, selected: option.value == selection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.ground))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func face(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.mr(13, 700))
            .foregroundStyle(selected ? Theme.onCobalt : Theme.chipIdleText)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background { if selected { Capsule().fill(Theme.cobaltFill) } }
            .contentShape(Capsule())
    }
}

/// Rounded card that stacks `SettingRow`s with hairline separators.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        _VariadicView.Tree(GroupLayout()) { content() }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.chipIdle))
    }

    private struct GroupLayout: _VariadicView_UnaryViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { i, child in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    child
                }
            }
            .padding(.horizontal, 18)
        }
    }
}

/// One line in a `SettingsGroup`: title, optional hint and a trailing control.
struct SettingRow<Accessory: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.mr(14.5, 800)).foregroundStyle(Theme.ink)
                if let hint {
                    Text(hint).font(.mr(12.5, 500)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.vertical, 14)
    }
}

/// Capsule with a 1.5 pt outline; `destructive` uses coral.
struct OutlinePill<Label: View>: View {
    var destructive = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.previewMode) private var previewMode
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if previewMode {
            face
        } else {
            Button(action: action) { face }.buttonStyle(.plain)
        }
    }

    private var face: some View {
        label()
            .font(.mr(13, 700))
            .foregroundStyle(destructive ? Theme.coral : Theme.chipIdleText)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .overlay(Capsule().strokeBorder(destructive ? Theme.coral : Theme.chipOutline, lineWidth: 1.5))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// 36×36 symbol button (edit, export, delete, gear).
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = Theme.chipIdleText
    let action: () -> Void
    @Environment(\.previewMode) private var previewMode
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if previewMode {
            face
        } else {
            Button(action: action) { face }.buttonStyle(.plain)
        }
    }

    private var face: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

/// Row in the Settings rail.
struct RailButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        if previewMode {
            face
        } else {
            Button(action: action) { face }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private var face: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Theme.cobalt : Theme.secondary)
                .frame(width: 18)
            Text(title).font(.mr(14, 700)).foregroundStyle(selected ? Theme.ink : Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.chipIdle : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
