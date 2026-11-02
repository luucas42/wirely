import Testing
@testable import WirelyApp

struct SubnetTests {
    @Test func slash24SkipsNetworkBroadcastAndOwn() {
        let hosts = Subnet.hosts(address: "192.168.1.10", prefix: 24)
        #expect(hosts.count == 253)
        #expect(hosts.first == "192.168.1.1")
        #expect(hosts.last == "192.168.1.254")
        #expect(!hosts.contains("192.168.1.10"))
        #expect(!hosts.contains("192.168.1.0"))
        #expect(!hosts.contains("192.168.1.255"))
    }

    @Test func slash25UsesOnlyItsHalf() {
        let hosts = Subnet.hosts(address: "192.168.1.200", prefix: 25)
        #expect(hosts.first == "192.168.1.129")
        #expect(hosts.last == "192.168.1.254")
        #expect(hosts.count == 125)
    }

    @Test func slash30HasOneOtherHost() {
        #expect(Subnet.hosts(address: "192.168.1.1", prefix: 30) == ["192.168.1.2"])
    }

    @Test func largerSubnetsAreCappedToOurSlash24() {
        let hosts = Subnet.hosts(address: "10.20.30.40", prefix: 16)
        #expect(hosts.count == 253)
        #expect(hosts.first == "10.20.30.1")
        #expect(hosts.last == "10.20.30.254")
        #expect(Subnet.hosts(address: "10.20.30.40", prefix: 8) == hosts)
    }

    @Test func tinyAndInvalidInputsGiveNothing() {
        #expect(Subnet.hosts(address: "192.168.1.1", prefix: 31).isEmpty)
        #expect(Subnet.hosts(address: "192.168.1.1", prefix: 32).isEmpty)
        #expect(Subnet.hosts(address: "nope", prefix: 24).isEmpty)
        #expect(Subnet.hosts(address: "192.168.1.1", prefix: 40).isEmpty)
    }
}
