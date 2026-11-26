import AppKit
import Testing
@testable import Features

@MainActor
struct AccessEnvironmentTests {
    static let candidates = [
        AccessEnvironment.Candidate(id: "local", label: "Mac", machine: "desktop", connected: true),
        AccessEnvironment.Candidate(id: "vps", label: "VPS", machine: "server", connected: false),
    ]

    /// `resolveAccessEnvironmentId` (ConnectionsSettings.logic.ts:494-510).
    @Test func resolvesSelectionThenPrimaryThenConnected() {
        #expect(AccessEnvironment.resolve(primary: "local", candidates: Self.candidates, selected: "vps") == "vps")
        #expect(AccessEnvironment.resolve(primary: "local", candidates: Self.candidates, selected: "gone") == "local")
        #expect(AccessEnvironment.resolve(primary: nil, candidates: Self.candidates.reversed(), selected: nil) == "local")
        #expect(AccessEnvironment.resolve(primary: nil, candidates: [Self.candidates[1]], selected: nil) == "vps")
        #expect(AccessEnvironment.resolve(primary: nil, candidates: [], selected: nil) == nil)
    }

    /// The picker shows above the machine on Access only, and reports a pick.
    @Test func pickerShowsOnAccessAndReportsThePick() {
        let page = ConnectionsSettingsView()
        page.showsAccess = true
        var picked: String?
        page.actions.pickAccessEnvironment = { picked = $0 }
        var model = ConnectionsPageModel(thisMachine: .init(label: "Mac", machine: "desktop", rows: []))
        model.accessPicker = .init(candidates: Self.candidates, selected: "local")
        page.set(model)
        let picker = page.subviews.compactMap { $0 as? AccessEnvironmentPickerView }.first
        #expect(picker?.select.options == ["Mac", "VPS"])
        #expect(picker?.select.selectedIndex == 0)
        #expect(picker?.select.optionTrailingDetails == [nil, "Offline"])
        picker?.select.onChange?(1)
        #expect(picked == "vps")
        page.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        page.layout()
        #expect(picker?.isHidden == false && picker?.frame.minY == 0)
        page.showsAccess = false
        page.layout()
        #expect(picker?.isHidden == true)
    }
}
