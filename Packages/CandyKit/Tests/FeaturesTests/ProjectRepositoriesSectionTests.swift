import Foundation
import Testing
import T3Protocol
@testable import Features

@MainActor
struct ProjectRepositoriesSectionTests {
    /// `trackedFolderDisplayPath`: relative inside the project folder, absolute outside it.
    @Test func displayPathIsRelativeInsideTheProject() {
        #expect(ProjectRepositoriesSection.displayPath("/w/app/lib", workspaceRoot: "/w/app") == "lib")
        #expect(ProjectRepositoriesSection.displayPath("/w/app/lib", workspaceRoot: "/w/app/") == "lib")
        #expect(ProjectRepositoriesSection.displayPath("/w/other", workspaceRoot: "/w/app") == "/w/other")
        #expect(ProjectRepositoriesSection.displayPath("/w/application", workspaceRoot: "/w/app") == "/w/application")
    }

    /// `resolveTrackedFolderInput` without a listing: only absolute paths, trailing slashes dropped, name from the leaf.
    @Test func resolveTakesAbsolutePathsOnly() {
        #expect(ProjectRepositoriesSection.resolve("relative/repo") == nil)
        #expect(ProjectRepositoriesSection.resolve("  ") == nil)
        #expect(ProjectRepositoriesSection.resolve("/") == nil)
        let r = ProjectRepositoriesSection.resolve(" /Users/me/code/api/ ")
        #expect(r?.path == "/Users/me/code/api")
        #expect(r?.name == "api")
    }

    /// `suggestedTrackedFolders`: workspace file folders not tracked yet; child folders are found without asking.
    @Test func suggestionsAreUntrackedWorkspaceFileFolders() throws {
        let scanned = try JSONValue.array([
            .object(["path": .string("/w/a"), "name": .string("a"), "isGitRepository": .bool(true), "source": .string("code-workspace")]),
            .object(["path": .string("/w/b"), "name": .string("b"), "isGitRepository": .bool(true), "source": .string("code-workspace")]),
            .object(["path": .string("/w/c"), "name": .string("c"), "isGitRepository": .bool(true), "source": .string("child")]),
        ]).decode(as: [WorkspaceScannedFolder].self)
        #expect(ProjectRepositoriesSection.suggested(["/w/a"], scanned: scanned).map(\.path) == ["/w/b"])
    }
}
