import Testing
@testable import WirelyCore

/// Hand-built packets.
private func name(_ n: String) -> [UInt8] {
    var out: [UInt8] = []
    for label in n.split(separator: ".") { out.append(UInt8(label.utf8.count)); out += Array(label.utf8) }
    return out + [0]
}

private func header(id: UInt16 = 0x1234, flags: UInt16, qd: UInt16 = 1, an: UInt16 = 0, ns: UInt16 = 0, ar: UInt16 = 0) -> [UInt8] {
    [UInt8(id >> 8), UInt8(id & 0xFF), UInt8(flags >> 8), UInt8(flags & 0xFF),
     UInt8(qd >> 8), UInt8(qd & 0xFF), UInt8(an >> 8), UInt8(an & 0xFF),
     UInt8(ns >> 8), UInt8(ns & 0xFF), UInt8(ar >> 8), UInt8(ar & 0xFF)]
}

private func query(_ n: String, type: UInt16 = 1, flags: UInt16 = 0x0100) -> [UInt8] {
    header(flags: flags) + name(n) + [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
}

/// Answer record whose owner name is a pointer to offset 12 (the question name).
private func record(type: UInt16, rdata: [UInt8], owner: [UInt8] = [0xC0, 0x0C]) -> [UInt8] {
    owner + [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 0, 60, 0, UInt8(rdata.count)] + rdata
}

private let v6bytes: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

private func response(answers: [[UInt8]], type: UInt16 = 1) -> [UInt8] {
    header(flags: 0x8180, an: UInt16(answers.count)) + name("www.example.com") + [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        + answers.flatMap { $0 }
}

@Test func parseQueryReadsFirstQuestion() {
    let q = DNSMessage.parseQuery(query("WWW.Example.com", type: 28))
    #expect(q?.id == 0x1234)
    #expect(q?.name == "www.example.com")
    #expect(q?.type == 28)
    #expect(DNSMessage.parseQuery(query("example.com", type: 65))?.type == 65)
}

@Test func parseQueryRejectsBadInput() {
    #expect(DNSMessage.parseQuery([]) == nil)
    #expect(DNSMessage.parseQuery(Array(query("example.com").prefix(11))) == nil)
    #expect(DNSMessage.parseQuery(Array(query("example.com").dropLast())) == nil)          // missing class byte
    #expect(DNSMessage.parseQuery(Array(query("example.com").prefix(20))) == nil)          // label cut off
    #expect(DNSMessage.parseQuery(query("example.com", flags: 0x8100)) == nil)             // a response, not a query
    #expect(DNSMessage.parseQuery(header(flags: 0, qd: 0) + [0, 0, 1, 0, 0, 1]) == nil)    // no question
}

@Test func answerAddressesHandlesCompressionAndTypes() {
    let cname = record(type: 5, rdata: name("edge.example.net"))
    let a1 = record(type: 1, rdata: [198, 51, 100, 9])
    let a2 = record(type: 1, rdata: [203, 0, 113, 7])
    let aaaa = record(type: 28, rdata: v6bytes)
    let r = response(answers: [cname, a1, aaaa, a2])
    #expect(DNSMessage.answerAddresses(r) == [IPAddress("198.51.100.9")!, IPAddress("2001:db8::1")!, IPAddress("203.0.113.7")!])
}

@Test func answerAddressesIgnoresWrongLengthsAndOtherSections() {
    let bad4 = record(type: 1, rdata: [1, 2, 3])
    let bad16 = record(type: 28, rdata: [1, 2, 3, 4])
    let txt = record(type: 16, rdata: [3, 0x61, 0x62, 0x63])
    #expect(DNSMessage.answerAddresses(response(answers: [bad4, bad16, txt])) == [])
    // An A record in the authority section (ns = 1, an = 0) is not an answer.
    let ns = header(flags: 0x8180, ns: 1) + name("www.example.com") + [0, 1, 0, 1] + record(type: 1, rdata: [10, 0, 0, 1])
    #expect(DNSMessage.answerAddresses(ns) == [])
}

@Test func answerAddressesSkipsMultipleQuestions() {
    let a = record(type: 1, rdata: [198, 51, 100, 9], owner: name("other.example.org"))
    let packet = header(flags: 0x8180, qd: 2, an: 1) + name("www.example.com") + [0, 1, 0, 1]
        + name("other.example.org") + [0, 1, 0, 1] + a
    #expect(DNSMessage.answerAddresses(packet) == [IPAddress("198.51.100.9")!])
}

@Test func answerAddressesPointerLoopAndOverrun() {
    // Name that points at itself.
    let loop = header(flags: 0x8180, an: 1) + name("www.example.com") + [0, 1, 0, 1]
    let selfPointer = UInt8(loop.count)
    let looped = loop + [0xC0, selfPointer, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]
    #expect(DNSMessage.answerAddresses(looped) == [])
    // Two pointers pointing at each other.
    let n = loop.count
    let pingPong = loop + [0xC0, UInt8(n + 2), 0xC0, UInt8(n), 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]
    #expect(DNSMessage.answerAddresses(pingPong) == [])
    // Pointer past the end, and a reserved label type (0x40).
    #expect(DNSMessage.answerAddresses(loop + [0xC3, 0xFF, 0, 1, 0, 1]) == [])
    #expect(DNSMessage.answerAddresses(loop + [0x40, 0, 0, 1]) == [])
}

@Test func answerAddressesTruncatedGivesEmptyNeverCrashes() {
    let full = response(answers: [record(type: 1, rdata: [198, 51, 100, 9]), record(type: 28, rdata: v6bytes)])
    for cut in 0..<full.count {
        _ = DNSMessage.answerAddresses(Array(full.prefix(cut)))   // must not trap
    }
    #expect(DNSMessage.answerAddresses(Array(full.dropLast())) == [])
    // Declared more answers than present.
    var lying = full
    lying[7] = 9
    #expect(DNSMessage.answerAddresses(lying) == [])
    // Garbage.
    #expect(DNSMessage.answerAddresses([UInt8](repeating: 0xFF, count: 64)) == [])
}

@Test func tooManyJumpsRejected() {
    // 17 chained pointers ending in a real name.
    var packet = header(flags: 0x8180, an: 1) + name("www.example.com") + [0, 1, 0, 1]
    let base = packet.count
    for i in 0..<17 { packet += [0xC0, UInt8(base + (i + 1) * 2)] }
    packet += [0]
    packet += [0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]
    // Owner name is the first pointer of the chain; the chain has 17 hops then a root name.
    let owner = packet
    #expect(DNSMessage.answerAddresses(owner).isEmpty)
}

@Test func emptyResponseMirrorsQuery() throws {
    let q = query("www.example.com", type: 28)
    let r = try #require(DNSMessage.emptyResponse(to: q))
    #expect(Array(r[0..<2]) == [0x12, 0x34])
    #expect(r[2] == 0x81)                                // QR, RD
    #expect(r[3] == 0x80)                                // RA, RCODE 0
    #expect(Array(r[4..<12]) == [0, 1, 0, 0, 0, 0, 0, 0])
    #expect(Array(r[12...]) == Array(q[12...]))
    // Without RD the bit stays clear; extra additional records (EDNS) are dropped.
    var noRD = query("example.com", flags: 0)
    noRD[11] = 1
    noRD += [0, 0, 41, 0x10, 0, 0, 0, 0, 0, 0, 0]
    let r2 = try #require(DNSMessage.emptyResponse(to: noRD))
    #expect(r2[2] == 0x80)
    #expect(r2.count == 12 + name("example.com").count + 4)
    #expect(DNSMessage.answerAddresses(r) == [])
    #expect(DNSMessage.parseQuery(r) == nil)             // it is a response
}

@Test func servfailSetsRcode() throws {
    let r = try #require(DNSMessage.servfail(to: query("example.com")))
    #expect(r[3] == 0x82)
    #expect(r[2] & 0x80 != 0)
    #expect(DNSMessage.servfail(to: [1, 2, 3]) == nil)
    #expect(DNSMessage.emptyResponse(to: query("example.com", flags: 0x8100)) == nil)
    #expect(DNSMessage.emptyResponse(to: Array(query("example.com").prefix(18))) == nil)
}
