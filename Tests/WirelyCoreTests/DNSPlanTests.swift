import Testing
import Foundation
@testable import WirelyCore

@Test func parsesHardwareServicesOnly() {
    let out = """
    An asterisk (*) denotes that a network service is disabled.
    (1) AX88179A
    (Hardware Port: AX88179A, Device: en8)

    (2) USB 10/100 LAN
    (Hardware Port: USB 10/100 LAN, Device: en11)

    (*) Thunderbolt Bridge
    (Hardware Port: Thunderbolt Bridge, Device: bridge0)

    (4) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (6) Tailscale
    (Hardware Port: io.tailscale.ipn.macos, Device: )

    (9) Example VPN
    (Hardware Port: com.wireguard.macos, Device: )
    """
    #expect(DNSPlan.parseHardwareServices(out) == ["AX88179A", "USB 10/100 LAN", "Wi-Fi"])
    let paren = "(3) My (Office) LAN\n(Hardware Port: Ethernet, Device: en5)\n"
    #expect(DNSPlan.parseHardwareServices(paren) == ["My (Office) LAN"])
}

@Test func dnsParsing() {
    #expect(DNSPlan.parseList("There aren't any DNS Servers set on Wi-Fi.\n") == [])
    #expect(DNSPlan.parseList("1.1.1.1\n 8.8.8.8 \n\n") == ["1.1.1.1", "8.8.8.8"])
    #expect(DNSPlan.listServiceOrder == NetCommand("/usr/sbin/networksetup", ["-listnetworkserviceorder"]))
    #expect(DNSPlan.getServers("Wi-Fi") == NetCommand("/usr/sbin/networksetup", ["-getdnsservers", "Wi-Fi"]))
    #expect(DNSPlan.getSearchDomains("Wi-Fi") == NetCommand("/usr/sbin/networksetup", ["-getsearchdomains", "Wi-Fi"]))
}

@Test func dnsApplyAndRestore() {
    let a = DNSPlan.apply(service: "Wi-Fi", servers: [IPAddress("10.0.0.1")!, IPAddress("fd00::1")!], search: [])
    #expect(a == [
        NetCommand("/usr/sbin/networksetup", ["-setdnsservers", "Wi-Fi", "10.0.0.1", "fd00::1"]),
        NetCommand("/usr/sbin/networksetup", ["-setsearchdomains", "Wi-Fi", "Empty"]),
    ])
    let b = DNSPlan.apply(service: "Wi-Fi", servers: [IPAddress("10.0.0.1")!], search: ["corp.test", "lan"])
    #expect(b.last == NetCommand("/usr/sbin/networksetup", ["-setsearchdomains", "Wi-Fi", "corp.test", "lan"]))
    let r = DNSPlan.restore(DNSBackup(service: "Wi-Fi", servers: [], searchDomains: []))
    #expect(r == [
        NetCommand("/usr/sbin/networksetup", ["-setdnsservers", "Wi-Fi", "Empty"]),
        NetCommand("/usr/sbin/networksetup", ["-setsearchdomains", "Wi-Fi", "Empty"]),
    ])
}
