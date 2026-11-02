import Testing
import Foundation
@testable import WirelyApp

private let routerMAC = MACAddress("a4:5e:60:00:00:01")!
private let thisMAC = MACAddress("a4:5e:60:00:00:0a")!
private let tvMAC = MACAddress("a4:5e:60:00:00:20")!
private let pixelMAC = MACAddress("a4:5e:60:00:00:09")!
private let newMAC = MACAddress("a4:5e:60:00:00:58")!

private let lan = NetworkInfo(interface: "en0", name: "home-wifi", address: "192.168.1.10", prefix: 24,
                              router: "192.168.1.1", isWiFi: true)

/// A scripted `LANEnvironment` that records what it was asked and what was saved.
private final class FakeEnv: LANEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var _network: NetworkInfo? = lan
    private var _entries: [ARPEntry] = []
    private var _denied = false
    private var _sightings: [BonjourSighting] = []
    private var _dns: [String: String] = [:]
    private var _store = DeviceStore()
    private var _saved: [DeviceStore] = []
    private var _portCalls: [String] = []
    private var _sweeps = 0

    var network: NetworkInfo? { get { lock.withLock { _network } } set { lock.withLock { _network = newValue } } }
    var entries: [ARPEntry] { get { lock.withLock { _entries } } set { lock.withLock { _entries = newValue } } }
    var denied: Bool { get { lock.withLock { _denied } } set { lock.withLock { _denied = newValue } } }
    var sightings: [BonjourSighting] { get { lock.withLock { _sightings } } set { lock.withLock { _sightings = newValue } } }
    var dns: [String: String] { get { lock.withLock { _dns } } set { lock.withLock { _dns = newValue } } }
    var saved: [DeviceStore] { lock.withLock { _saved } }
    var portCalls: [String] { lock.withLock { _portCalls } }
    var sweeps: Int { lock.withLock { _sweeps } }

    func currentNetwork() async -> NetworkInfo? { network }
    func interfaceMAC(_ bsdName: String) async -> MACAddress? { thisMAC }
    func computerName() async -> String? { "Test Mac" }
    func sweep(network: NetworkInfo) async -> SweepResult {
        lock.withLock { _sweeps += 1 }
        return SweepResult(entries: entries, denied: denied)
    }
    func bonjour() async -> [BonjourSighting] { sightings }
    func reverseNames(_ ips: [String], router: String?, interface: String) async -> [String: String] { dns.filter { ips.contains($0.key) } }
    func openPorts(ip: String, interface: String?) async -> [Int] { lock.withLock { _portCalls.append(ip) }; return [80, 443] }
    func vendors() async -> OUIDirectory? { OUIDirectory(tsv: "A45E60\tAcme\n") }
    func loadStore() async -> DeviceStore { lock.withLock { _store } }
    func saveStore(_ store: DeviceStore) async { lock.withLock { _saved.append(store) } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

private func entry(_ ip: String, _ mac: MACAddress) -> ARPEntry { ARPEntry(ip: ip, mac: mac) }

private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(devices: [LANDevice], network: String)] = []
    var calls: [(devices: [LANDevice], network: String)] { lock.withLock { _calls } }
    func add(_ d: [LANDevice], _ n: String) { lock.withLock { _calls.append((d, n)) } }
}

@MainActor
private func make(_ env: FakeEnv, _ notes: Notes = Notes(), opened: Bool = false, notifyPref: Bool = true,
                  now: @escaping () -> Date = Date.init) -> DeviceScanner {
    let d = UserDefaults(suiteName: "devices-test-\(UUID().uuidString)")!
    d.set(opened, forKey: AppPreferences.devicesOpenedKey)
    d.set(notifyPref, forKey: AppPreferences.notifyNewDevicesKey)
    return DeviceScanner(env: env, notify: { notes.add($0, $1) }, now: now, defaults: d)
}

private func baseEntries() -> [ARPEntry] {
    [entry("192.168.1.1", routerMAC), entry("192.168.1.20", tvMAC), entry("192.168.1.9", pixelMAC)]
}

