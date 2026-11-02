import Testing
import Foundation
import WirelyCore
@testable import WirelyApp

private let home = HomeLocation(city: "Istanbul", point: GeoPoint(lat: 41.0, lon: 28.97))

private func loc(_ city: String, _ cc: String, _ lat: Double, _ lon: Double) -> ExitLocation {
    ExitLocation(city: city, countryCode: cc, point: GeoPoint(lat: lat, lon: lon), fetchedAt: Date(timeIntervalSince1970: 0))
}

private let sofia = loc("Sofia", "BG", 42.7, 23.3)
private let vienna = loc("Vienna", "AT", 48.2, 16.4)
private let frankfurt = loc("Frankfurt", "DE", 50.1, 8.7)
private let amsterdam = loc("Amsterdam", "NL", 52.4, 4.9)

private func hop(_ ttl: Int, _ address: String?, _ rtt: Double?, dest: Bool = false) -> TraceHop {
    TraceHop(ttl: ttl, address: address, rttMs: rtt, isDestination: dest)
}

private func result(_ hops: [TraceHop], target: String = "example.com", address: String = "198.51.100.9",
                    reached: Bool = true) -> TraceResult {
    TraceResult(target: target, address: address, hops: hops, durationMs: 700, reached: reached)
}

struct RouteStationsTests {
    @Test func privateHopsMergeIntoHome() {
        let r = result([hop(1, "192.168.1.1", 1), hop(2, "100.64.0.1", 3), hop(3, nil, nil), hop(4, "10.1.1.1", 5)],
                       reached: false)
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: [:], vpn: nil, targetName: "example.com")
        #expect(s.count == 1)
        #expect(s[0].kind == .home)
        #expect(s[0].hopCount == 4)
        #expect(s[0].address == "10.1.1.1")
        #expect(s[0].rttMs == 5)
        #expect(s[0].id == 0)
    }

    @Test func sameCityHopsMerge() {
        let r = result([hop(1, "192.168.1.1", 1), hop(2, "203.0.113.1", 8), hop(3, "203.0.113.2", 9),
                        hop(4, "203.0.113.3", 7), hop(5, "198.51.100.9", 40, dest: true)])
        let locs = ["203.0.113.1": sofia, "203.0.113.2": sofia, "203.0.113.3": sofia, "198.51.100.9": vienna]
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        #expect(s.map(\.city) == ["Istanbul", "Sofia", "Vienna"])
        #expect(s[1].kind == .hop)
        #expect(s[1].hopCount == 3)
        #expect(s[1].address == "203.0.113.3")
        #expect(s[1].rttMs == 9)
        #expect(s[2].kind == .target)
        #expect(s.map(\.id) == [0, 1, 2])
    }

    @Test func vpnStationMarkedAndLegsSplit() {
        let tunnel = result([hop(1, "192.168.1.1", 1), hop(2, "203.0.113.1", 20),
                             hop(3, "192.0.2.50", 45, dest: true)], target: "192.0.2.50", address: "192.0.2.50")
        let open = result([hop(1, "192.0.2.1", 46), hop(2, "198.51.100.1", 52), hop(3, "198.51.100.9", 55, dest: true)])
        let locs = ["203.0.113.1": sofia, "192.0.2.1": frankfurt, "198.51.100.1": amsterdam, "198.51.100.9": amsterdam]
        let s = RouteStations.build(home: home, legs: [(.tunnel, tunnel), (.open, open)], locations: locs,
                                    vpn: frankfurt, targetName: "example.com")
        #expect(s.map(\.city) == ["Istanbul", "Sofia", "Frankfurt", "Amsterdam"])
        #expect(s.map(\.kind) == [.home, .hop, .vpn, .target])
        #expect(s[2].leg == .tunnel)
        #expect(s[2].hopCount == 2)   // server + the tunnel's first hop, no duplicate station
        #expect(s[3].leg == .open)
        #expect(s[3].hopCount == 2)
    }

    @Test func vpnStationUsesKnownLocationEvenWhenHopCityDiffers() {
        let tunnel = result([hop(1, "203.0.113.1", 20), hop(2, "192.0.2.50", 45, dest: true)],
                            target: "192.0.2.50", address: "192.0.2.50")
        let locs = ["203.0.113.1": sofia, "192.0.2.50": vienna]
        let s = RouteStations.build(home: home, legs: [(.tunnel, tunnel)], locations: locs, vpn: frankfurt, targetName: "")
        #expect(s.last?.kind == .vpn)
        #expect(s.last?.city == "Frankfurt")
        #expect(s.last?.point == frankfurt.point)
    }

    @Test func unreachedTunnelLegStillEndsAtVPN() {
        let tunnel = result([hop(1, "192.168.1.1", 1), hop(2, "203.0.113.1", 20)], target: "192.0.2.50",
                            address: "192.0.2.50", reached: false)
        let locs = ["203.0.113.1": sofia]
        let with = RouteStations.build(home: home, legs: [(.tunnel, tunnel)], locations: locs, vpn: frankfurt,
                                       tunnelLatencyMs: 42, targetName: "")
        #expect(with.map(\.kind) == [.home, .hop, .vpn])
        #expect(with.last?.city == "Frankfurt")
        #expect(with.last?.rttMs == 42)
        #expect(with.last?.leg == .tunnel)
        let without = RouteStations.build(home: home, legs: [(.tunnel, tunnel)], locations: locs, vpn: frankfurt,
                                          targetName: "")
        #expect(without.last?.kind == .vpn)
        #expect(without.last?.rttMs == nil)
    }

    @Test func missingHomeUsesFirstLocatedPoint() {
        let r = result([hop(1, "192.168.1.1", 1), hop(2, "203.0.113.1", 20), hop(3, "198.51.100.9", 30, dest: true)])
        let locs = ["203.0.113.1": sofia, "198.51.100.9": vienna]
        let s = RouteStations.build(home: nil, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        #expect(s.first?.kind == .home)
        #expect(s.first?.point == sofia.point)
        #expect(s.first?.city == L10n.shared(.you))
        #expect(s.count == 3)
        let none = RouteStations.build(home: nil, legs: [(.direct, result([hop(1, "192.168.1.1", 1)], reached: false))],
                                       locations: [:], vpn: nil, targetName: "example.com")
        #expect(none.isEmpty)
    }

    @Test func jumpPicksLargestIncreaseAbove10ms() {
        let r = result([hop(1, "203.0.113.1", 5), hop(2, "203.0.113.2", 20), hop(3, "203.0.113.3", 90),
                        hop(4, "198.51.100.9", 110, dest: true)])
        let locs = ["203.0.113.1": sofia, "203.0.113.2": vienna, "203.0.113.3": frankfurt, "198.51.100.9": amsterdam]
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        let jumps = s.filter { $0.jumpMs != nil }
        #expect(jumps.count == 1)
        #expect(jumps[0].city == "Frankfurt")
        #expect(jumps[0].jumpMs == 70)
    }

    @Test func noJumpBelowThreshold() {
        let r = result([hop(1, "203.0.113.1", 5), hop(2, "203.0.113.2", 11), hop(3, "198.51.100.9", 20, dest: true)])
        let locs = ["203.0.113.1": sofia, "203.0.113.2": vienna, "198.51.100.9": amsterdam]
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        #expect(s.allSatisfy { $0.jumpMs == nil })
    }

    @Test func unknownCityMergesIntoPrevious() {
        let r = result([hop(1, "203.0.113.1", 8), hop(2, "203.0.113.2", 12), hop(3, "198.51.100.9", 30, dest: true)])
        let locs = ["203.0.113.1": sofia, "198.51.100.9": vienna]   // 203.0.113.2 has no location
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        #expect(s.map(\.city) == ["Istanbul", "Sofia", "Vienna"])
        #expect(s[1].hopCount == 2)
        #expect(s[1].rttMs == 8)   // the unlocated hop (12 ms) no longer lends its round trip
    }

    @Test func directLegWhenDisconnected() {
        let r = result([hop(1, "192.168.1.1", 1), hop(2, "198.51.100.9", 25, dest: true)])
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: ["198.51.100.9": vienna], vpn: nil,
                                    targetName: "example.com")
        #expect(s.map(\.kind) == [.home, .target])
        #expect(s.allSatisfy { $0.leg == .direct })
    }

    @Test func unreachedTargetEndsWithLastAnswer() {
        let r = result([hop(1, "192.168.1.1", 1), hop(2, "203.0.113.1", 20)], reached: false)
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: ["203.0.113.1": sofia], vpn: nil,
                                    targetName: "example.com")
        #expect(s.last?.kind == .lastAnswer)
    }

    @Test func endpointHostParsing() {
        #expect(TraceModel.endpointHost("203.0.113.5:51820") == "203.0.113.5")
        #expect(TraceModel.endpointHost("203.0.113.5") == "203.0.113.5")
        #expect(TraceModel.endpointHost("[2001:db8::1]:51820") == nil)
        #expect(TraceModel.endpointHost("2001:db8::1") == nil)
        #expect(TraceModel.endpointHost("vpn.example.com:51820") == nil)
        #expect(TraceModel.endpointHost("999.1.1.1:51820") == nil)
        #expect(TraceModel.endpointHost("") == nil)
        #expect(TraceModel.endpointHost(nil) == nil)
    }

    @Test func nonPublicAddresses() {
        for ip in ["10.0.0.1", "172.16.5.5", "192.168.1.1", "100.64.0.1", "100.127.255.254", "169.254.1.1",
                   "127.0.0.1", "not an ip"] {
            #expect(RouteStations.isNonPublic(ip), "\(ip)")
        }
        for ip in ["203.0.113.1", "198.51.100.9", "192.0.2.50", "100.63.255.255", "100.128.0.1"] {
            #expect(!RouteStations.isNonPublic(ip), "\(ip)")
        }
    }

    // MARK: Plausibility

    private static let indiana = loc("Francisco", "US", 38.3, -87.4)
    private static let oregon = loc("Boardman", "US", 45.8, -119.7)

    @Test func infeasibleTargetIsShownNearPreviousStop() {
        let r = result([hop(1, "192.0.2.1", 46), hop(2, "198.51.100.9", 47, dest: true)])
        let locs = ["192.0.2.1": frankfurt, "198.51.100.9": Self.indiana]
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "cdn.example.com")
        #expect(s.map(\.city) == ["Istanbul", "Frankfurt", "Frankfurt"])
        #expect(s[2].kind == .target)
        #expect(s[2].point == frankfurt.point)
        #expect(s[2].locationNearPrevious)
        #expect(!s[1].locationNearPrevious)
        #expect(s[2].rttMs == 47)
    }

    @Test func infeasibleMiddleHopFolds() {
        let r = result([hop(1, "192.0.2.1", 20), hop(2, "198.51.100.1", 22), hop(3, "198.51.100.9", 60, dest: true)])
        let locs = ["192.0.2.1": sofia, "198.51.100.1": Self.indiana, "198.51.100.9": vienna]
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        #expect(s.map(\.city) == ["Istanbul", "Sofia", "Vienna"])
        #expect(s[1].hopCount == 2)
        #expect(s.allSatisfy { !$0.locationNearPrevious })
    }

    @Test func feasibleFarTargetIsKept() {
        let r = result([hop(1, "192.0.2.1", 46), hop(2, "198.51.100.9", 188, dest: true)])
        let locs = ["192.0.2.1": frankfurt, "198.51.100.9": Self.oregon]
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        #expect(s.map(\.city) == ["Istanbul", "Frankfurt", "Boardman"])
        #expect(s[2].point == Self.oregon.point)
        #expect(!s[2].locationNearPrevious)
    }

    @Test func vpnRttFromOpenLegWhenTunnelNotReached() {
        let tunnel = result([hop(1, "192.168.1.1", 1), hop(2, nil, nil)], target: "192.0.2.50", address: "192.0.2.50",
                            reached: false)
        let open = result([hop(1, "192.0.2.1", 46), hop(2, "192.0.2.2", 46), hop(3, "198.51.100.9", 55, dest: true)])
        let locs = ["192.0.2.1": frankfurt, "192.0.2.2": frankfurt, "198.51.100.9": amsterdam]
        let s = RouteStations.build(home: home, legs: [(.tunnel, tunnel), (.open, open)], locations: locs,
                                    vpn: frankfurt, tunnelLatencyMs: 109, targetName: "example.com")
        let vpnStation = s.first { $0.kind == .vpn }
        #expect(vpnStation?.rttMs == 46)
        #expect(s.allSatisfy { $0.jumpMs == nil || $0.jumpMs! < 100 })
    }

    @Test func openLegHopInVpnCityFoldsIntoVpnStation() {
        let tunnel = result([hop(1, "192.168.1.1", 1), hop(2, "192.0.2.50", 60, dest: true)],
                            target: "192.0.2.50", address: "192.0.2.50")
        let open = result([hop(1, "192.0.2.1", 46), hop(2, "198.51.100.9", 47, dest: true)])
        let locs = ["192.0.2.1": frankfurt, "198.51.100.9": Self.indiana]
        let s = RouteStations.build(home: home, legs: [(.tunnel, tunnel), (.open, open)], locations: locs,
                                    vpn: frankfurt, targetName: "cdn.example.com")
        #expect(s.map(\.kind) == [.home, .vpn, .target])
        #expect(s[1].rttMs == 46)
        #expect(s[2].locationNearPrevious)
    }

    @Test func foldedUnknownHopsKeepStationRtt() {
        let r = result([hop(1, "203.0.113.1", 8), hop(2, "203.0.113.2", 90), hop(3, "240.1.1.1", 120),
                        hop(4, "198.51.100.9", 30, dest: true)])
        let locs = ["203.0.113.1": sofia, "198.51.100.9": vienna]   // .2 has no location, .3 is class E
        let s = RouteStations.build(home: home, legs: [(.direct, r)], locations: locs, vpn: nil, targetName: "example.com")
        #expect(s.map(\.city) == ["Istanbul", "Sofia", "Vienna"])
        #expect(s[1].hopCount == 3)
        #expect(s[1].rttMs == 8)
        #expect(s[1].address == "240.1.1.1")
    }

    @Test func classEAddressesAreNonPublic() {
        #expect(RouteStations.isNonPublic("240.5.80.41"))
        #expect(RouteStations.isNonPublic("255.255.255.255"))
        #expect(!RouteStations.isNonPublic("198.51.100.9"))
    }

    @Test func awsBackboneHopsDoNotInflateVpnRtt() {
        let tunnel = result([hop(1, "192.168.1.1", 1), hop(2, nil, nil)], target: "203.0.113.10", address: "203.0.113.10",
                            reached: false)
        let open = result([hop(1, "10.67.0.1", 46), hop(2, "240.5.80.41", 150), hop(3, "240.5.80.42", 185),
                           hop(4, "192.0.2.200", 187)], reached: false)
        let boardman = loc("Boardman", "US", 45.8, -119.7)
        let locs = ["192.0.2.200": boardman]
        let s = RouteStations.build(home: home, legs: [(.tunnel, tunnel), (.open, open)], locations: locs,
                                    vpn: frankfurt, tunnelLatencyMs: 109, vpnAddress: "203.0.113.10",
                                    targetName: "example.com")
        let v = s.first { $0.kind == .vpn }
        #expect(v?.rttMs == 46)
        #expect(v?.address == "203.0.113.10")
        #expect(s.last?.city == "Boardman")
        #expect(s.last?.kind == .lastAnswer)
        #expect(s.last?.jumpMs == 141)
    }
}
