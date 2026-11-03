import SwiftUI
import AppKit
import WirelyCore

private let previewHomeNetwork = NetworkInfo(interface: "en0", name: "home-wifi", address: "192.168.1.20", prefix: 24,
                                             router: "192.168.1.1", isWiFi: true)

/// QA hook: `Wirely --render-previews <dir>` renders the main states to PNGs and exits.
/// Run it from the built `.app` binary so Manrope is found in the bundle.
@MainActor
enum PreviewRenderer {
    static func requestedDirectory() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    nonisolated private static let defaultAllowed = "0.0.0.0/0, ::/0"
    /// Split previews: a server that only accepts the 10.8 and 172.16 networks, so 10.2.2.4 is uncovered.
    nonisolated private static let splitAllowed = "10.8.0.0/16, 172.16.0.0/16"

    private static func configText(allowed: String) -> String {
        """
    [Interface]
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = 10.8.0.2/32, fd00::2/128
    DNS = 1.1.1.1, 9.9.9.9
    PostUp = echo hi

    [Peer]
    PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Endpoint = vpn.example.com:51820
    AllowedIPs = \(allowed)
    PersistentKeepalive = 25
    """
    }

    private static let istanbul = HomeLocation(city: "Istanbul", point: GeoPoint(lat: 41.01, lon: 28.98))
    private static let exitIP = "203.0.113.10"

    private static func frankfurt(_ now: Date) -> ExitLocation {
        ExitLocation(city: "Frankfurt", countryCode: "DE", point: GeoPoint(lat: 50.11, lon: 8.68), fetchedAt: now)
    }

    private struct Scenario {
        var label: String
        var profiles = ["home", "office", "travel"]
        var broken: String?
        var selected: String? = "home"
        var status: TunnelStatus = .disconnected
        var helper: HelperState = .ready
        var samples = false
        var exit = true
        var locating = false
        var latency: Double?
        var language = AppLanguage.en
        var menuBar = false
        var reconnect: ReconnectStatus?
        var settings: SettingsSection?
        var update: ReleaseInfo?
        var checked = false
        var sheet = false
        var route: RouteScenario?
        var mode = AppMode.tunnel
        var devices: DevicesScenario?
        var lanBlocked: Bool?
        var size = CGSize(width: 920, height: 600)
        var allowedIPs = PreviewRenderer.defaultAllowed
        /// Split-tunnel settings of "home" (rules in display order) and whether the panel is open.
        var splitMode = SplitMode.all
        var splitRules: [String] = []
        var splitPanel = false
    }

    /// Route-mode state for the full window.
    private struct RouteScenario {
        var phase: TraceModel.Phase
        var stations: [TraceStation]
        var selected: Int?
        var target: String
        var reached = true
    }

    /// Devices-mode state for the full window.
    private struct DevicesScenario {
        var network: NetworkInfo? = previewHomeNetwork
        var devices: [LANDevice]
        var phase = ScanPhase.idle
        var selected: MACAddress?
        var permissionDenied = false
        var lastScan: Date?
    }

    /// Does nothing: previews never scan.
    private struct NullLANEnvironment: LANEnvironment {
        func currentNetwork() async -> NetworkInfo? { nil }
        func interfaceMAC(_ bsdName: String) async -> MACAddress? { nil }
        func computerName() async -> String? { nil }
        func sweep(network: NetworkInfo) async -> SweepResult { SweepResult(entries: [], denied: false) }
        func bonjour() async -> [BonjourSighting] { [] }
        func reverseNames(_ ips: [String], router: String?, interface: String) async -> [String: String] { [:] }
        func openPorts(ip: String, interface: String?) async -> [Int] { [] }
        func vendors() async -> OUIDirectory? { nil }
        func loadStore() async -> DeviceStore { DeviceStore() }
        func saveStore(_ store: DeviceStore) async {}
    }

    private static func mac(_ last: Int) -> MACAddress { MACAddress(String(format: "a4:5e:60:00:00:%02x", last))! }