@MainActor
struct DeviceScannerTests {
    @Test func firstScanSeedsThenNewDeviceNotifiesOnce() async throws {
        let env = FakeEnv(); env.entries = baseEntries()
        let notes = Notes()
        let s = make(env, notes)
        await s.scan()
        #expect(notes.calls.isEmpty)
        #expect(s.devices.count == 4)   // router, this Mac, two others
        #expect(s.devices.allSatisfy { !$0.isNew })
        #expect(s.phase == .idle)
        #expect(s.lastScan != nil)

        env.entries = baseEntries() + [entry("192.168.1.88", newMAC)]
        await s.scan()
        #expect(notes.calls.count == 1)
        #expect(notes.calls[0].devices.map(\.mac) == [newMAC])
        #expect(notes.calls[0].network == "home-wifi")
        #expect(s.devices.first { $0.mac == newMAC }?.isNew == true)

        await s.scan()
        #expect(notes.calls.count == 1)
    }

    @Test func selectingANewDeviceClearsAndPersists() async throws {
        let env = FakeEnv(); env.entries = baseEntries()
        let s = make(env)
        await s.scan()
        env.entries = baseEntries() + [entry("192.168.1.88", newMAC)]
        await s.scan()
        s.select(newMAC)
        #expect(s.selected == newMAC)
        #expect(s.devices.first { $0.mac == newMAC }?.isNew == false)
        await s.waitForPersistence()
        let key = routerMAC.description
        #expect(env.saved.last?.networks[key]?[newMAC.description]?.acknowledged == true)
    }

    @Test func deniedSweepNeverTouchesTheStore() async throws {
        let env = FakeEnv(); env.denied = true; env.entries = baseEntries()
        let notes = Notes()
        let s = make(env, notes)
        await s.scan()
        await s.waitForPersistence()
        #expect(s.permissionDenied)
        #expect(env.saved.isEmpty)
        #expect(notes.calls.isEmpty)
        #expect(s.devices.allSatisfy { !$0.isNew })

        env.denied = false
        await s.scan()
        #expect(!s.permissionDenied)
        #expect(notes.calls.isEmpty)   // this is the seeding scan, not a "new device" scan
    }

    @Test func onlyRouterAndThisMacDoesNotSeed() async throws {
        let env = FakeEnv(); env.entries = [entry("192.168.1.1", routerMAC)]
        let s = make(env)
        await s.scan()
        await s.waitForPersistence()
        #expect(env.saved.isEmpty)
        #expect(s.devices.count == 2)
    }

    @Test func checkPortsRunsOnceAndSurvivesRescan() async throws {
        let env = FakeEnv(); env.entries = baseEntries()
        let s = make(env)
        await s.scan()
        await s.checkPorts(tvMAC)
        await s.checkPorts(tvMAC)
        #expect(env.portCalls == ["192.168.1.20"])
        #expect(s.devices.first { $0.mac == tvMAC }?.openPorts == [80, 443])
        #expect(s.checkingPorts.isEmpty)
        await s.scan()
        #expect(s.devices.first { $0.mac == tvMAC }?.openPorts == [80, 443])
        #expect(s.devices.first { $0.mac == pixelMAC }?.openPorts == nil)
    }

    @Test func namePriorityAndOrdering() async throws {
        let env = FakeEnv()
        env.entries = [entry("192.168.1.30", MACAddress("a4:5e:60:00:00:30")!),
                       entry("192.168.1.20", tvMAC), entry("192.168.1.9", pixelMAC), entry("192.168.1.1", routerMAC),
                       entry("192.168.1.15", MACAddress("a4:5e:60:00:00:15")!)]
        env.sightings = [BonjourSighting(ip: "192.168.1.20", name: "Living Room TV", services: ["_googlecast._tcp"],
                                         model: nil, hostName: "lgtv")]
        env.dns = ["192.168.1.20": "dns-tv", "192.168.1.9": "pixel-8"]
        let s = make(env)
        await s.scan()
        #expect(s.devices.map(\.ip) == ["192.168.1.1", "192.168.1.10", "192.168.1.9", "192.168.1.15", "192.168.1.20", "192.168.1.30"])
        #expect(s.devices[0].isRouter)
        #expect(s.devices[1].isThisMac)
        #expect(s.devices[1].name == "Test Mac")
        #expect(s.devices.first { $0.mac == tvMAC }?.name == "Living Room TV")
        #expect(s.devices.first { $0.mac == tvMAC }?.kind == .tv)
        #expect(s.devices.first { $0.mac == pixelMAC }?.name == "pixel-8")
        #expect(s.devices.first { $0.ip == "192.168.1.30" }?.name == "Acme")   // vendor fallback

        s.rename(tvMAC, to: "  Den TV ")
        #expect(s.devices.first { $0.mac == tvMAC }?.name == "Den TV")
        await s.scan()
        #expect(s.devices.first { $0.mac == tvMAC }?.name == "Den TV")
        s.rename(tvMAC, to: "")
        #expect(s.devices.first { $0.mac == tvMAC }?.name == "Living Room TV")
        await s.waitForPersistence()
        #expect(env.saved.last?.networks[routerMAC.description]?[tvMAC.description]?.customName == nil)
    }

