import Foundation
import Network

/// A parsed HTTP/1.1 request. Headers are lowercased.
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Writes a response back to one connection. Every response closes the connection
/// (`Connection: close`), which keeps the server simple and works with every OpenAI client.
final class HTTPResponder: @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) { self.connection = connection }

    /// One-shot response with a body.
    func respond(status: Int, contentType: String = "application/json", body: Data) async {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        try? await send(Data(head.utf8) + body)
        close()
    }

    func respondJSON(status: Int = 200, _ object: some Encodable) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(object)) ?? Data("{}".utf8)
        await respond(status: status, body: data)
    }

    func respondError(status: Int, message: String, type: String = "invalid_request_error") async {
        await respondJSON(status: status, OpenAIError(error: .init(message: message, type: type)))
    }

    /// Starts a Server-Sent Events stream.
    func startEventStream() async throws {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        try await send(Data(head.utf8))
    }

    func sendEvent(_ object: some Encodable) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = try encoder.encode(object)
        try await send(Data("data: ".utf8) + json + Data("\n\n".utf8))
    }

    func sendDone() async throws {
        try await send(Data("data: [DONE]\n\n".utf8))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func close() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

struct OpenAIError: Codable, Sendable {
    struct Detail: Codable, Sendable {
        let message: String
        let type: String
    }
    let error: Detail
}

/// A tiny HTTP/1.1 server on the loopback interface only. Nothing outside this Mac can reach it.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, HTTPResponder) async -> Void

    enum ServerError: LocalizedError {
        case noFreePort(Int)
        var errorDescription: String? {
            switch self {
            case .noFreePort(let port): "Ports \(port)–\(port + 9) are all in use."
            }
        }
    }

    private let queue = DispatchQueue(label: "hearth.http")
    private var listener: NWListener?
    private let handler: Handler
    private(set) var port: Int?

    private static let maxBodyBytes = 32 * 1_048_576

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Binds to `preferredPort`, or the next free one within 10 ports. Returns the bound port.
    func start(preferredPort: Int) async throws -> Int {
        stop()
        for candidate in preferredPort..<(preferredPort + 10) {
            if let bound = try? await bind(port: candidate) { return bound }
        }
        throw ServerError.noFreePort(preferredPort)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func bind(port: Int) async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw ServerError.noFreePort(port) }
        let listener = try NWListener(using: parameters, on: nwPort)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard resumed.set() else { return }
                    self?.listener = listener
                    self?.port = port
                    continuation.resume(returning: port)
                case .failed(let error):
                    listener.cancel()
                    guard resumed.set() else { return }
                    continuation.resume(throwing: error)
                case .waiting(let error):
                    // Port in use shows up as "waiting" with EADDRINUSE.
                    listener.cancel()
                    guard resumed.set() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads until headers and the full body (Content-Length) are in, then hands off.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxBodyBytes {
                let responder = HTTPResponder(connection: connection)
                Task { await responder.respondError(status: 413, message: "Request is too large.") }
                return
            }

            switch Self.parse(buffer) {
            case .complete(let request):
                let responder = HTTPResponder(connection: connection)
                let handler = self.handler
                Task { await handler(request, responder) }
            case .invalid:
                let responder = HTTPResponder(connection: connection)
                Task { await responder.respondError(status: 400, message: "Malformed HTTP request.") }
            case .needMore:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    enum ParseResult {
        case complete(HTTPRequest)
        case needMore
        case invalid
    }

    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return .needMore }
        guard let headText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .needMore }
        let body = buffer[bodyStart..<(bodyStart + length)]

        var path = String(requestLine[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path,
                                     headers: headers, body: Data(body)))
    }
}

/// Resumes a continuation exactly once across NWListener state callbacks.
private final class LockedFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    /// Returns true the first time only.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
