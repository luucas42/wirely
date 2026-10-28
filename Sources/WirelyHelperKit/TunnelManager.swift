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
    private let log: (String) -> Void
    private let now: () -> Date

    private var active: Active?
    private var lastFailed: TunnelStatus?

    public var onStatusChange: ((TunnelStatus) -> Void)?

    public init(runner: CommandRunner, makeLauncher: @escaping () -> WireGuardLauncher,
                resolver: EndpointResolver, store: StateStore,
                log: @escaping (String) -> Void, now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.makeLauncher = makeLauncher
        self.resolver = resolver
        self.store = store
        self.log = log
        self.now = now
    }

    // MARK: - up

    public func up(name: String, configText: String) throws -> TunnelStatus {
        let started = DispatchTime.now()
        let config: TunnelConfig
        do {
            config = try TunnelConfig.parse(configText)
        } catch let e as ConfigError {
            throw TunnelError.config(e)
        }

        if active != nil { _ = down() }
        lastFailed = nil

        var resolved: [IPAddress?] = []
        for peer in config.peers {
            if let ep = peer.endpoint {
                do { resolved.append(try resolver.resolve(ep)) } catch { throw TunnelError.resolve(ep.host) }
            } else {
                resolved.append(nil)
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
            throw TunnelError.wireguard(describe(error))
        }

        var state = PersistedState(
            tunnelName: name, interface: iface, wireguardPID: launcher.pid,
            endpointRoutes: [], dnsBackups: [],
            dnsServers: config.interface.dnsServers, dnsSearch: config.interface.dnsSearchDomains,
            connectedAt: now(), ignoredKeys: config.ignoredKeys)

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

            if !config.interface.dnsServers.isEmpty {
                for service in DNSPlan.parseHardwareServices(runner.run(DNSPlan.listServiceOrder).stdout) {
                    state.dnsBackups.append(backup(of: service))
                    try persist(state)  // backup must be durable before DNS is touched
                    applyDNS(service: service, state: state)
                }
            }

            try persist(state)
        } catch {
            teardown(state, launcher: launcher, stopLauncher: true)
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
        guard let a = active else { return .disconnected }
        active = nil
        teardown(a.state, launcher: a.launcher, stopLauncher: true)
        onStatusChange?(.disconnected)
        return .disconnected
    }

    // MARK: - status

    public func status() -> TunnelStatus {
        guard let a = active else { return lastFailed ?? .disconnected }
        var s = TunnelStatus(state: .connected, tunnelName: a.state.tunnelName, interface: a.state.interface,
                             connectedAt: a.state.connectedAt, ignoredKeys: a.state.ignoredKeys)
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

        if !a.state.dnsServers.isEmpty {
            // Never re-read existing backups: the system DNS now holds our own servers.
            for b in a.state.dnsBackups { applyDNS(service: b.service, state: a.state) }
            let known = Set(a.state.dnsBackups.map(\.service))
            for service in DNSPlan.parseHardwareServices(runner.run(DNSPlan.listServiceOrder).stdout) where !known.contains(service) {
                a.state.dnsBackups.append(backup(of: service))
                applyDNS(service: service, state: a.state)
            }
        }

        active = a
        do { try store.save(a.state) } catch { log("Durum kaydedilemedi: \(describe(error))") }
    }

    // MARK: - stale cleanup

    public func cleanupStale() {
        guard active == nil, let state = store.load() else { return }
        if let pid = state.wireguardPID {
            let out = runner.run(NetCommand("/bin/ps", ["-p", String(pid), "-o", "comm="])).stdout
            if out.contains("wireguard-go") {
                _ = runner.run(NetCommand("/bin/kill", ["-TERM", String(pid)]))
            }
        }
        teardown(state, launcher: nil, stopLauncher: false)
    }

    // MARK: - internals

    private func handleUnexpectedExit(of launcher: WireGuardLauncher) {
        guard let a = active, a.launcher === launcher else { return }
        active = nil
        teardown(a.state, launcher: launcher, stopLauncher: false)
        let s = TunnelStatus(state: .failed, tunnelName: a.state.tunnelName, interface: a.state.interface,
                             message: "wireguard-go beklenmedik şekilde kapandı",
                             ignoredKeys: a.state.ignoredKeys)
        lastFailed = s
        onStatusChange?(s)
    }

    /// Undoes everything recorded in `state`. Failures are logged and never stop the remaining steps.
    private func teardown(_ state: PersistedState, launcher: WireGuardLauncher?, stopLauncher: Bool) {
        if let launcher {
            launcher.onUnexpectedExit = nil
            if stopLauncher { launcher.stop() }
        }
        for r in state.endpointRoutes {
            let c = NetPlan.endpointRouteDelete(r.ip)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
        }
        for b in state.dnsBackups {
            for c in DNSPlan.restore(b) where runner.run(c).status != 0 {
                log("DNS geri yüklenemedi: \(c)")
            }
        }
        for n in state.rejectRoutes {
            let c = NetPlan.routeDelete(n)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
        }
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

    private func backup(of service: String) -> DNSBackup {
        DNSBackup(service: service,
                  servers: DNSPlan.parseList(runner.run(DNSPlan.getServers(service)).stdout),
                  searchDomains: DNSPlan.parseList(runner.run(DNSPlan.getSearchDomains(service)).stdout))
    }

    private func applyDNS(service: String, state: PersistedState) {
        for c in DNSPlan.apply(service: service, servers: state.dnsServers, search: state.dnsSearch)
        where runner.run(c).status != 0 {
            log("DNS ayarlanamadı: \(c)")
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
