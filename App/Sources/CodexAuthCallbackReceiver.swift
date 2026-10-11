import AppKit
import Network
import T3Client

/// `receiveCodexAuthCallback` (packages/shared/src/codexAuthCallback.ts) for `t3code://auth/codex` links:
/// listens on the sign-in's loopback `redirect_uri` port, opens ChatGPT's authorize page in the browser,
/// and answers the callback with a 303 to the requesting client's return address, the code in the
/// fragment (`codexAuthDeliveryUrl`). The listener lives only while a sign-in is open, 5 minutes at most.
@MainActor
final class CodexAuthCallbackReceiver {
    private var listeners: [String: NWListener] = [:]
    private var timeouts: [String: Timer] = [:]
    private static let returnPage = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>T3 Code</title><style>body{font-family:system-ui;display:grid;place-items:center;min-height:90vh;margin:0}main{max-width:360px;padding:32px}h1{font-size:24px}p{line-height:1.6;opacity:.7}</style></head><body><main><h1>Return to T3 Code</h1><p>Your sign-in response has been received. T3 Code is finishing the connection. You can close this tab.</p></main></body></html>
        """

    /// Starts the handoff; `failed` gets T3's message when it can't (DesktopClerk.ts:156-160 logs these).
    func receive(_ handoff: CodexAuthHandoff, failed: @escaping @MainActor (String) -> Void) {
        guard let request = try? CodexAuthorizationRequest(handoff.authorizationUrl) else { return }
        guard listeners[request.state] == nil else {
            failed("This sign-in is already open on this computer.")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: request.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            failed("The ChatGPT callback port is in use on this computer. Close the other sign-in and try again, or paste the redirect URL in T3 Code.")
            return
        }
        listeners[request.state] = listener
        let state = request.state
        let timeout = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.listeners[state] != nil else { return }
                self?.stop(state)
                failed("Sign-in expired. Try again.")
            }
        }
        timeout.tolerance = 30
        timeouts[state] = timeout
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection, handoff: handoff, request: request) }
        }
        listener.stateUpdateHandler = { [weak self] update in
            MainActor.assumeIsolated {
                switch update {
                case .ready:
                    guard let url = URL(string: request.authorizationUrl), NSWorkspace.shared.open(url) else {
                        self?.stop(state)
                        failed("Could not open your sign-in browser.")
                        return
                    }
                case .failed:
                    self?.stop(state)
                    failed("The ChatGPT callback port is in use on this computer. Close the other sign-in and try again, or paste the redirect URL in T3 Code.")
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    private func stop(_ state: String) {
        listeners.removeValue(forKey: state)?.cancel()
        timeouts.removeValue(forKey: state)?.invalidate()
    }

    /// One HTTP/1.1 request: the request line is all T3 reads (`incoming.method`, `incoming.url`).
    private func serve(_ connection: NWConnection, handoff: CodexAuthHandoff, request: CodexAuthorizationRequest) {
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
                    if let delivery = try? handoff.deliveryURL(callbackUrl: callback) {
                        let headers = "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
                        response = "HTTP/1.1 303 See Other\r\nLocation: \(delivery)\r\n\(headers)Content-Length: 0\r\n\r\n"
                        self?.stop(request.state)
                    } else if (try? request.validateCallback(callback)) != nil {
                        let body = Data(Self.returnPage.utf8)
                        response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n" + Self.returnPage
                        self?.stop(request.state)
                    }
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
