import Foundation
import Testing
@testable import WirelyCore

// MARK: - Packet builders (what a macOS raw ICMP socket hands back: IPv4 header, then ICMP)

private func ipv4Header(src: [UInt8], dst: [UInt8], proto: UInt8 = 1, ihl: Int = 5, totalLength: Int) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: ihl * 4)
    h[0] = 0x40 | UInt8(ihl)
    h[2] = UInt8(totalLength >> 8); h[3] = UInt8(totalLength & 0xff)
    h[8] = 64
    h[9] = proto
    h.replaceSubrange(12..<16, with: src)
    h.replaceSubrange(16..<20, with: dst)
    return h
}

private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

private let me: [UInt8] = [198, 51, 100, 42]
private let router: [UInt8] = [203, 0, 113, 10]
private let target: [UInt8] = [192, 0, 2, 7]

private func echoReplyPacket(from src: [UInt8], id: UInt16, seq: UInt16, ihl: Int = 5) -> [UInt8] {
    let icmp: [UInt8] = [0, 0, 0, 0] + be16(id) + be16(seq)
    return ipv4Header(src: src, dst: me, ihl: ihl, totalLength: ihl * 4 + icmp.count) + icmp
}

/// Time Exceeded (11) or Destination Unreachable (3) quoting our probe.
private func errorPacket(type: UInt8, code: UInt8 = 0, from src: [UInt8], id: UInt16, seq: UInt16,
                         outerIHL: Int = 5, innerIHL: Int = 5, quotedEchoBytes: Int = 8) -> [UInt8] {
    let original = ICMPCodec.echoRequest(id: id, seq: seq, payload: [])
    let inner = ipv4Header(src: me, dst: target, ihl: innerIHL, totalLength: innerIHL * 4 + original.count)
    let icmp: [UInt8] = [type, code, 0, 0, 0, 0, 0, 0] + inner + Array(original.prefix(quotedEchoBytes))
    return ipv4Header(src: src, dst: me, ihl: outerIHL, totalLength: outerIHL * 4 + icmp.count) + icmp
}

// MARK: - Codec

@Test func checksumMatchesRFC1071Example() {
    #expect(ICMPCodec.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]) == 0x220d)
}

@Test func echoRequestHasValidChecksum() {
    let packet = ICMPCodec.echoRequest(id: 0xBEEF, seq: 70, payload: [1, 2, 3, 4, 5])
    #expect(packet[0] == 8 && packet[1] == 0)
    #expect(Array(packet[4...5]) == [0xBE, 0xEF])
    #expect(Array(packet[6...7]) == [0x00, 70])
    #expect(packet.count == 8 + 5)
    #expect(ICMPCodec.checksum(packet) == 0)
}

@Test func parsesEchoReply() {
    let packet = echoReplyPacket(from: target, id: 0x1234, seq: 64 + 9)
    #expect(ICMPCodec.parse(packet, id: 0x1234) == ICMPAnswer(kind: .echoReply, from: "192.0.2.7", seq: 73))
}

@Test func parsesEchoReplyWithIPOptions() {
    let packet = echoReplyPacket(from: target, id: 0x1234, seq: 5, ihl: 6)
    #expect(ICMPCodec.parse(packet, id: 0x1234)?.seq == 5)
}

@Test func parsesTimeExceededQuotingOurProbe() {
    let packet = errorPacket(type: 11, from: router, id: 0x1234, seq: 3)
    #expect(ICMPCodec.parse(packet, id: 0x1234) == ICMPAnswer(kind: .timeExceeded, from: "203.0.113.10", seq: 3))
    // Different header lengths on the outer and the quoted header.
    let odd = errorPacket(type: 11, from: router, id: 0x1234, seq: 66, outerIHL: 6, innerIHL: 7)
    #expect(ICMPCodec.parse(odd, id: 0x1234) == ICMPAnswer(kind: .timeExceeded, from: "203.0.113.10", seq: 66))
}

@Test func parsesDestinationUnreachable() {
    let packet = errorPacket(type: 3, code: 3, from: target, id: 0x1234, seq: 12)
    #expect(ICMPCodec.parse(packet, id: 0x1234) == ICMPAnswer(kind: .unreachable, from: "192.0.2.7", seq: 12))
}

@Test func ignoresOtherIdentifiers() {
    #expect(ICMPCodec.parse(echoReplyPacket(from: target, id: 0x1111, seq: 1), id: 0x2222) == nil)
    #expect(ICMPCodec.parse(errorPacket(type: 11, from: router, id: 0x1111, seq: 1), id: 0x2222) == nil)
}

@Test func ignoresOtherIcmpTypes() {
    var echoRequest = ICMPCodec.echoRequest(id: 0x1234, seq: 1, payload: [])
    echoRequest = ipv4Header(src: router, dst: me, totalLength: 20 + echoRequest.count) + echoRequest
    #expect(ICMPCodec.parse(echoRequest, id: 0x1234) == nil)
    // Time Exceeded during reassembly (code 1) is not an answer to our TTL probe.
    #expect(ICMPCodec.parse(errorPacket(type: 11, code: 1, from: router, id: 0x1234, seq: 1), id: 0x1234) == nil)
}