    /// Sample devices (made-up names, documentation-style addresses, fake MAC suffixes); `extra` adds filler devices.
    private static func sampleDevices(now: Date, extra: Int = 0, onlyBasics: Bool = false) -> [LANDevice] {
        func day(_ d: Double) -> Date { now.addingTimeInterval(-86_400 * d) }
        func dev(_ last: Int, _ ip: String, _ name: String, _ kind: DeviceKind, vendor: String?, first: Date,
                 ports: [Int]? = nil, router: Bool = false, me: Bool = false, new: Bool = false) -> LANDevice {
            var d = LANDevice(ip: ip, mac: mac(last), name: name, kind: kind, vendor: vendor, isRouter: router,
                              isThisMac: me, isNew: new, firstSeen: first, lastSeen: now, openPorts: ports)
            if vendor == nil, !new { d.mac = MACAddress(String(format: "a2:5e:60:00:00:%02x", last))! }
            return d
        }
        var list = [
            dev(1, "192.168.1.1", "Router", .router, vendor: "Huawei", first: day(400), ports: [80, 443], router: true),
            dev(20, "192.168.1.20", "MacBook", .computer, vendor: "Apple", first: day(400), me: true),
        ]
        if onlyBasics { return list }
        list += [
            dev(34, "192.168.1.34", "iPhone", .phone, vendor: nil, first: day(90)),
            dev(23, "192.168.1.23", "Living Room TV", .tv, vendor: "Samsung", first: day(150), ports: [8001, 9197]),
            dev(40, "192.168.1.40", "HP LaserJet", .printer, vendor: "HP", first: day(365), ports: [80, 631, 9100]),
            dev(51, "192.168.1.51", "Hue Bridge", .smartHome, vendor: "Philips", first: day(240), ports: [80, 443]),
            dev(45, "192.168.1.45", "iPad", .tablet, vendor: "Apple", first: day(60)),
            dev(37, "192.168.1.37", "Pixel 8", .phone, vendor: "Google", first: day(30)),
            dev(71, "192.168.1.71", "Echo Dot", .speaker, vendor: "Amazon", first: day(180), ports: [8080]),
            dev(62, "192.168.1.62", "Robot vacuum", .smartHome, vendor: "Xiaomi", first: day(120)),
            dev(88, "192.168.1.88", "Unknown device", .unknown, vendor: nil, first: now.addingTimeInterval(-20),
                ports: [22, 80], new: true),
        ]
        let names = ["Garage Camera", "Kitchen Display", "Bedroom TV", "Office Laptop", "Guest Phone", "Smart Plug",
                     "Thermostat", "Desk Speaker", "NAS"]
        for i in 0..<extra {
            list.append(dev(100 + i, "192.168.1.\(100 + i)", names[i % names.count], .unknown, vendor: "Acme", first: day(Double(10 + i))))
        }
        return DeviceScanner.sorted(list)
    }

    /// Never reached: previews must not touch the network.
    private struct OfflineHTTP: HTTPFetching {
        func get(_ url: URL, timeout: TimeInterval) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    private static let sampleNotes = """
    ## What's new

    ### Settings
    - A **Settings** page inside the main window.
    - Reconnects automatically when the tunnel drops.
    - Open at login and connect on launch.

    ### Fixes
    1. The map no longer flickers while connecting.
    2. Profile names with spaces export correctly.

    Run `wirely --help` for details.
    """

    private static func sampleRelease(_ now: Date) -> ReleaseInfo {
        ReleaseInfo(version: AppVersion("1.2.0")!, tag: "v1.2.0", name: "Wirely 1.2.0", notes: sampleNotes,
                    pageURL: URL(string: "https://github.com/luucas42/wirely/releases/tag/v1.2.0")!,
                    dmgURL: nil, publishedAt: now.addingTimeInterval(-86_400 * 2))
    }

    private static func updateChecker(_ s: Scenario) -> UpdateChecker {
        let u = UpdateChecker(http: OfflineHTTP(), current: AppVersion("1.1.0")!,
                              defaults: UserDefaults(suiteName: "wirely-preview-\(UUID().uuidString)")!)
        if let r = s.update { u.setPreview(.available(r)) } else if s.checked { u.setPreview(.upToDate) }
        return u
    }

