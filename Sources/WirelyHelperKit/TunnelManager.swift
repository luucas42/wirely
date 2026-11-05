import Foundation
import WirelyCore

/// What the manager needs from the split-tunnel DNS proxy (a fake in tests).
public protocol SplitDNSServing: AnyObject {
    func start() throws
    func stop()
    func update(_ config: SplitDNSConfig)
    func resolveNow(name: String) -> [IPAddress]
}

extension SplitDNSProxy: SplitDNSServing {}

/// Orchestrates wireguard-go plus the routes/DNS changes `wg-quick` would make, with exact rollback.
/// Not thread-safe: callers must use one serial queue.
public final class TunnelManager {
    private struct Active {
        var state: PersistedState
        var launcher: WireGuardLauncher
        var split: SplitContext?
    }

    /// Everything about a running split-mode tunnel. The learn hook (proxy threads) only reads the `let`
    /// members and the thread-safe `table`; `rules`/`proxy`/`endpointIPs` belong to the manager queue.
    private final class SplitContext {
        var rules: [SplitRule]
        let config: TunnelConfig
        let iface: String
        let killSwitch: Bool
        /// Exclude mode: everything is tunnelled except the listed destinations (bypass routes).
        let exclude: Bool
        let table = SplitRouteTable()
        var proxy: SplitDNSServing?
        var endpointIPs: [IPAddress] = []
        /// Exclude mode with the kill switch: the normal DNS servers currently in the pf table (manager queue).
        var dnsTable: [String] = []
        private let lock = NSLock()
        private var capLogged = Set<SplitRule>()
        // Exclude mode: written on the manager queue, read by the learn hook on proxy threads.
        private var _defaults = DefaultRoutes(v4Gateway: nil, v4Interface: nil, v6Gateway: nil, v6Interface: nil)
        private var _filter = BypassFilter()

        init(rules: [SplitRule], config: TunnelConfig, iface: String, killSwitch: Bool, exclude: Bool = false) {
            self.rules = rules
            self.config = config
            self.iface = iface
            self.killSwitch = killSwitch
            self.exclude = exclude
        }

        /// The physical default gateway/interface that bypass routes use.
        var defaults: DefaultRoutes {
            get { lock.lock(); defer { lock.unlock() }; return _defaults }
            set { lock.lock(); defer { lock.unlock() }; _defaults = newValue }
        }
        /// What must never be bypass-routed.
        var filter: BypassFilter {
            get { lock.lock(); defer { lock.unlock() }; return _filter }
            set { lock.lock(); defer { lock.unlock() }; _filter = newValue }
        }

        var domains: [SplitRule] { rules.filter { $0.isDomain } }
        var staticTexts: [String] {
            exclude ? TunnelManager.excludeTableTexts(rules) : TunnelManager.staticTexts(rules, config)
        }
        var tunnelFamilies: Set<IPFamily> { Set(config.interface.addresses.map(\.address.family)) }

