import AppKit

enum MenuBarIcon {
    /// The app icon's route "W" as an 18x18 pt template image. The exit node at the end of the
    /// route is a filled dot when connected and a hollow ring when idle.
    static func image(connected: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let start = NSPoint(x: 2.6, y: 12.6)
            let valley1 = NSPoint(x: 5.9, y: 5.2)
            let peak = NSPoint(x: 9, y: 10.4)
            let valley2 = NSPoint(x: 12.1, y: 5.2)
            let exit = NSPoint(x: 15.2, y: 12.6)
            let ring: CGFloat = 2.4

            // Stop the line at the ring's edge so the idle ring reads as hollow.
            let dx = exit.x - valley2.x, dy = exit.y - valley2.y
            let len = (dx * dx + dy * dy).squareRoot()
            let lineEnd = NSPoint(x: exit.x - dx / len * ring, y: exit.y - dy / len * ring)

            NSColor.black.set()
            let route = NSBezierPath()
            route.move(to: start)
            route.line(to: valley1)
            route.line(to: peak)
            route.line(to: valley2)
            route.line(to: connected ? exit : lineEnd)
            route.lineWidth = 2
            route.lineCapStyle = .round
            route.lineJoinStyle = .round
            route.stroke()

            NSBezierPath(ovalIn: NSRect(x: start.x - 1.6, y: start.y - 1.6, width: 3.2, height: 3.2)).fill()
            let node = NSBezierPath(ovalIn: NSRect(x: exit.x - ring, y: exit.y - ring, width: ring * 2, height: ring * 2))
            if connected {
                node.fill()
            } else {
                node.lineWidth = 1.4
                node.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