    private static func store(for s: Scenario) -> TunnelStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wirely-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in s.profiles {
            try? configText(allowed: s.allowedIPs).write(to: dir.appendingPathComponent(name + ".conf"), atomically: true, encoding: .utf8)
        }
        if let b = s.broken {
            try? "[Interface]".write(to: dir.appendingPathComponent(b + ".conf"), atomically: true, encoding: .utf8)
        }
        return TunnelStore(directory: dir)
    }

    private static func controller(_ s: Scenario) -> ConnectionController {
        // A scratch store so previews never read the real split.json.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wirely-preview-split-\(UUID().uuidString)/split.json")
        let splitStore = SplitStore(url: url)
        for rule in s.splitRules.reversed() { _ = splitStore.add(rule, for: "home") }
        splitStore.setMode(s.splitMode, for: "home")
        let c = ConnectionController(splitStore: splitStore)
        c.helperState = s.helper
        c.status = s.status
        c.reconnectStatus = s.reconnect
        if s.samples {
            let now = Date()
            var list: [ThroughputSample] = []
            for i in 0..<40 {
                let x = Double(i)
                list.append(ThroughputSample(id: now.addingTimeInterval(x - 40),
                                             rxRate: 2_310_000 + (x == 39 ? 0 : 400_000 * sin(x / 3)),
                                             txRate: 126_000 + (x == 39 ? 0 : 30_000 * cos(x / 3))))
            }
            c.samples = list
        }
        return c
    }

    /// A `TraceModel` with fake closures (no helper, no network); route scenarios set its state directly.
    private static func traceModel(_ s: Scenario) -> TraceModel {
        let t = TraceModel(trace: { _ in .failure(TraceFailure(code: nil, message: "preview")) },
                           locate: { _ in nil },
                           context: { (home: istanbul, vpn: nil, endpointHost: nil, connected: false, latencyMs: nil) })
        if let r = s.route {
            let hops = max(0, r.stations.reduce(0) { $0 + $1.hopCount })
            t.setPreview(phase: r.phase, stations: r.stations, selected: r.selected, target: r.target,
                         hopCount: hops, totalMs: r.stations.last?.rttMs.map { Int($0.rounded()) },
                         reached: r.reached)
        }
        return t
    }

    private static func view(_ s: Scenario, now: Date) -> AnyView {
        let store = store(for: s)
        let controller = controller(s)
        let route = RouteModel(store: store, controller: controller, home: istanbul, live: false)
        route.setPreview(exit: s.exit ? frankfurt(now) : nil, ip: s.exit ? exitIP : nil, locating: s.locating,
                         latency: s.latency, selected: s.selected)
        let l10n = L10n(fixed: s.language)
        let router = AppRouter(defaults: nil)
        router.mode = s.mode
        router.splitPanel = s.splitPanel
        let scanner = DeviceScanner(env: NullLANEnvironment(), notify: { _, _ in }, defaults: UserDefaults(suiteName: "wirely-preview-\(UUID().uuidString)")!)
        if let d = s.devices {
            scanner.setPreview(network: d.network, devices: d.devices, phase: d.phase, selected: d.selected,
                               lastScan: d.lastScan, permissionDenied: d.permissionDenied)
        }
        if let section = s.settings { router.openSettings(section) }
        let updates = updateChecker(s)
        let trace = traceModel(s)
        if s.sheet, let r = s.update {
            return AnyView(ReleaseNotesSheet(release: r).environmentObject(l10n))
        }
        if s.menuBar {
            return AnyView(MenuBarView(store: store, controller: controller, route: route)
                .environmentObject(l10n)
                .environmentObject(router)
                .environmentObject(updates)
                .environmentObject(trace)
                .environmentObject(scanner))
        }
        var main = MainView(store: store, controller: controller, route: route)
        main.lanBlockedOverride = s.lanBlocked ?? false
        return AnyView(main
            .environmentObject(scanner)
            .environmentObject(l10n)
            .environmentObject(router)
            .environmentObject(updates)
            .environmentObject(trace)
            .frame(width: s.size.width, height: s.size.height))
    }

