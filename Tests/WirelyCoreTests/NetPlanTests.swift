import Testing
import Foundation
@testable import WirelyCore

private let zeroKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

private func config(allowed1: String, allowed2: String? = nil, tableOff: Bool = false) throws -> TunnelConfig {
    var text = "[Interface]\nPrivateKey = \(zeroKey)\nAddress = 10.0.0.2/32\n"
    if tableOff { text += "Table = off\n" }
    text += "[Peer]\nPublicKey = \(zeroKey)\nAllowedIPs = \(allowed1)\nEndpoint = 203.0.113.5:51820\n"
    if let a2 = allowed2 {
        text += "[Peer]\nPublicKey = \(zeroKey)\nAllowedIPs = \(a2)\n"
    }
    return try TunnelConfig.parse(text)
}

private func net(_ s: String) -> IPNetwork { IPNetwork(s)! }
private func ip(_ s: String) -> IPAddress { IPAddress(s)! }

@Test func interfaceCommandsOrder() {
    let cmds = NetPlan.interfaceCommands(iface: "utun5", addresses: [net("10.0.0.2/32"), net("fd00::2/128")], mtu: 1412)
    #expect(cmds == [
        NetCommand("/sbin/ifconfig", ["utun5", "inet", "10.0.0.2/32", "10.0.0.2", "alias"]),
        NetCommand("/sbin/ifconfig", ["utun5", "inet6", "fd00::2/128", "alias"]),
        NetCommand("/sbin/ifconfig", ["utun5", "mtu", "1412"]),
        NetCommand("/sbin/ifconfig", ["utun5", "up"]),
    ])
}

@Test func routeTargetsSplitsDefault() throws {
    let c = try config(allowed1: "0.0.0.0/0, ::/0, 10.0.0.0/8", allowed2: "10.0.0.0/8")
    #expect(NetPlan.routeTargets(c) == [net("0.0.0.0/1"), net("128.0.0.0/1"), net("::/1"), net("8000::/1"), net("10.0.0.0/8")])
    let off = try config(allowed1: "0.0.0.0/0", tableOff: true)
    #expect(NetPlan.routeTargets(off) == [])
}

@Test func routeAddCommandsShape() {
    let cmds = NetPlan.routeAddCommands(iface: "utun5", targets: [net("10.0.0.0/8"), net("::/1")],
                                         addresses: [net("10.67.0.2/32"), net("fd00::2/128")])
    #expect(cmds == [
        NetCommand("/sbin/route", ["-q", "-n", "add", "-inet", "10.0.0.0/8", "-interface", "utun5"]),
        NetCommand("/sbin/route", ["-q", "-n", "add", "-inet6", "::/1", "-interface", "utun5"]),
    ])
}

@Test func routeAddRejectsFamilyWithoutAddress() {
    let targets = [net("0.0.0.0/1"), net("128.0.0.0/1"), net("::/1"), net("8000::/1")]
    let r = "/sbin/route"
    let v4Only = NetPlan.routeAddCommands(iface: "utun7", targets: targets, addresses: [net("10.67.0.2/32")])
    #expect(v4Only == [
        NetCommand(r, ["-q", "-n", "add", "-inet", "0.0.0.0/1", "-interface", "utun7"]),
        NetCommand(r, ["-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", "utun7"]),
        NetCommand(r, ["-q", "-n", "add", "-inet6", "::/1", "::1", "-reject"]),
        NetCommand(r, ["-q", "-n", "add", "-inet6", "8000::/1", "::1", "-reject"]),
    ])
    #expect(NetPlan.rejectedTargets(targets, addresses: [net("10.67.0.2/32")]) == [net("::/1"), net("8000::/1")])
    let dual = NetPlan.routeAddCommands(iface: "utun7", targets: targets,
                                        addresses: [net("10.67.0.2/32"), net("fd00::2/128")])
    #expect(dual.count == 4)
    #expect(dual.allSatisfy { $0.args.suffix(2) == ["-interface", "utun7"] })
    #expect(NetPlan.rejectedTargets(targets, addresses: [net("10.67.0.2/32"), net("fd00::2/128")]).isEmpty)
    let v6Only = NetPlan.routeAddCommands(iface: "utun7", targets: [net("0.0.0.0/1")], addresses: [net("fd00::2/128")])
    #expect(v6Only == [NetCommand(r, ["-q", "-n", "add", "-inet", "0.0.0.0/1", "127.0.0.1", "-reject"])])
}

@Test func routeDeleteShape() {
    #expect(NetPlan.routeDelete(net("::/1")) == NetCommand("/sbin/route", ["-q", "-n", "delete", "-inet6", "::/1"]))
    #expect(NetPlan.routeDelete(net("0.0.0.0/1")) == NetCommand("/sbin/route", ["-q", "-n", "delete", "-inet", "0.0.0.0/1"]))
}

@Test func endpointBypassOnlyWhenCovered() {
    let full = [net("0.0.0.0/1"), net("128.0.0.0/1")]
    #expect(NetPlan.endpointNeedsBypass(ip("203.0.113.5"), targets: full))
    #expect(!NetPlan.endpointNeedsBypass(ip("203.0.113.5"), targets: [net("10.0.0.0/8")]))
}

