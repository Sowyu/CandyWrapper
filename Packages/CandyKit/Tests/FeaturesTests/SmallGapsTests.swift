import AppKit
import Testing
import T3Protocol
@testable import Features

/// The welcome wizard's import logic (projectImport.logic.test.ts cases) and the composer's resting images.
@MainActor
struct SmallGapsTests {
    private func candidate(_ path: String, git: OnboardingProjectCandidate.Git, threads: Int = 5, at: String? = "2026-10-10T00:00:00.000Z") -> OnboardingProjectCandidate {
        OnboardingProjectCandidate(environmentId: "env", path: path, title: (path as NSString).lastPathComponent, threadCount: threads, lastActiveAt: at, git: git)
    }

    @Test func groupsClonesAndFoldsPlainFolders() {
        let a = candidate("/w/app", git: .repository(remoteKey: "github.com/o/app", name: "o/app"), at: "2026-10-01T00:00:00.000Z")
        let b = candidate("/w/app-2", git: .repository(remoteKey: "github.com/o/app", name: "o/app"), at: "2026-10-09T00:00:00.000Z")
        let c = candidate("/w/solo", git: .repository(remoteKey: nil, name: nil), at: "2026-10-05T00:00:00.000Z")
        let d = candidate("/w/notes", git: .none)
        let old = candidate("/w/legacy", git: .unknown, at: nil)
        let (repos, other) = OnboardingProjectImport.group([a, c, b, d, old])
        #expect(repos.map(\.label) == ["o/app", "solo", "legacy"])
        #expect(repos[0].candidates.map(\.path) == ["/w/app", "/w/app-2"])
        #expect(repos[0].threadCount == 10)
        #expect(repos[0].lastActiveAt == "2026-10-09T00:00:00.000Z")
        #expect(repos[1].repository == nil)
        #expect(other.map(\.path) == ["/w/notes"])
    }

    @Test func defaultSelectionIsRecentRepositoriesWithThreads() {
        let now = T3Timestamp.parseEpochMs("2026-10-12T00:00:00.000Z")!
        let picked = OnboardingProjectImport.recent([
            candidate("/a", git: .repository(remoteKey: nil, name: nil)),
            candidate("/b", git: .none),
            candidate("/c", git: .unknown, threads: 2),
            candidate("/d", git: .unknown, at: "2026-08-01T00:00:00.000Z"),
            candidate("/e", git: .unknown, at: nil),
            candidate("/f", git: .unknown, at: "2026-10-13T00:00:00.000Z"),
        ], nowMs: now)
        #expect(picked.map(\.path) == ["/a"])
    }

    @Test func landingAndWarnings() {
        let history = ["k2": "p2"], done = ["k1": "p1", "k2": "p2"]
        #expect(OnboardingProjectImport.landing(["k1", "k2"], withHistory: history, completed: done) == "p2")
        #expect(OnboardingProjectImport.landing(["k1"], withHistory: [String: String](), completed: done) == "p1")
        #expect(OnboardingProjectImport.landing(["k3"], withHistory: history, completed: done) == nil)
        #expect(OnboardingProjectImport.warning(imported: 3, skipped: 1) == "Imported 3 threads. 1 thread could not be imported.")
        #expect(OnboardingProjectImport.warning(imported: 0, skipped: 2) == "2 threads could not be imported.")
        #expect(OnboardingProjectImport.warning(imported: 1, skipped: 0) == "Imported 1 thread. Some thread history could not be imported.")
        #expect(OnboardingProjectImport.warning(imported: 0, skipped: 0) == "Could not import thread history.")
    }

    @Test func candidateDecodesGitStates() throws {
        let missing = try #require(OnboardingProjectCandidate(environmentId: "e", json: .object(["path": .string("/p"), "title": .string("p")])))
        #expect(missing.git == .unknown)
        let none = try #require(OnboardingProjectCandidate(environmentId: "e", json: .object(["path": .string("/p"), "git": .null])))
        #expect(none.git == .none)
        let repo = try #require(OnboardingProjectCandidate(environmentId: "e", json: .object([
            "path": .string("/p"), "git": .object(["remoteKey": .string("k"), "repository": .string("o/n")])])))
        #expect(repo.git == .repository(remoteKey: "k", name: "o/n"))
        #expect(OnboardingProjectImport.key("e", "/p") == #"["e","/p"]"#)
    }

    @Test func restingImagesShowThreeThenACount() {
        #expect(ComposerRestingImagesView.width(count: 0) == 0)
        #expect(ComposerRestingImagesView.width(count: 1) == CGFloat(32))
        #expect(ComposerRestingImagesView.width(count: 3) == CGFloat(96))
        #expect(ComposerRestingImagesView.width(count: 7) == CGFloat(128))
    }
}
