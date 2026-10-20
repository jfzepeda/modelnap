import Foundation
import Darwin

struct LoadedModel: Decodable, Identifiable, Sendable {
    var name: String
    var size: Int64
    var id: String { name }
}

actor InferenceManager {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    func models(at base: URL) async throws -> [LoadedModel] {
        let (data, response) = try await session.data(from: base.appendingPathComponent("api/ps"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GatewayError.upstream }
        struct Response: Decodable { var models: [LoadedModel] }
        return try JSONDecoder().decode(Response.self, from: data).models
    }

    // The stop path kills the entire private server group, including model runners.
    // API unload is useful for explicit maintenance, but must never delay Human First.
    func unload(_ models: [LoadedModel], at base: URL) async throws {
        for model in models {
            var request = URLRequest(url: base.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model.name, "keep_alive": 0])
            _ = try await session.data(for: request)
        }
        guard try await self.models(at: base).isEmpty else { throw GatewayError.upstream }
    }

    static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GatewayError.upstream }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw GatewayError.upstream }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw GatewayError.upstream }
        return UInt16(bigEndian: address.sin_port)
    }
}
