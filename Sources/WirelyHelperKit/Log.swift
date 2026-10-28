import Foundation

/// Thread-safe append-only log file with ISO-8601 timestamps. Never pass secrets to `write`.
public final class FileLog {
    private let path: String
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(path: String) {
        self.path = path
    }

    public func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = "\(formatter.string(from: Date())) \(line)\n"
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
