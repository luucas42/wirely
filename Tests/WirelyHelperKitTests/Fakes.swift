import Foundation
import WirelyCore
@testable import WirelyHelperKit

final class FakeRunner: CommandRunner {
    /// Every command run, in order.
    private(set) var commands: [NetCommand] = []
    /// Commands interleaved with launcher events ("launcher.start", "launcher.stop").
    private(set) var events: [String] = []
    private var outputs: [String: CommandResult] = [:]
    private var failing: Set<String> = []
    var onRun: ((NetCommand) -> Void)?

    func script(_ command: NetCommand, stdout: String) {
        outputs[command.description] = CommandResult(status: 0, stdout: stdout, stderr: "")
    }

    func fail(_ command: NetCommand) { failing.insert(command.description) }

    func note(_ event: String) { events.append(event) }

    func clearRecorded() {
        commands = []
        events = []
    }

    func run(_ command: NetCommand) -> CommandResult {
        commands.append(command)
        events.append(command.description)
        onRun?(command)
        if failing.contains(command.description) {
            return CommandResult(status: 1, stdout: "", stderr: "failed")
        }
        return outputs[command.description] ?? CommandResult(status: 0, stdout: "", stderr: "")
    }

    func ran(_ text: String) -> Bool { commands.contains { $0.description == text } }
    func index(of text: String) -> Int? { commands.firstIndex { $0.description == text } }
}

final class FakeLauncher: WireGuardLauncher {
    struct Failure: Error {}
    let runner: FakeRunner?
    var interfaceName = "utun7"
    var pid: Int32? = 4242
    var onUnexpectedExit: (() -> Void)?
    var getOutput = "errno=0\n"
    var failConfigure = false
    var failGet = false
    private(set) var started = false
    private(set) var stopped = false
    private(set) var configureTexts: [String] = []

    init(runner: FakeRunner? = nil) { self.runner = runner }

    func start() throws -> String {
        started = true
        runner?.note("launcher.start")
        return interfaceName
    }

    func configure(_ uapiSet: String) throws {
        configureTexts.append(uapiSet)
        if failConfigure { throw Failure() }
    }

    func get() throws -> String {
        if failGet { throw Failure() }
        return getOutput
    }

    func stop() {
        stopped = true
        runner?.note("launcher.stop")
    }

    func simulateExit() { onUnexpectedExit?() }
}

struct FakeResolver: EndpointResolver {
    struct Failure: Error {}
    var table: [String: String]
    func resolve(_ endpoint: Endpoint) throws -> IPAddress {
        guard let s = table[endpoint.host], let ip = IPAddress(s) else { throw Failure() }
        return ip
    }
}

final class MemoryStore: StateStore {
    struct Failure: Error {}
    var state: PersistedState?
    var failSave = false
    private(set) var saves: [PersistedState] = []
    func save(_ state: PersistedState) throws {
        if failSave { throw Failure() }
        saves.append(state)
        self.state = state
    }
    func load() -> PersistedState? { state }
    func clear() { state = nil }
}
