import Foundation

/// What is remembered about one device on one network.
struct DeviceRecord: Codable, Equatable {
    var firstSeen: Date
    var lastSeen: Date
    var customName: String?
    /// False from the moment a device shows up unannounced until the user selects it once.
    var acknowledged: Bool
}

/// The devices seen per network, used to tell which ones are new and to keep user renames.
///
/// A network is keyed by any stable string (the router's MAC, else router IP plus subnet); a device
/// by its MAC. The first scan of a network seeds the store silently, so nothing on it is "new".
struct DeviceStore: Codable, Equatable {
    private(set) var networks: [String: [String: DeviceRecord]] = [:]

    /// Folds a scan into the store.
    ///
    /// - Returns: `devices` in scan order with first/last seen, custom names and `isNew` applied; `newOnes`
    ///   are the devices that appeared in this very merge (notify once). A device stays `isNew` until
    ///   `markSeen`. The router and this Mac are never new. An empty scan of an unknown network records
    ///   nothing, so the seeding scan is the first one that finds anybody.
    mutating func merge(scan: [LANDevice], network: String, now: Date) -> (devices: [LANDevice], newOnes: [LANDevice]) {
        let seeding = networks[network] == nil
        if seeding && scan.isEmpty { return ([], []) }
        var records = networks[network] ?? [:]
        var devices: [LANDevice] = []
        var newOnes: [LANDevice] = []
        for var device in scan {
            let key = device.mac.description
            let known = records[key]
            var record = known ?? DeviceRecord(firstSeen: now, lastSeen: now, customName: nil,
                                               acknowledged: seeding || device.isRouter || device.isThisMac)
            record.lastSeen = now
            records[key] = record
            device.firstSeen = record.firstSeen
            device.lastSeen = now
            device.isNew = !record.acknowledged
            if let custom = record.customName { device.name = custom }
            if known == nil && device.isNew { newOnes.append(device) }
            devices.append(device)
        }
        networks[network] = records
        return (devices, newOnes)
    }

    /// The user looked at the device: drop its "new" state.
    mutating func markSeen(mac: MACAddress, network: String) {
        networks[network]?[mac.description]?.acknowledged = true
    }

    /// Sets the name the user gave; blank clears it.
    mutating func rename(mac: MACAddress, network: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        networks[network]?[mac.description]?.customName = trimmed.isEmpty ? nil : trimmed
    }
}

/// Reads and writes a `DeviceStore` at a given file, readable by the owner only.
struct DeviceStoreFile {
    let url: URL

    /// The saved store; empty when the file is missing or unreadable.
    func load() -> DeviceStore {
        guard let data = try? Data(contentsOf: url) else { return DeviceStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DeviceStore.self, from: data)) ?? DeviceStore()
    }

    func save(_ store: DeviceStore) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
