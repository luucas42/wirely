import Foundation
import Darwin
import WirelyCore

/// Runs `wireguard-go -f utun` and talks to it over its UAPI unix socket.
public final class WireGuardGoLauncher: WireGuardLauncher {
    private let executable: String
    private let runDir: String
    private let logPath: String
    private let callbackQueue: DispatchQueue

    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var interfaceName: String?

    public var onUnexpectedExit: (() -> Void)?

    public init(executable: String, runDir: String = "/var/run/wireguard",
                logPath: String = HelperConstants.logPath, callbackQueue: DispatchQueue) {
        self.executable = executable
        self.runDir = runDir
        self.logPath = logPath
        self.callbackQueue = callbackQueue
    }

    public var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    private var nameFile: String { runDir + "/wirely.name" }

    public func start() throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw TunnelError.wireguard("wireguard-go bulunamadı: \(executable)")
        }
        do {
            try FileManager.default.createDirectory(
                atPath: runDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        } catch {
            throw TunnelError.wireguard("\(runDir) oluşturulamadı: \(error.localizedDescription)")
        }
        unlink(nameFile)

        let logDir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: logDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let logFD = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        let logHandle: FileHandle? = logFD >= 0 ? FileHandle(fileDescriptor: logFD, closeOnDealloc: true) : nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-f", "utun"]
        var env = ProcessInfo.processInfo.environment
        env["WG_TUN_NAME_FILE"] = nameFile
        env["LOG_LEVEL"] = "error"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = logHandle ?? FileHandle.nullDevice
        p.standardError = logHandle ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.callbackQueue.async {
                self.lock.lock()
                let wasStopped = self.stopped
                self.lock.unlock()
                if !wasStopped { self.onUnexpectedExit?() }
            }
        }

        lock.lock()
        stopped = false
        process = p
        lock.unlock()

        do {
            try p.run()
        } catch {
            markStoppedAndClear()
            throw TunnelError.wireguard("başlatılamadı: \(error.localizedDescription)")
        }

        guard let iface = waitForInterfaceName(p) else {
            stop()
            throw TunnelError.wireguard("arayüz adı alınamadı (zaman aşımı)")
        }
        lock.lock()
        interfaceName = iface
        lock.unlock()

        let sock = socketPath(iface)
        guard waitUntil({ FileManager.default.fileExists(atPath: sock) && p.isRunning }) else {
            stop()
            throw TunnelError.wireguard("UAPI soketi oluşmadı: \(sock)")
        }
        return iface
    }

    public func configure(_ uapiSet: String) throws {
        let response = try exchange(uapiSet)
        try check(response)
    }

    public func get() throws -> String {
        let response = try exchange("get=1\n\n")
        try check(response)
        return response
    }

    public func stop() {
        lock.lock()
        stopped = true
        let p = process
        process = nil
        onUnexpectedExit = nil
        interfaceName = nil
        lock.unlock()

        guard let p else { unlink(nameFile); return }
        if p.isRunning {
            p.terminate()  // SIGTERM
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(10_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        unlink(nameFile)
    }

    // MARK: - helpers

    private func markStoppedAndClear() {
        lock.lock()
        stopped = true
        process = nil
        lock.unlock()
    }

    private func socketPath(_ iface: String) -> String { runDir + "/\(iface).sock" }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private func waitForInterfaceName(_ p: Process) -> String? {
        var found: String?
        _ = waitUntil {
            guard p.isRunning else { return true }  // died early; give up
            guard let data = FileManager.default.contents(atPath: nameFile),
                  let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return false }
            found = s
            return true
        }
        return found
    }

    private func exchange(_ command: String) throws -> String {
        lock.lock()
        let iface = interfaceName
        lock.unlock()
        guard let iface else { throw TunnelError.wireguard("wireguard-go çalışmıyor") }
        do {
            let fd = try UnixSocket.connect(path: socketPath(iface), timeout: 5)
            defer { close(fd) }
            try UnixSocket.writeAll(fd, Data(command.utf8))
            let data = try UnixSocket.readUntilBlankLine(fd, maxBytes: 1 << 20)
            return String(decoding: data, as: UTF8.self)
        } catch let e as UnixSocketError {
            throw TunnelError.wireguard("UAPI: \(String(cString: strerror(e.code)))")
        }
    }

    private func check(_ response: String) throws {
        do {
            try UAPI.checkErrno(response)
        } catch UAPIError.errno(let n) {
            throw TunnelError.wireguard("UAPI hata kodu \(n)")
        } catch {
            throw TunnelError.wireguard("UAPI yanıtı geçersiz")
        }
    }
}
