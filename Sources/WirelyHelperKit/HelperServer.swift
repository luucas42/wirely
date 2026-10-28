import Foundation
import Darwin
import WirelyCore

/// Line-delimited JSON server on a unix socket. Each connection is authorised by peer UID.
public final class HelperServer {
    private let socketPath: String
    private let allowedUIDs: Set<uid_t>
    private let queue: DispatchQueue
    private let handler: (HelperRequest) -> HelperResponse
    private var listenFD: Int32 = -1

    public init(socketPath: String, allowedUIDs: Set<uid_t>, queue: DispatchQueue,
                handler: @escaping (HelperRequest) -> HelperResponse) {
        self.socketPath = socketPath
        self.allowedUIDs = allowedUIDs
        self.queue = queue
        self.handler = handler
    }

    public func start() throws {
        let fd = try UnixSocket.listen(path: socketPath, mode: 0o666)
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "wirely.accept"
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            do {
                let client = try UnixSocket.accept(fd)
                DispatchQueue.global().async { [self] in handle(client) }
            } catch let e as UnixSocketError {
                if e.code == EBADF || e.code == EINVAL { return }
                usleep(100_000)  // transient (EMFILE etc.); don't spin
            } catch {
                return
            }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let uid = UnixSocket.peerUID(fd), allowedUIDs.contains(uid) else {
            reply(fd, deny("Bu işlem için yetkin yok", code: "auth"))
            return
        }
        let line: Data
        do {
            line = try UnixSocket.readLine(fd, maxBytes: HelperClient.maxLineBytes)
        } catch {
            return
        }
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: line) else {
            reply(fd, deny("Geçersiz istek", code: "request.invalid"))
            return
        }
        let response = queue.sync { handler(request) }
        reply(fd, response)
    }

    private func deny(_ message: String, code: String) -> HelperResponse {
        HelperResponse(ok: false, error: message, status: nil, helperVersion: HelperConstants.helperVersion,
                       errorCode: code)
    }

    private func reply(_ fd: Int32, _ response: HelperResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        try? UnixSocket.writeAll(fd, data)
    }
}
