import Foundation

/// Everything the scanner needs from the outside world, so the model can be tested with fakes.
protocol LANEnvironment: Sendable {
    func currentNetwork() async -> NetworkInfo?
    func interfaceMAC(_ bsdName: String) async -> MACAddress?
    func computerName() async -> String?
    func sweep(network: NetworkInfo) async -> SweepResult
    func bonjour() async -> [BonjourSighting]
    func reverseNames(_ ips: [String]) async -> [String: String]
    func openPorts(ip: String, interface: String?) async -> [Int]
    func vendors() async -> OUIDirectory?
    func loadStore() async -> DeviceStore
    func saveStore(_ store: DeviceStore) async
}

/// The real thing: SystemConfiguration, a UDP sweep + ARP, Bonjour, reverse DNS, and the bundled OUI table.
struct LiveLANEnvironment: LANEnvironment {
    private actor VendorCache {
        private var loaded = false
        private var directory: OUIDirectory?
        func get() -> OUIDirectory? {
            if !loaded { directory = OUIDirectory.loadBundled(); loaded = true }
            return directory
        }
    }

    private let cache = VendorCache()
    let storeFile: DeviceStoreFile

    init(storeURL: URL = LiveLANEnvironment.defaultStoreURL) {
        storeFile = DeviceStoreFile(url: storeURL)
    }

    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wirely/devices.json")
    }

    func currentNetwork() async -> NetworkInfo? { NetworkProbe.current() }
    func interfaceMAC(_ bsdName: String) async -> MACAddress? { NetworkProbe.interfaceMAC(bsdName) }
    func computerName() async -> String? { NetworkProbe.computerName() }
    func sweep(network: NetworkInfo) async -> SweepResult {
        await LANSweep.run(network: network, hosts: Subnet.hosts(address: network.address, prefix: network.prefix))
    }
    func bonjour() async -> [BonjourSighting] { await BonjourScout.browse() }
    func reverseNames(_ ips: [String]) async -> [String: String] { await ReverseDNS.names(for: ips) }
    func openPorts(ip: String, interface: String?) async -> [Int] { await PortCheck.openPorts(ip: ip, interface: interface) }
    func vendors() async -> OUIDirectory? { await cache.get() }
    func loadStore() async -> DeviceStore { storeFile.load() }
    func saveStore(_ store: DeviceStore) async { try? storeFile.save(store) }
}

enum ScanPhase: Equatable {
    case idle, scanning, failed(String)
}

/// Scans the local network and holds the result for the Devices screen.
///
/// A device with no Bonjour or DNS name is named after its vendor, else "Unknown device" (`LANDevice.name` is not
/// optional); a user rename always wins. Nothing is merged into the known-device store when the sweep was denied
/// by Local Network privacy or found nobody besides this Mac and the router, so a bad first scan can never seed
/// the store and make every real device look new later.
@MainActor final class DeviceScanner: ObservableObject {
    @Published private(set) var network: NetworkInfo?
    /// Router first, this Mac second, then by IP address.
    @Published private(set) var devices: [LANDevice] = []
    @Published private(set) var phase: ScanPhase = .idle
    @Published private(set) var lastScan: Date?
    @Published private(set) var permissionDenied = false
    @Published private(set) var checkingPorts: Set<MACAddress> = []
    @Published var selected: MACAddress?

    private let env: LANEnvironment
    private let notify: @MainActor ([LANDevice], String) -> Void
    private let now: () -> Date
    private let defaults: UserDefaults
    private let backgroundInterval: TimeInterval

    private var store = DeviceStore()
    private var storeLoaded = false
    private var networkKey: String?
    /// Names found by the scan, before any user rename.
    private var scanNames: [MACAddress: String] = [:]
    private var portCache: [MACAddress: [Int]] = [:]
    private var saveTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?

    init(env: LANEnvironment = LiveLANEnvironment(), notify: @escaping @MainActor ([LANDevice], String) -> Void,
         now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard, backgroundInterval: TimeInterval = 300) {
        self.env = env
        self.notify = notify
        self.now = now
        self.defaults = defaults
        self.backgroundInterval = backgroundInterval
    }

    var isBackgroundRunning: Bool { backgroundTask != nil }

    // MARK: Scanning

    /// Ignored while a scan is running.
    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        if !storeLoaded {
            store = await env.loadStore()
            storeLoaded = true
        }
        guard let net = await env.currentNetwork() else {
            network = nil
            devices = []
            permissionDenied = false
            phase = .failed(L10n.shared(.devicesOffline))
            return
        }
        network = net
        async let sweepResult = env.sweep(network: net)
        async let sightingList = env.bonjour()
        let (sweep, sightings) = await (sweepResult, sightingList)
        let byIP = Dictionary(sightings.map { ($0.ip, $0) }, uniquingKeysWith: { a, _ in a })

        let thisMAC = await env.interfaceMAC(net.interface)
        let computerName = await env.computerName()
        let vendors = await env.vendors()

        var seen = Set<MACAddress>()
        var entries: [ARPEntry] = []
        for e in sweep.entries where !e.mac.isMulticast && e.ip != net.address && e.mac != thisMAC && seen.insert(e.mac).inserted {
            entries.append(e)
        }
        let unnamed = entries.map(\.ip).filter { byIP[$0]?.name == nil }
        let dns = await env.reverseNames(unnamed)

