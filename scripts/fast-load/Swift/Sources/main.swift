import Foundation
import T3Client
import T3Store
import T3Protocol
import CryptoKit

struct Input: Decodable {
    let port: Int
    let token: String
    let threadId: String
    let label: String
}

actor Progress {
    var shell = false
    var thread = false
    var firstProjection: Double?
    var failure: String?
    let start = ContinuousClock.now
    func event(_ event: SubscriptionEvent, shell isShell: Bool) {
        switch event {
        case .value(let json):
            if json["kind"]?.stringValue == "synchronized" {
                if isShell { shell = true } else { thread = true }
            }
        case .interrupted(let error): failure = String(describing: error)
        case .subscribed: break
        }
    }
    func projectionReady() {
        if firstProjection == nil { firstProjection = elapsed() }
    }
    func failed(_ error: any Error) { failure = String(describing: error) }
    func elapsed() -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    var complete: Bool { shell && thread }
}

func counters(port: Int, mark: String) async throws -> [String: Int] {
    let url = URL(string: "http://127.0.0.1:\(port + 1000)/\(mark)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    return Dictionary(uniqueKeysWithValues: ["up", "down", "http_up", "http_down", "socket_up", "socket_down"].map {
        if case .number(let count) = value[$0] { return ($0, Int(count)) }
        return ($0, 0)
    })
}

func content(_ projection: ThreadProjection?) throws -> [String: Any] {
    guard let projection else { return [:] }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try encoded(projection)
    // Compare restored visible bodies, including every user/assistant item and
    // command input. Command outputs are intentionally omitted by both servers.
    func fields(_ value: JSONValue, _ keys: [String]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, value[$0] ?? .null) }))
    }
    let messages: [JSONValue]
    if case .array(let values) = json["messages"] { messages = values } else { messages = [] }
    let visible: [JSONValue]
    if case .array(let values) = json["visibleTurnItems"] { visible = values } else { visible = [] }
    let bodies: [JSONValue] = [
        .array(messages.map { fields($0, ["id", "role", "text", "attachments"]) }),
        .array(visible.map { fields($0["item"] ?? $0, ["id", "type", "text", "markdown", "input", "title", "messageId"]) })
    ]
    let bytes = try encoder.encode(bodies)
    let visibleMessages = visible.map { $0["item"] ?? $0 }.filter {
        ["user_message", "assistant_message"].contains($0["type"]?.stringValue ?? "")
    }
    return ["sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "messages": projection.messages.count, "visible_items": projection.visibleTurnItems.count,
            "blank_messages": messages.filter { ($0["text"]?.stringValue ?? "").isEmpty }.count,
            "visible_message_items": visibleMessages.count,
            "blank_visible_message_items": visibleMessages.filter { ($0["text"]?.stringValue ?? "").isEmpty }.count]
}

func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

func run(_ input: Input) async throws {
    guard [47541, 47542].contains(input.port) else { fatalError("Only the fast-load loopback proxies are allowed") }
    let http = EnvironmentHTTP(baseURL: URL(string: "http://127.0.0.1:\(input.port)")!)
    let supervisor = ConnectionSupervisor(dependencies: .init(connect: ConnectionSupervisor.directConnector(
        http: http, environmentId: nil, identity: ClientIdentity(appVersion: "fast-load-benchmark"), token: { input.token })))
    let shell = ShellStore(onChange: {})
    let thread = ThreadStore(threadId: ThreadId(rawValue: input.threadId), onChange: {})
    #if CANDY_HTTP_FIRST
    let loader = ThreadSnapshotLoader(http: http, token: input.token, threadId: ThreadId(rawValue: input.threadId))
    #endif

    for phase in ["cold", "retained-reconnect"] {
        let before = try await counters(port: input.port, mark: "\(input.label)-\(phase)-start")
        let progress = Progress()
        if await thread.currentUpdate()?.projection != nil { await progress.projectionReady() }
        let shellSubscription = supervisor.subscribe("orchestration.subscribeShell", payload: {
            var payload: [String: JSONValue] = ["requestCompletionMarker": .bool(true)]
            if let after = await shell.afterSequence { payload["afterSequence"] = .number(Double(after)) }
            return .object(payload)
        }, handler: { event in
            if case .value(let value) = event {
                do {
                    await shell.apply([try value.decode(as: ShellStreamItem.self)])
                } catch { await progress.failed(error) }
            }
            await progress.event(event, shell: true)
        })
        let threadSubscription = supervisor.subscribe("orchestration.subscribeThread", payload: {
            #if CANDY_HTTP_FIRST
            if await thread.subscribeInput().afterSequence == nil, let snapshot = await loader.load() {
                await thread.applySnapshot(snapshot)
                await progress.projectionReady()
            }
            #endif
            do { return try encoded(await thread.subscribeInput()) }
            catch { await progress.failed(error); return .object([:]) }
        }, handler: { event in
            if case .value(let value) = event {
                do {
                    #if CANDY_FAST_WIRE
                    try await thread.applyWire(value)
                    #else
                    await thread.apply([try value.decode(as: ThreadStreamItem.self)])
                    #endif
                    if await thread.currentUpdate()?.projection != nil { await progress.projectionReady() }
                } catch { await progress.failed(error) }
            }
            await progress.event(event, shell: false)
        })
        await supervisor.connect()
        while !(await progress.complete), await progress.failure == nil, await progress.elapsed() < 180 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let update = await thread.currentUpdate()
        let seconds = await progress.elapsed()
        let after = try await counters(port: input.port, mark: "\(input.label)-\(phase)-ready")
        let wireBytes = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, after[$0, default: 0] - before[$0, default: 0]) })
        let result: [String: Any] = [
            "label": input.label, "phase": phase,
            "synchronized": await progress.complete,
            "seconds": seconds,
            "first_projection_seconds": await progress.firstProjection as Any? ?? NSNull(),
            "messages": update?.projection?.messages.count ?? 0,
            "turn_items": update?.projection?.turnItems.count ?? 0,
            "sequence": update?.lastSequence as Any? ?? NSNull(),
            "failure": await progress.failure as Any? ?? NSNull(),
            "wire_bytes": wireBytes,
            "content": try content(update?.projection),
            "http_first": {
                #if CANDY_HTTP_FIRST
                true
                #else
                false
                #endif
            }()
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        fflush(stdout)
        shellSubscription.cancel()
        threadSubscription.cancel()
        await supervisor.disconnect()
        await shellSubscription.value
        await threadSubscription.value
    }
    // History correctness runs after both timed phases, over the unthrottled
    // sandbox origin. It cannot inflate the measured cold/reconnect traffic.
    var validationHTTP = EnvironmentHTTP(baseURL: URL(string: "http://127.0.0.1:\(input.port - 100)")!)
    validationHTTP.timeout = 30
    var pages = 0
    while let request = await thread.beginLoadEarlier(), pages < 100 {
        let page = try await validationHTTP.get(request.path, token: input.token, as: ThreadHistoryPage.self)
        await thread.applyHistoryPage(page, requestCursor: request.cursor)
        pages += 1
    }
    let validation = try content(await thread.currentUpdate()?.projection)
    let result: [String: Any] = ["label": input.label, "phase": "history-validation", "pages": pages, "content": validation]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}

let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
try await run(input)
