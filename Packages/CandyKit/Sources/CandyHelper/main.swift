import Foundation
import T3Protocol
import T3Store
import T3Transport

// Spike: connect to one server with a bearer token, subscribe to its shell and print what arrives.
// candywrapper-helper probe <url> <token-file>
// candywrapper-helper wsecho <wss-url>   (a WebSocket and TLS check that needs no T3)
// candywrapper-helper descriptor <url>   (the server's public descriptor, no auth)
let args = CommandLine.arguments
if args.count == 3, args[1] == "wsecho", let url = URL(string: args[2]) {
    do {
        let socket = try await URLSessionRPCSocket.open(url: url)
        try await socket.send(Data("candywrapper-helper".utf8))
        for _ in 0..<3 {
            let reply = String(decoding: try await socket.receive(), as: UTF8.self)
            print("ws received: \(reply.prefix(80))")
            if reply == "candywrapper-helper" { print("ok"); socket.close(); exit(0) }
        }
        print("failed: no echo"); exit(1)
    } catch { print("failed: \(error)"); exit(1) }
}
if args.count == 3, args[1] == "descriptor", let url = URL(string: args[2]) {
    do {
        let d = try await EnvironmentHTTP(baseURL: url).descriptor()
        print("descriptor: \(d.label), protocol \(d.protocolVersion)"); print("ok"); exit(0)
    } catch { print("failed: \(error)"); exit(1) }
}
guard args.count == 4, args[1] == "probe", let url = URL(string: args[2]),
      let token = try? String(contentsOfFile: args[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
    FileHandle.standardError.write(Data("usage: candywrapper-helper probe <url> <token-file>\n".utf8))
    exit(2)
}
#if os(Linux)
let os = "Linux"
#else
let os = "macOS"
#endif
let identity = ClientIdentity(label: "CandyWrapper Helper", appVersion: "0.0.1-spike", deviceType: "bot", os: os)
let http = EnvironmentHTTP(baseURL: url)
do {
    let descriptor = try await http.descriptor()
    print("descriptor: \(descriptor.label) \(descriptor.environmentId)")
    let ticket = try await http.webSocketTicket(token: token)
    let socket = try await URLSessionRPCSocket.open(url: http.webSocketURL(ticket: ticket.ticket, identity: identity))
    let connection = RPCConnection(socket: socket)
    await connection.start()
    let config = try await connection.request("server.getConfig")
    print("server.getConfig: \(config.objectValue?.keys.count ?? 0) keys")
    let store = ShellStore(onChange: {})
    for try await value in await connection.stream("orchestration.subscribeShell", payload: .object(["requestCompletionMarker": .bool(true)])) {
        if let item = try? value.decode(as: ShellStreamItem.self) { await store.apply([item]) }
        if let snapshot = await store.snapshot {
            print("shell: \(snapshot.projects.count) projects, \(snapshot.threads.count) threads")
            break
        }
    }
    await connection.close()
    print("ok")
} catch {
    print("failed: \(error)")
    exit(1)
}
