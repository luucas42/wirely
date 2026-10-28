import Foundation
import WirelyCore

struct ExitLocation: Codable, Equatable {
    var city: String
    var countryCode: String
    var point: GeoPoint
    var fetchedAt: Date
}

protocol HTTPFetching: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> Data
}

struct URLSessionHTTPFetcher: HTTPFetching {
    func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Wirely/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Resolves an exit IP to a city/coordinates. Actor-isolated so cache access is race-free.
actor ExitLocator {
    static let cacheKey = "exitLocationCache"
    static let maxAge: TimeInterval = 30 * 86400

    private let http: HTTPFetching
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var cache: [String: ExitLocation]

    init(http: HTTPFetching, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([String: ExitLocation].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func location(for ip: String) async -> ExitLocation? {
        guard !Self.isPrivate(ip) else { return nil }
        if let hit = cache[ip], now().timeIntervalSince(hit.fetchedAt) < Self.maxAge { return hit }

        var found: ExitLocation?
        if let url = URL(string: "https://ipwho.is/\(ip)"),
           let data = try? await http.get(url, timeout: 4) {
            found = Self.parseIpwho(data, now: now())
        }
        if found == nil, let url = URL(string: "https://ipinfo.io/\(ip)/json"),
           let data = try? await http.get(url, timeout: 4) {
            found = Self.parseIpinfo(data, now: now())
        }
        guard let loc = found else { return nil }
        cache[ip] = loc
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
        return loc
    }

    // MARK: Parsing

    static func parseIpwho(_ data: Data, now: Date = Date()) -> ExitLocation? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (o["success"] as? Bool) == true,
              let city = o["city"] as? String, !city.isEmpty,
              let cc = o["country_code"] as? String,
              let lat = (o["latitude"] as? NSNumber)?.doubleValue,
              let lon = (o["longitude"] as? NSNumber)?.doubleValue
        else { return nil }
        return ExitLocation(city: city, countryCode: cc, point: GeoPoint(lat: lat, lon: lon), fetchedAt: now)
    }

    static func parseIpinfo(_ data: Data, now: Date = Date()) -> ExitLocation? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let city = o["city"] as? String, !city.isEmpty,
              let cc = o["country"] as? String,
              let loc = o["loc"] as? String
        else { return nil }
        let parts = loc.split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return ExitLocation(city: city, countryCode: cc, point: GeoPoint(lat: lat, lon: lon), fetchedAt: now)
    }

    // MARK: Private ranges

    private static let privateNets: [IPNetwork] = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8",
        "fc00::/7", "fe80::/10", "::1/128",
    ].compactMap { IPNetwork($0) }

    static func isPrivate(_ ip: String) -> Bool {
        guard let addr = IPAddress(ip) else { return true }   // unparseable: never look up
        return privateNets.contains { $0.contains(addr) }
    }
}
