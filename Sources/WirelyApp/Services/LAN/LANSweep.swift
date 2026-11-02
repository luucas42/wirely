import Foundation
import Darwin

struct ARPEntry: Equatable {
    var ip: String
    var mac: MACAddress
}

struct SweepResult: Equatable {
    var entries: [ARPEntry]
    /// Every probe was refused (`EHOSTUNREACH`/`EPERM`): Local Network access is not allowed for Wirely.
    var denied: Bool
}

/// Fills the ARP cache with one UDP datagram per host, then reads it with `/usr/sbin/arp -an`.
enum LANSweep {
    static func run(network: NetworkInfo, hosts: [String]) async -> SweepResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(network: network, hosts: hosts))
            }
        }
    }

    private static func runBlocking(network: NetworkInfo, hosts: [String]) -> SweepResult {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return SweepResult(entries: [], denied: false) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var index = if_nametoindex(network.interface)
        if index != 0 { setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) }

        let first = send(fd, to: hosts)
        let denied = first.attempted > 0 && first.refused == first.attempted
        Thread.sleep(forTimeInterval: 1.2)
        var found = readARP(interface: network.interface)
        let missing = hosts.filter { h in !found.contains { $0.ip == h } }
        if !denied, !missing.isEmpty {
            _ = send(fd, to: missing)
            Thread.sleep(forTimeInterval: 1.2)
            for e in readARP(interface: network.interface) where !found.contains(where: { $0.ip == e.ip }) { found.append(e) }
        }
        return SweepResult(entries: found, denied: denied)
    }

    /// One byte to port 9 of each host, 1 ms apart. `refused` counts the Local Network refusals.
    private static func send(_ fd: Int32, to hosts: [String]) -> (attempted: Int, refused: Int) {
        var attempted = 0, refused = 0
        var byte: UInt8 = 0
        for host in hosts {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = UInt16(9).bigEndian
            guard inet_pton(AF_INET, host, &sa.sin_addr) == 1 else { continue }
            attempted += 1
            for attempt in 0..<2 {
                let n = withUnsafePointer(to: &sa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if n >= 0 { break }
                if (errno == ENOBUFS || errno == EAGAIN) && attempt == 0 { usleep(2000); continue }
                if errno == EHOSTUNREACH || errno == EPERM { refused += 1 }
                break
            }
            usleep(1000)
        }
        return (attempted, refused)
    }

    private static func readARP(interface: String) -> [ARPEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ARPTable.parse(String(decoding: data, as: UTF8.self), interface: interface).map { ARPEntry(ip: $0.ip, mac: $0.mac) }
    }
}
