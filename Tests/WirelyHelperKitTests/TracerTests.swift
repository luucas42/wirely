import Testing
import Foundation
import WirelyCore
@testable import WirelyHelperKit

@Test func tracerAcceptsHostsAndIPv4Literals() throws {
    #expect(try Tracer.validate("example.com") == "example.com")
    #expect(try Tracer.validate("203.0.113.10") == "203.0.113.10")
    #expect(try Tracer.validate("  example.com  ") == "example.com")
}

@Test(arguments: ["", "   ", String(repeating: "a", count: 254), "a b", "x;rm", "$(id)", "a/b", "ex\u{e4}mple.com"])
func tracerRejectsInvalidTargets(_ target: String) {
    #expect(throws: TraceError.invalidTarget) { try Tracer.validate(target) }
}

@Test(arguments: ["::1", "2001:db8::1"])
func tracerRejectsIPv6Literals(_ target: String) {
    #expect(throws: TraceError.ipv6Unsupported) { try Tracer.validate(target) }
}

@Test func traceErrorCodes() {
    #expect(TraceError.busy.code == "trace.busy")
    #expect(TraceError.resolve("example.com").arg == "example.com")
    #expect(TraceError.invalidTarget.arg == nil)
}

@Test func directCommandIsAnsweredWhileManagerQueueIsBlocked() throws {
    let path = "/tmp/wly-\(UInt32.random(in: 0...UInt32.max)).sock"
    defer { unlink(path) }
    let queue = DispatchQueue(label: "t.manager")
    let release = DispatchSemaphore(value: 0)
    queue.async { release.wait() }  // manager queue busy until released
    defer { release.signal() }

    let server = HelperServer(socketPath: path, allowedUIDs: [getuid()], queue: queue,
                              directCommands: [.trace]) { _ in
        HelperResponse(ok: true, error: nil, status: nil, helperVersion: 1)
    }
    try server.start()

    // Direct: answered although the queue is blocked.
    let direct = try HelperClient(socketPath: path, timeout: 5).send(HelperRequest(command: .trace, traceTarget: "example.com"))
    #expect(direct.ok)

    // Non-direct: still waits for the manager queue.
    #expect(throws: HelperClientError.timeout) {
        try HelperClient(socketPath: path, timeout: 1).send(HelperRequest(command: .status))
    }
}
