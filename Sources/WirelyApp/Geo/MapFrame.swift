import Foundation
import CoreGraphics

/// Equirectangular framing of a few points inside a view of a given size.
public struct MapFrame {
    private let minLon: Double      // framing longitude space (may exceed 180 across the antimeridian)
    private let minLat: Double
    private let lonSpan: Double
    private let latSpan: Double
    private let xScale: Double      // cos(mid-latitude)
    private let size: CGSize

    public init(points: [GeoPoint], size: CGSize, paddingFraction: Double = 0.6, minSpanLon: Double = 40) {
        self.size = size
        var lons = points.map(\.lon)
        if let lo = lons.min(), let hi = lons.max(), hi - lo > 180 {
            lons = lons.map { $0 < 0 ? $0 + 360 : $0 }
        }
        let lats = points.map { min(75, max(-75, $0.lat)) }
        let loLon = lons.min() ?? 0, hiLon = lons.max() ?? 0
        let loLat = lats.min() ?? 0, hiLat = lats.max() ?? 0
        let midLon = (loLon + hiLon) / 2, midLat = (loLat + hiLat) / 2
        let xs = max(0.05, cos(midLat * .pi / 180))

        var spanLon = max(minSpanLon, (hiLon - loLon) * (1 + 2 * paddingFraction))
        var spanLat = max(0.0001, (hiLat - loLat) * (1 + 2 * paddingFraction))
        // Grow the shorter axis so the frame's aspect equals the view's.
        let aspect = Double(size.width / max(size.height, 1))
        if spanLon * xs / spanLat > aspect {
            spanLat = spanLon * xs / aspect
        } else {
            spanLon = spanLat * aspect / xs
        }
        xScale = xs
        lonSpan = spanLon
        latSpan = spanLat
        minLon = midLon - spanLon / 2
        minLat = midLat - spanLat / 2
    }

    /// Longitude in framing space, shifted east when the frame crosses the antimeridian.
    private func frameLon(_ lon: Double) -> Double {
        var l = lon
        let mid = minLon + lonSpan / 2
        while l - mid > 180 { l -= 360 }
        while l - mid < -180 { l += 360 }
        return l
    }

    public func project(_ p: GeoPoint) -> CGPoint {
        let x = (frameLon(p.lon) - minLon) / lonSpan * Double(size.width)
        let y = (1 - (p.lat - minLat) / latSpan) * Double(size.height)
        return CGPoint(x: x, y: y)
    }

    private func unproject(_ pt: CGPoint) -> GeoPoint {
        let lon = minLon + Double(pt.x / size.width) * lonSpan
        let lat = minLat + (1 - Double(pt.y / size.height)) * latSpan
        return GeoPoint(lat: lat, lon: lon)
    }

    /// Grid points (every `spacing`, offset spacing/2) that fall on land.
    public func landDots(spacing: CGFloat) -> [CGPoint] {
        guard spacing > 0 else { return [] }
        var out: [CGPoint] = []
        var y = spacing / 2
        while y < size.height {
            var x = spacing / 2
            while x < size.width {
                let g = unproject(CGPoint(x: x, y: y))
                if LandMask.isLand(lat: g.lat, lon: g.lon) { out.append(CGPoint(x: x, y: y)) }
                x += spacing
            }
            y += spacing
        }
        return out
    }
}
