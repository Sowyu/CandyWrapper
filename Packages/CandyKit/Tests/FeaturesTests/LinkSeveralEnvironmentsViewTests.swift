import AppKit
import Testing
import DesignSystem
@testable import Features

/// The "Link several" dialog's form (LinkSeveralEnvironments.tsx): picking, the button, the run's states.
@MainActor
struct LinkSeveralEnvironmentsViewTests {
    static func machine(_ id: String, linked: Bool = false, connected: Bool = true) -> LinkableMachine {
        LinkableMachine(environmentId: id, label: id, connected: connected, linked: linked, urls: ["https://\(id).ts.net"], canMint: true)
    }

    static func make(preset: [String] = [], links: LinkBatch.ListState = .loaded) -> (LinkSeveralEnvironmentsFormView, DialogView, ButtonView, ButtonView) {
        let machines = [machine("a"), machine("b"), machine("c", linked: true), machine("d", connected: false)]
        let form = LinkSeveralEnvironmentsFormView(candidates: LinkBatch.candidates(machines, writable: ["a", "b", "c"], links: links),
                                                   sourceLabel: "nucbox", preset: preset, presetOnly: false, linksState: links)
        let (dialog, cancel, link) = LinkSeveralEnvironmentsDialog.make(form: form)
        form.frame = NSRect(x: 0, y: 0, width: 400, height: form.height(forWidth: 400))
        form.layoutSubtreeIfNeeded()
        return (form, dialog, cancel, link)
    }

    @Test func titleAndPicking() {
        let (form, dialog, cancel, link) = Self.make(preset: ["a", "c"])
        #expect(dialog.title == "Link several machines from nucbox")
        #expect(form.chosen.map(\.environmentId) == ["a"])  // c is linked already, so it stays unticked
        #expect(link.title == "Link 1 machine" && link.isEnabled)
        #expect(cancel.title == "Cancel")
        form.selectAll.performAction()
        #expect(form.chosen.count == 2 && link.title == "Link 2 machines")
        #expect(form.selectAll.title == "Select none")
        form.selectAll.performAction()
        #expect(form.chosen.isEmpty && !link.isEnabled)
    }

    @Test func nothingPicksUntilTheLinksLoad() {
        let (form, _, _, link) = Self.make(preset: ["a"], links: .loading)
        #expect(form.chosen.isEmpty && !link.isEnabled)
    }

    @Test func aRunShowsOutcomesAndKeepsTheFailed() {
        let (form, _, cancel, link) = Self.make(preset: ["a", "b"])
        form.linking = ["a", "b"]
        #expect(link.title == "Linking…" && !cancel.isEnabled)
        form.outcomes["a"] = .linked(back: .linked)
        form.outcomes["b"] = .failed(.codeRefused, detail: "The code was used")
        form.linking = []
        form.keepFailed()
        #expect(form.chosen.map(\.environmentId) == ["b"])
        #expect(cancel.title == "Done")
        #expect(LinkBatch.summary(form.outcomes) == "Linked 1 of 2. The ones that failed stay selected, so you can try them again.")
        #expect(LinkBatch.status(linking: false, outcome: form.outcomes["a"], blocked: nil) == "Linked both ways")
    }

    @Test func theLinkBackBoxShowsOnlyWhereOffered() {
        let (form, _, _, _) = Self.make()
        #expect(!form.showsBack)
        form.backOffered = ["a"]
        #expect(form.showsBack)
        form.backBox.performAction()
        form.selectAll.performAction()
        #expect(form.alsoLinkBack && form.oneWayOnly == 1)
    }
}

extension LinkSeveralEnvironmentsViewTests {
    /// With `CW_SNAP_DIR` set, the dialog after a run, in the default theme and in Redesign.
    @Test func snapshots() throws {
        let (form, dialog, _, _) = Self.make(preset: ["a", "b"])
        form.backOffered = ["a"]
        form.outcomes = ["a": .linked(back: .failed(.unreachable, detail: nil)), "b": .failed(.codeRefused, detail: "The code was used")]
        form.keepFailed()
        dialog.frame = NSRect(x: 0, y: 0, width: 448, height: 100)
        dialog.frame.size.height = dialog.height(forWidth: 448)
        #expect(dialog.frame.height > 400)
        dialog.layoutSubtreeIfNeeded()
        for theme in ["light", "dark"] {
            for redesign in [false, true] {
                try EnvironmentsMapViewTests.snap(dialog, "link-several-\(theme)\(redesign ? "-redesign" : "")", dark: theme == "dark", redesign: redesign)
            }
        }
    }
}
