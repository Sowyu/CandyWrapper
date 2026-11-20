import Foundation
import Testing
@testable import T3Protocol
@testable import Features

/// #38294: which issue links get a preview card, after client-runtime issueLinks.test.ts.
struct IssueLinkLogicTests {
    static func identity(_ json: String) throws -> RepositoryIdentity { try JSONDecoder().decode(RepositoryIdentity.self, from: Data(json.utf8)) }

    @Test func resolvesGitHostLinks() throws {
        let gh = try Self.identity(#"{"canonicalKey":"github.com/pingdotgg/t3code","locator":{"source":"git-remote","remoteName":"origin","remoteUrl":"https://github.com/pingdotgg/t3code.git"},"provider":"github","owner":"pingdotgg","name":"t3code","displayName":"pingdotgg/t3code"}"#)
        let projects: [IssueLinkLogic.Project] = [(id: "p1", identity: gh)]
        let own = IssueLinkLogic.target(url: "https://github.com/PingDotGG/t3code/issues/12", projects: projects)
        #expect(own == IssueRef(projectId: "p1", tracker: "github", host: "github.com", scope: "pingdotgg/t3code", key: "12"))
        // Another repository on the host borrows the project's credentials and keeps its own scope.
        #expect(IssueLinkLogic.target(url: "https://github.com/octo/other/issues/3", projects: projects)?.scope == "octo/other")
        #expect(IssueLinkLogic.target(url: "https://github.com/pingdotgg/t3code/pull/12", projects: projects) == nil)
        #expect(IssueLinkLogic.target(url: "https://github.evil.com/pingdotgg/t3code/issues/12", projects: projects) == nil)
        #expect(IssueLinkLogic.target(url: "https://github.com/pingdotgg/t3code/issues/12", projects: []) == nil)
        #expect(IssueLinkLogic.target(url: "https://github.com/pingdotgg/t3code/issues/0", projects: projects) == nil)
    }
}