@Test func endpointRouteUsesGateway() {
    let r = DefaultRoutes(v4Gateway: "192.168.1.1", v4Interface: "en0", v6Gateway: nil, v6Interface: nil)
    #expect(NetPlan.endpointRouteAdd(ip("203.0.113.5"), routes: r)
        == NetCommand("/sbin/route", ["-q", "-n", "add", "-inet", "203.0.113.5", "-gateway", "192.168.1.1"]))
}

@Test func endpointRouteUsesInterfaceForLinkGateway() {
    let r = DefaultRoutes(v4Gateway: nil, v4Interface: "ppp0", v6Gateway: nil, v6Interface: nil)
    #expect(NetPlan.endpointRouteAdd(ip("203.0.113.5"), routes: r)
        == NetCommand("/sbin/route", ["-q", "-n", "add", "-inet", "203.0.113.5", "-interface", "ppp0"]))
}

@Test func endpointRouteBlackholeWhenOffline() {
    let r = DefaultRoutes(v4Gateway: nil, v4Interface: nil, v6Gateway: nil, v6Interface: nil)
    #expect(NetPlan.endpointRouteAdd(ip("203.0.113.5"), routes: r)
        == NetCommand("/sbin/route", ["-q", "-n", "add", "-inet", "203.0.113.5", "127.0.0.1", "-blackhole"]))
    #expect(NetPlan.endpointRouteAdd(ip("2001:db8::1"), routes: r)
        == NetCommand("/sbin/route", ["-q", "-n", "add", "-inet6", "2001:db8::1", "::1", "-blackhole"]))
}

@Test func endpointRouteV6Gateway() {
    let r = DefaultRoutes(v4Gateway: "192.168.1.1", v4Interface: "en0", v6Gateway: "fe80::1%en0", v6Interface: "en0")
    #expect(NetPlan.endpointRouteAdd(ip("2001:db8::1"), routes: r)
        == NetCommand("/sbin/route", ["-q", "-n", "add", "-inet6", "2001:db8::1", "-gateway", "fe80::1%en0"]))
}

@Test func endpointRouteDeleteShape() {
    #expect(NetPlan.endpointRouteDelete(ip("203.0.113.5"))
        == NetCommand("/sbin/route", ["-q", "-n", "delete", "-inet", "203.0.113.5"]))
    #expect(NetPlan.endpointRouteDelete(ip("2001:db8::1"))
        == NetCommand("/sbin/route", ["-q", "-n", "delete", "-inet6", "2001:db8::1"]))
}

@Test func parseDefaultRouteSkipsUtun() {
    let sample = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            link#22            UCSg                utun4
    default            192.168.1.1        UGScg                 en0
    127                127.0.0.1          UCS                   lo0
    """
    let r = NetPlan.parseDefaultRoute(netstat: sample)
    #expect(r.gateway == "192.168.1.1")
    #expect(r.interface == "en0")
    let ppp = NetPlan.parseDefaultRoute(netstat: "default            link#5             UCSg                  ppp0\n")
    #expect(ppp.gateway == nil)
    #expect(ppp.interface == "ppp0")
    let none = NetPlan.parseDefaultRoute(netstat: "")
    #expect(none.gateway == nil && none.interface == nil)
}

@Test func parseMTUAndTunnelMTU() {
    #expect(NetPlan.parseMTU(ifconfig: "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1492\n\tether aa:bb:cc:dd:ee:ff\n") == 1492)
    #expect(NetPlan.parseMTU(ifconfig: "nothing here") == nil)
    #expect(NetPlan.tunnelMTU(configured: nil, physicalMTU: 1492) == 1412)
    #expect(NetPlan.tunnelMTU(configured: nil, physicalMTU: nil) == 1420)
    #expect(NetPlan.tunnelMTU(configured: 1280, physicalMTU: 1492) == 1280)
}

@Test func netstatAndIfconfigShowCommands() {
    #expect(NetPlan.netstatCommand(.v4) == NetCommand("/usr/sbin/netstat", ["-nr", "-f", "inet"]))
    #expect(NetPlan.netstatCommand(.v6) == NetCommand("/usr/sbin/netstat", ["-nr", "-f", "inet6"]))
    #expect(NetPlan.ifconfigShow("en0") == NetCommand("/sbin/ifconfig", ["en0"]))
    #expect(NetCommand("/sbin/route", ["-q", "x"]).description == "/sbin/route -q x")
}

@Test func routeGetAndParseInterface() {
    #expect(NetPlan.routeGet(ip("203.0.113.5")) == NetCommand("/sbin/route", ["-n", "get", "-inet", "203.0.113.5"]))
    let sample = """
       route to: 203.0.113.5
    destination: 203.0.113.5
        gateway: 192.168.1.1
      interface: en0
          flags: <UP,GATEWAY,HOST,DONE,WASCLONED,IFSCOPE,IFREF>
    """
    #expect(NetPlan.parseRouteGetInterface(sample) == "en0")
    #expect(NetPlan.parseRouteGetInterface("route: writing to routing socket: not in table") == nil)
}
