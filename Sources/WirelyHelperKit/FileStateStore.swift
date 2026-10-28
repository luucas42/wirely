import Foundation
import Darwin
import WirelyCore

/// Persists `PersistedState` as JSON (dir 0700, file 0600, atomic replace).
public final class FileStateStore: StateStore {
    private let path: String

    public init(path: String = HelperConstants.statePath) {
        self.path = path
    }

    public func save(_ state: PersistedState) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        _ = chmod(dir, 0o700)

        let data = try JSONEncoder().encode(state)
        let tmp = dir + "/.state-\(UUID().uuidString).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = true
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                off += n
            }
        }
        let writeErr = errno
        if ok { fsync(fd) }
        close(fd)
        guard ok else {
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: writeErr) ?? .EIO)
        }
        if rename(tmp, path) != 0 {
            let e = errno
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
    }

    public func load() -> PersistedState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    public func clear() {
        unlink(path)
    }
}
