import Testing
import Foundation
import WirelyCore
@testable import WirelyHelperKit

private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wirely-test-" + UUID().uuidString
    return d
}

@Test func fileStateStoreRoundTrip() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/sub/state.json"
    let store = FileStateStore(path: path)
    #expect(store.load() == nil)

    let state = PersistedState(
        tunnelName: "office", interface: "utun7", wireguardPID: 123,
        endpointRoutes: [], dnsBackups: [], dnsServers: [IPAddress("1.1.1.1")!],
        dnsSearch: ["example.com"], connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
        ignoredKeys: ["PostUp"])
    try store.save(state)
    #expect(store.load() == state)

    var attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    attrs = try FileManager.default.attributesOfItem(atPath: dir + "/sub")
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    store.clear()
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(store.load() == nil)
}

@Test func fileStateStoreCorruptFileLoadsNil() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: URL(fileURLWithPath: dir + "/state.json"))
    #expect(FileStateStore(path: dir + "/state.json").load() == nil)
}
