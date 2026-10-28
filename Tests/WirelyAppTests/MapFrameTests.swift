import Testing
import CoreGraphics
@testable import WirelyApp

struct MapFrameTests {
    let ist = GeoPoint(lat: 41.0082, lon: 28.9784)
    let fra = GeoPoint(lat: 50.1109, lon: 8.6821)
    let size = CGSize(width: 840, height: 300)

    @Test func framesContainPointsWithPadding() {
        let f = MapFrame(points: [ist, fra], size: size)
        for p in [ist, fra] {
            let x = f.project(p).x
            #expect(x >= 0.15 * size.width && x <= 0.85 * size.width)
        }
    }

    @Test func minimumSpanForNearbyPoints() {
        let near = GeoPoint(lat: ist.lat, lon: ist.lon + 0.1)
        let f = MapFrame(points: [ist, near], size: size)
        let d = abs(f.project(near).x - f.project(ist).x)
        #expect(d > 0 && d < 0.2 * size.width)
    }

    @Test func antimeridianTakesShortSpan() {
        let tokyo = GeoPoint(lat: 35.68, lon: 139.69)
        let sf = GeoPoint(lat: 37.77, lon: -122.42)
        let f = MapFrame(points: [tokyo, sf], size: size)
        for p in [tokyo, sf] {
            let q = f.project(p)
            #expect(q.x >= 0 && q.x <= size.width && q.y >= 0 && q.y <= size.height)
        }
        #expect(abs(f.project(tokyo).x - f.project(sf).x) < 0.8 * size.width)
    }

    @Test func singlePointIsCentred() {
        let f = MapFrame(points: [ist], size: size)
        let q = f.project(ist)
        #expect(abs(q.x - size.width / 2) < 1 && abs(q.y - size.height / 2) < 1)
    }

    @Test func landDotsNonEmptyForEurope() {
        let f = MapFrame(points: [ist, fra], size: size)
        #expect(f.landDots(spacing: 6).count > 100)
    }
}
