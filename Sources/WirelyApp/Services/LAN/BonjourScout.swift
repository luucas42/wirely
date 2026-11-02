import Foundation
import Darwin

/// What Bonjour told about one IPv4 address.
struct BonjourSighting: Equatable {
    var ip: String
    var name: String?
    var services: Set<String>
    var model: String?
    var hostName: String?
}

/// Browses a fixed list of service types for a few seconds and resolves what it finds; never connects to a device.
enum BonjourScout {
    static let serviceTypes = [
        "_airplay._tcp", "_raop._tcp", "_companion-link._tcp", "_device-info._tcp", "_googlecast._tcp", "_ipp._tcp",
        "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_hap._tcp", "_homekit._tcp", "_hue._tcp",
        "_spotify-connect._tcp", "_smb._tcp", "_ssh._tcp", "_http._tcp", "_amzn-wplay._tcp", "_sonos._tcp",
    ]

    /// One resolved service.
    struct Hit: Equatable {
        var type: String
        var instance: String
        var ips: [String]
        var hostName: String?
        var txt: [String: String]
    }

    // MARK: Pure helpers

    /// `_raop` instances are named `MAC@Name`; the name is what a person knows.
    static func displayName(type: String, instance: String) -> String {
        guard type == "_raop._tcp", let at = instance.firstIndex(of: "@") else { return instance }
        let prefix = instance[..<at]
        guard prefix.count == 12, prefix.allSatisfy(\.isHexDigit) else { return instance }
        return String(instance[instance.index(after: at)...])
    }

    /// Lower is better: services whose instance name is the device's own name beat generic ones.
    static func namePriority(type: String) -> Int {
        switch type {
        case "_airplay._tcp", "_googlecast._tcp", "_companion-link._tcp", "_ipp._tcp", "_hap._tcp": return 0
        case "_http._tcp", "_smb._tcp", "_ssh._tcp": return 2
        default: return 1
        }
    }

    /// The model identifier a service's TXT record carries: `model` (`_device-info`), then `md` (`_googlecast`), then `am` (`_airplay`).
    static func modelCandidate(type: String, txt: [String: String]) -> (rank: Int, model: String)? {
        let pick: [(String, String, Int)] = [("_device-info._tcp", "model", 0), ("_googlecast._tcp", "md", 1), ("_airplay._tcp", "am", 2)]
        for (t, key, rank) in pick where t == type {
            if let v = txt[key], !v.isEmpty { return (rank, v) }
        }
        return nil
    }

    /// Merges resolved services per IPv4 address.
    static func merge(_ hits: [Hit]) -> [BonjourSighting] {
        struct Acc { var name: (rank: Int, value: String)?; var services = Set<String>(); var model: (rank: Int, value: String)?; var host: String? }
        var byIP: [String: Acc] = [:]
        for hit in hits {
            let name = displayName(type: hit.type, instance: hit.instance)
            let rank = namePriority(type: hit.type)
            let model = modelCandidate(type: hit.type, txt: hit.txt)
            for ip in hit.ips {
                var a = byIP[ip] ?? Acc()
                a.services.insert(hit.type)
                if !name.isEmpty, a.name == nil || rank < a.name!.rank { a.name = (rank, name) }
                if let m = model, a.model == nil || m.rank < a.model!.rank { a.model = (m.rank, m.model) }
                if a.host == nil { a.host = hit.hostName.flatMap { ReverseDNS.clean($0, ip: ip) } }
                byIP[ip] = a
            }
        }
        return byIP.keys.sorted().map { ip in
            let a = byIP[ip]!
            return BonjourSighting(ip: ip, name: a.name?.value, services: a.services, model: a.model?.value, hostName: a.host)
        }
    }

    // MARK: Browsing

    /// Browses for `seconds`, then lets the resolves that are still running finish (each is capped at 1.5 s).
    @MainActor static func browse(for seconds: Double = 2.5) async -> [BonjourSighting] {
        await withCheckedContinuation { cont in
            let session = Session(seconds: seconds) { cont.resume(returning: merge($0)) }
            session.start()
        }
    }

    private final class Session: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
        private let seconds: Double
        private var finish: (([Hit]) -> Void)?
        private var browsers: [NetServiceBrowser] = []
        private var services: [NetService] = []
        private var pending = 0
        private var browsing = true
        private var hits: [Hit] = []

        init(seconds: Double, finish: @escaping ([Hit]) -> Void) {
            self.seconds = seconds
            self.finish = finish
        }

        func start() {
            for type in BonjourScout.serviceTypes {
                let b = NetServiceBrowser()
                b.delegate = self
                b.searchForServices(ofType: type, inDomain: "local.")
                browsers.append(b)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
                browsing = false
                browsers.forEach { $0.stop() }
                complete(force: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1.6) { [self] in complete(force: true) }
        }

        private func complete(force: Bool) {
            guard let done = finish, force || (!browsing && pending == 0) else { return }
            finish = nil
            browsers.forEach { $0.stop() }
            services.forEach { $0.stop() }
            done(hits)
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
            guard browsing, finish != nil else { return }
            services.append(service)
            pending += 1
            service.delegate = self
            service.resolve(withTimeout: 1.5)
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            var ips: [String] = []
            for data in sender.addresses ?? [] {
                data.withUnsafeBytes { raw in
                    guard raw.count >= MemoryLayout<sockaddr_in>.size,
                          raw.loadUnaligned(as: sockaddr.self).sa_family == sa_family_t(AF_INET) else { return }
                    var sin = raw.loadUnaligned(as: sockaddr_in.self)
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil { ips.append(String(cString: buf)) }
                }
            }
            var txt: [String: String] = [:]
            if let d = sender.txtRecordData() {
                for (k, v) in NetService.dictionary(fromTXTRecord: d) { txt[k] = String(data: v, encoding: .utf8) ?? "" }
            }
            let type = sender.type.hasSuffix(".") ? String(sender.type.dropLast()) : sender.type
            hits.append(Hit(type: type, instance: sender.name, ips: ips, hostName: sender.hostName, txt: txt))
            resolved()
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { resolved() }

        private func resolved() {
            pending -= 1
            complete(force: false)
        }
    }
}
