import Foundation
import WirelyCore

/// Runs system commands (ifconfig, route, networksetup, ...) with a hard timeout.
public final class ProcessRunner: CommandRunner {
    private let log: (String) -> Void
    private let timeout: TimeInterval

    public init(log: @escaping (String) -> Void) {
        self.log = log
        self.timeout = 30
    }

    public func run(_ command: NetCommand) -> CommandResult {
        let result = execute(command)
        var line = "$ \(command) → \(result.status)"
        if result.status != 0 {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { line += " " + err }
        }
        log(line)
        return result
    }

    private func execute(_ command: NetCommand) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            return CommandResult(status: 127, stdout: "", stderr: "\(command.path): komut bulunamadı")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.path)
        process.arguments = command.args
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Wait on the termination callback, not `waitUntilExit()`: the latter polls a run loop and
        // can add ~65 ms per command, which made connecting (~25 commands) take seconds.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: "\(command.path): \(error.localizedDescription)")
        }

        // Drain both pipes while the process runs, otherwise output beyond the pipe buffer deadlocks.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var didTimeOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            didTimeOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        // Pipe EOF can be delayed if a grandchild inherited the fds; don't wait forever.
        _ = group.wait(timeout: .now() + 2)

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        if didTimeOut {
            return CommandResult(status: -1, stdout: stdout, stderr: "zaman aşımı (\(Int(timeout)) sn)")
        }
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
