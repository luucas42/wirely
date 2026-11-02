import Foundation
import WirelyCore

/// Orchestrates wireguard-go plus the routes/DNS changes `wg-quick` would make, with exact rollback.
/// Not thread-safe: callers must use one serial queue.
public final class TunnelManager {
    private struct Active {
        var state: PersistedState
        var launcher: WireGuardLauncher
    }

    private let runner: CommandRunner
    private let makeLauncher: () -> WireGuardLauncher
    private let resolver: EndpointResolver
    private let store: StateStore
    private let dns: DNSConfigurator
    private let firewall: Firewall
    private let log: (String) -> Void
    private let now: () -> Date

    private var active: Active?
    private var lastFailed: TunnelStatus?
    /// The tunnel dropped while its kill switch was armed: everything is torn down except the pf
    /// rules, which keep blocking traffic until the user reconnects or disconnects.
    private var held: PersistedState?

    public var onStatusChange: ((TunnelStatus) -> Void)?

    public init(runner: CommandRunner, makeLauncher: @escaping () -> WireGuardLauncher,
                resolver: EndpointResolver, store: StateStore, dns: DNSConfigurator, firewall: Firewall,
                log: @escaping (String) -> Void, now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.makeLauncher = makeLauncher
        self.resolver = resolver
        self.store = store
        self.dns = dns
        self.firewall = firewall
        self.log = log
        self.now = now
    }

    // MARK: - up

