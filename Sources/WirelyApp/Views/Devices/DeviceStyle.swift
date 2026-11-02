import SwiftUI

extension LANDevice {
    /// Icon colour: new is amber, this Mac cobalt, the rest quiet.
    var iconColor: Color {
        isNew ? Theme.signal : (isThisMac ? Theme.cobalt : Theme.chipIdleText)
    }
}

/// Capsule label next to a device name ("New", "This Mac").
struct DeviceBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.mr(11, 800))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// The "New" / "This Mac" badge a device carries, if any.
func deviceBadge(_ d: LANDevice, _ l10n: L10n) -> (text: String, color: Color)? {
    if d.isNew { return (l10n(.devNew), Theme.signal) }
    if d.isThisMac { return (l10n(.devThisMac), Theme.cobalt) }
    return nil
}
