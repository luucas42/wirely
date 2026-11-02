import Testing
@testable import WirelyApp

private let sample = """
? (192.168.1.1) at a4:5e:60:0:0:1 on en0 ifscope [ethernet]
? (192.168.1.6) at (incomplete) on en0 ifscope [ethernet]
? (192.168.1.20) at 2:0:0:0:0:20 on en0 ifscope [ethernet]
? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
? (10.67.0.1) at (incomplete) on utun10 ifscope [ipsec]
? (10.0.0.9) at a4:5e:60:0:0:9 on en5 ifscope [ethernet]
? (192.168.1.31) at a4:5e:60:00:00:31 on en0 ifscope [ethernet]
"""

struct ARPTableTests {
    @Test func keepsCompleteUnicastEntriesOnTheInterface() {
        let rows = ARPTable.parse(sample, interface: "en0")
        #expect(rows.map(\.ip) == ["192.168.1.1", "192.168.1.20", "192.168.1.31"])
        #expect(rows[0].mac.description == "a4:5e:60:00:00:01")
    }

    @Test func dropsIncompleteBroadcastMulticastAndOtherInterfaces() {
        let ips = ARPTable.parse(sample, interface: "en0").map(\.ip)
        #expect(!ips.contains("192.168.1.6"))
        #expect(!ips.contains("192.168.1.255"))
        #expect(!ips.contains("224.0.0.251"))
        #expect(!ips.contains("10.0.0.9"))
    }

    @Test func otherInterfaceSelectsItsOwnRows() {
        let rows = ARPTable.parse(sample, interface: "en5")
        #expect(rows.map(\.ip) == ["10.0.0.9"])
    }

    @Test func multicastAddressWithUnicastLookingMACIsDropped() {
        let out = "? (239.255.255.250) at 0:11:22:33:44:56 on en0 ifscope [ethernet]"
        #expect(ARPTable.parse(out, interface: "en0").isEmpty)
    }

    @Test func garbageAndEmptyInputGiveNothing() {
        #expect(ARPTable.parse("", interface: "en0").isEmpty)
        #expect(ARPTable.parse("arp: nothing here\n\n? (bad) at zz on en0", interface: "en0").isEmpty)
    }
}
