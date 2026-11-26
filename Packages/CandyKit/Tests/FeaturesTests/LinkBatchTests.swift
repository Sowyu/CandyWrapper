import Testing
@testable import Features

/// T3 5258 client-runtime/src/linkBatch.ts: which machines a batch may link, and how a run reports.
@MainActor
struct LinkBatchTests {
    static func machine(_ id: String, connected: Bool = true, linked: Bool = false, urls: [String] = ["https://\(1).ts.net"]) -> LinkableMachine {
        LinkableMachine(environmentId: id, label: id, connected: connected, linked: linked, urls: urls, canMint: true)
    }

    @Test func blocksWhatABatchCannotLink() {
        let machines = [Self.machine("a"), Self.machine("b", linked: true), Self.machine("c", connected: false),
                        Self.machine("d"), Self.machine("e", urls: [])]
        let blocked = LinkBatch.candidates(machines, writable: ["a", "b", "c", "e"], links: .loaded).map(\.blocked)
        #expect(blocked == [nil, .linked, .notConnected, .noAccess, .noAddress])
        #expect(LinkBatch.candidates(machines, writable: [], links: .loading).allSatisfy { $0.blocked == .linksUnknown })
    }

    @Test func runsEachMachineAndReports() async {
        let machines = (1...6).map { Self.machine("m\($0)") }
        let outcomes = await LinkBatch.run(machines, link: { m in
            m.environmentId == "m3" ? .failed(.codeRefused, detail: nil) : .linked
        }, back: { m in m.environmentId == "m1" ? .failed(.other, detail: "no") : .linked }, onOutcome: { _, _ in })
        #expect(outcomes.count == 6)
        #expect(outcomes["m3"] == .failed(.codeRefused, detail: nil))
        #expect(LinkBatch.status(linking: false, outcome: outcomes["m1"], blocked: nil) == "Linked one way")
        #expect(LinkBatch.status(linking: false, outcome: outcomes["m2"], blocked: nil) == "Linked both ways")
        #expect(LinkBatch.summary(outcomes) == "Linked 5 of 6. The ones that failed stay selected, so you can try them again. 1 machine could not link back.")
        #expect(LinkBatch.failure(reason: "pairing_rejected", answeredAs: false) == .codeRefused)
        #expect(LinkBatch.failure(reason: "unreachable", answeredAs: true) == .wrongEnvironment)
    }
}
