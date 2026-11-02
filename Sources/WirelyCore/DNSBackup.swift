import Foundation

public struct DNSBackup: Equatable, Codable {
    public var service: String
    public var servers: [String]
    public var searchDomains: [String]
    public init(service: String, servers: [String], searchDomains: [String]) {
        self.service = service
        self.servers = servers
        self.searchDomains = searchDomains
    }
}
