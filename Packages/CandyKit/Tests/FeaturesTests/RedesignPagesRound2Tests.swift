import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Round-2 review fixes on Redesign's pages, Settings and states.
@MainActor
struct RedesignPagesRound2Tests {
    private func withRedesign(_ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        try body()
    }

    private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    /// P4, P7: a server too old for a page names itself and offers its update, or Environments without the grant.
    @Test func unsupportedServerRoute() {
        #expect(ServerUpdateRoute(environment: "studio", canUpdate: true).buttonTitle == "Update studio")
        #expect(ServerUpdateRoute(environment: "studio", canUpdate: false).buttonTitle == "Open Environments")
        #expect(ServerUpdateRoute(environment: "studio", canUpdate: true).message(for: "workflows").contains("on studio"))
    }

    @Test func workflowsUnsupportedOffersTheUpdate() {
        withRedesign {
            let page = WorkflowsPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            var pressed = false
            page.onUpdateServer = { pressed = true }
            page.content = .unsupported(ServerUpdateRoute(environment: "studio", canUpdate: true))
            page.layoutSubtreeIfNeeded()
            let button = Self.descendants(of: page).compactMap { $0 as? ButtonView }.first { $0.title == "Update studio" }
            #expect(button != nil)
            button?.performAction()
            #expect(pressed)
        }
    }

    /// O4: the inline row shows the recovery step, not a restatement of its title.
    @Test func inlineStateShowsTheRecovery() {
        #expect(EmptyView.inlineDetail("Git could not be started in /Users/demo/repo. Check that git is installed, then retry.")
            == "Check that git is installed, then retry.")
        #expect(EmptyView.inlineDetail("One sentence only.") == "One sentence only.")
    }

    /// G4: an untitled section, the Keybindings toolbar under the page title, drops its header row in Redesign.
    @Test func untitledSectionHasNoHeaderRow() {
        withRedesign {
            let row = SettingsRowView(title: "Row")
            let titled = SettingsSectionView(title: "Keybindings", rows: [row])
            let untitled = SettingsSectionView(title: "", rows: [SettingsRowView(title: "Row")])
            #expect(titled.height(forWidth: 600) - untitled.height(forWidth: 600) == 38)
        }
    }
}
