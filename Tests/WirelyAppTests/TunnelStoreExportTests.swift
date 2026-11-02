import Testing
import Foundation
@testable import WirelyApp

private let sampleConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
"""

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("wirely-export-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
struct TunnelStoreExportTests {
    @Test func exportWritesTextWith0600() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TunnelStore(directory: dir.appendingPathComponent("store"))
        let tunnel = try store.add(name: "demo", text: sampleConfig)
        let out = dir.appendingPathComponent("out.conf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try store.export(tunnel.name, to: out)

        #expect(try String(contentsOf: out, encoding: .utf8) == sampleConfig)
        let perms = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func exportUnknownThrows() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TunnelStore(directory: dir.appendingPathComponent("store"))
        #expect(throws: StoreError.self) {
            try store.export("nope", to: dir.appendingPathComponent("x.conf"))
        }
    }
}
