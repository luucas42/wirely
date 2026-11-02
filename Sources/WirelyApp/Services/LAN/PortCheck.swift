import Foundation
import Darwin

/// On-demand TCP port check of one device: connect, see whether it answers, close at once.
enum PortCheck {
    static let ports = [22, 53, 80, 139, 443, 445, 548, 554, 631, 1883, 3389, 5000, 8008, 8009, 8080, 8443, 9100, 62078]

    /// Open ports among `ports`, sorted, 16 connects at a time.
    static func openPorts(ip: String, interface: String?, timeout: Double = 0.4) async -> [Int] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let lock = NSLock()
                var open: [Int] = []
                for chunk in stride(from: 0, to: ports.count, by: 16).map({ Array(ports[$0..<min($0 + 16, ports.count)]) }) {
                    let group = DispatchGroup()
                    for port in chunk {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            if isOpen(ip: ip, port: port, interface: interface, timeout: timeout) { lock.withLock { open.append(port) } }
                            group.leave()
                        }
                    }
                    group.wait()
                }
                cont.resume(returning: open.sorted())
            }
        }
    }

    private static func isOpen(ip: String, port: Int, interface: String?, timeout: Double) -> Bool {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if let interface {
            var index = if_nametoindex(interface)
            if index != 0 { setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) }
        }
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}
