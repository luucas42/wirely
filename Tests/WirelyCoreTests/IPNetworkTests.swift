import Testing
@testable import WirelyCore

@Test func endpointParsing() {
    let e = Endpoint("[fd00::1]:51820")
    #expect(e?.host == "fd00::1")
    #expect(e?.port == 51820)
    #expect(e?.description == "[fd00::1]:51820")
    #expect(Endpoint("1.2.3.4:51820")?.description == "1.2.3.4:51820")
    #expect(Endpoint("host-without-port") == nil)
    #expect(Endpoint("example.com:70000") == nil)
}

@Test func networkContains() {
    let half = IPNetwork("0.0.0.0/1")!
    #expect(half.contains(IPAddress("1.2.3.4")!))
    #expect(!half.contains(IPAddress("200.1.1.1")!))
    #expect(!IPNetwork("10.0.0.0/8")!.contains(IPAddress("fd00::1")!))
    #expect(IPNetwork("10.0.0.1/33") == nil)
    #expect(IPNetwork("fd00::/129") == nil)
    #expect(IPNetwork("10.0.0.1")?.prefixLength == 32)
    #expect(IPNetwork("fd00::1")?.prefixLength == 128)
    #expect(IPNetwork("10.0.0.0/24")?.description == "10.0.0.0/24")
}

@Test func addressRejectsScopeAndGarbage() {
    #expect(IPAddress("fe80::1%en0") == nil)
    #expect(IPAddress("not-an-ip") == nil)
    #expect(IPAddress("::1")?.family == .v6)
    #expect(IPAddress("1.2.3.4")?.bytes == [1, 2, 3, 4])
}
