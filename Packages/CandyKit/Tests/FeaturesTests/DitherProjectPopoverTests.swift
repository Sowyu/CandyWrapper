import AppKit
import Testing
import DesignSystem
@testable import Features

/// Dither's Capy project popover: filtering, the fixed rows and keyboard picks.
@MainActor
struct DitherProjectPopoverTests {
    static let projects = [DitherProjectPopoverView.Project(key: "a", label: "Home", icon: nil),
                           DitherProjectPopoverView.Project(key: "b", label: "Café app", icon: nil)]

    @Test func filterMatchesWithoutCaseOrAccents() {
        #expect(DitherProjectPopoverView.filter(Self.projects, query: "cafe").map(\.key) == ["b"])
        #expect(DitherProjectPopoverView.filter(Self.projects, query: " ").count == 2)
    }

    @Test func noProjectRowFollowsTheScratchMachine() {
        let with = DitherProjectPopoverView(projects: Self.projects, selectedKey: "a", noProjectMachine: "This Mac", isScratch: false)
        let without = DitherProjectPopoverView(projects: Self.projects, selectedKey: "a", noProjectMachine: nil, isScratch: false)
        // 36 search + 0.5, projects 8 + 2 x 28 + 0.5, No project 8 + 28 + 0.5, footer 8 + 2 x 28.
        #expect(with.popupSize == CGSize(width: 256, height: 36.5 + 64.5 + 36.5 + 64))
        #expect(without.popupSize.height == with.popupSize.height - 36.5)
    }

    @Test func keysWalkProjectsThenFixedRows() {
        let view = DitherProjectPopoverView(projects: Self.projects, selectedKey: "a", noProjectMachine: "This Mac", isScratch: false)
        var picked: [DitherProjectPopoverView.Choice] = []
        view.onChoose = { picked.append($0) }
        _ = view.popupHandleKey(.up)
        _ = view.popupHandleKey(.enter)
        view.setQuery("caf")
        _ = view.popupHandleKey(.enter)
        _ = view.popupHandleKey(.down)
        _ = view.popupHandleKey(.enter)
        #expect(picked == [.manageProjects, .project("b"), .noProject])
    }
}
