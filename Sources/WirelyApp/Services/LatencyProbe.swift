import Foundation
import Darwin

enum LatencyProbe {
    /// TCP connect RTT in ms (median of `attempts`), nil if every attempt fails.
    static func measure(host: String, port: UInt16, attempts: Int = 3, timeout: TimeInterval = 2) async -> Double? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var samples: [Double] = []
                for _ in 0..<max(1, attempts) {
                    if let ms = connectOnce(host: host, port: port, timeout: timeout) { samples.append(ms) }
                }
                cont.resume(returning: median(samples))
            }
        }
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Non-blocking connect + poll; elapsed time via the monotonic clock. Blocking: call off the main thread.
    private static func connectOnce(host: String, port: UInt16, timeout: TimeInterval) -> Double? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }

        let start = DispatchTime.now().uptimeNanoseconds
        let rc = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if rc != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(1, timeout * 1000)))
            guard pr > 0 else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }
}
