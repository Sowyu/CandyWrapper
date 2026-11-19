import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Nightly 4928's one model and effort control (#28057): the trigger suffix, the docked effort column and its footer.
@MainActor @Suite struct ComposerModelEffortTests {
    static func effort(_ ids: [String], current: String? = nil, injected: [String]? = nil) -> ProviderOptionDescriptor {
        ProviderOptionDescriptor(id: "effort", label: "Effort", type: .select,
                                 options: ids.map { ProviderOptionChoice(id: $0, label: $0.capitalized, isDefault: $0 == "medium") },
                                 currentValue: current.map { .string($0) }, promptInjectedValues: injected)
    }

    @Test func defaultIsNamedInsteadOfTheLowestBar() throws {
        // #38684: Default leaves the level to the agent, so it shows its name.
        let d = Self.effort(["default", "low", "medium", "high"])
        let named = try #require(ComposerEffort.resolve(d, current: "default"))
        #expect(named.special && named.label == "Default" && named.count == 3)
        let low = try #require(ComposerEffort.resolve(d, current: "low"))
        #expect(!low.special && low.filled == 1 && low.count == 3)
        // More than seven ordinary levels no longer draw as bars.
        #expect(ComposerEffort.resolve(Self.effort((1...8).map { "l\($0)" }), current: "l1") == nil)
    }

    @Test func suffixNamesTheEffortSpeedAndUltracode() {
        let descriptors = [Self.effort(["low", "medium", "high", "ultrathink"], current: "high", injected: ["ultrathink"]),
                           ProviderOptionDescriptor(id: "fastMode", label: "Fast Mode", type: .boolean, currentValue: .bool(true)),
                           ProviderOptionDescriptor(id: "ultracode", label: "Ultracode", type: .boolean, currentValue: .bool(true))]
        let words = ComposerModelSuffix(descriptors, ultrathink: false, bars: false)
        #expect(words.word == "High" && words.glyph == nil && words.speed == "Fast" && words.ultracode)
        let bars = ComposerModelSuffix(descriptors, ultrathink: false, bars: true)
        #expect(bars.word == nil && bars.glyph?.filled == 3)
        // The prompt's Ultrathink is a named level in either display mode.
        #expect(ComposerModelSuffix(descriptors, ultrathink: true, bars: true).word == "Ultrathink")
        #expect(ComposerModelSuffix([], ultrathink: false, bars: false).isEmpty)
    }

    @Test func columnListsLevelsWithoutUltrathinkAndMovesByKeyboard() {
        let column = ComposerEffortColumnView(frame: NSRect(x: 0, y: 0, width: 192, height: 346))
        var picked: String?
        column.onSelect = { _, value in picked = value }
        let agent = ProviderOptionDescriptor(id: "agent", label: "Agent", type: .select,
                                             options: [ProviderOptionChoice(id: "build", label: "Build"), ProviderOptionChoice(id: "plan", label: "Plan")],
                                             currentValue: .string("build"))
        column.update(descriptors: [Self.effort(["low", "medium", "high", "ultrathink"], current: "medium", injected: ["ultrathink"]), agent],
                      ultrathink: false, locked: false, model: "Haiku 5.5")
        // #28044: Ultrathink leaves the levels; the agent's mode is one row below them.
        #expect(column.rows.map(\.kind) == [.level(label: "Low", selected: false, isDefault: false),
                                           .level(label: "Medium", selected: true, isDefault: true),
                                           .level(label: "High", selected: false, isDefault: false),
                                           .menu(label: "Agent", value: "Build")])
        #expect(column.focus(levelsOnly: true) && column.focusIndex == 1)
        #expect(column.handleKey(.down) && column.focusIndex == 2)
        #expect(column.handleKey(.enter) && picked == "high")
        #expect(column.handleKey(.down) && column.handleKey(.down) && column.focusIndex == 3)
        // Ultrathink in the prompt body locks the levels; the option row keeps the only stop.
        column.update(descriptors: [Self.effort(["low", "medium"], current: "medium", injected: ["ultrathink"]), agent],
                      ultrathink: true, locked: true, model: "Haiku 5.5")
        #expect(column.rows.filter(\.isEnabled).count == 1)
        #expect(column.focus(levelsOnly: false) && column.focusIndex == 2)
    }

    @Test func footerOffersSpeedAndPermissions() {
        let footer = ComposerPickerFooterView(frame: NSRect(x: 0, y: 0, width: 552, height: 45))
        var fast: Bool?
        footer.onBoolean = { id, on in if id == "fastMode" { fast = on } }
        footer.update(descriptors: [ProviderOptionDescriptor(id: "fastMode", label: "Fast Mode", type: .boolean, currentValue: .bool(false))],
                      runtimeMode: .fullAccess)
        #expect(footer.speed?.segments.map(\.checked) == [true, false])
        footer.speed?.segments[1].performAction()
        #expect(fast == true && footer.ultracode == nil && footer.permissions != nil)
    }

    @Test func pickersDockTheColumnAndDropTheTraitsTrigger() throws {
        let p = try PickersFidelityTests.pickers()
        #expect(p.docksEffort)
        #expect(!p.controlsView.showsTraits)
        #expect((p.modelButton.adornment as? ComposerModelSuffixView)?.suffix.word == "Medium")
        // The default permissions live in the picker's footer, so the chip hides.
        #expect(p.controlsView.hidesPermissions)
    }
}

/// Writes the docked picker and the closed footer controls to `CW_EXPORT_DIR` for eyeballing. An export tool, not a
/// test: runs only with CW_EXPORT=1.
@MainActor @Suite struct ComposerModelEffortExport {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CW_EXPORT"] != nil, "export tool, set CW_EXPORT=1"))
    func dockedPicker() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CW_EXPORT_DIR"] ?? NSTemporaryDirectory())
        let config = try PickersFidelityTests.recordedConfig(transcript: "24-nightly-3814")
        let p = try PickersFidelityTests.pickers()
        let view = ModelPickerView(catalog: ProviderCatalog(config.providers), favorites: [], active: "claudeAgent", activeModel: "claude-haiku-5-5")
        let dock = DockedModelPickerView(picker: view)
        dock.column.update(descriptors: p.current.descriptors, ultrathink: false, locked: false, model: "Haiku 5.5")
        dock.footer.update(descriptors: p.current.descriptors + [ProviderOptionDescriptor(id: "fastMode", label: "Fast Mode", type: .boolean, currentValue: .bool(false))],
                           runtimeMode: .fullAccess)
        let popup = PickerPopupView(dock)
        for theme in ["light", "dark"] {
            let size = CGSize(width: popup.popupSize.width + 16, height: popup.popupSize.height + 16)
            let image = PickersFidelityTests.render(popup, size: size, backdrop: .gray, dark: theme == "dark",
                                                    contentFrame: CGRect(origin: CGPoint(x: 8, y: 8), size: popup.popupSize))
            try Snapshot.writePNG(image, to: dir.appendingPathComponent("docked.\(theme).png"))
            let bar = p.controlsView
            let w = bar.intrinsicContentSize.width
            let footer = PickersFidelityTests.render(bar, size: CGSize(width: w + 16, height: 44), backdrop: .gray, dark: theme == "dark",
                                                     contentFrame: CGRect(x: 8, y: 8, width: w, height: 28))
            try Snapshot.writePNG(footer, to: dir.appendingPathComponent("footer.\(theme).png"))
        }
    }
}