    @Test func ordersAddressesNumerically() {
        let a = LANDevice(ip: "192.168.1.10", mac: tvMAC, name: "a", kind: .unknown)
        let b = LANDevice(ip: "192.168.1.9", mac: pixelMAC, name: "b", kind: .unknown)
        #expect(DeviceScanner.sorted([a, b]).map(\.ip) == ["192.168.1.9", "192.168.1.10"])
        var r = LANDevice(ip: "192.168.1.200", mac: routerMAC, name: "r", kind: .router); r.isRouter = true
        var t = LANDevice(ip: "192.168.1.100", mac: thisMAC, name: "t", kind: .computer); t.isThisMac = true
        #expect(DeviceScanner.sorted([a, b, t, r]).map(\.ip) == ["192.168.1.200", "192.168.1.100", "192.168.1.9", "192.168.1.10"])
    }

    @Test func offlineFails() async throws {
        let env = FakeEnv(); env.network = nil
        let s = make(env)
        await s.scan()
        #expect(s.phase == .failed(L10n.shared(.devicesOffline)))
        #expect(s.devices.isEmpty)
        #expect(s.network == nil)
    }

    @Test func backgroundNeedsDevicesOpenedAndThePreference() {
        let env = FakeEnv()
        let closed = make(env, opened: false)
        closed.startBackground()
        #expect(!closed.isBackgroundRunning)

        let off = make(env, opened: true, notifyPref: false)
        off.startBackground()
        #expect(!off.isBackgroundRunning)

        let on = make(env, opened: true)
        on.startBackground()
        #expect(on.isBackgroundRunning)
        on.startBackground()   // idempotent
        on.stopBackground()
        #expect(!on.isBackgroundRunning)
    }

    @Test func openingDevicesRescansOnlyWhenStale() async throws {
        let env = FakeEnv(); env.entries = baseEntries()
        let clock = Clock()
        let s = make(env, now: { clock.now })
        func settle(_ sweeps: Int) async throws {
            for _ in 0..<200 where env.sweeps != sweeps || s.phase == .scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        s.devicesOpened()
        try await settle(1)
        #expect(env.sweeps == 1)
        clock.advance(30)
        s.devicesOpened()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(env.sweeps == 1)   // fresh: no rescan
        clock.advance(40)          // 70 s since the scan
        s.devicesOpened()
        try await settle(2)
        #expect(env.sweeps == 2)
        s.stopBackground()
    }

    @Test func openingDevicesStartsBackgroundAndScansOnce() async throws {
        let env = FakeEnv(); env.entries = baseEntries()
        let s = make(env, opened: false)
        s.devicesOpened()
        #expect(s.isBackgroundRunning)
        for _ in 0..<200 where s.lastScan == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(s.lastScan != nil)
        s.stopBackground()
    }
}

struct LANHelperTests {
    @Test func reverseDNSCleaning() {
        #expect(ReverseDNS.clean("Living-Room-TV.local.", ip: "192.168.1.20") == "Living-Room-TV")
        #expect(ReverseDNS.clean("pixel-8.lan", ip: "192.168.1.9") == "pixel-8")
        #expect(ReverseDNS.clean("nas.home.arpa.", ip: "192.168.1.5") == "nas")
        #expect(ReverseDNS.clean("host.localdomain", ip: "192.168.1.5") == "host")
        #expect(ReverseDNS.clean("192.168.1.9", ip: "192.168.1.9") == nil)
        #expect(ReverseDNS.clean(".local", ip: "192.168.1.9") == nil)
        #expect(ReverseDNS.clean("printer.example.com", ip: "192.168.1.9") == "printer.example.com")
    }