    static func run(into directory: String) {
        let now = Date()
        let name = "home"
        let connected = TunnelStatus(state: .connected, tunnelName: name, interface: "utun4",
                                     connectedAt: now.addingTimeInterval(-2538),
                                     lastHandshake: now.addingTimeInterval(-8),
                                     rxBytes: 184_000_000, txBytes: 12_400_000,
                                     endpoint: "\(exitIP):51820", ignoredKeys: ["PostUp"])
        var noResponse = connected
        noResponse.connectedAt = now.addingTimeInterval(-95)
        noResponse.lastHandshake = nil
        noResponse.rxBytes = 0
        noResponse.txBytes = 148
        let connecting = TunnelStatus(state: .connecting, tunnelName: name, endpoint: "\(exitIP):51820")
        let failed = TunnelStatus(state: .failed, tunnelName: name, message: "Handshake did not complete")
        let blockedRetry = TunnelStatus(state: .failed, tunnelName: name, message: "Handshake did not complete",
                                        killSwitch: true)
        let blocked = TunnelStatus(state: .failed, tunnelName: name, message: "wireguard-go exited", killSwitch: true)

        let release = sampleRelease(now)
        let sample = sampleStations()
        // No VPN: the same path as one open leg, without the Sofia stop.
        let directStations = sample.filter { $0.city != "Sofia" }.enumerated().map { i, st -> TraceStation in
            var d = st
            d.id = i
            d.leg = .open
            if d.kind == .vpn { d.kind = .hop }
            return d
        }

        let longNames = RouteScenario(phase: .done, stations: longNameStations(), selected: 4,
                                      target: "leagueoflegends.com", reached: false)
        let scenarios: [Scenario] = [
            Scenario(label: "connected", status: connected, samples: true, latency: 46),
            Scenario(label: "connecting", status: connecting),
            Scenario(label: "idle"),
            Scenario(label: "idle-unknown-exit", exit: false),
            Scenario(label: "noresponse", status: noResponse, samples: true, latency: nil),
            Scenario(label: "failed", status: failed),
            Scenario(label: "blocked", status: blocked),
            Scenario(label: "reconnecting", status: blockedRetry,
                     reconnect: ReconnectStatus(name: name, attempts: 2, nextAt: now.addingTimeInterval(12))),
            Scenario(label: "invalid", profiles: ["home", "office"], broken: "broken", selected: "broken", exit: false),
            Scenario(label: "empty", profiles: [], selected: nil, exit: false),
            Scenario(label: "helper-setup", helper: .notInstalled),
            Scenario(label: "settings-profiles", settings: .profiles),
            Scenario(label: "settings-connection", settings: .connection),
            Scenario(label: "settings-general", settings: .general),
            Scenario(label: "settings-service", settings: .service),
            Scenario(label: "settings-profiles-empty", profiles: [], selected: nil, exit: false, settings: .profiles),
            Scenario(label: "settings-about", settings: .about, update: release),
            Scenario(label: "settings-about-uptodate", settings: .about, checked: true),
            Scenario(label: "update-banner", status: connected, samples: true, latency: 46, update: release),
            Scenario(label: "route-connected", status: connected, samples: true, latency: 46,
                     route: RouteScenario(phase: .done, stations: sample, selected: 2, target: "example.com")),
            Scenario(label: "route-direct", exit: false,
                     route: RouteScenario(phase: .done, stations: directStations, selected: directStations.firstIndex { $0.jumpMs != nil },
                                          target: "example.com")),
            Scenario(label: "route-running", status: connected, samples: true, latency: 46,
                     route: RouteScenario(phase: .running, stations: [], selected: nil, target: "example.com")),
            Scenario(label: "route-connected-min", status: connected, samples: true, latency: 46,
                     route: RouteScenario(phase: .done, stations: sample, selected: 2, target: "example.com"),
                     size: CGSize(width: 820, height: 560)),
            Scenario(label: "route-connected-wide", status: connected, samples: true, latency: 46,
                     route: RouteScenario(phase: .done, stations: sample, selected: 2, target: "example.com"),
                     size: CGSize(width: 1200, height: 760)),
            Scenario(label: "route-cdn", status: connected, samples: true, latency: 46,
                     route: RouteScenario(phase: .done, stations: cdnStations(), selected: 2, target: "cdn.example.com")),
            Scenario(label: "route-long-names-min", status: connected, samples: true, latency: 46,
                     route: longNames, size: CGSize(width: 820, height: 560)),
            Scenario(label: "route-long-names-wide", status: connected, samples: true, latency: 46,
                     route: longNames, size: CGSize(width: 1200, height: 760)),
            Scenario(label: "menubar", status: connected, samples: true, latency: 46, menuBar: true),
        ]
        // Split tunnel: "home" connected in split mode through a server that accepts 10.8/16 and 172.16/16 only.
        let splitRules = ["intranet.example.com", "10.2.2.4", "10.8.0.0/16", "example.net"]
        var splitConnected = connected
        splitConnected.split = ["intranet.example.com": SplitRuleStatus(routed: 2, rejected: 0),
                                "example.net": SplitRuleStatus(routed: 0, rejected: 0)]
        splitConnected.splitDNS = true
        var splitEmpty = connected
        splitEmpty.split = [:]
        splitEmpty.splitDNS = true
        var splitDNSOff = splitConnected
        splitDNSOff.splitDNS = false
        var splitBlocked = blocked
        splitBlocked.split = [:]
        func splitScenario(_ label: String, status: TunnelStatus, mode: SplitMode = .selected, rules: [String] = splitRules,
                           allowed: String = splitAllowed, panel: Bool = true,
                           size: CGSize = CGSize(width: 920, height: 600)) -> Scenario {
            Scenario(label: label, status: status, samples: status.state == .connected, latency: 46, size: size,
                     allowedIPs: allowed, splitMode: mode, splitRules: rules, splitPanel: panel)
        }
        let minSize = CGSize(width: 820, height: 560)
        let splitScenarios: [Scenario] = [
            splitScenario("split-panel", status: splitConnected),
            splitScenario("split-panel-empty", status: splitEmpty, rules: [], allowed: defaultAllowed),
            splitScenario("split-panel-all", status: connected, mode: .all),
            splitScenario("split-panel-disconnected", status: .disconnected),
            splitScenario("split-panel-dns-off", status: splitDNSOff),
            splitScenario("split-panel-min", status: splitConnected, size: minSize),
            splitScenario("split-panel-disconnected-min", status: .disconnected, size: minSize),
            splitScenario("blocked-split", status: splitBlocked, panel: false),
            splitScenario("blocked-split-panel", status: splitBlocked),
            splitScenario("blocked-split-panel-min", status: splitBlocked, size: minSize),
            splitScenario("connected-min", status: connected, rules: [], panel: false, size: minSize),
            splitScenario("split-pill", status: splitConnected, panel: false),
        ]
        let sampleList = sampleDevices(now: now)
        let hue = sampleList.first { $0.name == "Hue Bridge" }?.mac
        let fresh = sampleList.first { $0.isNew }?.mac
        func devicesScenario(_ label: String, _ list: [LANDevice], selected: MACAddress? = nil, phase: ScanPhase = .idle,
                             denied: Bool = false, lastScan: Date? = now.addingTimeInterval(-20), network: NetworkInfo? = previewHomeNetwork,
                             size: CGSize = CGSize(width: 920, height: 600), blocked: Bool? = nil, status: TunnelStatus = .disconnected) -> Scenario {
            Scenario(label: label, status: status, mode: .devices,
                     devices: DevicesScenario(network: network, devices: list, phase: phase, selected: selected,
                                              permissionDenied: denied, lastScan: lastScan),
                     lanBlocked: blocked, size: size)
        }
        let deviceScenarios: [Scenario] = [
            devicesScenario("devices", sampleList, selected: hue),
            devicesScenario("devices-new", sampleList, selected: fresh),
            devicesScenario("devices-scanning", [], phase: .scanning, lastScan: nil),
            devicesScenario("devices-empty", sampleDevices(now: now, onlyBasics: true)),
            devicesScenario("devices-offline", [], phase: .failed(L10n(fixed: .en)(.devicesOffline)), lastScan: nil, network: nil),
            devicesScenario("devices-denied", sampleDevices(now: now, onlyBasics: true), denied: true),
            devicesScenario("devices-killswitch", sampleDevices(now: now, onlyBasics: true), blocked: true, status: connected),
            devicesScenario("devices-crowded", sampleDevices(now: now, extra: 9), selected: hue),
            devicesScenario("devices-min", sampleList, selected: hue, size: CGSize(width: 820, height: 560)),
            devicesScenario("devices-wide", sampleList, selected: hue, size: CGSize(width: 1200, height: 760)),
            devicesScenario("devices-crowded-min", sampleDevices(now: now, extra: 9), selected: hue, size: CGSize(width: 820, height: 560)),
            devicesScenario("devices-hidden", sampleDevices(now: now, extra: 9) + (0..<8).map { i in
                LANDevice(ip: "192.168.1.\(200 + i)", mac: mac(200 + i), name: "Device \(i + 1)", kind: .unknown, vendor: "Acme",
                          firstSeen: now.addingTimeInterval(-86_400), lastSeen: now)
            }),
        ]

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for s in scenarios + deviceScenarios + splitScenarios {
            for scheme in [ColorScheme.light, .dark] {
                render(s, scheme: scheme, now: now, into: directory)
            }
        }
        var tr = Scenario(label: "connected-tr", status: connected, samples: true, latency: 46)
        tr.language = .tr
        render(tr, scheme: .dark, now: now, into: directory)
        var splitTR = splitScenarios[0]
        splitTR.label = "split-panel-tr"
        splitTR.language = .tr
        render(splitTR, scheme: .dark, now: now, into: directory)
        var devicesTR = deviceScenarios[0]
        devicesTR.label = "devices-tr"
        devicesTR.language = .tr
        render(devicesTR, scheme: .dark, now: now, into: directory)
        var generalTR = Scenario(label: "settings-general-tr", settings: .general)
        generalTR.language = .tr
        render(generalTR, scheme: .dark, now: now, into: directory)

        render(Scenario(label: "release-notes", update: release, sheet: true), scheme: .dark, now: now, into: directory)

        // Debug: land-mask sanity checks (whole world; Istanbul + Frankfurt framing).
        let l10n = L10n(fixed: .en)
        write(AnyView(WorldDebugView().frame(width: 920, height: 600)), label: "world", scheme: .dark, into: directory)
        for scheme in [ColorScheme.dark, .light] {
            let overlay = TraceOverlay(stations: sampleStations(), selected: 2, running: false, targetName: "example.com")
            write(AnyView(RouteMapView(home: istanbul, exit: nil, exitIP: nil, phase: .connected, trace: overlay)
                .equatable().environmentObject(l10n).frame(width: 840, height: 378).background(Theme.ground)),
                  label: "route-map", scheme: scheme, into: directory)
        }
        write(AnyView(RouteMapView(home: istanbul, exit: frankfurt(now), exitIP: exitIP, phase: .connected)
            .environmentObject(l10n).padding(40).frame(width: 920, height: 600).background(Theme.ground)),
              label: "europe", scheme: .dark, into: directory)
    }

