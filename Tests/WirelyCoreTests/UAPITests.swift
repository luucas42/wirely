import Foundation
import Testing
@testable import WirelyCore

@Test func uapiSetCommandExactText() throws {
    let config = TunnelConfig(
        interface: InterfaceSection(
            privateKey: Data(base64Encoded: privB64)!, listenPort: 51820,
            addresses: [IPNetwork("10.8.0.2/32")!], dnsServers: [], dnsSearchDomains: [],
            mtu: nil, tableOff: false),
        peers: [PeerSection(
            publicKey: Data(base64Encoded: pubB64)!, presharedKey: Data(base64Encoded: pskB64)!,
            endpoint: Endpoint(host: "vpn.example.com", port: 51820),
            allowedIPs: [IPNetwork("0.0.0.0/0")!, IPNetwork("fd00::/64")!],
            persistentKeepalive: 25)],
        ignoredKeys: [])
    let expected = """
    set=1
    private_key=4d4b351b976d6cfacd3ab4aa995fc775d964d4c31b1f0eb7743e1e21494e0d95
    listen_port=51820
    replace_peers=true
    public_key=e5e39632fa78e2b2877c5ba1654fffb766f6aba49b96e9655d3da7e1e79aa4ac
    preshared_key=ee3c632f51f371f58c7c0c25ca9ec96311f754ad7797e03c402cdd5c77d8a5c6
    endpoint=203.0.113.5:51820
    persistent_keepalive_interval=25
    replace_allowed_ips=true
    allowed_ip=0.0.0.0/0
    allowed_ip=fd00::/64


    """
    #expect(UAPI.setCommand(config, resolvedEndpoints: ["203.0.113.5:51820"]) == expected)
    #expect(expected.hasSuffix("\n\n"))
}

@Test func uapiParseGet() throws {
    let response = """
    private_key=00
    listen_port=51820
    public_key=aa
    endpoint=203.0.113.5:51820
    last_handshake_time_sec=1700000000
    last_handshake_time_nsec=500000000
    tx_bytes=100
    rx_bytes=200
    allowed_ip=0.0.0.0/0
    public_key=bb
    last_handshake_time_sec=0
    last_handshake_time_nsec=0
    tx_bytes=1
    rx_bytes=2
    unknown_key=zzz
    errno=0


    """
    let snap = try UAPI.parseGet(response)
    #expect(snap.peers.count == 2)
    #expect(snap.peers[0].publicKey == Data(hex: "aa"))
    #expect(snap.peers[0].endpoint == "203.0.113.5:51820")
    #expect(snap.peers[0].lastHandshake == Date(timeIntervalSince1970: 1700000000.5))
    #expect(snap.peers[1].lastHandshake == nil)
    #expect(snap.peers[1].endpoint == nil)
    #expect(snap.totalRx == 202)
    #expect(snap.totalTx == 101)
    #expect(snap.latestHandshake == snap.peers[0].lastHandshake)
}

@Test func uapiErrno() throws {
    try UAPI.checkErrno("errno=0\n\n")
    #expect(throws: UAPIError.errno(22)) { try UAPI.checkErrno("errno=22\n\n") }
    #expect(throws: UAPIError.malformed("missing errno")) { try UAPI.checkErrno("") }
}

@Test func hexRoundTrip() {
    let d = Data([0x00, 0xab, 0xff])
    #expect(d.hexString == "00abff")
    #expect(Data(hex: "00abff") == d)
    #expect(Data(hex: "0") == nil)
    #expect(Data(hex: "zz") == nil)
}
