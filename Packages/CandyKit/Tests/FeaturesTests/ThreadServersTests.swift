import AppKit
import Testing
import T3Protocol
import DesignSystem
@testable import Features

@MainActor
struct ThreadServersTests {
    @Test func oldAndNewOwnershipDecodeAndFilterWithoutLosingProcessSource() throws {
        func decode(_ ownership: String) throws -> DiscoveredLocalServer {
            try JSONDecoder().decode(DiscoveredLocalServer.self, from: Data(#"{"host":"localhost","port":3000,"url":"http://localhost:3000","processName":"node","pid":42,\#(ownership)}"#.utf8))
        }
        let old = try decode(#""terminal":{"threadId":"t","terminalId":"term"}"#)
        let agent = try decode(#""terminal":null,"agent":{"threadId":"t"}"#)
        let foreign = try decode(#""terminal":null,"agent":{"threadId":"other"}"#)
        #expect(old.agent == nil)
        #expect(ThreadServerPresentation.servers([old, agent, foreign], threadId: "t") == [old, agent])
        #expect(ThreadServerPresentation.source(old) == "Terminal · node")
        #expect(ThreadServerPresentation.source(agent) == "Agent · node")
    }

    @Test func stopRequiresCapabilityGrantAndKnownPidAndModifiedClicksOpenExternally() {
        var server = DiscoveredLocalServer(host: "localhost", port: 3000, url: "http://localhost:3000", pid: 42)
        #expect(ThreadServerPresentation.stopInput(server, supported: true, permitted: true) == .object(["pid": .number(42), "port": .number(3000)]))
        #expect(ThreadServerPresentation.stopInput(server, supported: false, permitted: true) == nil)
        #expect(ThreadServerPresentation.stopInput(server, supported: true, permitted: false) == nil)
        server.pid = nil
        #expect(ThreadServerPresentation.stopInput(server, supported: true, permitted: true) == nil)
        #expect(!ThreadServerPresentation.opensExternally(modifiers: [], button: 0))
        #expect(ThreadServerPresentation.opensExternally(modifiers: .command, button: 0))
        #expect(ThreadServerPresentation.opensExternally(modifiers: .control, button: 0))
        #expect(ThreadServerPresentation.opensExternally(modifiers: [], button: 2))
    }

    @Test func sourceRemainsVisibleWithStopAndTheCardReleasesEmptyRows() {
        let card = ThreadDetailsCardView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let before = card.preferredHeight
        let server = DiscoveredLocalServer(host: "localhost", port: 3000, url: "http://localhost:3000", processName: "node", pid: 42, agent: .init(threadId: "t"))
        card.servers.configure(servers: [server], supportsStop: true, canOpen: true, canStop: true, stopping: nil)
        card.frame.size.height = card.preferredHeight
        card.layoutSubtreeIfNeeded()
        #expect(card.preferredHeight > before)
        func labels(_ view: NSView) -> [LabelView] { view.subviews.flatMap { ($0 as? LabelView).map { [$0] } ?? labels($0) } }
        let source = labels(card.servers).first { $0.text == "Agent · node" }
        #expect(source?.isHidden == false && (source?.frame.width ?? 0) > 0)
        card.servers.configure(servers: [], supportsStop: false, canOpen: false, canStop: false, stopping: nil)
        #expect(card.preferredHeight == before)
    }
}
