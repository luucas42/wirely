import Foundation
import CoreGraphics

extension NetworkInfo {
    /// The subnet in CIDR form, e.g. `192.168.1.0/24`.
    var subnetString: String {
        let o = address.split(separator: ".").compactMap { UInt8($0) }
        guard o.count == 4, (0...32).contains(prefix) else { return address }
        let ip = o.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let mask = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        let n = ip & mask
        return "\(n >> 24).\(n >> 16 & 0xFF).\(n >> 8 & 0xFF).\(n & 0xFF)/\(prefix)"
    }
}

extension DeviceKind {
    /// Localised name of the kind.
    func title(_ l10n: L10n) -> String {
        switch self {
        case .router: return l10n(.kindRouter)
        case .computer: return l10n(.kindComputer)
        case .phone: return l10n(.kindPhone)
        case .tablet: return l10n(.kindTablet)
        case .tv: return l10n(.kindTV)
        case .speaker: return l10n(.kindSpeaker)
        case .printer: return l10n(.kindPrinter)
        case .smartHome: return l10n(.kindSmartHome)
        case .console: return l10n(.kindConsole)
        case .nas: return l10n(.kindNAS)
        case .unknown: return l10n(.kindUnknown)
        }
    }
}

extension LANDevice {
    /// The vendor, else "Private address" for a randomised MAC, else "Unknown vendor".
    func vendorText(_ l10n: L10n) -> String {
        vendor ?? (mac.isLocallyAdministered ? l10n(.privateAddress) : l10n(.devUnknownVendor))
    }
}

enum DeviceFormat {
    /// "just now" under a minute, else a relative date in the app language ("3 months ago"); "—" for nil.
    static func relative(_ date: Date?, now: Date, l10n: L10n) -> String {
        guard let date else { return "—" }
        if now.timeIntervalSince(date) < 60 { return l10n(.justNow) }
        let f = RelativeDateTimeFormatter()
        f.locale = l10n.locale
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// Where the devices sit on the radial map. Points are relative to the map area.
enum DeviceMapLayout {
    static let maxNodes = 24
    static let singleRing = 0.66
    static let innerRing = 0.46
    static let outerRing = 0.84
    /// Dotted decoration rings, as fractions of the half size.
    static let decorationRings: [Double] = [0.40, 0.72, 0.98]

    static func half(in size: CGSize) -> CGFloat { min(size.width, size.height) / 2 }

    /// How many devices sit on the inner and outer ring (outer is 0 for a single ring).
    static func ringSizes(count: Int) -> (inner: Int, outer: Int) {
        let n = min(max(count, 0), maxNodes)
        guard n > 12 else { return (n, 0) }
        let inner = Int((Double(n) * innerRing / (innerRing + outerRing)).rounded())
        return (inner, n - inner)
    }

    /// Widest name that fits under each node without running into the next one on its ring (48...96 pt).
    static func labelWidths(count: Int, in size: CGSize) -> [CGFloat] {
        let (inner, outer) = ringSizes(count: count)
        let half = half(in: size)
        func width(_ k: Int, _ fraction: Double) -> CGFloat {
            guard k > 1 else { return 96 }
            let chord = 2 * half * CGFloat(fraction) * CGFloat(sin(Double.pi / Double(k)))
            return min(96, max(48, chord - 6))
        }
        if outer == 0 { return Array(repeating: 96, count: inner) }
        return Array(repeating: width(inner, innerRing), count: inner) + Array(repeating: width(outer, outerRing), count: outer)
    }

    /// The router's name and address fit under the centre only when the inner ring clears them.
    static func showsCenterLabel(count: Int, in size: CGSize) -> Bool {
        ringSizes(count: count).outer == 0 || half(in: size) * CGFloat(innerRing) - 24 >= 94
    }

    /// One ring up to 12 devices, two rings (split in proportion to radius, outer ring shifted half a step) up to 24.
    /// The first point is at the top; the rest follow clockwise. More than 24 are not drawn.
    static func positions(count: Int, in size: CGSize) -> [CGPoint] {
        let n = min(max(count, 0), maxNodes)
        guard n > 0 else { return [] }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let half = half(in: size)
        func ring(_ k: Int, radius: CGFloat, offset: Double) -> [CGPoint] {
            (0..<k).map { i in
                let a = (-90 + offset + 360 * Double(i) / Double(k)) * .pi / 180
                return CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
            }
        }
        if n <= 12 { return ring(n, radius: half * singleRing, offset: 0) }
        let (inner, outer) = ringSizes(count: n)
        return ring(inner, radius: half * innerRing, offset: 0)
            + ring(outer, radius: half * outerRing, offset: 180 / Double(outer))
    }
}
