import Testing
import Foundation
@testable import WirelyApp

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let t1 = t0.addingTimeInterval(300)
private let t2 = t0.addingTimeInterval(600)
private let net = "a4:5e:60:00:00:01"

private func device(_ last: Int, name: String = "Unknown device", router: Bool = false, thisMac: Bool = false) -> LANDevice {
    LANDevice(ip: "192.168.1.\(last)", mac: MACAddress("a4:5e:60:00:00:\(String(last, radix: 16))")!, name: name,
              kind: .unknown, isRouter: router, isThisMac: thisMac)
}

struct DeviceStoreTests {
    @Test func firstScanSeedsSilently() {
        var store = DeviceStore()
        let r = store.merge(scan: [device(1, router: true), device(2), device(3)], network: net, now: t0)
        #expect(r.newOnes.isEmpty)
        #expect(r.devices.count == 3)
        #expect(r.devices.allSatisfy { !$0.isNew })
        #expect(r.devices.allSatisfy { $0.firstSeen == t0 && $0.lastSeen == t0 })
    }

    @Test func emptyFirstScanDoesNotSeed() {
        var store = DeviceStore()
        _ = store.merge(scan: [], network: net, now: t0)
        let r = store.merge(scan: [device(2)], network: net, now: t1)
        #expect(r.newOnes.isEmpty)   // this one is the seeding scan
    }

    @Test func laterUnknownDeviceIsNewExactlyOnce() {
        var store = DeviceStore()
        _ = store.merge(scan: [device(1), device(2)], network: net, now: t0)
        let second = store.merge(scan: [device(1), device(2), device(9)], network: net, now: t1)
        #expect(second.newOnes.map(\.ip) == ["192.168.1.9"])
        #expect(second.devices.first { $0.ip == "192.168.1.9" }?.isNew == true)
        let third = store.merge(scan: [device(1), device(2), device(9)], network: net, now: t2)
        #expect(third.newOnes.isEmpty)
        #expect(third.devices.first { $0.ip == "192.168.1.9" }?.isNew == true)   // still badged until seen
    }

    @Test func keepsFirstSeenAndUpdatesLastSeen() {
        var store = DeviceStore()
        _ = store.merge(scan: [device(2)], network: net, now: t0)
        let r = store.merge(scan: [device(2)], network: net, now: t2)
        #expect(r.devices[0].firstSeen == t0)
        #expect(r.devices[0].lastSeen == t2)
    }

    @Test func markSeenClearsTheBadge() {
        var store = DeviceStore()
        _ = store.merge(scan: [device(1)], network: net, now: t0)
        _ = store.merge(scan: [device(1), device(9)], network: net, now: t1)
        store.markSeen(mac: device(9).mac, network: net)
        let r = store.merge(scan: [device(1), device(9)], network: net, now: t2)
        #expect(r.devices.allSatisfy { !$0.isNew })
        #expect(r.newOnes.isEmpty)
    }

    @Test func renameOverridesNameAndPersists() {
        var store = DeviceStore()
        _ = store.merge(scan: [device(2, name: "Unknown device")], network: net, now: t0)
        store.rename(mac: device(2).mac, network: net, to: "  Living Room TV ")
        #expect(store.merge(scan: [device(2)], network: net, now: t1).devices[0].name == "Living Room TV")
        store.rename(mac: device(2).mac, network: net, to: "   ")
        #expect(store.merge(scan: [device(2, name: "Pixel 8")], network: net, now: t2).devices[0].name == "Pixel 8")
    }

    @Test func networksAreIndependent() {
        var store = DeviceStore()
        _ = store.merge(scan: [device(1)], network: net, now: t0)
        let other = store.merge(scan: [device(1), device(7)], network: "other", now: t1)
        #expect(other.newOnes.isEmpty)   // "other" is seeded on its own
    }

    @Test func thisMacAndRouterAreNeverNew() {
        var store = DeviceStore()
        _ = store.merge(scan: [device(2)], network: net, now: t0)
        let r = store.merge(scan: [device(2), device(1, router: true), device(10, thisMac: true)], network: net, now: t1)
        #expect(r.newOnes.isEmpty)
        #expect(r.devices.allSatisfy { !$0.isNew })
    }

    @Test func codableRoundTrip() throws {
        var store = DeviceStore()
        _ = store.merge(scan: [device(1)], network: net, now: t0)
        _ = store.merge(scan: [device(1), device(9)], network: net, now: t1)
        store.rename(mac: device(9).mac, network: net, to: "Pixel 8")
        let data = try JSONEncoder().encode(store)
        #expect(try JSONDecoder().decode(DeviceStore.self, from: data) == store)
    }
}

struct DeviceStoreFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wirely-devices-\(UUID().uuidString)")
            .appendingPathComponent("devices.json")
    }

    @Test func missingFileLoadsEmpty() {
        #expect(DeviceStoreFile(url: tempURL()).load() == DeviceStore())
    }

    @Test func saveThenLoadWithOwnerOnlyPermissions() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = DeviceStore()
        _ = store.merge(scan: [device(1), device(2)], network: net, now: t0)
        let file = DeviceStoreFile(url: url)
        try file.save(store)
        #expect(file.load() == store)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try file.save(store)   // overwrite keeps the mode
        let again = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((again[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(DeviceStoreFile(url: url).load() == DeviceStore())
    }
}
