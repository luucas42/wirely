import AppKit

enum MenuBarIcon {
    /// The app icon's tunnel arch as an 18x18 pt template image: filled when connected, outline when idle.
    static func image(connected: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 3, y: 2.5))
            path.line(to: NSPoint(x: 3, y: 9))
            path.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: 15, y: 2.5))
            path.close()
            NSColor.black.set()
            if connected {
                path.fill()
            } else {
                path.lineWidth = 1.6
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
