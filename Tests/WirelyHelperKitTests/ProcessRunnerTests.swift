import Testing
import Foundation
import WirelyCore
@testable import WirelyHelperKit

@Test func processRunnerHandlesLargeOutputAndMissingExecutable() {
    let runner = ProcessRunner(log: { _ in })
    let big = runner.run(NetCommand("/usr/bin/head", ["-c", "300000", "/dev/zero"]))
    #expect(big.status == 0)
    #expect(big.stdout.utf8.count == 300000)
    let missing = runner.run(NetCommand("/nonexistent/tool", []))
    #expect(missing.status == 127)
}

/// Connecting runs ~25 commands; `Process.waitUntilExit()` added ~65 ms to each (≈3 s per connect).
@Test func processRunnerHasNoPerCommandWaitOverhead() {
    let runner = ProcessRunner(log: { _ in })
    let start = Date()
    for _ in 0..<10 {
        #expect(runner.run(NetCommand("/usr/bin/true", [])).status == 0)
    }
    #expect(Date().timeIntervalSince(start) < 0.3)
}

@Test func processRunnerReportsExitStatusAndStderr() {
    let runner = ProcessRunner(log: { _ in })
    let r = runner.run(NetCommand("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
    #expect(r.status == 3)
    #expect(r.stdout == "out\n")
    #expect(r.stderr == "err\n")
}

@Test func systemResolverReturnsLiteralIPs() throws {
    let r = SystemResolver()
    #expect(try r.resolve(Endpoint(host: "203.0.113.5", port: 1)) == IPAddress("203.0.113.5")!)
    #expect(try r.resolve(Endpoint(host: "localhost", port: 1)).family == .v4)
}