        func markCapLogged(_ rule: SplitRule) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return capLogged.insert(rule).inserted
        }
    }

    /// What the kill switch blocks in split mode besides learned addresses: the address/network rules and the
    /// profile's own (non-default) networks, which are routed through the tunnel on purpose. DNS-server host
    /// routes stay out: the normal DNS may be the same IP and blocking it would break all DNS.
    fileprivate static func staticTexts(_ rules: [SplitRule], _ config: TunnelConfig) -> [String] {
        var seen = Set<String>()
        let texts = rules.filter { !$0.isDomain }.map(\.text) + SplitCoverage.profileNetworks(config).map(\.description)
        return texts.filter { seen.insert($0).inserted }
    }

    /// Exclude mode: the static rule addresses/networks that may leave outside the tunnel (the pf table).
    /// IPv4 only; the bypass is not routed for IPv6.
    fileprivate static func excludeTableTexts(_ rules: [SplitRule]) -> [String] {
        var seen = Set<String>()
        return rules.compactMap { rule -> String? in
            switch rule {
            case .domain: return nil
            case .address(let a): return a.family == .v4 ? rule.text : nil
            case .network(let n): return n.address.family == .v4 ? rule.text : nil
            }
        }.filter { seen.insert($0).inserted }
    }

    /// The pf ruleset for the kill switch in any mode (`table` nil = full tunnel).
    fileprivate static func killRules(iface: String?, endpoints: [Endpoint], allowLAN: Bool, table: [String]?,
                                      exclude: Bool, allowDNS: Bool = false) -> String {
        guard let table else {
            return KillSwitchPlan.rules(iface: iface, endpoints: endpoints, allowLAN: allowLAN, allowDNS: allowDNS)
        }
        if exclude {
            return KillSwitchPlan.excludeRules(iface: iface, endpoints: endpoints, allowLAN: allowLAN,
                                               table: table, allowDNS: allowDNS)
        }
        return KillSwitchPlan.splitRules(iface: iface, endpoints: endpoints, table: table)
    }

    private let runner: CommandRunner
    private let makeLauncher: () -> WireGuardLauncher
    private let resolver: EndpointResolver
    private let store: StateStore
    private let dns: DNSConfigurator
    private let firewall: Firewall
    private let log: (String) -> Void
    private let now: () -> Date
    private let makeSplitProxy: (SplitDNSConfig, @escaping (SplitRule, [IPAddress]) -> Void) -> SplitDNSServing
    private let normalDNS: NormalDNSSource
    private let background: (@escaping () -> Void) -> Void
    private let ledger: BypassLedger

    private var active: Active?
    private var lastFailed: TunnelStatus?
    /// The tunnel dropped while its kill switch was armed: everything is torn down except the pf
    /// rules, which keep blocking traffic until the user reconnects or disconnects.
    private var held: PersistedState?

    public var onStatusChange: ((TunnelStatus) -> Void)?

    public init(runner: CommandRunner, makeLauncher: @escaping () -> WireGuardLauncher,
                resolver: EndpointResolver, store: StateStore, dns: DNSConfigurator, firewall: Firewall,
                log: @escaping (String) -> Void, now: @escaping () -> Date = Date.init,
                makeSplitProxy: @escaping (SplitDNSConfig, @escaping (SplitRule, [IPAddress]) -> Void) -> SplitDNSServing
                    = { SplitDNSProxy(listen: IPAddress("127.0.0.1")!, port: 53, config: $0, onLearn: $1) },
                normalDNS: NormalDNSSource = SystemDNSUpstreams(),
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                ledger: BypassLedger = BypassLedger()) {
        self.runner = runner
        self.makeLauncher = makeLauncher
        self.resolver = resolver
        self.store = store
        self.dns = dns
        self.firewall = firewall
        self.log = log
        self.now = now
        self.makeSplitProxy = makeSplitProxy
        self.normalDNS = normalDNS
        self.background = background
        self.ledger = ledger
    }

    // MARK: - up

    public func up(name: String, configText: String, killSwitch: Bool = false, allowLAN: Bool = true,
                   split: [SplitRule]? = nil, splitExclude: Bool = false) throws -> TunnelStatus {
        let started = DispatchTime.now()
        let config: TunnelConfig
        do {
            config = try TunnelConfig.parse(configText)
        } catch let e as ConfigError {
            throw TunnelError.config(e)
        }
        // nil = full tunnel (everything below is unchanged); non-nil, even empty = split mode.
        let exclude = split != nil && splitExclude
        let staticTable: [String]? = split.map {
            exclude ? TunnelManager.excludeTableTexts($0) : TunnelManager.staticTexts($0, config)
        }

        // Hand over from the current tunnel (or from blocking after a drop). If both sides use the
        // kill switch, pf stays engaged throughout, so there's no unprotected gap while switching.
        var blockToken: String?            // pf reference still held from before this call
        var wasBlocking = false
        if let a = active {
            active = nil
            let keep = killSwitch && a.state.killSwitch != nil
            teardown(a.state, launcher: a.launcher, stopLauncher: true, keepKillSwitch: keep, split: a.split)
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
            let rules = TunnelManager.killRules(iface: nil, endpoints: [], allowLAN: allowLAN, table: staticTable,
                                                exclude: exclude, allowDNS: true)
            _ = try? firewall.engage(rules: rules, token: blockToken)
        }

        var resolved: [IPAddress?] = []
        for peer in config.peers {
            if let ep = peer.endpoint {
                do {
                    resolved.append(try resolver.resolve(ep))
                } catch {
                    if wasBlocking { keepBlocking(name: name, token: blockToken, allowLAN: allowLAN, splitTable: staticTable, splitExclude: exclude) }
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
                let rules = TunnelManager.killRules(iface: nil, endpoints: serverEndpoints, allowLAN: allowLAN,
                                                    table: staticTable, exclude: exclude)
                let token = try firewall.engage(rules: rules, token: blockToken)
                killRecord = KillSwitchRecord(token: token, allowLAN: allowLAN, endpoints: serverEndpoints,
                                              splitTable: staticTable, splitExclude: exclude ? true : nil)
            } catch {
                if wasBlocking { keepBlocking(name: name, token: blockToken, allowLAN: allowLAN, splitTable: staticTable, splitExclude: exclude) }
                throw TunnelError.commandFailed("kill switch: \(describe(error))")
            }
        }

        let targets: [IPNetwork]
        if exclude {
            targets = NetPlan.routeTargets(config)   // exactly the full-tunnel routes; bypass routes come after
        } else if let split {
            let planned = splitStaticTargets(config, split)
            targets = planned.targets
            for t in planned.skipped { log("Bölünmüş tünel: \(t) atlandı (tünelde bu aile için adres yok)") }
        } else {
            targets = NetPlan.routeTargets(config)
        }
        let defaults = readDefaultRoutes()
        var physicalMTU: Int?
        var connectedSubnets: [IPNetwork] = []
        if let physical = defaults.v4Interface {
            let ifconfig = runner.run(NetPlan.ifconfigShow(physical)).stdout
            physicalMTU = NetPlan.parseMTU(ifconfig: ifconfig)
            connectedSubnets = NetPlan.parseIPv4Subnets(ifconfig: ifconfig)
        }

        let launcher = makeLauncher()
        let iface: String
        do {
            iface = try launcher.start()
        } catch {
            launcher.stop()
            if let k = killRecord {
                if wasBlocking { keepBlocking(name: name, token: k.token, allowLAN: allowLAN, splitTable: staticTable, splitExclude: exclude) }
                else { firewall.disengage(token: k.token) }
            }
            throw TunnelError.wireguard(describe(error))
        }

        var state = PersistedState(
            tunnelName: name, interface: iface, wireguardPID: launcher.pid,
            endpointRoutes: [], dnsBackups: [],
            dnsServers: split == nil || exclude ? config.interface.dnsServers : [],
            dnsSearch: split == nil || exclude ? config.interface.dnsSearchDomains : [],
            connectedAt: now(), ignoredKeys: config.ignoredKeys, killSwitch: killRecord,
            split: split?.map(\.text))
        let splitCtx = split.map {
            SplitContext(rules: $0, config: config, iface: iface, killSwitch: killRecord != nil, exclude: exclude)
        }
        splitCtx?.endpointIPs = resolved.compactMap { $0 }
        if let splitCtx, exclude {
            splitCtx.defaults = defaults
            splitCtx.filter = BypassFilter(endpoints: splitCtx.endpointIPs,
                                           profileNets: SplitCoverage.profileNetworks(config),
                                           connected: connectedSubnets)
        }

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

            if let splitCtx, exclude {
                try addBypassRoutes(for: splitCtx, plan: bypassPlan(splitCtx, splitCtx.rules), routes: defaults)
            }

            if let k = killRecord {
                do {
                    let rules = TunnelManager.killRules(iface: iface, endpoints: k.endpoints, allowLAN: k.allowLAN,
                                                        table: k.splitTable, exclude: k.splitExclude == true)
                    _ = try firewall.engage(rules: rules, token: k.token)
                } catch {
                    throw TunnelError.commandFailed("kill switch: \(describe(error))")
                }
            }

            // Exclude mode with domain rules runs the DNS proxy; every way that can fail lands in the
            // full-tunnel DNS below, exactly as a full-tunnel `up` does (never "DNS untouched").
            var excludeProxy = false
            if let splitCtx, splitCtx.exclude, !splitCtx.domains.isEmpty {
                excludeProxy = try startExcludeDNS(splitCtx, state: &state)
            }
            if let splitCtx, !splitCtx.exclude {
                try startSplitDNS(splitCtx, state: &state)
            } else if !excludeProxy, !config.interface.dnsServers.isEmpty {
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
            teardown(state, launcher: launcher, stopLauncher: true, keepKillSwitch: wasBlocking, split: splitCtx)
            if wasBlocking {
                keepBlocking(name: name, token: state.killSwitch?.token, allowLAN: allowLAN, splitTable: staticTable)
            }
            throw error
        }

        active = Active(state: state, launcher: launcher, split: splitCtx)
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
        teardown(a.state, launcher: a.launcher, stopLauncher: true, split: a.split)
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
        if let ctx = a.split {
            let learned = ctx.table.status
            s.split = Dictionary(uniqueKeysWithValues: ctx.domains.map {
                ($0.text, learned[$0.text] ?? SplitRuleStatus(routed: 0, rejected: 0))
            })
            s.splitDNS = ctx.proxy != nil
            s.splitExclude = ctx.exclude
        }
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

        if let ctx = a.split, ctx.exclude { repointBypassRoutes(ctx, defaults) }

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
        if let ctx = a.split, let proxy = ctx.proxy, let cfg = splitDNSConfig(ctx, backups: a.state.dnsBackups) {
            proxy.update(cfg)   // the normal upstreams follow the network
            if ctx.exclude { swapDNSTable(ctx, cfg) }
        }
        if let desired { applyDNS(desired) }   // after the save, so new backups are durable first
    }

    // MARK: - split tunnel

    /// Replaces the rules of the running split tunnel. Must run on the manager queue.
    @discardableResult
    public func updateSplit(_ newRules: [SplitRule]) throws -> TunnelStatus {
        guard var a = active, let ctx = a.split else { throw TunnelError.splitNotActive }
        var seen = Set<SplitRule>()
        let rules = newRules.filter { seen.insert($0).inserted }
        if ctx.exclude { return try updateExcludeSplit(&a, ctx, rules) }
        let old = ctx.rules
        let oldStatic = Set(TunnelManager.staticTexts(old, ctx.config))
        let newStatic = TunnelManager.staticTexts(rules, ctx.config)
        let oldDomains = old.filter { $0.isDomain }
        let newDomains = rules.filter { $0.isDomain }
        let removedDomains = oldDomains.filter { !newDomains.contains($0) }
        let addedDomains = newDomains.filter { !oldDomains.contains($0) }

        // Static routes: diff the whole target set so a route shared with the profile or its DNS stays.
        let before = splitStaticTargets(ctx.config, old).targets
        ctx.rules = rules
        let planned = splitStaticTargets(ctx.config, rules)
        for n in before where !planned.targets.contains(n) {
            let c = NetPlan.routeDelete(n)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
        }
        let addedTargets = planned.targets.filter { !before.contains($0) }
        for t in planned.skipped where !before.contains(t) {
            log("Bölünmüş tünel: \(t) atlandı (tünelde bu aile için adres yok)")
        }
        if !addedTargets.isEmpty {
            let defaults = readDefaultRoutes()
            for ip in ctx.endpointIPs where NetPlan.endpointNeedsBypass(ip, targets: addedTargets)
                && !a.state.endpointRoutes.contains(where: { $0.ip == ip }) {
                let c = NetPlan.endpointRouteAdd(ip, routes: defaults)
                if runner.run(c).status == 0 { a.state.endpointRoutes.append(EndpointRoute(ip: ip, command: c)) }
                else { log("Uç nokta yönlendirmesi eklenemedi: \(c)") }
            }
            let adds = NetPlan.routeAddCommands(iface: ctx.iface, targets: addedTargets,
                                                addresses: ctx.config.interface.addresses)
            for c in adds {
                let r = runner.run(c)
                if r.status != 0 { log("Yönlendirme eklenemedi: \(c) (\(r.stderr))") }
            }
        }

        // Domains: first make the proxy stop learning the removed ones, then drop what they owned.
        var pfDelete = oldStatic.subtracting(newStatic)
        let pfAdd = newStatic.filter { !oldStatic.contains($0) }
        if let proxy = ctx.proxy {
            if newDomains.isEmpty {
                proxy.stop()
                ctx.proxy = nil
                do { try dns.apply(a.state.dnsBackups) } catch { log("DNS geri yüklenemedi: \(describe(error))") }
                a.state.dnsBackups = []
                a.state.dnsServers = []
                a.state.dnsSearch = []
            } else if let cfg = splitDNSConfig(ctx, backups: a.state.dnsBackups) {
                proxy.update(cfg)
            } else {
                log("Bölünmüş tünel: DNS yukarı akışı bulunamadı, kurallar güncellenemedi")
            }
        }
        for rule in removedDomains {
            for ip in ctx.table.forget(rule: rule) {
                let c = NetPlan.hostRouteDelete(ip)
                if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
                pfDelete.insert(ip.description)
            }
        }
        let keptStatic = Set(newStatic)
        let learned = Set(ctx.table.allAddresses.map(\.description))
        let toDelete = pfDelete.subtracting(keptStatic).subtracting(learned).sorted()
        if ctx.killSwitch {
            if !toDelete.isEmpty { _ = runner.run(KillSwitchPlan.tableDelete(toDelete)) }
            if !pfAdd.isEmpty { _ = runner.run(KillSwitchPlan.tableAdd(pfAdd)) }
            a.state.killSwitch?.splitTable = newStatic + ctx.table.allAddresses.map(\.description)
        }

        if ctx.proxy == nil, !newDomains.isEmpty {
            do { try startSplitDNS(ctx, state: &a.state) } catch {
                active = a
                throw error
            }
        } else if let proxy = ctx.proxy, !addedDomains.isEmpty {
            preResolve(addedDomains, with: proxy)
        } else if !removedDomains.isEmpty {
            flushDNSCache()
        }

        a.state.split = rules.map(\.text)
        active = a
        try persist(a.state)
        let s = status()
        onStatusChange?(s)
        return s
    }

    // MARK: - split tunnel, exclude mode

    /// Bypass routes the rules call for, plus what was left out and why.
    private struct BypassPlan {
        var routes: [IPNetwork] = []
        var skipped: [(net: IPNetwork, reason: String)] = []
        var ipv6: [SplitRule] = []
    }

    /// IPv4 address/network rules not on the skip list. Domain rules own learned addresses (the learn hook).
    private func bypassPlan(_ ctx: SplitContext, _ rules: [SplitRule]) -> BypassPlan {
        let filter = ctx.filter
        var plan = BypassPlan()
        var seen = Set<IPNetwork>()
        for rule in rules {
            let net: IPNetwork
            switch rule {
            case .domain: continue
            case .address(let a): net = IPNetwork(address: a, prefixLength: a.family == .v4 ? 32 : 128)
            case .network(let n): net = n
            }
            guard net.address.family == .v4 else { plan.ipv6.append(rule); continue }
            guard seen.insert(net).inserted else { continue }
            if let reason = filter.skipReason(net) { plan.skipped.append((net, reason)) } else { plan.routes.append(net) }
        }
        return plan
    }

    private func bypassRouteDelete(_ net: IPNetwork) -> NetCommand {
        net.prefixLength == (net.address.family == .v4 ? 32 : 128) ? NetPlan.hostRouteDelete(net.address)
                                                                   : NetPlan.routeDelete(net)
    }

    private func logBypassPlan(_ plan: BypassPlan, only fresh: ((IPNetwork) -> Bool)? = nil) {
        for (net, reason) in plan.skipped where fresh?(net) ?? true {
            log("Bölünmüş tünel: \(net) atlandı (\(reason))")
        }
        for rule in plan.ipv6 {
            log("Bölünmüş tünel: \(rule.text) atlandı (IPv6 dışlamaları desteklenmiyor)")
        }
    }

    /// Records the routes in the ledger first, then adds them via the physical gateway. A failed `route add`
    /// is logged and forgotten (the destination just stays in the tunnel); a failed ledger write throws.
    private func addBypassRoutes(for ctx: SplitContext, plan: BypassPlan, routes: DefaultRoutes) throws {
        logBypassPlan(plan)
        do { try ledger.add(plan.routes) } catch {
            throw TunnelError.commandFailed("durum kaydedilemedi: \(describe(error))")
        }
        var failed: [IPNetwork] = []
        for n in plan.routes {
            let c = NetPlan.bypassRouteAdd(n, routes: routes)
            let r = runner.run(c)
            if r.status != 0 {
                log("Yönlendirme eklenemedi: \(c) (\(r.stderr))")
                failed.append(n)
            }
        }
        ledger.remove(failed)
    }

    /// Deletes every ledger route and empties the ledger (teardown, crash cleanup).
    private func dropBypassRoutes() {
        for n in ledger.all {
            let c = bypassRouteDelete(n)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
        }
        ledger.clear()
    }

    private func hostNet(_ ip: IPAddress) -> IPNetwork { IPNetwork(address: ip, prefixLength: ip.family == .v4 ? 32 : 128) }

    /// Exclude mode: listed names go to the network's own DNS servers, bound to the physical interface (so
    /// they leave outside the tunnel); everything else to the profile's servers through the tunnel, or to
    /// the same servers unbound when the profile has none. nil when the network has no usable server.
    private func excludeDNSConfig(_ ctx: SplitContext, backups: [DNSBackup]) -> SplitDNSConfig? {
        let physical = ctx.defaults.v4Interface
        let listed = normalDNS.normalUpstreams(backups: backups)
            .filter { !$0.isLoopbackOrUnspecified }
            .map { DNSUpstream(address: $0, interface: physical) }
        if listed.isEmpty { return nil }
        let families = ctx.tunnelFamilies
        var normal = ctx.config.interface.dnsServers.filter { families.contains($0.family) }.map { DNSUpstream(address: $0) }
        if normal.isEmpty { normal = listed.map { DNSUpstream(address: $0.address) } }
        return SplitDNSConfig(rules: ctx.rules, listed: listed, normal: normal, tunnelIPv6: false)
    }

    /// Exclude mode: starts the proxy and points every service at it; false (nothing changed) on every
    /// failure, so the caller keeps the full-tunnel DNS. Backups already taken (full-tunnel DNS is applied)
    /// are reused: a new snapshot would capture our own servers.
    private func startExcludeDNS(_ ctx: SplitContext, state: inout PersistedState) throws -> Bool {
        guard ctx.proxy == nil, !ctx.domains.isEmpty else { return false }
        let backups: [DNSBackup]
        if state.dnsBackups.isEmpty {
            do { backups = try dns.snapshot() } catch {
                log("Bölünmüş tünel: DNS okunamadı, site kuralları devre dışı: \(describe(error))")
                return false
            }
        } else {
            backups = state.dnsBackups
        }
        guard let cfg = excludeDNSConfig(ctx, backups: backups) else {
            log("Bölünmüş tünel: kullanılabilir DNS sunucusu yok, site kuralları devre dışı")
            return false
        }
        let proxy = makeSplitProxy(cfg, makeLearnHook(ctx))
        do { try proxy.start() } catch {
            log("Bölünmüş tünel: DNS vekili başlatılamadı (\(error)), site kuralları devre dışı")
            return false
        }
        ctx.proxy = proxy
        // The normal servers must pass pf for the listed names' lookups.
        ctx.dnsTable = cfg.listed.map(\.address.description)
        if ctx.killSwitch, !ctx.dnsTable.isEmpty { _ = runner.run(KillSwitchPlan.tableAdd(ctx.dnsTable)) }
        state.dnsBackups = backups
        state.dnsServers = [IPAddress("127.0.0.1")!]   // search domains stay the profile's
        try persist(state)  // backups must be durable before DNS is touched
        applyDNS(tunnelDNS(for: backups.map(\.service), state: state))
        preResolve(ctx.domains, with: proxy)
        return true
    }

    /// Network change in exclude mode, steps 1-3: new gateway into the context, new connected subnets into
    /// the skip filter, then every ledger route (static and learned) is deleted and added via the new gateway.
    /// A route that now falls inside a directly connected subnet is dropped instead of re-pointed.
    private func repointBypassRoutes(_ ctx: SplitContext, _ defaults: DefaultRoutes) {
        ctx.defaults = defaults
        var filter = ctx.filter
        filter.connected = []
        if let physical = defaults.v4Interface {
            filter.connected = NetPlan.parseIPv4Subnets(ifconfig: runner.run(NetPlan.ifconfigShow(physical)).stdout)
        }
        ctx.filter = filter
        var dropped: [IPNetwork] = []
        for n in ledger.all {
            if runner.run(bypassRouteDelete(n)).status != 0 { log("Yönlendirme silinemedi: \(bypassRouteDelete(n))") }
            if let reason = filter.skipReason(n) {
                log("Bölünmüş tünel: \(n) artık atlandı (\(reason))")
                dropped.append(n)
                continue
            }
            let c = NetPlan.bypassRouteAdd(n, routes: defaults)
            let r = runner.run(c)
            if r.status != 0 { log("Yönlendirme eklenemedi: \(c) (\(r.stderr))") }
        }
        ledger.remove(dropped)
    }

    /// Network change in exclude mode, step 5: the old normal DNS entries out of the pf table, the new in.
    private func swapDNSTable(_ ctx: SplitContext, _ cfg: SplitDNSConfig) {
        let new = cfg.listed.map(\.address.description)
        let old = ctx.dnsTable
        ctx.dnsTable = new
        guard ctx.killSwitch else { return }
        let keep = Set(new).union(TunnelManager.excludeTableTexts(ctx.rules)).union(ctx.table.allAddresses.map(\.description))
        let toDelete = old.filter { !keep.contains($0) }
        let toAdd = new.filter { !old.contains($0) }
        if !toDelete.isEmpty { _ = runner.run(KillSwitchPlan.tableDelete(toDelete)) }
        if !toAdd.isEmpty { _ = runner.run(KillSwitchPlan.tableAdd(toAdd)) }
    }

    /// Live rule change in exclude mode: bypass routes, the pf table, the proxy's rules and what removed
    /// names learned. A route or table entry goes only when no rule (static or learned) owns it any more.
    private func updateExcludeSplit(_ a: inout Active, _ ctx: SplitContext, _ rules: [SplitRule]) throws -> TunnelStatus {
        let old = bypassPlan(ctx, ctx.rules)
        let new = bypassPlan(ctx, rules)
        let oldTable = Set(TunnelManager.excludeTableTexts(ctx.rules))
        let newTable = TunnelManager.excludeTableTexts(rules)
        let oldDomains = ctx.domains
        let newDomains = rules.filter { $0.isDomain }
        let removedDomains = oldDomains.filter { !newDomains.contains($0) }
        let addedDomains = newDomains.filter { !oldDomains.contains($0) }

        let added = new.routes.filter { !old.routes.contains($0) }
        let removed = old.routes.filter { !new.routes.contains($0) }
        let freshPlan = BypassPlan(routes: added, skipped: new.skipped, ipv6: new.ipv6.filter { !ctx.rules.contains($0) })
        let wasSkipped = Set(old.skipped.map(\.net))
        logBypassPlan(freshPlan, only: { !wasSkipped.contains($0) })
        do { try ledger.add(added) } catch {
            throw TunnelError.commandFailed("durum kaydedilemedi: \(describe(error))")
        }
        ctx.rules = rules
        let defaults = readDefaultRoutes()
        ctx.defaults = defaults

        // Domains: first make the proxy stop learning the removed ones, then drop what they owned.
        var pfDelete = oldTable.subtracting(newTable)
        if let proxy = ctx.proxy {
            if newDomains.isEmpty {
                proxy.stop()
                ctx.proxy = nil
                pfDelete.formUnion(ctx.dnsTable)
                ctx.dnsTable = []
                if ctx.config.interface.dnsServers.isEmpty {
                    do { try dns.apply(a.state.dnsBackups) } catch { log("DNS geri yüklenemedi: \(describe(error))") }
                    a.state.dnsBackups = []
                    a.state.dnsServers = []
                    a.state.dnsSearch = []
                } else {   // back to the full-tunnel DNS; the backups stay for teardown
                    a.state.dnsServers = ctx.config.interface.dnsServers
                    a.state.dnsSearch = ctx.config.interface.dnsSearchDomains
                    applyDNS(tunnelDNS(for: a.state.dnsBackups.map(\.service), state: a.state))
                }
            } else if let cfg = splitDNSConfig(ctx, backups: a.state.dnsBackups) {
                proxy.update(cfg)
                swapDNSTable(ctx, cfg)
            } else {
                log("Bölünmüş tünel: DNS yukarı akışı bulunamadı, kurallar güncellenemedi")
            }
        }
        let staticNow = Set(new.routes)
        for rule in removedDomains {
            for ip in ctx.table.forget(rule: rule) {
                pfDelete.insert(ip.description)
                let host = hostNet(ip)
                guard !staticNow.contains(host) else { continue }   // a static rule still owns this route
                let c = bypassRouteDelete(host)
                if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
                ledger.remove([host])
            }
        }

        // Static routes. A learned address already has its route (and ledger entry): leave those alone.
        let learnedHosts = Set(ctx.table.allAddresses.map(hostNet))
        for n in removed where !learnedHosts.contains(n) {
            let c = bypassRouteDelete(n)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
            ledger.remove([n])
        }
        var failed: [IPNetwork] = []
        for n in added where !learnedHosts.contains(n) {
            let c = NetPlan.bypassRouteAdd(n, routes: defaults)
            let r = runner.run(c)
            if r.status != 0 { log("Yönlendirme eklenemedi: \(c) (\(r.stderr))"); failed.append(n) }
        }
        ledger.remove(failed)

        let learned = Set(ctx.table.allAddresses.map(\.description))
        let toDelete = pfDelete.subtracting(newTable).subtracting(learned).subtracting(ctx.dnsTable).sorted()
        let toAdd = newTable.filter { !oldTable.contains($0) }
        if ctx.killSwitch {
            if !toDelete.isEmpty { _ = runner.run(KillSwitchPlan.tableDelete(toDelete)) }
            if !toAdd.isEmpty { _ = runner.run(KillSwitchPlan.tableAdd(toAdd)) }
            a.state.killSwitch?.splitTable = newTable + ctx.table.allAddresses.map(\.description)
        }

        if ctx.proxy == nil, !newDomains.isEmpty {
            do { _ = try startExcludeDNS(ctx, state: &a.state) } catch {
                active = a
                throw error
            }
        } else if let proxy = ctx.proxy, !addedDomains.isEmpty {
            preResolve(addedDomains, with: proxy)
        } else if !removedDomains.isEmpty {
            flushDNSCache()
        }

        a.state.split = rules.map(\.text)
        active = a
        try persist(a.state)
        let s = status()
        onStatusChange?(s)
        return s
    }

    /// Routes for split mode: rule addresses/networks, the profile's non-default AllowedIPs and covered DNS
    /// servers; targets of a family the tunnel has no address for are returned separately (not routed).
    private func splitStaticTargets(_ config: TunnelConfig, _ rules: [SplitRule]) -> (targets: [IPNetwork], skipped: [IPNetwork]) {
        func host(_ a: IPAddress) -> IPNetwork { IPNetwork(address: a, prefixLength: a.family == .v4 ? 32 : 128) }
        var targets = NetPlan.splitTargets(config: config, rules: rules)
        let explicit = Set(rules.compactMap { rule -> IPNetwork? in
            switch rule {
            case .domain: return nil
            case .address(let a): return host(a)
            case .network(let n): return n
            }
        } + SplitCoverage.profileNetworks(config))
        let uncoveredDNS = Set(config.interface.dnsServers.filter { !SplitCoverage.covers($0, config: config) }.map(host))
        targets.removeAll { uncoveredDNS.contains($0) && !explicit.contains($0) }
        let families = Set(config.interface.addresses.map(\.address.family))
        let skipped = targets.filter { !families.contains($0.address.family) }
        targets.removeAll { !families.contains($0.address.family) }
        return (targets, skipped)
    }

    /// Upstreams for the proxy: the profile's covered DNS servers for listed names, the network's own for the
    /// rest (or the profile's when the network has none). nil when there is nowhere to send queries.
    private func splitDNSConfig(_ ctx: SplitContext, backups: [DNSBackup]) -> SplitDNSConfig? {
        if ctx.exclude { return excludeDNSConfig(ctx, backups: backups) }
        let families = ctx.tunnelFamilies
        let listed = ctx.config.interface.dnsServers
            .filter { SplitCoverage.covers($0, config: ctx.config) && families.contains($0.family) }
            .map { DNSUpstream(address: $0) }
        var normal = normalDNS.normalUpstreams(backups: backups)
            .filter { !$0.isLoopbackOrUnspecified }
            .map { DNSUpstream(address: $0) }
        if normal.isEmpty { normal = listed }
        if normal.isEmpty { return nil }
        return SplitDNSConfig(rules: ctx.rules, listed: listed, normal: normal, tunnelIPv6: families.contains(.v6))
    }

    /// Starts the proxy and points every service at it. Any failure short of a state-save error leaves DNS
    /// untouched and the tunnel up with `splitDNS == false`.
    private func startSplitDNS(_ ctx: SplitContext, state: inout PersistedState) throws {
        guard ctx.proxy == nil, !ctx.domains.isEmpty else { return }
        let backups: [DNSBackup]
        do { backups = try dns.snapshot() } catch {
            log("Bölünmüş tünel: DNS okunamadı, site kuralları devre dışı: \(describe(error))")
            return
        }
        guard let cfg = splitDNSConfig(ctx, backups: backups) else {
            log("Bölünmüş tünel: kullanılabilir DNS sunucusu yok, site kuralları devre dışı")
            return
        }
        let proxy = makeSplitProxy(cfg, makeLearnHook(ctx))
        do { try proxy.start() } catch {
            log("Bölünmüş tünel: DNS vekili başlatılamadı (\(error)), site kuralları devre dışı")
            return
        }
        ctx.proxy = proxy
        state.dnsBackups = backups
        state.dnsServers = [IPAddress("127.0.0.1")!]
        state.dnsSearch = []
        try persist(state)  // backups must be durable before DNS is touched
        applyDNS(tunnelDNS(for: backups.map(\.service), state: state))
        preResolve(ctx.domains, with: proxy)
    }

    /// Looks the domain rules up now so their addresses are routed before the first real query, then
    /// flushes the system cache. Off the manager queue in production.
    private func preResolve(_ rules: [SplitRule], with proxy: SplitDNSServing) {
        let runner = self.runner
        background {
            for case .domain(let name) in rules { _ = proxy.resolveNow(name: name) }
            for c in NetPlan.flushDNSCache { _ = runner.run(c) }
        }
    }

    private func flushDNSCache() {
        for c in NetPlan.flushDNSCache { _ = runner.run(c) }
    }

    /// Runs on proxy threads: touches only the table (own lock), the runner and immutable context.
    private func makeLearnHook(_ ctx: SplitContext) -> (SplitRule, [IPAddress]) -> Void {
        let runner = self.runner
        let log = self.log
        if ctx.exclude {
            // Exclude mode: every usable IPv4 answer gets a bypass route via the gateway. Nothing goes into the
            // tunnel, so there is no AllowedIPs check and nothing is ever rejected. The ledger entry comes
            // before the route, so a crash in between cannot leave a route nobody knows about.
            let ledger = self.ledger
            return { rule, addresses in
                let usable = addresses.filter {
                    $0.family == .v4 && ctx.filter.skipReason(IPNetwork(address: $0, prefixLength: 32)) == nil
                }
                let fresh = ctx.table.learn(rule: rule, addresses: usable)
                let nets = fresh.map { IPNetwork(address: $0, prefixLength: 32) }
                if !nets.isEmpty {
                    do { try ledger.add(nets) } catch {
                        log("Bölünmüş tünel: durum kaydedilemedi, \(rule.text) adresleri yönlendirilmedi: \(error)")
                        return
                    }
                    // A failed add stays in the ledger: a static rule may own the same entry, and teardown's
                    // delete of a route that isn't there is harmless.
                    let routes = ctx.defaults
                    for n in nets {
                        let c = NetPlan.bypassRouteAdd(n, routes: routes)
                        let r = runner.run(c)
                        if r.status != 0 { log("Yönlendirme eklenemedi: \(c) (\(r.stderr))") }
                    }
                }
                if ctx.killSwitch, !fresh.isEmpty {
                    _ = runner.run(KillSwitchPlan.tableAdd(fresh.map(\.description)))
                }
                if ctx.table.count(for: rule) >= SplitRouteTable.defaultCap, ctx.markCapLogged(rule) {
                    log("Bölünmüş tünel: \(rule.text) için adres sınırına ulaşıldı (\(SplitRouteTable.defaultCap))")
                }
            }
        }
        return { rule, addresses in
            let families = ctx.tunnelFamilies
            let usable = addresses.filter { SplitCoverage.covers($0, config: ctx.config) && families.contains($0.family) }
            ctx.table.reject(rule: rule, addresses: addresses.filter { !usable.contains($0) })
            let fresh = ctx.table.learn(rule: rule, addresses: usable)
            for ip in fresh {
                let c = NetPlan.hostRouteAdd(ip, iface: ctx.iface)
                let r = runner.run(c)
                if r.status != 0 { log("Yönlendirme eklenemedi: \(c) (\(r.stderr))") }
            }
            if ctx.killSwitch, !fresh.isEmpty {
                _ = runner.run(KillSwitchPlan.tableAdd(fresh.map(\.description)))
            }
            if ctx.table.count(for: rule) >= SplitRouteTable.defaultCap, ctx.markCapLogged(rule) {
                log("Bölünmüş tünel: \(rule.text) için adres sınırına ulaşıldı (\(SplitRouteTable.defaultCap))")
            }
        }
    }

    // MARK: - stale cleanup

    public func cleanupStale() {
        guard active == nil, held == nil else { return }
        guard let state = store.load() else {
            dropBypassRoutes()   // bypass routes outlive the state file only after a crash in between
            return
        }
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
        teardown(a.state, launcher: launcher, stopLauncher: false, keepKillSwitch: a.state.killSwitch != nil,
                 split: a.split)
        if var k = a.state.killSwitch {
            // Split mode keeps blocking exactly the listed destinations, including everything learned. Exclude
            // mode keeps letting them through, plus the normal DNS servers the restored system DNS now uses.
            if let ctx = a.split {
                k.splitTable = ctx.staticTexts + ctx.table.allAddresses.map(\.description) + (ctx.exclude ? ctx.dnsTable : [])
            }
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
        let rules = TunnelManager.killRules(iface: nil, endpoints: record.endpoints, allowLAN: record.allowLAN,
                                            table: record.splitTable, exclude: record.splitExclude == true)
        _ = try? firewall.engage(rules: rules, token: record.token)
        let h = PersistedState(tunnelName: name, interface: "", wireguardPID: nil, endpointRoutes: [],
                               dnsBackups: [], dnsServers: [], dnsSearch: [], connectedAt: now(),
                               ignoredKeys: [], killSwitch: record)
        held = h
        do { try store.save(h) } catch { log("Durum kaydedilemedi: \(describe(error))") }
        lastFailed = TunnelStatus(state: .failed, tunnelName: name, message: message, killSwitch: true)
        log("kill switch holding: \(message)")
    }

    private func keepBlocking(name: String, token: String?, allowLAN: Bool, splitTable: [String]? = nil,
                              splitExclude: Bool = false) {
        hold(name: name, record: KillSwitchRecord(token: token, allowLAN: allowLAN, endpoints: [], splitTable: splitTable,
                                                  splitExclude: splitExclude ? true : nil),
             message: "Bağlantı kurulamadı; kill switch interneti engelliyor")
    }

    /// Undoes everything recorded in `state`. Failures are logged and never stop the remaining steps.
    private func teardown(_ state: PersistedState, launcher: WireGuardLauncher?, stopLauncher: Bool,
                          keepKillSwitch: Bool = false, split: SplitContext? = nil) {
        // The proxy goes first: nothing may learn routes or touch pf while the rest is undone. Learned routes
        // are utun routes and vanish with the interface.
        if let split {
            split.proxy?.stop()
            split.proxy = nil
        }
        if let launcher {
            launcher.onUnexpectedExit = nil
            if stopLauncher { launcher.stop() }
        }
        for r in state.endpointRoutes {
            let c = NetPlan.endpointRouteDelete(r.ip)
            if runner.run(c).status != 0 { log("Yönlendirme silinemedi: \(c)") }
        }
        dropBypassRoutes()
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

private extension SplitRule {
    var isDomain: Bool {
        if case .domain = self { return true }
        return false
    }
}
