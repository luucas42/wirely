import Testing
import Foundation
import WirelyCore
@testable import WirelyHelperKit

private func socketPath() -> String {
    // sun_path is short; keep it compact.
    "/tmp/wly-\(UInt32.random(in: 0...UInt32.max)).sock"
}

@Test func helperServerRejectsForeignUID() throws {
    let path = socketPath()
    defer { unlink(path) }
    var handled = false
    let server = HelperServer(socketPath: path, allowedUIDs: [getuid() + 1],
                              queue: DispatchQueue(label: "t.manager")) { _ in
        handled = true
        return HelperResponse(ok: true, error: nil, status: nil, helperVersion: 1)
    }
    try server.start()
    let r = try HelperClient(socketPath: path, timeout: 5).send(HelperRequest(command: .status))
    #expect(r.ok == false)
    #expect(r.error?.contains("yetki") == true)
    #expect(handled == false)
}

@Test func helperServerAllowsOwnUID() throws {
    let path = socketPath()
    defer { unlink(path) }
    let server = HelperServer(socketPath: path, allowedUIDs: [getuid()],
                              queue: DispatchQueue(label: "t.manager")) { req in
        #expect(req.command == .status)
        return HelperResponse(ok: true, error: nil, status: .disconnected, helperVersion: 1)
    }
    try server.start()
    let r = try HelperClient(socketPath: path, timeout: 5).send(HelperRequest(command: .status))
    #expect(r.ok)
    #expect(r.status == .disconnected)
}

@Test func helperServerRejectsGarbageRequest() throws {
    let path = socketPath()
    defer { unlink(path) }
    let server = HelperServer(socketPath: path, allowedUIDs: [getuid()],
                              queue: DispatchQueue(label: "t.manager")) { _ in
        HelperResponse(ok: true, error: nil, status: nil, helperVersion: 1)
    }
    try server.start()
    let fd = try UnixSocket.connect(path: path, timeout: 5)
    defer { close(fd) }
    try UnixSocket.writeAll(fd, Data("garbage\n".utf8))
    let line = try UnixSocket.readLine(fd, maxBytes: 1 << 20)
    let r = try JSONDecoder().decode(HelperResponse.self, from: line)
    #expect(r.ok == false)
    #expect(r.error == "Geçersiz istek")
}
