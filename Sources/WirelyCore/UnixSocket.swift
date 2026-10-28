import Foundation
import Darwin

public struct UnixSocketError: Error, Equatable {
    public let code: Int32
    public init(code: Int32) { self.code = code }
}

/// Thin Darwin wrappers over AF_UNIX stream sockets; every failure throws `UnixSocketError(code: errno)`.
public enum UnixSocket {
    private static func makeAddr(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { throw UnixSocketError(code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError(code: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func setTimeout(_ fd: Int32, _ timeout: TimeInterval) {
        let whole = timeout.rounded(.down)
        var tv = timeval(tv_sec: Int(whole), tv_usec: Int32((timeout - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = try makeAddr(path)
        let fd = try makeSocket()
        setTimeout(fd, timeout)
        let rc = withSockaddr(&addr) { Darwin.connect(fd, $0, $1) }
        if rc != 0 {
            let e = errno
            close(fd)
            throw UnixSocketError(code: e)
        }
        return fd
    }

    public static func listen(path: String, mode: mode_t) throws -> Int32 {
        var addr = try makeAddr(path)
        let fd = try makeSocket()
        unlink(path)
        let rc = withSockaddr(&addr) { Darwin.bind(fd, $0, $1) }
        if rc != 0 {
            let e = errno
            close(fd)
            throw UnixSocketError(code: e)
        }
        if chmod(path, mode) != 0 || Darwin.listen(fd, 16) != 0 {
            let e = errno
            close(fd)
            unlink(path)
            throw UnixSocketError(code: e)
        }
        return fd
    }

    public static func accept(_ fd: Int32) throws -> Int32 {
        while true {
            let c = Darwin.accept(fd, nil, nil)
            if c >= 0 {
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                return c
            }
            if errno == EINTR { continue }
            throw UnixSocketError(code: errno)
        }
    }

    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError(code: errno)
                }
                off += n
            }
        }
    }

    /// Reads byte-by-byte (no over-read) until `done(buffer)` is true.
    private static func read(_ fd: Int32, maxBytes: Int, until done: ([UInt8]) -> Bool) throws -> [UInt8] {
        var out: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError(code: errno)
            }
            if n == 0 { throw UnixSocketError(code: ECONNRESET) }  // EOF before terminator
            out.append(byte)
            if done(out) { return out }
            if out.count >= maxBytes { throw UnixSocketError(code: EMSGSIZE) }
        }
    }

    public static func readLine(_ fd: Int32, maxBytes: Int) throws -> Data {
        let bytes = try read(fd, maxBytes: maxBytes) { $0.last == 0x0A }
        return Data(bytes.dropLast())
    }

    public static func readUntilBlankLine(_ fd: Int32, maxBytes: Int) throws -> Data {
        let bytes = try read(fd, maxBytes: maxBytes) { $0.count >= 2 && $0[$0.count - 1] == 0x0A && $0[$0.count - 2] == 0x0A }
        return Data(bytes)
    }
}