    /// An anycast target: the CDN address geolocates far away, so it is drawn near the previous stop.
    private static func cdnStations() -> [TraceStation] {
        func st(_ id: Int, _ city: String, _ cc: String, _ lat: Double, _ lon: Double, _ kind: TraceStationKind,
                _ addr: String?, _ ms: Double, _ leg: TraceLegKind, near: Bool = false) -> TraceStation {
            var s = TraceStation(id: id, city: city, countryCode: cc, point: GeoPoint(lat: lat, lon: lon), kind: kind,
                                 hopCount: 2, address: addr, rttMs: ms, jumpMs: nil, leg: leg)
            s.locationNearPrevious = near
            return s
        }
        return [
            st(0, "Istanbul", "TR", 41.01, 28.98, .home, nil, 10, .tunnel),
            st(1, "Frankfurt am Main", "DE", 50.11, 8.68, .vpn, "203.0.113.10", 46, .tunnel),
            st(2, "Frankfurt am Main", "DE", 50.11, 8.68, .target, "192.0.2.140", 47, .open, near: true),
        ]
    }

    /// A route that leaves Istanbul and comes back, with a long city name and a silent target.
    private static func longNameStations() -> [TraceStation] {
        func st(_ id: Int, _ city: String, _ cc: String, _ lat: Double, _ lon: Double, _ kind: TraceStationKind,
                _ addr: String?, _ ms: Double, jump: Double? = nil, _ leg: TraceLegKind) -> TraceStation {
            TraceStation(id: id, city: city, countryCode: cc, point: GeoPoint(lat: lat, lon: lon), kind: kind,
                         hopCount: 2, address: addr, rttMs: ms, jumpMs: jump, leg: leg)
        }
        return [
            st(0, "Istanbul", "TR", 41.01, 28.98, .home, nil, 10, .tunnel),
            st(1, "Ankara", "TR", 39.93, 32.86, .hop, "198.51.100.12", 8, .tunnel),
            st(2, "Istanbul", "TR", 41.00, 28.97, .hop, "198.51.100.30", 9, .tunnel),
            st(3, "Frankfurt am Main", "DE", 50.11, 8.68, .vpn, "203.0.113.10", 49, .tunnel),
            st(4, "Boardman", "US", 45.84, -119.70, .lastAnswer, "192.0.2.200", 188, jump: 139, .open),
        ]
    }

