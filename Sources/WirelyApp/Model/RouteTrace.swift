import Foundation
import WirelyCore

/// Which part of the journey a hop belongs to.
enum TraceLegKind: Equatable {
    /// You to your VPN server (outside the tunnel).
    case tunnel
    /// VPN server to the target (inside the tunnel).
    case open
    /// Not connected: you straight to the target.
    case direct
}

enum TraceStationKind: Equatable {
    case home, hop, vpn, target
    /// The target never answered; this is the last router that did.
    case lastAnswer
}

/// One stop on the map: consecutive hops in the same city collapse into a single station.
struct TraceStation: Equatable, Identifiable {
    var id: Int
    var city: String
    var countryCode: String?
    var point: GeoPoint
    var kind: TraceStationKind
    /// Hops folded into this station.
    var hopCount: Int
    /// Address of the last hop folded in.
    var address: String?
    /// Largest round trip among the folded hops.
    var rttMs: Double?
    /// Extra milliseconds over the previous station; set on the one station with the biggest jump.
    var jumpMs: Double?
    var leg: TraceLegKind
}

enum RouteStations {
    /// Smallest round-trip increase worth highlighting.
    static let jumpThresholdMs = 10.0

    private static let nonPublicNets: [IPNetwork] = [
        "100.64.0.0/10", "169.254.0.0/16", "0.0.0.0/8",
    ].compactMap { IPNetwork($0) }

    /// Private, loopback, link-local, CGNAT (100.64.0.0/10) or unparseable: never geolocated.
    static func isNonPublic(_ ip: String) -> Bool {
        if ExitLocator.isPrivate(ip) { return true }
        guard let addr = IPAddress(ip) else { return true }
        return nonPublicNets.contains { $0.contains(addr) }
    }

    /// Turns the raw hops of each leg into map stations.
    ///
    /// Hops without an address, with a non-public address or with an unknown city fold into the
    /// station before them; the first station is `home`. The tunnel leg ends at the VPN server
    /// (`vpn` location), which the next leg continues from.
    /// - Parameters:
    ///   - locations: public hop address to its location.
    ///   - vpn: where the VPN server is; the tunnel leg always ends with a `.vpn` station there, even
    ///     when the server never answered (then `tunnelLatencyMs` is its round trip, if known).
    ///   - home: nil places the home station at the first located station (kept as "You"); with
    ///     nothing located the result is empty.
    ///   - targetName: unused for placement; kept so callers pass what the user typed.
    static func build(home: HomeLocation?,
                      legs: [(kind: TraceLegKind, result: TraceResult)],
                      locations: [String: ExitLocation],
                      vpn: ExitLocation?,
                      tunnelLatencyMs: Double? = nil,
                      targetName: String) -> [TraceStation] {
        var stations = [TraceStation(id: 0, city: home?.city ?? L10n.shared(.you), countryCode: nil,
                                     point: home?.point ?? GeoPoint(lat: 0, lon: 0), kind: .home,
                                     hopCount: 0, address: nil, rttMs: nil, jumpMs: nil,
                                     leg: legs.first?.kind ?? .direct)]

        func fold(_ hop: TraceHop, into i: Int) {
            stations[i].hopCount += 1
            if let a = hop.address { stations[i].address = a }
            if let r = hop.rttMs { stations[i].rttMs = max(stations[i].rttMs ?? r, r) }
        }

        func append(_ hop: TraceHop, _ loc: ExitLocation, kind: TraceStationKind, leg: TraceLegKind) {
            stations.append(TraceStation(id: 0, city: loc.city, countryCode: loc.countryCode, point: loc.point,
                                         kind: kind, hopCount: 1, address: hop.address, rttMs: hop.rttMs,
                                         jumpMs: nil, leg: leg))
        }

        for (kind, result) in legs {
            var placedServer = false
            for hop in result.hops {
                let last = stations.count - 1
                let isServer = kind == .tunnel && hop.isDestination
                let loc: ExitLocation? = isServer
                    ? (vpn ?? hop.address.flatMap { locations[$0] })
                    : hop.address.flatMap { isNonPublic($0) ? nil : locations[$0] }
                guard let loc else {
                    fold(hop, into: last)
                    if isServer, stations[last].kind == .hop { stations[last].kind = .vpn; placedServer = true }
                    continue
                }
                // The server always gets its own station, even when it sits in the home city.
                if stations[last].city == loc.city, !(isServer && stations[last].kind == .home) {
                    fold(hop, into: last)
                    if isServer {
                        placedServer = true
                        stations[last].kind = .vpn
                        stations[last].countryCode = loc.countryCode
                        stations[last].point = loc.point
                    }
                } else {
                    if isServer { placedServer = true }
                    append(hop, loc, kind: isServer ? .vpn : .hop, leg: kind)
                }
            }
            // The server never answered, but we are connected through it: still end the leg there.
            if kind == .tunnel, !placedServer, let vpn {
                let last = stations.count - 1
                if stations[last].kind == .hop, stations[last].city == vpn.city {
                    stations[last].kind = .vpn
                    stations[last].countryCode = vpn.countryCode
                    stations[last].point = vpn.point
                    if let ms = tunnelLatencyMs { stations[last].rttMs = ms }
                } else {
                    stations.append(TraceStation(id: 0, city: vpn.city, countryCode: vpn.countryCode,
                                                 point: vpn.point, kind: .vpn, hopCount: 0, address: nil,
                                                 rttMs: tunnelLatencyMs, jumpMs: nil, leg: .tunnel))
                }
            }
        }

        if let final = legs.last, final.kind != .tunnel {
            let i = stations.count - 1
            if stations[i].kind == .hop { stations[i].kind = final.result.reached ? .target : .lastAnswer }
        }

        if home == nil {
            guard stations.count > 1 else { return [] }
            stations[0].point = stations[1].point
        }

        markJump(&stations)
        for i in stations.indices { stations[i].id = i }
        return stations
    }

    /// Sets `jumpMs` on the station with the largest round-trip increase, if it reaches the threshold.
    private static func markJump(_ stations: inout [TraceStation]) {
        var best: (index: Int, ms: Double)?
        var previous = 0.0
        for i in stations.indices {
            guard let rtt = stations[i].rttMs else { continue }
            let increase = rtt - previous
            if i > 0, increase >= jumpThresholdMs, increase > (best?.ms ?? 0) { best = (i, increase) }
            previous = rtt
        }
        if let best { stations[best.index].jumpMs = best.ms }
    }
}
