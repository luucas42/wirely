import Foundation
import Testing
@testable import WirelyCore

let privB64 = "TUs1G5dtbPrNOrSqmV/Hddlk1MMbHw63dD4eIUlODZU="
let pubB64 = "5eOWMvp44rKHfFuhZU//t2b2q6SblullXT2n4eeapKw="
let pskB64 = "7jxjL1HzcfWMfAwlyp7JYxH3VK13l+A8QCzdXHfYpcY="
let short31B64 = "qIJKnikU/XnxPYuvRxwwK9GFAWvyOG7ipc+04Zc+NA=="

let fullConfigLF = """
[Interface]
PrivateKey = \(privB64)
Address = 10.8.0.2/32, fd00::2/128
DNS = 1.1.1.1, corp.local
MTU = 1380

[Peer]
PublicKey = \(pubB64)
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"""

let fullConfigCRLF = """
[interface]
privatekey = \(privB64)
Address = 10.8.0.2/32 # home
ADDRESS = fd00::2/128
dns = 1.1.1.1, corp.local
mtu = 1380

[PEER]
publickey = \(pubB64)
endpoint = vpn.example.com:51820
ALLOWEDIPS = 0.0.0.0/0, ::/0
persistentkeepalive = 25 # keep
""".replacingOccurrences(of: "\n", with: "\r\n")

@Test func parsesFullConfig() throws {
    let c = try TunnelConfig.parse(fullConfigLF)
    #expect(c.interface.privateKey == Data(base64Encoded: privB64))
    #expect(c.interface.addresses == [IPNetwork("10.8.0.2/32")!, IPNetwork("fd00::2/128")!])
    #expect(c.interface.dnsServers == [IPAddress("1.1.1.1")!])
    #expect(c.interface.dnsSearchDomains == ["corp.local"])
    #expect(c.interface.mtu == 1380)
    #expect(c.interface.tableOff == false)
    #expect(c.peers.count == 1)
    let p = c.peers[0]
    #expect(p.publicKey == Data(base64Encoded: pubB64))
    #expect(p.endpoint == Endpoint(host: "vpn.example.com", port: 51820))
    #expect(p.allowedIPs == [IPNetwork("0.0.0.0/0")!, IPNetwork("::/0")!])
    #expect(p.persistentKeepalive == 25)
    #expect(c.routesAllTraffic == true)
}

@Test func parsesCRLFAndCaseAndComments() throws {
    let a = try TunnelConfig.parse(fullConfigLF)
    let b = try TunnelConfig.parse(fullConfigCRLF)
    #expect(a == b)
}

@Test func mergesRepeatedLists() throws {
    let text = """
    [Interface]
    PrivateKey = \(privB64)
    [Peer]
    PublicKey = \(pubB64)
    AllowedIPs = 10.0.0.0/8
    AllowedIPs = 192.168.0.0/16
    """
    let c = try TunnelConfig.parse(text)
    #expect(c.peers[0].allowedIPs == [IPNetwork("10.0.0.0/8")!, IPNetwork("192.168.0.0/16")!])
    #expect(c.routesAllTraffic == false)
}

@Test func rejectsAmneziaKeys() {
    let text = """
    [Interface]
    PrivateKey = \(privB64)
    Jc = 4
    [Peer]
    PublicKey = \(pubB64)
    """
    #expect(throws: ConfigError.unsupportedKey("Jc")) { try TunnelConfig.parse(text) }
    #expect(ConfigError.unsupportedKey("Jc").errorDescription?.contains("Jc") == true)
}

@Test func collectsIgnoredScriptKeys() throws {
    let text = """
    [Interface]
    PrivateKey = \(privB64)
    PostUp = iptables -A FORWARD -i %i -j ACCEPT
    PostUp = iptables -t nat -A POSTROUTING -j MASQUERADE
    SaveConfig = true
    [Peer]
    PublicKey = \(pubB64)
    """
    let c = try TunnelConfig.parse(text)
    #expect(c.ignoredKeys == ["PostUp", "SaveConfig"])
}

@Test func rejectsBadKeys() {
    let text = """
    [Interface]
    PrivateKey = \(short31B64)
    [Peer]
    PublicKey = \(pubB64)
    """
    #expect(throws: ConfigError.invalidKey(field: "PrivateKey")) { try TunnelConfig.parse(text) }
}

@Test func requiresInterfaceAndPeer() {
    #expect(throws: ConfigError.missingInterfaceSection) {
        try TunnelConfig.parse("[Peer]\nPublicKey = \(pubB64)\n")
    }
    #expect(throws: ConfigError.noPeers) {
        try TunnelConfig.parse("[Interface]\nPrivateKey = \(privB64)\n")
    }
    #expect(throws: ConfigError.missingPrivateKey) {
        try TunnelConfig.parse("[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = \(pubB64)\n")
    }
}

@Test func tableOffDisablesRoutes() throws {
    let base = "[Interface]\nPrivateKey = \(privB64)\n"
    let peer = "\n[Peer]\nPublicKey = \(pubB64)\n"
    let off = try TunnelConfig.parse(base + "Table = off" + peer)
    #expect(off.interface.tableOff == true)
    let auto = try TunnelConfig.parse(base + "Table = auto" + peer)
    #expect(auto.interface.tableOff == false)
    #expect(throws: ConfigError.invalidValue(key: "Table", value: "1234")) {
        try TunnelConfig.parse(base + "Table = 1234" + peer)
    }
}

@Test func syntaxErrors() {
    #expect(throws: ConfigError.syntax(line: 2)) {
        try TunnelConfig.parse("[Interface]\nbogus line\n")
    }
    #expect(throws: ConfigError.unknownSection("Foo")) {
        try TunnelConfig.parse("[Foo]\n")
    }
}

@Test func derivesInterfacePublicKey() throws {
    let c = try TunnelConfig.parse(fullConfigLF)
    #expect(c.interfacePublicKey.count == 32)
    #expect(c.interfacePublicKey != c.interface.privateKey)
}
