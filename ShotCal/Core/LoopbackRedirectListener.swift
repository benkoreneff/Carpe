import Foundation
import Network

enum LoopbackRedirectError: LocalizedError, Equatable {
    case couldNotListen(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .couldNotListen(let detail): "Couldn't open a local port for the Google sign-in. (\(detail))"
        case .timedOut: "The Google sign-in wasn't finished in the browser."
        }
    }
}

/// A one-shot web server on 127.0.0.1 that receives the OAuth redirect.
/// Google sends the browser to `http://127.0.0.1:<port>/?code=…&state=…`;
/// this hands back the query parameters and shows a short page.
///
/// It binds to the loopback address only, so nothing outside this Mac can
/// reach it, and it stops as soon as the sign-in ends.
nonisolated final class LoopbackRedirectListener: @unchecked Sendable {
    typealias Parameters = [String: String]

    let port: UInt16
    var redirectURI: String { "http://127.0.0.1:\(port)" }

    private let listener: NWListener
    private let queue: DispatchQueue
    // Touched only on `queue`.
    private var outcome: Result<Parameters, Error>?
    private var waiter: CheckedContinuation<Parameters, Error>?

    /// Starts listening on a port chosen by the system.
    static func start() async throws -> LoopbackRedirectListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackRedirectError.couldNotListen(error.localizedDescription)
        }
        let queue = DispatchQueue(label: "com.koreneff.ShotCal.oauth-redirect")

        // The port is only known once the listener is ready.
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: LoopbackRedirectError.couldNotListen("no port assigned"))
                    }
                case .failed(let error), .waiting(let error):
                    resumed = true
                    listener.cancel()
                    continuation.resume(throwing: LoopbackRedirectError.couldNotListen(error.localizedDescription))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: LoopbackRedirectError.couldNotListen("cancelled"))
                default:
                    break
                }
            }
            // Connections are routed once `self` exists; until then, refuse.
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }

        return LoopbackRedirectListener(listener: listener, queue: queue, port: port)
    }

    private init(listener: NWListener, queue: DispatchQueue, port: UInt16) {
        self.listener = listener
        self.queue = queue
        self.port = port
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.serve(connection)
        }
    }

    /// Waits for the browser to arrive. Throws `CancellationError` when the
    /// task is cancelled and `.timedOut` when nobody shows up.
    func redirect(timeout: TimeInterval = 300) async throws -> Parameters {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let outcome = self.outcome {
                        continuation.resume(with: outcome)
                    } else {
                        self.waiter = continuation
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(LoopbackRedirectError.timedOut))
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Serving (all on `queue`)

    private func finish(_ result: Result<Parameters, Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiter?.resume(with: result)
        waiter = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffered = buffered
            if let data { buffered.append(data) }

            // The request line is all that matters, and it ends at the first CRLF.
            if let lineEnd = buffered.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffered[..<lineEnd.lowerBound], as: UTF8.self)
                self.respond(to: line, on: connection)
            } else if isComplete || error != nil || buffered.count > 16_384 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffered: buffered)
            }
        }
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        guard let parameters = Self.parameters(fromRequestLine: requestLine) else {
            // Browsers also ask for /favicon.ico and the like; not the redirect.
            return send(status: "404 Not Found", page: Self.page("Not found", "Nothing here."), on: connection)
        }

        if parameters["code"] != nil {
            send(status: "200 OK", page: Self.page(
                "ShotCal is signing in",
                "You can close this tab and go back to ShotCal."
            ), on: connection)
            finish(.success(parameters))
        } else if parameters["error"] != nil {
            send(status: "200 OK", page: Self.page(
                "Google sign-in was not completed",
                "Nothing was connected. You can close this tab and try again from ShotCal."
            ), on: connection)
            finish(.success(parameters))
        } else {
            send(status: "400 Bad Request", page: Self.page("Not a sign-in redirect", "Start again from ShotCal."), on: connection)
        }
    }

    private func send(status: String, page: String, on connection: NWConnection) {
        let body = Data(page.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing

    /// The query parameters of `GET /?… HTTP/1.1`, or nil for any other
    /// method or path.
    static func parameters(fromRequestLine line: String) -> Parameters? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == "/"
        else { return nil }

        var parameters: Parameters = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        return parameters
    }

    private static func page(_ heading: String, _ text: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>ShotCal</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { font: 16px -apple-system, system-ui, sans-serif; margin: 20vh auto 0; max-width: 28em;
               padding: 0 1.5em; text-align: center; color: #1d1d1f; background: #fff; }
        h1 { font-size: 1.4em; } p { color: #6e6e73; }
        @media (prefers-color-scheme: dark) { body { color: #f5f5f7; background: #1d1d1f; } p { color: #a1a1a6; } }
        </style></head>
        <body><h1>\(heading)</h1><p>\(text)</p></body></html>
        """
    }
}
