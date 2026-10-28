import Foundation
import Darwin

public enum HelperClientError: Error, Equatable, LocalizedError {
    case notRunning, timeout, io(String), badResponse

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Wirely servisi çalışmıyor"
        case .timeout: return "Servis yanıt vermedi"
        case .io(let msg): return "Servisle iletişim hatası: \(msg)"
        case .badResponse: return "Servisten geçersiz yanıt"
        }
    }
}

public struct HelperClient {
    public static let maxLineBytes = 1 << 20

    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String = HelperConstants.socketPath, timeout: TimeInterval = 20) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(_ request: HelperRequest) throws -> HelperResponse {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: socketPath, timeout: timeout)
        } catch let e as UnixSocketError {
            throw map(e)
        }
        defer { close(fd) }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        guard payload.count <= Self.maxLineBytes else { throw HelperClientError.io("istek çok büyük") }
        do {
            try UnixSocket.writeAll(fd, payload)
            let line = try UnixSocket.readLine(fd, maxBytes: Self.maxLineBytes)
            do {
                return try JSONDecoder().decode(HelperResponse.self, from: line)
            } catch {
                throw HelperClientError.badResponse
            }
        } catch let e as UnixSocketError {
            throw map(e)
        }
    }

    private func map(_ e: UnixSocketError) -> HelperClientError {
        switch e.code {
        case ENOENT, ECONNREFUSED: return .notRunning
        case EAGAIN, EWOULDBLOCK: return .timeout
        default: return .io(String(cString: strerror(e.code)))
        }
    }
}