    public func up(name: String, configText: String, killSwitch: Bool = false, allowLAN: Bool = true) throws -> TunnelStatus {
        let started = DispatchTime.now()
        let config: TunnelConfig
        do {
            config = try TunnelConfig.parse(configText)
        } catch let e as ConfigError {
            throw TunnelError.config(e)
        }

        // Hand over from the current tunnel (or from blocking after a drop). If both sides use the
        // kill switch, pf stays engaged throughout, so there's no unprotected gap while switching.
        var blockToken: String?            // pf reference still held from before this call
        var wasBlocking = false
        if let a = active {
            active = nil
            let keep = killSwitch && a.state.killSwitch != nil
            teardown(a.state, launcher: a.launcher, stopLauncher: true, keepKillSwitch: keep)
            if keep { blockToken = a.state.killSwitch?.token; wasBlocking = true }
            onStatusChange?(.disconnected)
        }
        if let h = held {
            held = nil
            if killSwitch {
                blockToken = h.killSwitch?.token
                wasBlocking = true
            } else {
                firewall.disengage(token: h.killSwitch?.token)
            }
            store.clear()
        }
        lastFailed = nil

        // While blocking, a hostname endpoint can't be resolved: briefly allow DNS for the lookup.
        if wasBlocking, config.peers.contains(where: { $0.endpoint.map { IPAddress($0.host) == nil } ?? false }) {
            _ = try? firewall.engage(rules: KillSwitchPlan.rules(iface: nil, endpoints: [], allowLAN: allowLAN,
                                                                 allowDNS: true), token: blockToken)
        }

        var resolved: [IPAddress?] = []
        for peer in config.peers {
            if let ep = peer.endpoint {
                do {
                    resolved.append(try resolver.resolve(ep))
                } catch {
                    if wasBlocking { keepBlocking(name: name, token: blockToken, allowLAN: allowLAN) }
                    throw TunnelError.resolve(ep.host)
                }
            } else {
                resolved.append(nil)
            }
        }
        let serverEndpoints: [Endpoint] = zip(config.peers, resolved).compactMap { peer, ip in
            guard let ep = peer.endpoint, let ip else { return nil }
            return Endpoint(host: ip.description, port: ep.port)
        }

        // Arm the kill switch before wireguard-go starts, with its servers already reachable.
        var killRecord: KillSwitchRecord?
        if killSwitch {
            do {
                let token = try firewall.engage(rules: KillSwitchPlan.rules(iface: nil, endpoints: serverEndpoints,
                                                                            allowLAN: allowLAN), token: blockToken)
                killRecord = KillSwitchRecord(token: token, allowLAN: allowLAN, endpoints: serverEndpoints)
            } catch {
                if wasBlocking { keepBlocking(name: name, token: blockToken, allowLAN: allowLAN) }
                throw TunnelError.commandFailed("kill switch: \(describe(error))")
            }
        }

        let targets = NetPlan.routeTargets(config)
        let defaults = readDefaultRoutes()
        var physicalMTU: Int?
        if let physical = defaults.v4Interface {
            physicalMTU = NetPlan.parseMTU(ifconfig: runner.run(NetPlan.ifconfigShow(physical)).stdout)
        }

        let launcher = makeLauncher()
        let iface: String
        do {
            iface = try launcher.start()
        } catch {
            launcher.stop()
            if let k = killRecord {
                if wasBlocking { keepBlocking(name: name, token: k.token, allowLAN: allowLAN) }
                else { firewall.disengage(token: k.token) }
            }
            throw TunnelError.wireguard(describe(error))
        }

        var state = PersistedState(
            tunnelName: name, interface: iface, wireguardPID: launcher.pid,
            endpointRoutes: [], dnsBackups: [],
            dnsServers: config.interface.dnsServers, dnsSearch: config.interface.dnsSearchDomains,
            connectedAt: now(), ignoredKeys: config.ignoredKeys, killSwitch: killRecord)

        do {
            // Persist incrementally so a crash mid-up leaves a record for cleanupStale().
            try persist(state)
            let uapiEndpoints: [String?] = zip(config.peers, resolved).map { peer, ip in
                guard let ep = peer.endpoint, let ip else { return nil }
                return Endpoint(host: ip.description, port: ep.port).description
            }
            do {
                try launcher.configure(UAPI.setCommand(config, resolvedEndpoints: uapiEndpoints))
            } catch {
                throw TunnelError.wireguard(describe(error))
            }

            let mtu = NetPlan.tunnelMTU(configured: config.interface.mtu, physicalMTU: physicalMTU)
            for c in NetPlan.interfaceCommands(iface: iface, addresses: config.interface.addresses, mtu: mtu) {
                try runChecked(c)
            }

            var bypassed = Set<IPAddress>()
            for case let ip? in resolved where NetPlan.endpointNeedsBypass(ip, targets: targets) {
                guard bypassed.insert(ip).inserted else { continue }
                let c = NetPlan.endpointRouteAdd(ip, routes: defaults)
                try runChecked(c)
                state.endpointRoutes.append(EndpointRoute(ip: ip, command: c))
                try persist(state)
            }

            let addresses = config.interface.addresses
            let rejected = Set(NetPlan.rejectedTargets(targets, addresses: addresses))
            let adds = NetPlan.routeAddCommands(iface: iface, targets: targets, addresses: addresses)
            for (target, c) in zip(targets, adds) {
                let r = runner.run(c)
                if r.status != 0 {
                    if target.address.family == .v4 { throw TunnelError.commandFailed(c.description) }
                    log("IPv6 yönlendirmesi eklenemedi: \(c) (\(r.stderr))")
                } else if rejected.contains(target) {
                    state.rejectRoutes.append(target)
                    try persist(state)  // reject routes outlive the utun: record before anything else can fail
                }
            }

            if let k = killRecord {
                do {
                    _ = try firewall.engage(rules: KillSwitchPlan.rules(iface: iface, endpoints: k.endpoints,
                                                                        allowLAN: k.allowLAN), token: k.token)
                } catch {
                    throw TunnelError.commandFailed("kill switch: \(describe(error))")
                }
            }

            if !config.interface.dnsServers.isEmpty {
                // One read, one durable backup, one commit for every service.
                let current: [DNSBackup]
                do { current = try dns.snapshot() } catch { throw TunnelError.commandFailed("DNS: \(describe(error))") }
                state.dnsBackups = current
                try persist(state)  // backups must be durable before DNS is touched
                applyDNS(tunnelDNS(for: current.map(\.service), state: state))
            }

            try persist(state)
        } catch {
            // A failed reconnect while the kill switch was already blocking keeps blocking.
            teardown(state, launcher: launcher, stopLauncher: true, keepKillSwitch: wasBlocking)
            if wasBlocking { keepBlocking(name: name, token: state.killSwitch?.token, allowLAN: allowLAN) }
            throw error
        }

        active = Active(state: state, launcher: launcher)
        launcher.onUnexpectedExit = { [weak self, weak launcher] in
            guard let self, let launcher else { return }
            self.handleUnexpectedExit(of: launcher)
        }
        log("up \(name): \((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000) ms")
        let s = status()
        onStatusChange?(s)
        return s
    }

