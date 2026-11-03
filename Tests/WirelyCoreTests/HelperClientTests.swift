import Testing
import Foundation
import Darwin
@testable import WirelyCore

private func tempSocketPath() -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    let suffix = String((0..<6).map { _ in chars.randomElement()! })
    return "/tmp/wly-\(suffix).sock"
}

@Test func helperClientRoundTrip() throws {
    let path = tempSocketPath()
    defer { unlink(path) }
    let listener = try UnixSocket.listen(path: path, mode: 0o600)
    defer { close(listener) }

    final class Box: @unchecked Sendable { var request: HelperRequest? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        defer { done.signal() }
        guard let conn = try? UnixSocket.accept(listener) else { return }
        defer { close(conn) }
        guard let line = try? UnixSocket.readLine(conn, maxBytes: 1 << 20) else { return }
        box.request = try? JSONDecoder().decode(HelperRequest.self, from: line)
        let resp = HelperResponse(ok: true, error: nil, status: .disconnected, helperVersion: 1)
        var data = (try? JSONEncoder().encode(resp)) ?? Data()
        data.append(0x0A)
        try? UnixSocket.writeAll(conn, data)
    }

    let client = HelperClient(socketPath: path, timeout: 5)
    let resp = try client.send(HelperRequest(command: .status, tunnelName: nil, config: nil))
    #expect(resp == HelperResponse(ok: true, error: nil, status: .disconnected, helperVersion: 1))
    _ = done.wait(timeout: .now() + 5)
    #expect(box.request == HelperRequest(command: .status, tunnelName: nil, config: nil))
}

@Test func helperClientNotRunning() {
    let client = HelperClient(socketPath: tempSocketPath(), timeout: 1)
    #expect(throws: HelperClientError.notRunning) {
        try client.send(HelperRequest(command: .version, tunnelName: nil, config: nil))
    }
}

@Test func helperClientTimeout() throws {
    let path = tempSocketPath()
    defer { unlink(path) }
    let listener = try UnixSocket.listen(path: path, mode: 0o600)
    defer { close(listener) }
    let client = HelperClient(socketPath: path, timeout: 0.3)
    #expect(throws: HelperClientError.timeout) {
        try client.send(HelperRequest(command: .status, tunnelName: nil, config: nil))
    }
}

@Test func readUntilBlankLineStopsAtDoubleNewline() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { close(fds[0]); close(fds[1]) }
    try UnixSocket.writeAll(fds[0], Data("listen_port=1\nerrno=0\n\nextra".utf8))
    let data = try UnixSocket.readUntilBlankLine(fds[1], maxBytes: 1024)
    #expect(String(decoding: data, as: UTF8.self) == "listen_port=1\nerrno=0\n\n")
}

@Test func readLineEOFAndOversizeThrow() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    try UnixSocket.writeAll(fds[0], Data("abcdef".utf8))
    close(fds[0])
    defer { close(fds[1]) }
    #expect(throws: (any Error).self) { try UnixSocket.readLine(fds[1], maxBytes: 1024) }

    var f2: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &f2) == 0)
    defer { close(f2[0]); close(f2[1]) }
    try UnixSocket.writeAll(f2[0], Data("abcdefgh\n".utf8))
    #expect(throws: (any Error).self) { try UnixSocket.readLine(f2[1], maxBytes: 4) }
}

@Test func helperResponseDecodesWithoutErrorCode() throws {
    let json = #"{"ok":false,"error":"x","helperVersion":2}"#
    let r = try JSONDecoder().decode(HelperResponse.self, from: Data(json.utf8))
    #expect(r.errorCode == nil && r.errorArg == nil)
    let coded = HelperResponse(ok: false, error: "x", status: nil, helperVersion: 3, errorCode: "resolve", errorArg: "h")
    let back = try JSONDecoder().decode(HelperResponse.self, from: JSONEncoder().encode(coded))
    #expect(back.errorCode == "resolve" && back.errorArg == "h")
}

@Test func requestAndResponseRoundTripTrace() throws {
    let request = HelperRequest(command: .trace, traceTarget: "example.com")
    let backRequest = try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(request))
    #expect(backRequest == request && backRequest.command == .trace && backRequest.traceTarget == "example.com")

    let result = TraceResult(target: "example.com", address: "192.0.2.7",
                             hops: [TraceHop(ttl: 1, address: "203.0.113.1", rttMs: 1.5, isDestination: false),
                                    TraceHop(ttl: 2, address: nil, rttMs: nil, isDestination: false),
                                    TraceHop(ttl: 3, address: "192.0.2.7", rttMs: 12.25, isDestination: true)],
                             durationMs: 420, reached: true)
    let response = HelperResponse(ok: true, error: nil, status: nil, helperVersion: HelperConstants.helperVersion,
                                  trace: result)
    let backResponse = try JSONDecoder().decode(HelperResponse.self, from: JSONEncoder().encode(response))
    #expect(backResponse == response && backResponse.trace == result)
    #expect(HelperConstants.helperVersion == 8)
}

@Test func traceFieldsAreOptionalWhenDecoding() throws {
    let oldRequest = try JSONDecoder().decode(HelperRequest.self, from: Data(#"{"command":"status"}"#.utf8))
    #expect(oldRequest.traceTarget == nil)
    let oldResponse = try JSONDecoder().decode(HelperResponse.self, from: Data(#"{"ok":true,"helperVersion":6}"#.utf8))
    #expect(oldResponse.trace == nil)
}

@Test func splitProtocolFieldsAreOptionalAndRoundTrip() throws {
    #expect(HelperConstants.helperVersion == 8)
    // Old helper/app JSON without the new fields still decodes.
    let oldRequest = try JSONDecoder().decode(HelperRequest.self, from: Data(#"{"command":"up","tunnelName":"home","config":"x"}"#.utf8))
    #expect(oldRequest.split == nil)
    let oldStatus = try JSONDecoder().decode(TunnelStatus.self, from: Data(
        #"{"state":"connected","rxBytes":1,"txBytes":2,"ignoredKeys":[],"killSwitch":true}"#.utf8))
    #expect(oldStatus.split == nil)
    #expect(oldStatus.splitDNS == nil)
    #expect(oldStatus.killSwitch == true)

    let request = HelperRequest(command: .split, split: ["example.com", "10.2.2.4"])
    #expect(try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(request)) == request)
    let empty = HelperRequest(command: .up, tunnelName: "home", config: "x", split: [])
    #expect(try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(empty)).split == [])

    let status = TunnelStatus(state: .connected, split: ["example.com": SplitRuleStatus(routed: 3, rejected: 1)], splitDNS: true)
    let back = try JSONDecoder().decode(TunnelStatus.self, from: JSONEncoder().encode(status))
    #expect(back == status)
    #expect(back.split?["example.com"]?.rejected == 1)
}
