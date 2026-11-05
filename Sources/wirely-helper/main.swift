import Foundation
import Darwin
import WirelyCore
import WirelyHelperKit

let usage = """
Kullanım:
  wirely-helper daemon --allowed-uid <uid> --wireguard-go <yol>
  wirely-helper ctl status | down | up <conf-yolu> [--name N] [--split a,b,c [--exclude]] | split a,b,c | trace <hedef>
  wirely-helper trace <hedef>
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

struct InvalidSplitRule: Error { let text: String }

func parseSplitRules(_ texts: [String]) -> Result<[SplitRule], InvalidSplitRule> {
    var rules: [SplitRule] = []
    for text in texts {
        guard case .success(let rule) = SplitRule.parse(text) else { return .failure(InvalidSplitRule(text: text)) }
        rules.append(rule)
    }
    return .success(rules)
}

func makeManager(runner: CommandRunner, wireguardGo: String, queue: DispatchQueue, log: FileLog) -> TunnelManager {
    TunnelManager(
        runner: runner,
        makeLauncher: { WireGuardGoLauncher(executable: wireguardGo, callbackQueue: queue) },
        resolver: SystemResolver(),
        store: FileStateStore(),
        dns: SystemDNSConfigurator(),
        firewall: PFFirewall(runner: runner),
        log: log.write,
        makeSplitProxy: { SplitDNSProxy(listen: IPAddress("127.0.0.1")!, port: 53, config: $0, onLearn: $1) },
        normalDNS: SystemDNSUpstreams())
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

    let tracer = Tracer()
    let server = HelperServer(
        socketPath: HelperConstants.socketPath, allowedUIDs: [uid_t(uid), 0], queue: managerQueue,
        directCommands: [.trace]
    ) { request in
        let version = HelperConstants.helperVersion
        func invalidRule(_ text: String) -> HelperResponse {
            HelperResponse(ok: false, error: "Geçersiz kural: \(text)", status: nil, helperVersion: version,
                           errorCode: "split.invalidRule", errorArg: text)
        }
        switch request.command {
        case .up:
            guard let config = request.config, let name = request.tunnelName else {
                return HelperResponse(ok: false, error: "Yapılandırma eksik", status: nil, helperVersion: version,
                                      errorCode: "request.missingConfig")
            }
            var splitRules: [SplitRule]?
            if let texts = request.split {
                switch parseSplitRules(texts) {
                case .success(let r): splitRules = r
                case .failure(let bad): return invalidRule(bad.text)
                }
            }
            do {
                let status = try manager.up(name: name, configText: config,
                                            killSwitch: request.killSwitch ?? false,
                                            allowLAN: request.allowLAN ?? true, split: splitRules,
                                            splitExclude: request.splitExclude ?? false)
                return HelperResponse(ok: true, error: nil, status: status, helperVersion: version)
            } catch {
                let coded = (error as? TunnelError)?.codeAndArg
                return HelperResponse(ok: false, error: error.localizedDescription,
                                      status: manager.status(), helperVersion: version,
                                      errorCode: coded?.code, errorArg: coded?.arg)
            }
        case .down:
            return HelperResponse(ok: true, error: nil, status: manager.down(), helperVersion: version)
        case .trace:
            // Runs off the manager queue (directCommands): must not touch `manager`.
            guard let target = request.traceTarget else {
                return HelperResponse(ok: false, error: "Hedef eksik", status: nil, helperVersion: version,
                                      errorCode: "trace.invalidTarget")
            }
            do {
                let result = try tracer.trace(target)
                fileLog.write("trace \(result.target): \(result.hops.count) hops, \(result.durationMs) ms")
                return HelperResponse(ok: true, error: nil, status: nil, helperVersion: version, trace: result)
            } catch {
                let traceError = error as? TraceError
                return HelperResponse(ok: false, error: error.localizedDescription, status: nil,
                                      helperVersion: version, errorCode: traceError?.code ?? "trace.socket",
                                      errorArg: traceError?.arg)
            }
        case .split:
            guard let texts = request.split else { return invalidRule("") }
            let rules: [SplitRule]
            switch parseSplitRules(texts) {
            case .success(let r): rules = r
            case .failure(let bad): return invalidRule(bad.text)
            }
            do {
                let status = try manager.updateSplit(rules)
                fileLog.write("split: \(rules.count) kural güncellendi")
                return HelperResponse(ok: true, error: nil, status: status, helperVersion: version)
            } catch {
                let coded = (error as? TunnelError)?.codeAndArg
                return HelperResponse(ok: false, error: error.localizedDescription,
                                      status: manager.status(), helperVersion: version,
                                      errorCode: coded?.code, errorArg: coded?.arg)
            }
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
        let split = option("--split", in: args).map { $0.split(separator: ",").map(String.init) }
        let exclude = args.contains("--exclude")
        if exclude && split == nil { fail("--exclude için --split gerekli") }
        request = HelperRequest(command: .up, tunnelName: name, config: text, split: split,
                                splitExclude: exclude ? true : nil)
    case "split":
        guard args.count >= 2 else { usageExit() }
        request = HelperRequest(command: .split, split: args[1].split(separator: ",").map(String.init))
    case "trace":
        guard args.count >= 2 else { usageExit() }
        request = HelperRequest(command: .trace, traceTarget: args[1])
    default:
        usageExit()
    }

    do {
        let response = try HelperClient().send(request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let trace = response.trace, let out = try? encoder.encode(trace) {
            print(String(decoding: out, as: UTF8.self))
        }
        if let status = response.status, let out = try? encoder.encode(status) {
            print(String(decoding: out, as: UTF8.self))
        }
        if !response.ok { fail(response.error ?? "Bilinmeyen hata") }
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}

func runTrace(_ args: [String]) -> Never {
    guard getuid() == 0 else { fail("wirely-helper trace root olarak çalışmalı (must run as root)") }
    guard let target = args.first else { usageExit() }
    do {
        let result = try Tracer().trace(target)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        exit(0)
    } catch let error as TraceError {
        fail("\(error.code)" + (error.arg.map { ": \($0)" } ?? ""))
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
case "trace": runTrace(Array(argv.dropFirst()))
case "cleanup": runCleanup()
default: usageExit()
}