    // MARK: - down

    @discardableResult
    public func down() -> TunnelStatus {
        lastFailed = nil
        if let h = held {   // "Allow internet" after a drop
            held = nil
            firewall.disengage(token: h.killSwitch?.token)
            store.clear()
            log("kill switch released")
            onStatusChange?(.disconnected)
        }
        guard let a = active else { return .disconnected }
        let started = DispatchTime.now()
        active = nil
        teardown(a.state, launcher: a.launcher, stopLauncher: true)
        log("down \(a.state.tunnelName): \((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000) ms")
        onStatusChange?(.disconnected)
        return .disconnected
    }

    // MARK: - status

    public func status() -> TunnelStatus {
        guard let a = active else { return lastFailed ?? .disconnected }
        var s = TunnelStatus(state: .connected, tunnelName: a.state.tunnelName, interface: a.state.interface,
                             connectedAt: a.state.connectedAt, ignoredKeys: a.state.ignoredKeys,
                             killSwitch: a.state.killSwitch != nil)
        do {
            let snap = try UAPI.parseGet(try a.launcher.get())
            s.rxBytes = snap.totalRx
            s.txBytes = snap.totalTx
            s.lastHandshake = snap.latestHandshake
            s.endpoint = snap.peers.compactMap(\.endpoint).first
        } catch {
            s.message = "Durum okunamadı: \(describe(error))"
        }
        return s
    }

    // MARK: - network change

    public func networkChanged() {
        guard var a = active else { return }
        let defaults = readDefaultRoutes()

        for i in a.state.endpointRoutes.indices {
            let old = a.state.endpointRoutes[i]
            let fresh = NetPlan.endpointRouteAdd(old.ip, routes: defaults)
            if fresh != old.command || !bypassRouteHealthy(old.ip) {
                _ = runner.run(NetPlan.endpointRouteDelete(old.ip))
                if runner.run(fresh).status != 0 { log("Uç nokta yönlendirmesi güncellenemedi: \(fresh)") }
                a.state.endpointRoutes[i].command = fresh
            }
        }

        var desired: [DNSBackup]?
        if !a.state.dnsServers.isEmpty {
            do {
                let current = try dns.snapshot()
                // Back up services that appeared since connecting (e.g. a dock's Ethernet). Never re-read
                // known ones: they now hold our own servers.
                let known = Set(a.state.dnsBackups.map(\.service))
                a.state.dnsBackups += current.filter { !known.contains($0.service) }
                let wanted = tunnelDNS(for: current.map(\.service), state: a.state)
                if wanted != current { desired = wanted }   // unchanged → no commit, no resolver flush
            } catch {
                log("DNS okunamadı: \(describe(error))")
            }
        }

        active = a
        do { try store.save(a.state) } catch { log("Durum kaydedilemedi: \(describe(error))") }
        if let desired { applyDNS(desired) }   // after the save, so new backups are durable first
    }

    // MARK: - stale cleanup

    public func cleanupStale() {
        guard active == nil, held == nil, let state = store.load() else { return }
        if let pid = state.wireguardPID {
            let out = runner.run(NetCommand("/bin/ps", ["-p", String(pid), "-o", "comm="])).stdout
            if out.contains("wireguard-go") {
                _ = runner.run(NetCommand("/bin/kill", ["-TERM", String(pid)]))
            }
        }
        // pf rules survive a helper restart but not a reboot: only keep blocking if they're still loaded.
        let stillBlocking = state.killSwitch != nil && firewall.isEngaged()
        teardown(state, launcher: nil, stopLauncher: false, keepKillSwitch: stillBlocking)
        if stillBlocking, let k = state.killSwitch {
            hold(name: state.tunnelName, record: k, message: "Wirely servisi yeniden başladı; kill switch interneti engelliyor")
        }
    }

    // MARK: - internals

