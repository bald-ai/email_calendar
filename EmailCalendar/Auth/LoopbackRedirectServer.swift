#if os(macOS)
import Foundation
@preconcurrency import Network

/// The listener is bound to loopback only, uses an OS-selected port, and accepts one
/// verified OAuth callback. A browser redirect to an unrelated path cannot complete it.
actor LoopbackRedirectServer {
    private let expectedState: String
    private let callbackPath = "/oauth/callback"
    private let queue = DispatchQueue(label: "app.emailcalendar.oauth-loopback")
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<UInt16, any Error>?
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var result: Result<URL, any Error>?
    private var redirectURL: URL?
    private var buffers: [UUID: Data] = [:]
    private var timeout: Task<Void, Never>?

    init(expectedState: String) { self.expectedState = expectedState }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerStateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.start(queue: queue)
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)\(callbackPath)") else { throw GoogleAPIError.invalidURL }
        redirectURL = url
        timeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(300))
                await self?.cancel(error: GoogleOAuthError.timedOut)
            } catch { }
        }
        return url
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { callbackContinuation = $0 }
        } onCancel: {
            Task { await self.cancel(error: CancellationError()) }
        }
    }

    func cancel(error: any Error = CancellationError()) {
        finish(.failure(error))
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                readyContinuation?.resume(returning: port)
                readyContinuation = nil
            }
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
            finish(.failure(error))
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        buffers[id] = Data()
        connection.start(queue: queue)
        receive(connection, id: id)
    }

    private func receive(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            Task { await self?.consume(data, complete: complete, error: error, connection: connection, id: id) }
        }
    }

    private func consume(_ data: Data?, complete: Bool, error: NWError?, connection: NWConnection, id: UUID) {
        guard var buffer = buffers[id] else { connection.cancel(); return }
        if let data { buffer.append(data) }
        guard buffer.count <= 16_384, error == nil else {
            buffers.removeValue(forKey: id)
            connection.cancel()
            return
        }
        buffers[id] = buffer
        guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
            if complete { buffers.removeValue(forKey: id); connection.cancel() }
            else { receive(connection, id: id) }
            return
        }
        buffers.removeValue(forKey: id)
        let firstLine = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard firstLine.count == 3, firstLine[0] == "GET", let redirectURL,
              let callback = URL(string: String(firstLine[1]), relativeTo: redirectURL)?.absoluteURL,
              callback.scheme == "http", callback.host == "127.0.0.1", callback.port == redirectURL.port,
              callback.path == callbackPath,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            respond(connection, status: "404 Not Found", message: "This endpoint only handles Google sign-in.")
            return
        }
        let states = components.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, states[0].value == expectedState else {
            respond(connection, status: "400 Bad Request", message: "The sign-in state could not be verified.")
            return
        }
        respond(connection, status: "200 OK", message: "Sign-in received. You can return to Email + Calendar.")
        finish(.success(callback))
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let html = "<!doctype html><meta charset=\"utf-8\"><title>Email + Calendar</title><p>\(message)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
    }
}
#endif
