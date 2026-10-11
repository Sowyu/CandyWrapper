import Foundation
import Testing
import T3Protocol
@testable import Features

/// GitHub accounts and Bitbucket credentials, against GitHubAccountSettings.logic.test.ts and
/// BitbucketCredentialsSettings.tsx:92-112.
struct SourceControlCredentialsTests {
    @Test func groupsLoginsByHostKeepingBrokenAndEnvironmentLoginsOut() {
        let groups = GitHubAccountsLogic.group([
            .init(host: "github.com", account: "personal", active: true),
            .init(host: "github.com", account: "work"),
            .init(host: "github.com", account: "old", authenticated: false, error: "bad"),
            .init(host: "github.com", account: "bot", environmentVariable: "GH_TOKEN"),
            .init(host: "ghe.acme.test", account: "jm"),
        ])
        #expect(groups == [
            GitHubHostGroup(host: "github.com", activeAccount: "personal", selectable: ["personal", "work"],
                            broken: [.init(host: "github.com", account: "old", authenticated: false, error: "bad")],
                            environmentVariable: "GH_TOKEN"),
            GitHubHostGroup(host: "ghe.acme.test", activeAccount: "jm", selectable: ["jm"], broken: [], environmentVariable: nil),
        ])
    }

    @Test func decodesDiscoveredAccounts() {
        let json: JSONValue = .object(["host": .string("github.com"), "account": .string("a"), "active": .bool(true), "authenticated": .bool(true),
                                       "environmentVariable": .object(["_tag": .string("Some"), "value": .string("GH_TOKEN")])])
        #expect(GitHubDiscoveredAccount(json) == .init(host: "github.com", account: "a", active: true, environmentVariable: "GH_TOKEN"))
    }

    @Test func nextHostsPinsKeepsOthersAndDropsDefaults() {
        let other: [String: JSONValue] = ["ghe.acme.test": .object(["enabled": .bool(false)])]
        let pinned = GitHubAccountsLogic.nextHosts(other, host: "github.com", account: .some("work"))
        #expect(pinned == other.merging(["github.com": .object(["enabled": .bool(true), "account": .string("work")])]) { a, _ in a })
        let disabled = GitHubAccountsLogic.nextHosts(pinned, host: "github.com", enabled: false)
        #expect(disabled["github.com"] == .object(["enabled": .bool(false), "account": .string("work")]))
        #expect(GitHubAccountsLogic.nextHosts(disabled, host: "github.com", enabled: true, account: .some(nil)) == other)
    }

    @Test func bitbucketPatchFollowsT3() {
        typealias L = BitbucketCredentialsLogic
        let none = L.Saved()
        #expect(none.method == nil)
        // An access token clears the other method.
        #expect(L.patch(method: .accessToken, saved: none, accessToken: " tok ", email: nil, apiToken: "") == L.Saved(accessToken: "tok"))
        #expect(L.patch(method: .accessToken, saved: none, accessToken: "  ", email: nil, apiToken: "") == nil)
        // API token needs an email and a token.
        #expect(L.patch(method: .apiToken, saved: none, accessToken: "", email: "a@b.c", apiToken: "") == nil)
        #expect(L.patch(method: .apiToken, saved: none, accessToken: "", email: "a@b.c", apiToken: "t") == L.Saved(email: "a@b.c", apiToken: "t"))
        // Saved API token: Save is off until the email or token changes; the redacted token is resent.
        let saved = L.Saved(email: "a@b.c", apiToken: "••••")
        #expect(saved.method == .apiToken)
        #expect(L.patch(method: .apiToken, saved: saved, accessToken: "", email: nil, apiToken: "") == nil)
        #expect(L.patch(method: .apiToken, saved: saved, accessToken: "", email: "x@b.c", apiToken: "") == L.Saved(email: "x@b.c", apiToken: "••••"))
        // Access token wins when both are somehow saved.
        #expect(L.Saved(accessToken: "x", email: "a", apiToken: "b").method == .accessToken)
    }
}
