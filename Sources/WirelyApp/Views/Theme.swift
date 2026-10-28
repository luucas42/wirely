import SwiftUI
import AppKit
import WirelyCore

enum Theme {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }

    static let ground = dynamic(light: 0xEEF2F6, dark: 0x0F151C)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x18212B)
    static let ink = dynamic(light: 0x17202B, dark: 0xE8EDF2)
    static let secondary = dynamic(light: 0x4D5A68, dark: 0x9AA8B6)
    static let dot = dynamic(light: 0xC3CDD8, dark: 0x35424F)
    static let chipIdle = dynamic(light: 0xE1E7EE, dark: 0x1E2833)
    static let chipIdleText = dynamic(light: 0x2E3A47, dark: 0xC9D3DD)
    static let chipOutline = dynamic(light: 0xB9C4D0, dark: 0x3A4756)
    static let cobalt = dynamic(light: 0x2F5BEA, dark: 0x6B8CFF)
    static let signal = dynamic(light: 0xE0A030, dark: 0xF0B850)
    static let coral = dynamic(light: 0xD9574A, dark: 0xFF7A6B)
    static let hairline = dynamic(light: 0xD9E0E8, dark: 0x26313C)
    /// Filled surfaces (Connect button, selected chip). Dark mode uses a deeper cobalt than `cobalt`
    /// (which is tuned for strokes and text on the dark ground) so white text stays crisp (≈5:1).
    static let cobaltFill = dynamic(light: 0x2F5BEA, dark: 0x3B62F2)
    /// Text on `cobaltFill`.
    static let onCobalt = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)

    static func color(for state: TunnelState) -> Color {
        switch state {
        case .connected: return cobalt
        case .connecting: return signal
        case .failed: return coral
        case .disconnected: return secondary.opacity(0.5)
        }
    }
}

extension Font {
    /// Manrope at a variable weight (400...800), system font when it isn't available.
    static func mr(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        AppFonts.manrope(size, weight: weight)
    }
}

private struct PreviewModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while `PreviewRenderer` snapshots views; ImageRenderer cannot draw AppKit-backed controls.
    var previewMode: Bool {
        get { self[PreviewModeKey.self] }
        set { self[PreviewModeKey.self] = newValue }
    }
}

/// Capsule button: filled cobalt (Connect, Install) or 2 pt cobalt outline (Disconnect).
struct PillButton<Label: View>: View {
    enum Kind { case filled, outline }
    var kind: Kind = .filled
    var size: CGFloat = 15
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
            .font(.mr(size, 700))
            .foregroundStyle(kind == .filled ? Theme.onCobalt : Theme.cobalt)
            .padding(.horizontal, size * 1.6).padding(.vertical, size * 0.85)
            .background {
                if kind == .filled {
                    Capsule().fill(Theme.cobaltFill)
                } else {
                    Capsule().strokeBorder(Theme.cobalt, lineWidth: 2)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Native switch; in preview mode a drawn pill.
struct AppSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        if previewMode {
            Capsule().fill(isOn ? Theme.cobalt : Theme.secondary.opacity(0.35))
                .frame(width: 30, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 14, height: 14).padding(2)
                }
        } else {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .tint(Theme.cobalt)
        }
    }
}

/// Small spinner; in preview mode a static arc (ProgressView is AppKit-backed).
struct AppSpinner: View {
    @Environment(\.previewMode) private var previewMode

    var body: some View {
        if previewMode {
            Circle().trim(from: 0, to: 0.7).stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-60))
                .frame(width: 14, height: 14)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Makes the hidden-title-bar window draggable from any background area.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isMovableByWindowBackground = true
        }
    }
}
