import CoreGraphics

/// Greedy collision-free placement of map labels next to their station markers.
enum LabelPlacer {
    /// Half-size of the box kept clear around every anchor (the marker plus its halo).
    static let markerHalf: CGFloat = 7

    /// One rect per anchor, in station order.
    ///
    /// Tries right, left, above, below (then the four diagonals) of the anchor and takes the first candidate that lies fully inside
    /// `bounds` and touches no earlier label, no `avoid` rect and no marker; falls back to the right one.
    static func place(anchors: [CGPoint], sizes: [CGSize], bounds: CGRect, avoid: [CGRect]) -> [CGRect] {
        var placed: [CGRect] = []
        for (i, a) in anchors.enumerated() {
            let s = sizes[i]
            let candidates = [
                CGRect(x: a.x + 12, y: a.y - 10, width: s.width, height: s.height),
                CGRect(x: a.x - 12 - s.width, y: a.y - 10, width: s.width, height: s.height),
                CGRect(x: a.x - s.width / 2, y: a.y - 12 - s.height, width: s.width, height: s.height),
                CGRect(x: a.x - s.width / 2, y: a.y + 12, width: s.width, height: s.height),
                // Diagonals, only when the four sides are taken (lines crossing the marker, dense clusters).
                CGRect(x: a.x - s.width + 8, y: a.y + 12, width: s.width, height: s.height),
                CGRect(x: a.x - 8, y: a.y + 12, width: s.width, height: s.height),
                CGRect(x: a.x - s.width + 8, y: a.y - 12 - s.height, width: s.width, height: s.height),
                CGRect(x: a.x - 8, y: a.y - 12 - s.height, width: s.width, height: s.height),
            ]
            let obstacles = placed + avoid + markerBoxes(anchors)
            placed.append(candidates.first { fits($0, in: bounds, obstacles) } ?? candidates[0])
        }
        return placed
    }

    /// The detail chip: below-right of its anchor, then below-left, above-right, above-left.
    /// `obstacles` are the placed labels and any overlay cards; markers are added here.
    static func placeChip(anchor a: CGPoint, size s: CGSize, allAnchors: [CGPoint],
                          bounds: CGRect, obstacles: [CGRect]) -> CGRect {
        let candidates = [
            CGRect(x: a.x + 10, y: a.y + 14, width: s.width, height: s.height),
            CGRect(x: a.x - 10 - s.width, y: a.y + 14, width: s.width, height: s.height),
            CGRect(x: a.x + 10, y: a.y - 14 - s.height, width: s.width, height: s.height),
            CGRect(x: a.x - 10 - s.width, y: a.y - 14 - s.height, width: s.width, height: s.height),
        ]
        let all = obstacles + markerBoxes(allAnchors)
        if let hit = candidates.first(where: { fits($0, in: bounds, all) }) { return hit }
        // Nothing is free: keep the preferred spot but pull it into the bounds.
        var r = candidates[0]
        r.origin.x = max(bounds.minX, min(r.minX, bounds.maxX - r.width))
        r.origin.y = max(bounds.minY, min(r.minY, bounds.maxY - r.height))
        return r
    }

    /// Rough label size: no text measurement, so it also works off the main thread and in tests.
    static func estimate(title: String, subtitle: String?, titleSize: CGFloat = 14, subSize: CGFloat = 12) -> CGSize {
        let t = CGFloat(title.count) * titleSize * 0.58
        let s = CGFloat(subtitle?.count ?? 0) * subSize * 0.58
        let lines: CGFloat = subtitle == nil ? 1 : 2
        return CGSize(width: ceil(max(t, s)) + 6, height: ceil(lines * 17) + 2)
    }

    private static func markerBoxes(_ anchors: [CGPoint]) -> [CGRect] {
        anchors.map { CGRect(x: $0.x - markerHalf, y: $0.y - markerHalf, width: markerHalf * 2, height: markerHalf * 2) }
    }

    private static func fits(_ r: CGRect, in bounds: CGRect, _ obstacles: [CGRect]) -> Bool {
        bounds.contains(r) && !obstacles.contains { $0.intersects(r) }
    }
}