@Test func rejectsTruncatedPackets() {
    let good = errorPacket(type: 11, from: router, id: 0x1234, seq: 3)
    #expect(ICMPCodec.parse([], id: 0x1234) == nil)
    #expect(ICMPCodec.parse(Array(good.prefix(19)), id: 0x1234) == nil)
    // Cut inside the quoted original echo (needs its first 8 bytes) and inside the quoted IP header.
    #expect(ICMPCodec.parse(Array(good.dropLast(1)), id: 0x1234) == nil)
    #expect(ICMPCodec.parse(Array(good.prefix(20 + 8 + 10)), id: 0x1234) == nil)
    #expect(ICMPCodec.parse(Array(echoReplyPacket(from: target, id: 0x1234, seq: 1).dropLast(1)), id: 0x1234) == nil)
    // Garbage: not IPv4.
    var bad = good
    bad[0] = 0x65
    #expect(ICMPCodec.parse(bad, id: 0x1234) == nil)
    // IHL smaller than 5.
    bad = good
    bad[0] = 0x44
    #expect(ICMPCodec.parse(bad, id: 0x1234) == nil)
}

// MARK: - Collector

private func seq(_ ttl: Int, round: Int = 0) -> UInt16 { UInt16(round * 64 + ttl) }

@Test func collectorStopsAtDestination() {
    var c = TraceCollector()
    for ttl in 1...30 { c.sent(ttl: ttl, round: 0, at: 0) }
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.1", seq: seq(1)), at: 0.010, target: "192.0.2.7")
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.2", seq: seq(2)), at: 0.020, target: "192.0.2.7")
    #expect(!c.isComplete())
    c.received(ICMPAnswer(kind: .echoReply, from: "192.0.2.7", seq: seq(3)), at: 0.030, target: "192.0.2.7")
    // Later TTLs also reach the target and answer; they must be dropped.
    c.received(ICMPAnswer(kind: .echoReply, from: "192.0.2.7", seq: seq(4)), at: 0.031, target: "192.0.2.7")
    #expect(c.isComplete())
    #expect(c.reached)
    let hops = c.hops()
    #expect(hops.map(\.ttl) == [1, 2, 3])
    #expect(hops.map(\.address) == ["203.0.113.1", "203.0.113.2", "192.0.2.7"])
    #expect(hops.map(\.isDestination) == [false, false, true])
}

@Test func collectorTreatsUnreachableFromTargetAsDestination() {
    var c = TraceCollector()
    for ttl in 1...5 { c.sent(ttl: ttl, round: 0, at: 0) }
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.1", seq: seq(1)), at: 0.01, target: "192.0.2.7")
    c.received(ICMPAnswer(kind: .unreachable, from: "192.0.2.7", seq: seq(2)), at: 0.02, target: "192.0.2.7")
    #expect(c.hops().map(\.isDestination) == [false, true])
    // An unreachable from some router in the middle is not the destination.
    var d = TraceCollector()
    d.sent(ttl: 1, round: 0, at: 0)
    d.received(ICMPAnswer(kind: .unreachable, from: "203.0.113.1", seq: seq(1)), at: 0.01, target: "192.0.2.7")
    #expect(!d.reached)
}

@Test func collectorKeepsMinRTT() {
    var c = TraceCollector()
    c.sent(ttl: 2, round: 0, at: 1.000)
    c.sent(ttl: 2, round: 1, at: 1.150)
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.2", seq: seq(2, round: 0)), at: 1.040, target: "192.0.2.7")
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.2", seq: seq(2, round: 1)), at: 1.162, target: "192.0.2.7")
    let rtt = c.hops().last?.rttMs
    #expect(rtt != nil && abs(rtt! - 12) < 0.001)
}

@Test func collectorDropsTrailingSilence() {
    var c = TraceCollector()
    for ttl in 1...6 { c.sent(ttl: ttl, round: 0, at: 0) }
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.1", seq: seq(1)), at: 0.01, target: "192.0.2.7")
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.3", seq: seq(3)), at: 0.03, target: "192.0.2.7")
    let hops = c.hops()
    // TTL 2 stays as a silent hop in the middle; everything after the last answer is gone.
    #expect(hops.map(\.ttl) == [1, 2, 3])
    #expect(hops[1].address == nil && hops[1].rttMs == nil)
}

@Test func collectorReportsUnansweredForSecondRound() {
    var c = TraceCollector(maxTTL: 6)
    for ttl in 1...6 { c.sent(ttl: ttl, round: 0, at: 0) }
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.1", seq: seq(1)), at: 0.01, target: "192.0.2.7")
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.3", seq: seq(3)), at: 0.03, target: "192.0.2.7")
    #expect(c.unansweredTTLs() == [2, 4, 5, 6])
    #expect(!c.isComplete())
    c.received(ICMPAnswer(kind: .echoReply, from: "192.0.2.7", seq: seq(5)), at: 0.05, target: "192.0.2.7")
    // Past the destination nothing is worth re-probing.
    #expect(c.unansweredTTLs() == [2, 4])
    c.sent(ttl: 2, round: 1, at: 0.15)
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.2", seq: seq(2, round: 1)), at: 0.2, target: "192.0.2.7")
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.4", seq: seq(4)), at: 0.04, target: "192.0.2.7")
    #expect(c.unansweredTTLs().isEmpty)
    #expect(c.isComplete())
}

@Test func collectorReportsUnreachedTarget() {
    var c = TraceCollector()
    for ttl in 1...30 { c.sent(ttl: ttl, round: 0, at: 0) }
    for ttl in 1...9 {
        c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.\(ttl)", seq: seq(ttl)),
                   at: Double(ttl) / 100, target: "192.0.2.7")
    }
    #expect(c.hops().count == 9)
    #expect(!c.reached)
    #expect(!c.isComplete())
}

@Test func collectorIgnoresAnswersToProbesItNeverSent() {
    var c = TraceCollector()
    c.sent(ttl: 1, round: 0, at: 0)
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.9", seq: seq(9)), at: 0.01, target: "192.0.2.7")
    c.received(ICMPAnswer(kind: .timeExceeded, from: "203.0.113.9", seq: 0), at: 0.01, target: "192.0.2.7")
    #expect(c.hops().isEmpty)
}