    /// Sample route-mode stations for the map overlay (documentation addresses only).
    private static func sampleStations() -> [TraceStation] {
        func st(_ id: Int, _ city: String, _ cc: String?, _ lat: Double, _ lon: Double, _ kind: TraceStationKind,
                _ hops: Int, _ addr: String?, _ ms: Double, jump: Double? = nil, _ leg: TraceLegKind) -> TraceStation {
            TraceStation(id: id, city: city, countryCode: cc, point: GeoPoint(lat: lat, lon: lon), kind: kind,
                         hopCount: hops, address: addr, rttMs: ms, jumpMs: jump, leg: leg)
        }
        return [
            st(0, "Istanbul", "TR", 41.01, 28.98, .home, 3, nil, 11, .tunnel),
            st(1, "Sofia", "BG", 42.70, 23.32, .hop, 1, "198.51.100.42", 24, .tunnel),
            st(2, "Vienna", "AT", 48.21, 16.37, .hop, 1, "198.51.100.77", 38, jump: 14, .tunnel),
            st(3, "Frankfurt", "DE", 50.11, 8.68, .vpn, 1, "203.0.113.10", 46, .tunnel),
            st(4, "Amsterdam", "NL", 52.37, 4.90, .hop, 1, "192.0.2.81", 54, .open),
            st(5, "London", "GB", 51.51, -0.13, .target, 1, "192.0.2.140", 61, .open),
        ]
    }

    /// Whole-world dot map (row 0 = 90N, col 0 = 180W) to eyeball the land mask.
    private struct WorldDebugView: View {
        var body: some View {
            let size = CGSize(width: 920, height: 600)
            let frame = MapFrame(points: [GeoPoint(lat: -75, lon: 0), GeoPoint(lat: 75, lon: 0)], size: size,
                                 paddingFraction: 0, minSpanLon: 360)
            let dots = frame.landDots(spacing: 6)
            return Canvas { ctx, _ in
                for p in dots {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                             with: .color(Theme.ink))
                }
            }
            .background(Theme.ground)
        }
    }

    private static func render(_ s: Scenario, scheme: ColorScheme, now: Date, into directory: String) {
        // Theme colours resolve through NSAppearance, not the SwiftUI colour scheme.
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = nil }
        write(view(s, now: now), label: s.label, scheme: scheme, into: directory)
    }

    private static func write(_ content: AnyView, label: String, scheme: ColorScheme, into directory: String) {
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = nil }
        let framed = content
            .environment(\.colorScheme, scheme)
            .environment(\.previewMode, true)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed: \(label)\n".utf8))
            return
        }
        let file = "\(label)-\(scheme == .dark ? "dark" : "light").png"
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
    }
}
