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
