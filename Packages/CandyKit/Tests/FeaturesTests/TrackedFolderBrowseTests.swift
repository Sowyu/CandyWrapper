import AppKit
import Testing
@testable import Features

@MainActor
struct TrackedFolderBrowseTests {
    /// The listing starts at the project folder's parent (ProjectRepositoriesSettings.tsx:262-266).
    @Test func startsAtTheProjectsParent() {
        #expect(TrackedFolderBrowse.initialQuery(workspaceRoot: "/Users/me/code/app") == "/Users/me/code/")
        #expect(TrackedFolderBrowse.initialQuery(workspaceRoot: "/") == "/")
    }

    /// `..`, the filtered subfolders, and the folder a query resolves to (trackedFolders.logic.ts:21-42).
    @Test func listsFiltersAndResolves() {
        let state = FolderBrowseState(request: { _, _, _ in .null }, environmentId: "e", cwd: "/Users/me/code/app")
        state.set("/Users/me/code/", .loaded(parent: "/Users/me/code", entries: [
            .init(name: "app", fullPath: "/Users/me/code/app"), .init(name: "api", fullPath: "/Users/me/code/api"),
            .init(name: ".git", fullPath: "/Users/me/code/.git"),
        ]))
        let all = state.view(for: "/Users/me/code/")
        #expect(all.titles == ["..", "app", "api"])
        #expect(all.picks == ["/Users/me/", "/Users/me/code/app/", "/Users/me/code/api/"])
        #expect(all.folder?.path == "/Users/me/code" && all.folder?.name == "code")
        let typed = state.view(for: "/Users/me/code/api")
        #expect(typed.titles == ["..", "api"])
        #expect(typed.folder?.path == "/Users/me/code/api")
        #expect(state.view(for: "relative").folder == nil)
        #expect(state.view(for: "/Users/me/other/").status == .loading)
    }

    /// Over 100 matches say how many more there are.
    @Test func capsTheListAtAHundred() {
        let state = FolderBrowseState(request: { _, _, _ in .null }, environmentId: "e", cwd: "/r")
        state.set("/r/", .loaded(parent: "/r", entries: (0..<130).map { .init(name: "d\($0)", fullPath: "/r/d\($0)") }))
        let view = state.view(for: "/r/")
        #expect(view.titles.count == 101)
        #expect(view.status == .more(30))
        let browser = TrackedFolderBrowserView()
        browser.set(titles: view.titles, status: view.status)
        #expect(Int(browser.height(forWidth: 400)) == 101 * 32 + 28)
        browser.set(titles: [], status: .none)
        #expect(browser.height(forWidth: 400) == 160)
    }
}
