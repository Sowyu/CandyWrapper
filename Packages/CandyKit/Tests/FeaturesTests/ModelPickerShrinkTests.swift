import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The model picker's list shrinking under the pointer or the keyboard highlight: collapsing "Show less", a backend
/// heading, a tab switch, a search, a catalog refresh or a favorite. v1.15.0 trapped on "Show more" then "Show less"
/// (picker-crash, 2026-11-21): the highlight kept the clicked row's index from the longer list.
@MainActor @Suite(.serialized) struct ModelPickerShrinkTests {
    enum Theme: CaseIterable { case standard, redesign, glass }

    static func withTheme(_ theme: Theme, stacked: Bool = true, account: Bool = false, _ body: () throws -> Void) rethrows {
        let store = ClientSettingsStore.shared
        let before = ["redesignStackedPicker": store.current["redesignStackedPicker"], "redesignPickerAccount": store.current["redesignPickerAccount"]]
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous); store.update(before) }
        store.update(["redesignStackedPicker": .bool(stacked), "redesignPickerAccount": .bool(account)])
        var input = previous
        input.ditherLight = theme == .redesign; input.ditherDark = theme == .redesign
        input.glassLight = theme == .glass; input.glassDark = theme == .glass
        ThemeRuntime.apply(input)
        try body()
    }

    /// Claude with four current models and three legacy ones, as the report's picture, plus Codex for a second tab.
    static func catalog(legacy: Int = 3, current: Int = 4, subProviders: Bool = false, codex: Bool = true) -> ProviderCatalog {
        var models = (1...current).map { ServerProviderModel(slug: "m\($0)", name: "Claude Model \($0)") }
        models += (0..<legacy).map { ServerProviderModel(slug: "l\($0 + 1)", name: "Claude Legacy \($0 + 1)", isLegacy: true) }
        var claude = ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", models: models)
        if subProviders {
            claude.models = (1...3).map { ServerProviderModel(slug: "a\($0)", name: "Alpha \($0)", subProvider: "Alpha") }
                + (1...3).map { ServerProviderModel(slug: "b\($0)", name: "Beta \($0)", subProvider: "Beta") }
            claude.subProviders = [.init(name: "Alpha"), .init(name: "Beta")]
        }
        let codexProvider = ServerProvider(instanceId: "codex", driver: "codex", displayName: "Codex",
                                   models: [ServerProviderModel(slug: "gpt", name: "GPT")])
        return ProviderCatalog(codex ? [claude, codexProvider] : [claude])
    }

    final class Rig {
        let dock: DockedModelPickerView
        let window: NSWindow
        var picker: ModelPickerView { dock.picker }

        @MainActor init(catalog: ProviderCatalog = ModelPickerShrinkTests.catalog(), activeModel: String = "m1") {
            let picker = ModelPickerView(catalog: catalog, favorites: [], active: "claudeAgent", activeModel: activeModel)
            picker.jumpLabel = { $0 < 4 ? "⌘\($0 + 1)" : nil }
            picker.onSelect = { _, _ in }
            dock = DockedModelPickerView(picker: picker)
            dock.column.update(descriptors: [RedesignPickerLayoutTests.levels], ultrathink: false, locked: false, model: "Opus 5.5")
            dock.footer.update(descriptors: RedesignPickerLayoutTests.footerOptions, runtimeMode: .fullAccess)
            // Far off every screen, so the real pointer never rests on a row while a test runs.
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 900), styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(dock)
            lay()
        }

        /// The popup host sizes the dock to what it asks for, as `resizePopup` does on screen.
        @MainActor func lay() {
            let size = dock.naturalSize
            dock.frame = NSRect(x: 0, y: 0, width: size.width, height: min(size.height, 860))
            dock.layoutSubtreeIfNeeded()
        }

        @MainActor func event(_ type: NSEvent.EventType, at p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }

        @MainActor func center(_ row: ModelRowView) -> NSPoint { row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil) }

        /// Moves the pointer onto the row the way AppKit and HoverSync report it.
        @MainActor func hover(_ row: ModelRowView) { dock.layoutSubtreeIfNeeded(); picker.mouseMoved(with: event(.mouseMoved, at: center(row))) }

        /// A pointer click on the row: hover, then the row's own mouse up, then the host resizes. AppKit lays the views out
        /// before it delivers the next event, so a quick second click still finds a row made by the first; `relayout`
        /// false leaves the popup at its old size, as before the host resizes it.
        @MainActor func click(_ row: ModelRowView, relayout: Bool = true) {
            dock.layoutSubtreeIfNeeded()
            let p = center(row)
            picker.mouseMoved(with: event(.mouseMoved, at: p))
            row.mouseUp(with: event(.leftMouseUp, at: p))
            if relayout { lay() }
        }

        @MainActor var legacyRow: ModelRowView? { picker.rowViews.first { if case .legacy = $0.row { true } else { false } } }
        @MainActor var legacyExpanded: Bool? {
            for v in picker.rowViews { if case .legacy(_, _, let expanded) = v.row { return expanded } }
            return nil
        }

        /// Every invariant the picker keeps: the highlight names a row that exists, and each row view sits at its index.
        @MainActor func expectConsistent(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
            if let h = picker.highlightedRow {
                #expect(picker.rowViews.indices.contains(h) && picker.sections.rows.indices.contains(h), comment, sourceLocation: sourceLocation)
            }
            #expect(picker.rowViews.count == picker.sections.rows.count, comment, sourceLocation: sourceLocation)
            #expect(picker.rowViews.enumerated().allSatisfy { $0.offset == $0.element.index }, comment, sourceLocation: sourceLocation)
        }
    }

    // MARK: The reported sequence

    /// Redesign, stacked, the account card off: click Show more, then Show less, with the pointer on the row.
    @Test func showMoreThenShowLessByPointer() throws {
        try Self.withTheme(.redesign) {
            let rig = Rig()
            #expect(rig.dock.stacked)
            #expect(rig.picker.rowViews.count == 5)
            rig.click(try #require(rig.legacyRow))
            #expect(rig.legacyExpanded == true && rig.picker.rowViews.count == 8)
            rig.expectConsistent()
            rig.click(try #require(rig.legacyRow))
            #expect(rig.legacyExpanded == false && rig.picker.rowViews.count == 5)
            rig.expectConsistent()
        }
    }

    /// Every layout and theme the picker has, with the card on and off.
    @Test(arguments: [(Theme.redesign, true, false), (.redesign, true, true), (.redesign, false, false), (.redesign, false, true),
                      (.standard, true, false), (.glass, true, false)])
    func showMoreThenShowLessInEveryLayout(_ theme: Theme, _ stacked: Bool, _ account: Bool) throws {
        try Self.withTheme(theme, stacked: stacked, account: account) {
            let rig = Rig()
            for _ in 0..<2 {
                rig.click(try #require(rig.legacyRow))
                rig.expectConsistent()
                rig.click(try #require(rig.legacyRow))
                #expect(rig.legacyExpanded == false)
                rig.expectConsistent()
            }
        }
    }

    /// Expand and collapse twice before the host resizes in between.
    @Test(arguments: Theme.allCases)
    func twiceQuickly(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig()
            for _ in 0..<4 {
                rig.click(try #require(rig.legacyRow), relayout: false)
                rig.expectConsistent()
            }
            rig.lay()
            #expect(rig.legacyExpanded == false)
            rig.expectConsistent()
        }
    }

    /// Return on Show less collapses the group, and the highlight stays on that row, as T3's keyed highlight
    /// (ModelPickerContent.tsx:990, 1096-1105).
    @Test(arguments: Theme.allCases)
    func collapseWithTheKeyboard(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(), picker = rig.picker
            _ = picker.handleKey(.up)
            #expect(picker.highlightedRow == 4)
            _ = picker.handleKey(.enter)
            #expect(rig.legacyExpanded == true)
            #expect(picker.highlightedRow == 7, "the highlight follows Show more to its new place")
            rig.lay()
            _ = picker.handleKey(.enter)
            #expect(rig.legacyExpanded == false)
            #expect(picker.highlightedRow == 4)
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// The selected model is a legacy one, so the group opens expanded; Show less hides it.
    @Test(arguments: Theme.allCases)
    func collapseWithALegacyModelSelected(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(activeModel: "l3")
            #expect(rig.legacyExpanded == true)
            rig.click(try #require(rig.legacyRow))
            #expect(rig.legacyExpanded == false)
            rig.expectConsistent()
        }
    }

    /// The pointer rests on the last legacy model while VoiceOver presses Show less.
    @Test(arguments: Theme.allCases)
    func collapseWhileALegacyRowIsHovered(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig()
            rig.click(try #require(rig.legacyRow))
            rig.hover(rig.picker.rowViews[6])
            #expect(rig.picker.highlightedRow == 6)
            _ = try #require(rig.legacyRow).accessibilityPerformPress()
            #expect(rig.legacyExpanded == false)
            #expect(rig.picker.highlightedRow == nil, "the hovered legacy model is gone, so nothing is highlighted")
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// Searching lists the legacy models flat; clearing the search brings the group back.
    @Test(arguments: Theme.allCases)
    func searchAroundACollapse(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(), picker = rig.picker
            rig.click(try #require(rig.legacyRow))
            rig.hover(picker.rowViews[7])
            picker.setQuery("Legacy 2")
            rig.lay()
            rig.expectConsistent()
            picker.setQuery("")
            rig.lay()
            rig.expectConsistent()
            rig.click(try #require(rig.legacyRow))
            #expect(rig.legacyExpanded == false)
            rig.expectConsistent()
        }
    }

    // MARK: Sibling paths where the list shrinks

    /// A keyboard highlight on the last backend's last model while the first backend collapses (VoiceOver press).
    @Test(arguments: Theme.allCases)
    func backendHeadingCollapses(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(catalog: Self.catalog(subProviders: true), activeModel: "a1")
            let picker = rig.picker
            func heading(_ name: String) -> ModelRowView? {
                picker.rowViews.first { if case .subProvider(_, name, _, _, _) = $0.row { true } else { false } }
            }
            // Alpha opens with the active model; open Beta too, then highlight its last model from the keyboard.
            rig.click(try #require(heading("Beta")))
            #expect(picker.rowViews.count == 8)
            _ = picker.handleKey(.up)
            picker.highlightedRow = 7
            _ = try #require(heading("Alpha")).accessibilityPerformPress()
            #expect(picker.rowViews.count == 5)
            #expect(picker.highlightedRow == 4, "the highlight stays on Beta 3")
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// A catalog refresh that drops models (the project-model scan, 4928's refresh) under a highlight past the new end.
    @Test(arguments: Theme.allCases)
    func catalogRefreshShrinksTheList(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(), picker = rig.picker
            rig.click(try #require(rig.legacyRow))
            rig.hover(picker.rowViews[7])
            picker.catalog = Self.catalog(legacy: 1)
            #expect(picker.highlightedRow == 5, "the highlight stays on Show less")
            rig.lay()
            rig.expectConsistent()
            picker.catalog = Self.catalog(legacy: 0, current: 2)
            #expect(picker.highlightedRow == nil)
            rig.lay()
            rig.expectConsistent()
            picker.workspaceModelsScanning = true
            picker.catalog = Self.catalog(legacy: 3)
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// A model the keyboard highlights keeps it when a favorite moves it to the top.
    @Test(arguments: Theme.allCases)
    func favoritingMovesTheHighlightWithTheRow(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(), picker = rig.picker
            picker.highlightedRow = 3
            picker.favorites = [ModelFavorite(provider: "claudeAgent", model: "m4")]
            #expect(picker.highlightedRow == 0)
            picker.favorites = []
            #expect(picker.highlightedRow == 3)
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// A tab switch to a one-model tab while Show less is highlighted.
    @Test(arguments: Theme.allCases)
    func tabSwitchShrinksTheList(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(), picker = rig.picker
            rig.click(try #require(rig.legacyRow))
            picker.selectRail(.instance("codex"))
            rig.lay()
            rig.expectConsistent()
            _ = picker.handleKey(.down)
            _ = picker.handleKey(.down)
            rig.expectConsistent()
            picker.selectRail(.instance("claudeAgent"))
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// Keyboard focus on the Codex tab while a refresh drops Codex: Return must not reach past the tabs.
    @Test(arguments: Theme.allCases)
    func catalogRefreshDropsTheFocusedTab(_ theme: Theme) throws {
        try Self.withTheme(theme) {
            let rig = Rig(), picker = rig.picker
            _ = picker.handleKey(.left)
            if rig.dock.stacked { _ = picker.handleKey(.right) } else { _ = picker.handleKey(.down) }
            #expect(picker.railFocus == 2)
            picker.catalog = Self.catalog(codex: false)
            #expect(picker.railFocus == nil || picker.railFocus! < 2)
            _ = picker.handleKey(.enter)
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// An index from anywhere past the end clears the highlight instead of trapping.
    @Test func outOfRangeHighlightClears() {
        let rig = Rig()
        rig.picker.highlightedRow = 99
        #expect(rig.picker.highlightedRow == nil)
        rig.picker.highlightedRow = -1
        #expect(rig.picker.highlightedRow == nil)
    }

    // MARK: Stress

    /// A few thousand random sequences of expand, collapse, tab switch, search, catalog refresh, hover and keys, in both
    /// layouts and every theme. The picker never traps and its highlight always names a row that exists.
    @Test(arguments: [(Theme.redesign, true), (.redesign, false), (.standard, true), (.glass, true)])
    func randomSequences(_ theme: Theme, _ stacked: Bool) throws {
        try Self.withTheme(theme, stacked: stacked, account: stacked && theme == .redesign) {
            var rng = PickerShrinkRandom(seed: 0x51C4_2026 &+ UInt64(stacked ? 1 : 0) &+ UInt64(Theme.allCases.firstIndex(of: theme)!) << 8)
            let catalogs = [Self.catalog(), Self.catalog(legacy: 1), Self.catalog(legacy: 0, current: 2), Self.catalog(legacy: 5, current: 9),
                            Self.catalog(subProviders: true), Self.catalog(codex: false)]
            let queries = ["", "", "Legacy", "Model 1", "zzz", "Claude", "GPT", " "]
            let keys: [PopupKey] = [.up, .down, .enter, .left, .right]
            for sequence in 0..<750 {
                let rig = Rig(catalog: catalogs[Int(rng.next() % UInt64(catalogs.count))])
                let picker = rig.picker
                for step in 0..<12 {
                    switch rng.next() % 9 {
                    case 0, 1:
                        if let row = rig.legacyRow ?? picker.rowViews.first(where: { if case .subProvider = $0.row { true } else { false } }) {
                            rig.click(row, relayout: rng.next() % 2 == 0)
                        }
                    case 2: picker.selectRail(rng.next() % 3 == 0 ? .favorites : rng.next() % 2 == 0 ? .instance("codex") : .instance("claudeAgent"))
                    case 3: picker.setQuery(queries[Int(rng.next() % UInt64(queries.count))])
                    case 4: picker.catalog = catalogs[Int(rng.next() % UInt64(catalogs.count))]
                    case 5:
                        if !picker.rowViews.isEmpty { rig.hover(picker.rowViews[Int(rng.next() % UInt64(picker.rowViews.count))]) }
                    case 6: _ = picker.handleKey(keys[Int(rng.next() % UInt64(keys.count))])
                    case 7:
                        let slug = ["m1", "m2", "l1", "gpt"][Int(rng.next() % 4)]
                        picker.favorites = rng.next() % 2 == 0 ? [ModelFavorite(provider: slug == "gpt" ? "codex" : "claudeAgent", model: slug)] : []
                    default:
                        if let row = picker.rowViews.randomElement(using: &rng) { _ = row.accessibilityPerformPress() }
                    }
                    if rng.next() % 3 == 0 { rig.lay() }
                    rig.expectConsistent("sequence \(sequence) step \(step)")
                }
                rig.lay()
                rig.expectConsistent("sequence \(sequence) end")
            }
        }
    }
}

/// A seeded generator, so a failing sequence repeats.
struct PickerShrinkRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
