import Foundation
import Darwin
import WirelyCore
import WirelyHelperKit

let usage = """
Kullanım:
  wirely-helper daemon --allowed-uid <uid> --wireguard-go <yol>
  wirely-helper ctl status | down | up <conf-yolu> [--name N]
  wirely-helper cleanup
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usageExit() -> Never {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func makeManager(runner: CommandRunner, wireguardGo: String, queue: DispatchQueue, log: FileLog) -> TunnelManager {
    TunnelManager(
        runner: runner,
        makeLauncher: { WireGuardGoLauncher(executable: wireguardGo, callbackQueue: queue) },
        resolver: SystemResolver(),
        store: FileStateStore(),
        log: log.write)
}

func runDaemon(_ args: [String]) -> Never {
    guard getuid() == 0 else { fail("wirely-helper daemon root olarak çalışmalı") }
    guard let uidText = option("--allowed-uid", in: args), let uid = UInt32(uidText),
          let wgPath = option("--wireguard-go", in: args) else { usageExit() }

    signal(SIGPIPE, SIG_IGN)
    let fileLog = FileLog(path: HelperConstants.logPath)
    fileLog.write("daemon başlatıldı (izinli uid: \(uid))")

    let managerQueue = DispatchQueue(label: "wirely.manager")
    let manager = makeManager(runner: ProcessRunner(log: fileLog.write), wireguardGo: wgPath,
                              queue: managerQueue, log: fileLog)
    managerQueue.sync { manager.cleanupStale() }

    let server = HelperServer(
        socketPath: HelperConstants.socketPath, allowedUIDs: [uid_t(uid), 0], queue: managerQueue
    ) { request in
        let version = HelperConstants.helperVersion
        switch request.command {
        case .up:
            guard let config = request.config, let name = request.tunnelName else {
                return HelperResponse(ok: false, error: "Yapılandırma eksik", status: nil, helperVersion: version,
                                      errorCode: "request.missingConfig")
            }
            do {
                let status = try manager.up(name: name, configText: config)
                return HelperResponse(ok: true, error: nil, status: status, helperVersion: version)
            } catch {
                let coded = (error as? TunnelError)?.codeAndArg
                return HelperResponse(ok: false, error: error.localizedDescription,
                                      status: manager.status(), helperVersion: version,
                                      errorCode: coded?.code, errorArg: coded?.arg)
            }
        case .down:
            return HelperResponse(ok: true, error: nil, status: manager.down(), helperVersion: version)
        case .status, .version:
            return HelperResponse(ok: true, error: nil, status: manager.status(), helperVersion: version)
        }
    }
    do {
        try server.start()
    } catch {
        fileLog.write("soket açılamadı: \(error)")
        fail("Soket açılamadı: \(error)")
    }

    // Separate silent runner so the 10 s route poll doesn't flood the log.
    let monitor = NetworkMonitor(queue: managerQueue, runner: ProcessRunner(log: { _ in })) {
        manager.networkChanged()
    }
    monitor.start()

    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: managerQueue)
    term.setEventHandler {
        fileLog.write("SIGTERM alındı, tünel kapatılıyor")
        _ = manager.down()
        exit(0)
    }
    term.resume()

    RunLoop.main.run()
    exit(0)
}

func runCtl(_ args: [String]) -> Never {
    guard let sub = args.first else { usageExit() }
    let request: HelperRequest
    switch sub {
    case "status":
        request = HelperRequest(command: .status)
    case "down":
        request = HelperRequest(command: .down)
    case "up":
        guard args.count >= 2 else { usageExit() }
        let path = args[1]
        let name = option("--name", in: args) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            fail("Yapılandırma dosyası okunamadı: \(path)")
        }
        request = HelperRequest(command: .up, tunnelName: name, config: text)
    default:
        usageExit()
    }

    do {
        let response = try HelperClient().send(request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let status = response.status, let out = try? encoder.encode(status) {
            print(String(decoding: out, as: UTF8.self))
        }
        if !response.ok { fail(response.error ?? "Bilinmeyen hata") }
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}

func runCleanup() -> Never {
    guard getuid() == 0 else { fail("wirely-helper cleanup root olarak çalışmalı") }
    let fileLog = FileLog(path: HelperConstants.logPath)
    let queue = DispatchQueue(label: "wirely.manager")
    let manager = makeManager(runner: ProcessRunner(log: fileLog.write), wireguardGo: "",
                              queue: queue, log: fileLog)
    queue.sync { manager.cleanupStale() }
    exit(0)
}

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "daemon": runDaemon(Array(argv.dropFirst()))
case "ctl": runCtl(Array(argv.dropFirst()))
case "cleanup": runCleanup()
default: usageExit()
}