    private func handleUnexpectedExit(of launcher: WireGuardLauncher) {
        guard let a = active, a.launcher === launcher else { return }
        active = nil
        let message = "wireguard-go beklenmedik şekilde kapandı"
        teardown(a.state, launcher: launcher, stopLauncher: false, keepKillSwitch: a.state.killSwitch != nil)
        if let k = a.state.killSwitch {
            hold(name: a.state.tunnelName, record: k, message: message)
        } else {
            lastFailed = TunnelStatus(state: .failed, tunnelName: a.state.tunnelName, interface: a.state.interface,
                                      message: message, ignoredKeys: a.state.ignoredKeys)
        }
        if let s = lastFailed { onStatusChange?(s) }
    }

    /// Records that the kill switch keeps blocking after the tunnel is gone (and persists it, so a
    /// helper restart still knows), with block-only rules: no tunnel interface, servers reachable.
    private func hold(name: String, record: KillSwitchRecord, message: String) {
        _ = try? firewall.engage(rules: KillSwitchPlan.rules(iface: nil, endpoints: record.endpoints,
                                                             allowLAN: record.allowLAN), token: record.token)
        let h = PersistedState(tunnelName: name, interface: "", wireguardPID: nil, endpointRoutes: [],
                               dnsBackups: [], dnsServers: [], dnsSearch: [], connectedAt: now(),
                               ignoredKeys: [], killSwitch: record)
        held = h
        do { try store.save(h) } catch { log("Durum kaydedilemedi: \(describe(error))") }
        lastFailed = TunnelStatus(state: .failed, tunnelName: name, message: message, killSwitch: true)
        log("kill switch holding: \(message)")
    }

    private func keepBlocking(name: String, token: String?, allowLAN: Bool) {
        hold(name: name, record: KillSwitchRecord(token: token, allowLAN: allowLAN, endpoints: []),
             message: "Bağlantı kurulamadı; kill switch interneti engelliyor")
    }

    /// Undoes everything recorded in `state`. Failures are logged and never stop the remaining steps.
    private func teardown(_ state: PersistedState, launcher: WireGuardLauncher?, stopLauncher: Bool,
                          keepKillSwitch: Bool = false) {
        if let launcher {
            launcher.onUnexpectedExit = nil
            if stopLauncher { launcher.stop() }
        }
        for r in state.endpointRoutes {
            let c = NetPlan.endpointRouteDelete(r.ip)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
        }
        if !state.dnsBackups.isEmpty {
            do { try dns.apply(state.dnsBackups) } catch { log("DNS geri yüklenemedi: \(describe(error))") }
        }
        for n in state.rejectRoutes {
            let c = NetPlan.routeDelete(n)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
        }
        if let k = state.killSwitch, !keepKillSwitch { firewall.disengage(token: k.token) }
        store.clear()
    }

    private func persist(_ state: PersistedState) throws {
        do {
            try store.save(state)
        } catch {
            throw TunnelError.commandFailed("durum kaydedilemedi: \(describe(error))")
        }
    }

    private func readDefaultRoutes() -> DefaultRoutes {
        let v4 = NetPlan.parseDefaultRoute(netstat: runner.run(NetPlan.netstatCommand(.v4)).stdout)
        let v6 = NetPlan.parseDefaultRoute(netstat: runner.run(NetPlan.netstatCommand(.v6)).stdout)
        return DefaultRoutes(v4Gateway: v4.gateway, v4Interface: v4.interface,
                             v6Gateway: v6.gateway, v6Interface: v6.interface)
    }

    private func runChecked(_ c: NetCommand) throws {
        let r = runner.run(c)
        if r.status != 0 {
            log("Komut başarısız (\(r.status)): \(c) \(r.stderr)")
            throw TunnelError.commandFailed(c.description)
        }
    }

    /// True when the kernel still routes `ip` via a physical interface (not missing, not through a tunnel).
    private func bypassRouteHealthy(_ ip: IPAddress) -> Bool {
        let r = runner.run(NetPlan.routeGet(ip))
        guard r.status == 0, let iface = NetPlan.parseRouteGetInterface(r.stdout) else { return false }
        return !iface.hasPrefix("utun")
    }

    /// The profile's DNS for each of `services`.
    private func tunnelDNS(for services: [String], state: PersistedState) -> [DNSBackup] {
        services.map { DNSBackup(service: $0, servers: state.dnsServers.map(\.description), searchDomains: state.dnsSearch) }
    }

    private func applyDNS(_ settings: [DNSBackup]) {
        do { try dns.apply(settings) } catch { log("DNS ayarlanamadı: \(describe(error))") }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