    @Test func raopNamesLoseTheirMACPrefix() {
        #expect(BonjourScout.displayName(type: "_raop._tcp", instance: "A45E60000001@Living Room TV") == "Living Room TV")
        #expect(BonjourScout.displayName(type: "_raop._tcp", instance: "Plain") == "Plain")
        #expect(BonjourScout.displayName(type: "_raop._tcp", instance: "me@home") == "me@home")
        #expect(BonjourScout.displayName(type: "_airplay._tcp", instance: "A45E60000001@Keep") == "A45E60000001@Keep")
    }

    @Test func modelFallbackOrder() {
        let hits = [
            BonjourScout.Hit(type: "_airplay._tcp", instance: "Living Room TV", ips: ["192.168.1.20"], hostName: nil, txt: ["am": "AppleTV11,1"]),
            BonjourScout.Hit(type: "_googlecast._tcp", instance: "Chromecast", ips: ["192.168.1.20"], hostName: nil, txt: ["md": "Chromecast"]),
            BonjourScout.Hit(type: "_airplay._tcp", instance: "Echo", ips: ["192.168.1.30"], hostName: nil, txt: ["am": "AudioAccessory5,1"]),
        ]
        let merged = BonjourScout.merge(hits)
        #expect(merged.first { $0.ip == "192.168.1.20" }?.model == "Chromecast")
        #expect(merged.first { $0.ip == "192.168.1.30" }?.model == "AudioAccessory5,1")
        let withInfo = BonjourScout.merge(hits + [
            BonjourScout.Hit(type: "_device-info._tcp", instance: "x", ips: ["192.168.1.20"], hostName: nil, txt: ["model": "AppleTV11,1"])])
        #expect(withInfo.first { $0.ip == "192.168.1.20" }?.model == "AppleTV11,1")
    }

    @Test func nameAndServicesMergePerIP() {
        let hits = [
            BonjourScout.Hit(type: "_http._tcp", instance: "web-ui", ips: ["192.168.1.20"], hostName: "tv.local.", txt: [:]),
            BonjourScout.Hit(type: "_raop._tcp", instance: "A45E60000001@Living Room TV", ips: ["192.168.1.20"], hostName: nil, txt: [:]),
            BonjourScout.Hit(type: "_googlecast._tcp", instance: "Cast-Name", ips: ["192.168.1.20"], hostName: nil, txt: [:]),
        ]
        let s = BonjourScout.merge(hits)
        #expect(s.count == 1)
        #expect(s[0].name == "Cast-Name")
        #expect(s[0].services == ["_http._tcp", "_raop._tcp", "_googlecast._tcp"])
        #expect(s[0].hostName == "tv")
    }

    @Test func prefixLengthFromMask() {
        #expect(NetworkProbe.prefixLength(mask: "255.255.255.0") == 24)
        #expect(NetworkProbe.prefixLength(mask: "255.255.0.0") == 16)
        #expect(NetworkProbe.prefixLength(mask: "255.255.255.252") == 30)
        #expect(NetworkProbe.prefixLength(mask: "0.0.0.0") == 0)
        #expect(NetworkProbe.prefixLength(mask: "255.0.255.0") == nil)
        #expect(NetworkProbe.prefixLength(mask: "bad") == nil)
    }

    @Test func tunnelInterfaces() {
        #expect(NetworkProbe.isTunnel("utun10") && NetworkProbe.isTunnel("ipsec0"))
        #expect(!NetworkProbe.isTunnel("en0"))
    }

    @Test func portListIsFixed() {
        #expect(PortCheck.ports.count == 18)
        #expect(PortCheck.ports.first == 22 && PortCheck.ports.last == 62078)
    }
}

struct ReverseDNSPacketTests {
    private static let qname: [UInt8] = [2, 0x32, 0x33, 1, 0x31, 3, 0x31, 0x36, 0x38, 3, 0x31, 0x39, 0x32, 7] + Array("in-addr".utf8)
        + [4] + Array("arpa".utf8) + [0]   // 23.1.168.192.in-addr.arpa

