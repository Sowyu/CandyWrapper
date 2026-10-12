import AppKit
import Network
import T3Client

/// `receiveCodexAuthCallback` (packages/shared/src/codexAuthCallback.ts): listens on the sign-in's loopback
/// `redirect_uri` port, opens ChatGPT's authorize page in the browser and takes the one callback. Two callers:
/// `t3code://auth/codex` links answer the callback with a 303 to the requesting client's return address, the
/// code in the fragment (`codexAuthDeliveryUrl`); the app's own Codex setup gets the callback URL back
/// (`receiveProviderAuthCallback`, apps/desktop/src/ipc/methods/providerAuth.ts:16-38) and shows the
/// "Return to T3 Code" page. A listener lives only while a sign-in is open, 5 minutes at most.
@MainActor
final class CodexAuthCallbackReceiver {
    private var listeners: [String: NWListener] = [:]
    private var timeouts: [String: Timer] = [:]
    private var finishers: [String: @MainActor (Result<String, CodexAuthError>) -> Void] = [:]
    private static let returnPage = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>T3 Code</title><style>body{font-family:system-ui;display:grid;place-items:center;min-height:90vh;margin:0}main{max-width:360px;padding:32px}h1{font-size:24px}p{line-height:1.6;opacity:.7}</style></head><body><main><h1>Return to T3 Code</h1><p>Your sign-in response has been received. T3 Code is finishing the connection. You can close this tab.</p></main></body></html>
        """
    static let portInUse = "The ChatGPT callback port is in use on this computer. Close the other sign-in and try again, or paste the redirect URL in T3 Code."

    /// Starts the handoff; `failed` gets T3's message when it can't (DesktopClerk.ts:156-160 logs these).
    func receive(_ handoff: CodexAuthHandoff, failed: @escaping @MainActor (String) -> Void) {
        guard let request = try? CodexAuthorizationRequest(handoff.authorizationUrl) else { return }
        listen(request, destination: { try? handoff.deliveryURL(callbackUrl: $0) }) { result in
            if case .failure(let error) = result { failed(error.message) }
        }
    }

    /// `receiveProviderAuthCallback`: the callback URL once the browser returns. Any failure reads as T3's
    /// one IPC error; the setup view shows its own line for it.
    func receiveCallback(_ authorizationUrl: String) async throws -> String {
        let request = try CodexAuthorizationRequest(authorizationUrl)
        return try await withCheckedThrowingContinuation { continuation in
            listen(request, destination: nil) { result in
                switch result {
                case .success(let url): continuation.resume(returning: url)
                case .failure: continuation.resume(throwing: CodexAuthError("Could not receive ChatGPT sign-in on this computer. Try again or paste the redirect URL."))
                }
            }
        }
    }

    /// `cancelProviderAuthCallback`.
    func cancelCallback(_ authorizationUrl: String) {
        guard let request = try? CodexAuthorizationRequest(authorizationUrl) else { return }
        finish(request.state, .failure(CodexAuthError("Sign-in cancelled on this computer.")))
    }

    private func listen(_ request: CodexAuthorizationRequest, destination: (@MainActor @Sendable (String) -> String?)?,
                        done: @escaping @MainActor (Result<String, CodexAuthError>) -> Void) {
        guard listeners[request.state] == nil else {
            done(.failure(CodexAuthError("This sign-in is already open on this computer.")))
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: request.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            done(.failure(CodexAuthError(Self.portInUse)))
            return
        }
        let state = request.state
        listeners[state] = listener
        finishers[state] = done
        let timeout = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(state, .failure(CodexAuthError("Sign-in expired. Try again."))) }
        }
        timeout.tolerance = 30
        timeouts[state] = timeout
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection, request: request, destination: destination) }
        }
        listener.stateUpdateHandler = { [weak self] update in
            MainActor.assumeIsolated {
                switch update {
                case .ready:
                    guard let url = URL(string: request.authorizationUrl), NSWorkspace.shared.open(url) else {
                        self?.finish(state, .failure(CodexAuthError("Could not open your sign-in browser.")))
                        return
                    }
                case .failed:
                    self?.finish(state, .failure(CodexAuthError(Self.portInUse)))
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    /// Stops the listener and reports once.
    private func finish(_ state: String, _ result: Result<String, CodexAuthError>) {
        listeners.removeValue(forKey: state)?.cancel()
        timeouts.removeValue(forKey: state)?.invalidate()
        finishers.removeValue(forKey: state)?(result)
    }

    /// One HTTP/1.1 request: the request line is all T3 reads (`incoming.method`, `incoming.url`).
    private func serve(_ connection: NWConnection, request: CodexAuthorizationRequest, destination: (@MainActor @Sendable (String) -> String?)?) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                let parts = line.split(separator: " ")
                let rejection = "This response does not belong to the active sign-in."
                var response = "HTTP/1.1 400 Bad Request\r\nContent-Length: \(rejection.utf8.count)\r\nConnection: close\r\n\r\n" + rejection
                if parts.count >= 2, parts[0] == "GET" {
                    let callback = "http://127.0.0.1:\(request.port)" + parts[1]
                    let headers = "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
                    if let delivery = destination?(callback) {
                        response = "HTTP/1.1 303 See Other\r\nLocation: \(delivery)\r\n\(headers)Content-Length: 0\r\n\r\n"
                        self?.finish(request.state, .success(callback))
                    } else if (try? request.validateCallback(callback)) != nil {
                        let body = Data(Self.returnPage.utf8)
                        let csp = "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\n"
                        response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\(headers)\(csp)Content-Length: \(body.count)\r\n\r\n" + Self.returnPage
                        self?.finish(request.state, .success(callback))
                    }
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
