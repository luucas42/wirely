import Testing
@testable import WirelyHelperKit
@testable import WirelyCore

private func ip(_ s: String) -> IPAddress { IPAddress(s)! }

@Test func chooseManualWinsOverDHCP() {
    #expect(SystemDNSUpstreams.choose(manual: ["198.51.100.53", "198.51.100.54"], dhcp: ["192.0.2.1"])
            == [ip("198.51.100.53"), ip("198.51.100.54")])
}

@Test func chooseFallsBackToDHCPWhenManualEmptyOrLoopback() {
    #expect(SystemDNSUpstreams.choose(manual: [], dhcp: ["192.0.2.1", "2001:db8::1"]) == [ip("192.0.2.1"), ip("2001:db8::1")])
    #expect(SystemDNSUpstreams.choose(manual: ["127.0.0.1"], dhcp: ["192.0.2.1"]) == [ip("192.0.2.1")])
    #expect(SystemDNSUpstreams.choose(manual: ["not an ip"], dhcp: ["192.0.2.1"]) == [ip("192.0.2.1")])
}

@Test func chooseNeverReturnsLoopback() {
    #expect(SystemDNSUpstreams.choose(manual: ["127.0.0.1", "198.51.100.53", "::1"], dhcp: []) == [ip("198.51.100.53")])
    #expect(SystemDNSUpstreams.choose(manual: ["127.0.0.53"], dhcp: ["::1", "127.0.0.1", "0.0.0.0", "::ffff:127.0.0.1"]).isEmpty)
    #expect(SystemDNSUpstreams.choose(manual: ["192.0.2.1", "192.0.2.1"], dhcp: []) == [ip("192.0.2.1")])
}