    private static func response(id: UInt16 = 0x1234, flags: [UInt8] = [0x81, 0x80], answer: [UInt8]) -> [UInt8] {
        [UInt8(id >> 8), UInt8(id & 0xFF)] + flags + [0, 1, 0, 1, 0, 0, 0, 0] + qname + [0, 12, 0, 1] + answer
    }

    @Test func queryBytes() {
        let q = ReverseDNS.ptrQuery(id: 0xABCD, ip: "192.168.1.23")
        let expected: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
                                 2, 0x32, 0x33, 1, 0x31, 3, 0x31, 0x36, 0x38, 3, 0x31, 0x39, 0x32, 7] + Array("in-addr".utf8)
            + [4] + Array("arpa".utf8) + [0, 0, 12, 0, 1]
        #expect(q == expected)
        #expect(ReverseDNS.ptrQuery(id: 1, ip: "nope") == nil)
        #expect(ReverseDNS.ptrQuery(id: 1, ip: "1.2.3") == nil)
        #expect(ReverseDNS.ptrQuery(id: 1, ip: "1.2.3.999") == nil)
    }

    @Test func parsesACompressedAnswer() {
        // Answer name is a pointer to the question (0xC00C); the PTR data is "tv" + a pointer to "in-addr.arpa" (offset 25).
        let data: [UInt8] = [2, 0x74, 0x76, 0xC0, 25]
        let answer: [UInt8] = [0xC0, 12, 0, 12, 0, 1, 0, 0, 0, 60, 0, UInt8(data.count)] + data
        let r = ReverseDNS.parsePTRResponse(Self.response(answer: answer))
        #expect(r?.id == 0x1234)
        #expect(r?.name == "tv.in-addr.arpa")
    }

    @Test func parsesAPlainAnswer() {
        let name: [UInt8] = [11] + Array("living-room".utf8) + [5] + Array("local".utf8) + [0]
        let answer: [UInt8] = [0xC0, 12, 0, 12, 0, 1, 0, 0, 0, 60, 0, UInt8(name.count)] + name
        let r = ReverseDNS.parsePTRResponse(Self.response(answer: answer))
        #expect(r?.name == "living-room.local")
        #expect(r.flatMap { ReverseDNS.clean($0.name, ip: "192.168.1.23") } == "living-room")
    }

    @Test func rejectsGarbageTruncationAndErrors() {
        #expect(ReverseDNS.parsePTRResponse([]) == nil)
        #expect(ReverseDNS.parsePTRResponse([1, 2, 3, 4, 5]) == nil)
        #expect(ReverseDNS.parsePTRResponse(Array(repeating: 0xFF, count: 40)) == nil)
        let data: [UInt8] = [2, 0x74, 0x76, 0]
        let answer: [UInt8] = [0xC0, 12, 0, 12, 0, 1, 0, 0, 0, 60, 0, UInt8(data.count)] + data
        let full = Self.response(answer: answer)
        #expect(ReverseDNS.parsePTRResponse(full) != nil)
        for cut in [full.count - 1, full.count - 3, 30, 12] { #expect(ReverseDNS.parsePTRResponse(Array(full.prefix(cut))) == nil) }
        #expect(ReverseDNS.parsePTRResponse(Self.response(flags: [0x81, 0x83], answer: answer)) == nil)   // NXDOMAIN
        #expect(ReverseDNS.parsePTRResponse(Self.response(flags: [0x01, 0x00], answer: answer)) == nil)   // not a response
    }

    @Test func pointerLoopIsRejected() {
        // The PTR data points at itself.
        let rdataOffset = 12 + Self.qname.count + 4 + 12
        let data: [UInt8] = [0xC0, UInt8(rdataOffset)]
        let answer: [UInt8] = [0xC0, 12, 0, 12, 0, 1, 0, 0, 0, 60, 0, UInt8(data.count)] + data
        #expect(ReverseDNS.parsePTRResponse(Self.response(answer: answer)) == nil)
    }

    @Test func noRouterMeansNoQueries() async {
        #expect(await ReverseDNS.names(for: ["192.168.1.23"], router: nil, interface: "en0").isEmpty)
    }
}
