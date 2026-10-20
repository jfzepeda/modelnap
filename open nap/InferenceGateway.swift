import Foundation
import Network

struct GatewayRequest {
    let method: String
    let path: String
    let body: Data

    static func parse(_ data: Data) throws -> GatewayRequest? {
        guard data.count <= 8 * 1024 * 1024 else { throw GatewayError.invalidRequest }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw GatewayError.invalidRequest }
            return nil
        }
        guard separator.lowerBound <= 16_384,
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw GatewayError.invalidRequest }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "HEAD", "POST"].contains(first[0]) else { throw GatewayError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw GatewayError.invalidRequest }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw GatewayError.invalidRequest }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw GatewayError.invalidRequest }
        let length = headers["content-length"].flatMap(Int.init) ?? (headers["content-length"] == nil ? 0 : -1)
        guard length >= 0, length <= 8 * 1024 * 1024 else { throw GatewayError.invalidRequest }
        let available = data.count - separator.upperBound
        guard available >= length else { return nil }
        guard available == length else { throw GatewayError.invalidRequest }
        return GatewayRequest(method: String(first[0]), path: String(first[1]), body: Data(data[separator.upperBound...]))
    }

    var isAllowed: Bool {
        (method == "GET" && ["/api/tags", "/api/ps", "/api/version", "/v1/models"].contains(path)) ||
        (method == "POST" && ["/api/show", "/api/generate", "/api/chat", "/api/embed", "/api/embeddings", "/v1/chat/completions", "/v1/completions", "/v1/embeddings"].contains(path))
    }
}

enum GatewayError: Error { case invalidRequest, upstream }

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class InferenceGateway {
    static let port: UInt16 = 11435
    private let listeningPort: UInt16
    init(port: UInt16 = InferenceGateway.port) { listeningPort = port }
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private(set) var upstream: URL?
    var status: (() -> String)?
    var startAgent: (() async throws -> Void)?
    var onFailure: ((String) -> Void)?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listeningPort)!)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed(let error) = state { self?.onFailure?(error == .posix(.EADDRINUSE) ? "Port \(self?.listeningPort ?? Self.port) is occupied by another process. Close that server, then press Retry connection." : "Gateway: \(error.localizedDescription)") }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func shutdown() { block(); listener?.cancel(); listener = nil }

    func enable(upstream: URL) { self.upstream = upstream }
    func block() {
        upstream = nil
        for task in tasks.values { task.cancel() }
        for task in deadlines.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
        tasks.removeAll(); connections.removeAll(); deadlines.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        deadlines[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.finish(id)
        }
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                do {
                    if let request = try GatewayRequest.parse(buffer) {
                        self.deadlines.removeValue(forKey: id)?.cancel()
                        self.tasks[id] = Task { await self.respond(request, connection: connection, id: id) }
                    } else if complete || error != nil { self.finish(id) }
                    else { self.receive(connection, id: id, buffer: buffer) }
                } catch {
                    self.tasks[id] = Task {
                        try? await self.reply(connection, code: 400, body: "{\"error\":\"Invalid or unsupported HTTP request\"}")
                        self.finish(id)
                    }
                }
            }
        }
    }

    private func respond(_ request: GatewayRequest, connection: NWConnection, id: UUID) async {
        defer { finish(id) }
        do {
            // Ollama CLI probes HEAD / before every command. Gateway liveness is
            // independent of admission: a 200 prevents CLI auto-launching another server.
            if ["HEAD", "GET"].contains(request.method), request.path == "/" {
                try await reply(connection, code: 200, body: request.method == "HEAD" ? "" : "ModelNap gateway")
                return
            }
            if request.method == "GET", request.path == "/status" {
                try await reply(connection, code: 200, body: "{\"state\":\"\(status?() ?? "USER ACTIVE")\",\"accepting_requests\":\(upstream != nil)}")
                return
            }
            guard let upstream else {
                try await reply(connection, code: 503, body: "{\"error\":\"AI temporarily disabled: human activity has priority\"}")
                return
            }
            if request.method == "POST", request.path == "/agents/start" {
                do {
                    guard let startAgent else { throw GatewayError.upstream }
                    try await startAgent()
                    try await reply(connection, code: 202, body: "{\"status\":\"New agent session started\"}")
                } catch {
                    try await reply(connection, code: 409, body: "{\"error\":\"Agent unavailable; configure an executable in Settings\"}")
                }
                return
            }
            guard request.isAllowed else {
                try await reply(connection, code: 404, body: "{\"error\":\"Endpoint not exposed by ModelNap\"}")
                return
            }
            var outgoing = URLRequest(url: upstream.appendingPathComponent(String(request.path.dropFirst())))
            outgoing.httpMethod = request.method
            outgoing.httpBody = request.method == "POST" ? request.body : nil
            outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (bytes, response) = try await session.bytes(for: outgoing)
            try Task.checkCancellation()
            guard self.upstream == upstream, let http = response as? HTTPURLResponse else { throw GatewayError.upstream }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            try await send(connection, Data("HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nContent-Type: \(type)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8))
            var chunk = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if byte == 10 || chunk.count >= 4096 {
                    try await sendChunk(connection, chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try await sendChunk(connection, chunk) }
            try await send(connection, Data("0\r\n\r\n".utf8))
        } catch {
            // Cancelling an admitted request closes the transport; it can never resume.
            connection.cancel()
        }
    }

    private func sendChunk(_ connection: NWConnection, _ data: Data) async throws {
        var frame = Data("\(String(data.count, radix: 16))\r\n".utf8)
        frame.append(data); frame.append(Data("\r\n".utf8))
        try await send(connection, frame)
    }
    private func reply(_ connection: NWConnection, code: Int, body: String) async throws {
        try await send(connection, Data("HTTP/1.1 \(code) \(HTTPURLResponse.localizedString(forStatusCode: code))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8))
    }
    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel()
    }
}
