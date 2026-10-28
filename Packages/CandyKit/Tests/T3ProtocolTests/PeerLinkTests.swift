import Foundation
import Testing
@testable import T3Protocol

/// Linked environments at Nightly 3814: the list reply, link health, the offer gate, pairing scopes and link request answers.
struct PeerLinkTests {
    private func link(status: PeerLinkSummary.Status = .reachable, expiresAt: String, lastError: String? = nil) -> PeerLinkSummary {
        PeerLinkSummary(environmentId: "env-b", label: "box", urls: ["http://127.0.0.1:47399"], access: "approval-required",
                        linkedAt: "2026-10-28T10:00:00.000Z", expiresAt: expiresAt, lastError: lastError, status: status)
    }

    private let now = Date(timeIntervalSince1970: 1_793_188_800) // 2026-10-28T12:00:00Z

    @Test func listDecodesTheServerReply() throws {
        let reply = try JSONValue(parsing: Data("""
        {"links":[{"environmentId":"bb23b57a","label":"Sandbox B","urls":["http://127.0.0.1:47399"],"access":"read-only",
        "linkedAt":"2026-10-28T10:00:00.000Z","expiresAt":"2026-11-27T10:00:00.000Z","lastReachedAt":null,"lastError":null,"status":"reachable"}]}
        """.utf8))
        let links = try PeerLinkSummary.list(reply)
        #expect(links.count == 1)
        #expect(links[0].label == "Sandbox B")
        #expect(links[0].status == .reachable)
        #expect(links[0].lastReachedAt == nil)
    }

    /// `peerLinkHealth` (client-runtime/src/state/peerLinks.ts:47-57).
    @Test func healthFollowsT3() {
        #expect(PeerLinkHealth(link(expiresAt: "2026-12-01T12:00:00.000Z"), now: now) == .reachable(expiresInDays: nil))
        #expect(PeerLinkHealth(link(expiresAt: "2026-10-31T13:00:00.000Z"), now: now) == .reachable(expiresInDays: 4))
        #expect(PeerLinkHealth(link(expiresAt: "2026-10-28T11:00:00.000Z"), now: now) == .expired)
        #expect(PeerLinkHealth(link(status: .expired, expiresAt: "2026-12-01T12:00:00Z"), now: now) == .expired)
        #expect(PeerLinkHealth(link(status: .unreachable, expiresAt: "2026-12-01T12:00:00Z"), now: now) == .unreachable(nil))
        #expect(PeerLinkHealth(link(expiresAt: "2026-12-01T12:00:00Z", lastError: "Revoked"), now: now) == .failing("Revoked"))
        #expect(PeerLinkHealth(link(expiresAt: "2026-10-29T12:00:00.000Z"), now: now).text == "Expires in 1 day. Link it again to renew.")
        #expect(PeerLinkHealth.unreachable(nil).text == "Not answering right now.")
    }

    /// `offersLinkedEnvironments`: the capability and the Beta switch, so 3754 and older never offer links.
    @Test func offeredNeedsCapabilityAndSetting() {
        let on: JSONValue = .object(["linkedEnvironmentsEnabled": .bool(true)])
        #expect(PeerLinks.offered(capabilities: ["peerLinks"], settings: on))
        #expect(!PeerLinks.offered(capabilities: [], settings: on))
        #expect(!PeerLinks.offered(capabilities: ["peerLinks"], settings: .object(["linkedEnvironmentsEnabled": .bool(false)])))
        #expect(!PeerLinks.offered(capabilities: ["peerLinks"], settings: .object([:])))
    }

    @Test func pairingScopesMatchMcpClientScopes() {
        #expect(PeerLinks.scopes(for: "read-only") == ["orchestration:read"])
        #expect(PeerLinks.scopes(for: "approval-required") == ["orchestration:read", "orchestration:operate"])
        #expect(PeerLinks.scopes(for: "full-access").contains("source-control:write"))
    }

    @Test func linkAnswerNeedsCodeAndAddress() throws {
        #expect(LinkRequestAnswer.link(environmentId: nil, label: nil, urls: ["https://x"], access: "auto", pairingCode: "  ") == nil)
        #expect(LinkRequestAnswer.link(environmentId: nil, label: nil, urls: [" "], access: "auto", pairingCode: "abc") == nil)
        let answer = try #require(LinkRequestAnswer.link(environmentId: "env-b", label: "box", urls: ["https://a", "https://b"],
                                                         access: "auto", pairingCode: " abc "))
        #expect(answer["type"] == .string("link"))
        #expect(answer["pairingCode"] == .string("abc"))
        #expect(answer["urls"] == .array([.string("https://a"), .string("https://b")]))
        #expect(answer["environmentId"] == .string("env-b"))
    }

    /// `hintRank` and `linkRequestInitialMachine` (linkRequest.ts:150-200).
    @Test func hintPicksTheBestMachine() {
        #expect(LinkRequestAnswer.hintRank("VPS", "my vps") == 0)
        #expect(LinkRequestAnswer.hintRank("vps-hetzner", "vps") == 1)
        #expect(LinkRequestAnswer.hintRank("my-box", "box") == 2)
        #expect(LinkRequestAnswer.hintRank("box", "the box on hetzner") == 3)
        #expect(LinkRequestAnswer.hintRank("laptop", "vps") == 4)
        let labels = [(id: "a", label: "Laptop"), (id: "b", label: "Hetzner box"), (id: "c", label: "box")]
        #expect(LinkRequestAnswer.initialMachine(environmentId: nil, hint: "box", labels: labels) == "c")
        #expect(LinkRequestAnswer.initialMachine(environmentId: nil, hint: "mainframe", labels: labels) == nil)
        #expect(LinkRequestAnswer.initialMachine(environmentId: "z", hint: "box", labels: labels) == "z")
    }

    @Test func requestFailureTextByReason() {
        #expect(PeerLinks.requestFailure("already_answered") == "This link request was already answered.")
        #expect(PeerLinks.requestFailure("nope") == nil)
    }
}