        func build(ip: String, mac: MACAddress, name: String?) -> LANDevice {
            let sight = byIP[ip]
            let vendor = vendors?.vendor(for: mac)
            let hints = [name, sight?.hostName, dns[ip]].compactMap { $0 }.joined(separator: " ")
            let kind = DeviceClassifier.classify(ip: ip, mac: mac, vendor: vendor, services: sight?.services ?? [],
                                                 model: sight?.model, hostName: hints.isEmpty ? nil : hints,
                                                 routerIP: net.router, thisIP: net.address)
            var d = LANDevice(ip: ip, mac: mac, name: name ?? vendor ?? L10n.shared(.unknownDevice), kind: kind)
            d.vendor = vendor
            d.model = sight?.model
            d.isRouter = ip == net.router
            d.isThisMac = ip == net.address
            return d
        }

        var scanned = entries.map { build(ip: $0.ip, mac: $0.mac, name: byIP[$0.ip]?.name ?? dns[$0.ip]) }
        if let thisMAC {
            scanned.append(build(ip: net.address, mac: thisMAC, name: computerName ?? byIP[net.address]?.name))
        }
        scanNames = Dictionary(scanned.map { ($0.mac, $0.name) }, uniquingKeysWith: { a, _ in a })

        let routerMAC = net.router.flatMap { r in sweep.entries.first { $0.ip == r }?.mac }
        let key = routerMAC?.description ?? "ip:\(net.router ?? "-")/\(net.address)/\(net.prefix)"
        networkKey = key

        let others = scanned.filter { !$0.isThisMac && !$0.isRouter }
        var result = scanned
        if sweep.denied {
            permissionDenied = true
        } else {
            permissionDenied = false
            if !others.isEmpty {
                let merged = store.merge(scan: scanned, network: key, now: now())
                result = merged.devices
                persist()
                if !merged.newOnes.isEmpty { notify(merged.newOnes, net.name) }
            }
        }

        for i in result.indices { result[i].openPorts = portCache[result[i].mac] }
        devices = Self.sorted(result)
        if let s = selected, !devices.contains(where: { $0.mac == s }) { selected = nil }
        lastScan = now()
        phase = .idle
    }

    /// Selecting a new device acknowledges it: its badge goes away and that is saved.
    func select(_ mac: MACAddress?) {
        selected = mac
        guard let mac, let key = networkKey, let i = devices.firstIndex(where: { $0.mac == mac }), devices[i].isNew else { return }
        store.markSeen(mac: mac, network: key)
        devices[i].isNew = false
        persist()
    }

    /// A blank name clears the custom name.
    func rename(_ mac: MACAddress, to name: String) {
        guard let key = networkKey, let i = devices.firstIndex(where: { $0.mac == mac }) else { return }
        store.rename(mac: mac, network: key, to: name)
        devices[i].name = store.networks[key]?[mac.description]?.customName ?? scanNames[mac] ?? devices[i].name
        persist()
    }

    /// Runs the port check for one device; the result stays for the session. No-op if cached or running.
    func checkPorts(_ mac: MACAddress) async {
        guard portCache[mac] == nil, !checkingPorts.contains(mac),
              let ip = devices.first(where: { $0.mac == mac })?.ip else { return }
        checkingPorts.insert(mac)
        let ports = await env.openPorts(ip: ip, interface: network?.interface)
        checkingPorts.remove(mac)
        portCache[mac] = ports
        if let i = devices.firstIndex(where: { $0.mac == mac }) { devices[i].openPorts = ports }
    }

    // MARK: Background

    /// The user opened Devices: remember it, start background scans and scan now if nothing was scanned yet.
    func devicesOpened() {
        defaults.set(true, forKey: AppPreferences.devicesOpenedKey)
        startBackground()
        if lastScan == nil, phase != .scanning { Task { await scan() } }
    }

    /// Scans every 5 minutes. Only after Devices was opened once and while "Notify about new devices" is on.
    func startBackground() {
        guard backgroundTask == nil, AppPreferences.devicesOpened(in: defaults),
              AppPreferences.notifyNewDevices(in: defaults) else { return }
        let interval = backgroundInterval
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if AppPreferences.notifyNewDevices(in: self.defaults) { await self.scan() }
            }
        }
    }

    func stopBackground() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    // MARK: Helpers

    /// Saves the store after the saves already queued, in order.
    private func persist() {
        let snapshot = store
        let previous = saveTask
        let env = env
        saveTask = Task {
            await previous?.value
            await env.saveStore(snapshot)
        }
    }

    /// Waits for queued saves (tests).
    func waitForPersistence() async { await saveTask?.value }

    static func sorted(_ devices: [LANDevice]) -> [LANDevice] {
        func rank(_ d: LANDevice) -> Int { d.isRouter ? 0 : d.isThisMac ? 1 : 2 }
        func numeric(_ ip: String) -> UInt32 {
            ip.split(separator: ".").compactMap { UInt8($0) }.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        return devices.sorted { (rank($0), numeric($0.ip), $0.ip) < (rank($1), numeric($1.ip), $1.ip) }
    }
}
