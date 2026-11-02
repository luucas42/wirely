import XCTest
@testable import WirelyApp

final class LabelPlacerTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 840, height: 378)

    func testClusteredAnchorsDoNotOverlap() {
        let anchors = (0..<6).map { CGPoint(x: 300 + CGFloat($0) * 40, y: 160 + CGFloat($0 % 2) * 44) }
        let sizes = Array(repeating: CGSize(width: 70, height: 36), count: 6)
        let rects = LabelPlacer.place(anchors: anchors, sizes: sizes, bounds: bounds, avoid: [])
        XCTAssertEqual(rects.count, 6)
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(rects[i].intersects(rects[j]), "labels \(i) and \(j) overlap")
            }
        }
    }

    func testStaysInsideBoundsNearEdges() {
        let anchors = [CGPoint(x: 830, y: 10), CGPoint(x: 8, y: 330), CGPoint(x: 420, y: 6), CGPoint(x: 10, y: 40)]
        let sizes = Array(repeating: CGSize(width: 90, height: 36), count: 4)
        let rects = LabelPlacer.place(anchors: anchors, sizes: sizes, bounds: bounds, avoid: [])
        for r in rects { XCTAssertTrue(bounds.contains(r), "\(r) leaves the bounds") }
    }

    func testAvoidsGivenRects() {
        let anchor = CGPoint(x: 300, y: 200)
        let blocked = CGRect(x: 310, y: 180, width: 120, height: 50)   // right of the anchor
        let rects = LabelPlacer.place(anchors: [anchor], sizes: [CGSize(width: 80, height: 36)],
                                      bounds: bounds, avoid: [blocked])
        XCTAssertFalse(rects[0].intersects(blocked))
    }

    func testChipAvoidsLabelsAndStaysInside() {
        let anchors = [CGPoint(x: 700, y: 330), CGPoint(x: 780, y: 340)]
        let labels = LabelPlacer.place(anchors: anchors, sizes: Array(repeating: CGSize(width: 70, height: 36), count: 2),
                                       bounds: bounds, avoid: [])
        let chip = LabelPlacer.placeChip(anchor: anchors[0], size: CGSize(width: 196, height: 74),
                                         allAnchors: anchors, bounds: bounds, obstacles: labels)
        XCTAssertTrue(bounds.contains(chip))
        for l in labels { XCTAssertFalse(chip.intersects(l)) }
    }
}
