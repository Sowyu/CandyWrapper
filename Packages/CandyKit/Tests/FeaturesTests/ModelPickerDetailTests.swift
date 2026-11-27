import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign's detail layout (the user's layout 2, 2026-11-21): the cost line, the models.dev snapshot, the sizes, the
/// keyboard and the list shrinking under it.
@MainActor @Suite(.serialized) struct ModelPickerDetailTests {
    // MARK: Prices

    @Test func pricesComeFromTheAppsTableThenModelsDev() {
        let table = ModelDetailContent.prices(driver: "claudeAgent", slug: "claude-sonnet-5-5")
        #expect(table.map { "\($0.label) \($0.value)" } == ["Input $2", "Cached input $0.10", "Output $10"])
        // gemini-4-carbon is not in the app's table; models.dev's row for Google prices it.
        let fallback = ModelDetailContent.prices(driver: "antigravity", slug: "gemini-4-carbon")
        #expect(fallback.map(\.label) == ["Input", "Cached input", "Output"] && fallback.first?.value == "$2")
        #expect(ModelDetailContent.prices(driver: "custom", slug: "house-model").isEmpty)
        #expect(ModelDetailContent.dollars(0.075) == "$0.075" && ModelDetailContent.dollars(1.25) == "$1.25" && ModelDetailContent.dollars(40) == "$40")
    }

    /// The plain-terms cost: 1,000 words each way is 1,333 tokens each way, at the row's input plus output price.
    @Test func plainCostIsWorkedFromThePrices() {
        // Sonnet 5.5, $2 in and $10 out: 1,333.3 x $12 / 1M = $0.016, so 2¢.
        #expect(ModelDetailContent.example(input: 2, output: 10) == "about 2¢")
        // Haiku-sized prices round below a cent.
        #expect(ModelDetailContent.example(input: 0.1, output: 0.5) == "under 1¢")
        // $150 and $600: 1,333.3 x $750 / 1M = $1.00.
        #expect(ModelDetailContent.example(input: 150, output: 600) == "about $1")
        #expect(ModelDetailContent.example(input: 300, output: 600) == "about $1.20")
        let sonnet = ModelDetailContent.perMillion(driver: "claudeAgent", slug: "claude-sonnet-5-5")
        #expect(sonnet?.input == 2 && sonnet?.output == 10)
        #expect(ModelDetailContent.perMillion(driver: "custom", slug: "house-model") == nil)
    }

    // MARK: Snapshot

    @Test func theBundledSnapshotLoadsAndCreditsModelsDev() throws {
        let source = try #require(ModelNotes.source)
        #expect(source.name == "models.dev" && source.licence == "MIT" && !source.fetched.isEmpty)
        let sonnet = try #require(ModelNotes.note(driver: "claudeAgent", slug: "claude-sonnet-5-5"))
        #expect(sonnet.context == 1_000_000 && sonnet.description?.isEmpty == false && sonnet.input?.contains("image") == true)
        #expect((sonnet.description?.count ?? 0) <= 121)
        #expect(ModelNotes.note(driver: "claudeAgent", slug: "claude-sonnet-5-5[1m]") == sonnet)
    }

    @Test func lookupMatchesOnlyWhatIsSurelyTheModel() {
        let note = ModelNote(name: "N", description: "D")
        let models = ["anthropic/claude-x": note, "google/gemini-9-flash": note, "opencode/big-pickle": note, "openai/gpt-9": note]
        #expect(ModelNotes.lookup(driver: "claudeAgent", slug: "claude-x-20251001", in: models) == note)
        #expect(ModelNotes.lookup(driver: "antigravity", slug: "gemini-9-flash-high", in: models) == note)
        #expect(ModelNotes.lookup(driver: "opencode", slug: "opencode/big-pickle", in: models) == note)
        #expect(ModelNotes.lookup(driver: "cursor", slug: "gpt-9", in: models) == note, "one lab has it")
        #expect(ModelNotes.lookup(driver: "antigravity", slug: "gemini-pro-agent", in: models) == nil)
        #expect(ModelNotes.lookup(driver: "claudeAgent", slug: "claude-x-high", in: models) == nil, "effort variants only for Gemini")
    }

    @Test func onlyFactsThatHelpChooseShow() {
        let note = ModelNote(name: "N", context: 1_050_000, knowledge: "2026-06", input: ["text", "image", "pdf", "video"])
        #expect(ModelNotes.facts(note).map { "\($0.0)=\($0.1)" } == ["Context=1.05M", "Knowledge=Jun 2026"])
        #expect(ModelNotes.facts(ModelNote(name: "N")).isEmpty)
        #expect(["text", "image", "pdf", "audio", "video"].allSatisfy { ModelDetailPaneView.input($0) != nil })
        #expect(ModelDetailPaneView.input("pdf")?.1 == "PDF files" && ModelDetailPaneView.input("smell") == nil)
    }

    @Test func aModelModelsDevLacksShowsNameAndNoPrice() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let house = ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude",
                                       models: [ServerProviderModel(slug: "house-model", name: "House")])
            let rig = ModelPickerShrinkTests.Rig(catalog: ProviderCatalog([house]), activeModel: "house-model")
            let content = try #require(rig.dock.pane.content)
            #expect(content.name == "House" && content.description == nil && content.facts.isEmpty && content.inputs.isEmpty && content.prices.isEmpty)
            // Padding, name and provider, the price label, one "No price known" row, padding.
            let expected: CGFloat = 16 + 36 + 16 + 16 + 8 - 2 + 24 - 2 + 16
            #expect(rig.dock.pane.height(for: content, card: nil) == expected)
        }
    }

    // MARK: Layout

    static func catalog(_ count: Int) -> ProviderCatalog {
        let models = (1...count).map { ServerProviderModel(slug: "m\($0)", name: "Claude Model #\($0)") }
        return ProviderCatalog([ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", models: models),
                                ServerProvider(instanceId: "codex", driver: "codex", displayName: "Codex", models: [ServerProviderModel(slug: "gpt-6-astra", name: "GPT-6 Astra")])])
    }

    @Test(arguments: [1, 4, 14, 30])
    func heightStaysBetweenTheFloorAndTheCeiling(_ count: Int) throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(catalog: Self.catalog(count))
            #expect(rig.dock.detailed && !rig.dock.stacked)
            let top = rig.dock.detailTopHeight
            #expect(top >= DockedModelPickerView.detailMinHeight && top <= DockedModelPickerView.detailMaxHeight)
            #expect(rig.dock.naturalSize.width == ModelPickerView.detailListWidth + ModelDetailPaneView.width + 12)
            // The bottom row is one 28pt line 6pt under the cards and 6pt over the popup's edge.
            #expect(rig.dock.column.frame.height == CGFloat(28 + 6), "\(rig.dock.column.frame) lines \(rig.dock.column.levelLines.map(\.frame))")
            #expect(rig.dock.column.frame.minY == rig.dock.pane.frame.maxY + 6)
            #expect(rig.dock.pane.frame.minX == ModelPickerView.detailListWidth + 6)
            if count == 1 { #expect(top == DockedModelPickerView.detailMinHeight) }
            if count == 30 { #expect(top == DockedModelPickerView.detailMaxHeight) }
            // Under the ceiling, no Claude model row hides below the list.
            if count == 4 { #expect(rig.picker.rowViews.allSatisfy { $0.frame.maxY <= rig.picker.frame.height }) }
        }
    }

    @Test func noEffortLevelsLeaveNoHole() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig()
            let with = rig.dock.naturalSize.height
            rig.dock.column.update(descriptors: [], ultrathink: false, locked: false, model: "Haiku")
            rig.lay()
            // Fast and Ultracode keep the line, at the right.
            #expect(rig.dock.column.frame.height == 34 && rig.dock.naturalSize.height == with)
            #expect(rig.dock.footer.frame.maxX == rig.dock.bounds.width - 6)
            rig.dock.footer.update(descriptors: [], runtimeMode: .fullAccess)
            rig.lay()
            #expect(rig.dock.column.frame.height == 0)
            #expect(rig.dock.naturalSize.height == with - 34)
        }
    }

    /// Option A1: the levels at the left sized to their labels, Fast and Ultracode at the right, no Permissions, nothing
    /// clipped or overlapping with five levels including "Extra high", at the default width and with the details card widest.
    @Test func theBottomRowIsOneLineThatFits() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(), dock = rig.dock
            #expect(dock.footer.permissions == nil && dock.footer.items.count == 3)
            for paneWidth in [dock.paneLimits.lowerBound, ModelDetailPaneView.width, dock.paneLimits.upperBound] {
                dock.paneHandle.onResize?(paneWidth)
                rig.lay()
                let track = try #require(dock.column.levelLines.first)
                #expect(dock.column.levelLines.count == 1 && dock.column.segments.count == 5)
                #expect(track.frame.minX == 6 && track.frame.width == track.naturalWidth)
                #expect(track.segments.last.map { $0.frame.maxX <= track.bounds.width } == true)
                #expect(track.segments.allSatisfy { $0.frame.width >= $0.naturalWidth })
                let trackRight = dock.column.convert(track.frame, to: dock).maxX
                #expect(trackRight + 6 <= dock.footer.frame.minX, "the track \(trackRight) runs into the footer \(dock.footer.frame)")
                #expect(dock.footer.frame.maxX == dock.bounds.width - 6)
                #expect(dock.footer.frame.minY == dock.column.frame.minY + dock.column.convert(track.frame, to: dock.column).minY)
                #expect(dock.pane.frame.maxX == dock.bounds.width - 6 && dock.pane.frame.width == paneWidth)
            }
            dock.paneHandle.onReset?()
        }
    }

    static let context = ProviderOptionDescriptor(id: "contextWindow", label: "Context", type: .select,
                                                  options: [ProviderOptionChoice(id: "200k", label: "200K"), ProviderOptionChoice(id: "1m", label: "1M")],
                                                  currentValue: .string("1m"))

    /// Every option is a chip on the one row (the user, 2026-11-22): a select reads "Context 1M" and opens a menu, a
    /// two-state option toggles, and none falls to a full-width row. Five levels, speed, Ultracode and Context fit the
    /// default popup at every details card width; more chips drop their names, then fold into one "Options" chip.
    @Test func everyOptionIsAChipOnTheOneRow() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(), dock = rig.dock
            let height = dock.naturalSize.height
            let all = [RedesignPickerLayoutTests.levels, Self.context] + RedesignPickerLayoutTests.footerOptions
            dock.column.update(descriptors: all, ultrathink: false, locked: false, model: "Opus 5.5")
            dock.footer.update(descriptors: all, runtimeMode: .fullAccess)
            rig.lay()
            #expect(dock.column.rows.allSatisfy { if case .level = $0.kind { true } else { false } }, "no full-width option row")
            #expect(dock.naturalSize.height == height, "Context on the line keeps the popup's height")
            #expect(dock.naturalSize.width == DockedModelPickerView.detailWidth)
            #expect(dock.footer.chips.count == 1 && dock.footer.items.count == 4)
            var opened: String?
            dock.footer.onOpenOption = { d, _ in opened = d.id }
            dock.footer.chips.first?.segments.first?.action?()
            #expect(opened == "contextWindow")
            for paneWidth in [dock.paneLimits.lowerBound, dock.paneLimits.upperBound] {
                dock.paneHandle.onResize?(paneWidth)
                rig.lay()
                let track = try #require(dock.column.levelLines.first)
                #expect(dock.column.segments.count == 5 && track.frame.width == track.naturalWidth)
                #expect(track.segments.allSatisfy { $0.frame.width >= $0.naturalWidth }, "the levels never shrink")
                #expect(dock.column.convert(track.frame, to: dock).maxX + 6 <= dock.footer.frame.minX)
                #expect(dock.footer.frame.maxX == dock.bounds.width - 6 && dock.footer.frame.width == dock.footer.inlineWidth)
                let parts = dock.footer.subviews.filter { $0 is ComposerFooterGroupView }.sorted { $0.frame.minX < $1.frame.minX }
                #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX }, "chips overlap")
                #expect(parts.allSatisfy { $0.frame.maxX <= dock.footer.bounds.width })
            }
            dock.paneHandle.onReset?()

            // The collapse steps, in order.
            let footer = dock.footer
            #expect(footer.bestFit(within: .infinity) == .full && footer.bestFit(within: 0) == .collapsed)
            footer.fit = .full; let full = footer.inlineWidth
            footer.fit = .compact; let compact = footer.inlineWidth
            #expect(compact < full && footer.bestFit(within: compact) == .compact)
            #expect(footer.chips.first?.segments.first?.title == "1M")
            footer.fit = .collapsed
            #expect(footer.speed == nil && footer.ultracode == nil && footer.chips.count == 1 && footer.chips[0].segments[0].title == "Options")
            var menu: [String]?
            footer.onOpenOptions = { ds, _ in menu = ds.map(\.id) }
            footer.items.first?.action?()
            #expect(menu == ["fastMode", "ultracode", "contextWindow"])
            #expect(footer.bestFit(within: compact - 1) == .collapsed)

            // Enough chips that the full row cannot fit: they drop their names first, the levels keep theirs.
            let extra = (1...3).map { i in
                ProviderOptionDescriptor(id: "opt\(i)", label: "Option \(i)", type: .select,
                                         options: [ProviderOptionChoice(id: "a", label: "A")], currentValue: .string("a"))
            }
            dock.column.update(descriptors: all + extra, ultrathink: false, locked: false, model: "Opus 5.5")
            footer.update(descriptors: all + extra, runtimeMode: .fullAccess)
            rig.lay()
            #expect(footer.fit != .full && dock.naturalSize.width == DockedModelPickerView.detailWidth)
            let track = try #require(dock.column.levelLines.first)
            #expect(dock.column.convert(track.frame, to: dock).maxX + 6 <= footer.frame.minX)
            #expect(dock.column.rows.count == 5)

            // No levels: the chips alone at the right. No options: no row.
            dock.column.update(descriptors: [Self.context], ultrathink: false, locked: false, model: "Haiku")
            footer.update(descriptors: [Self.context], runtimeMode: .fullAccess)
            rig.lay()
            #expect(footer.fit == .full && footer.items.count == 1 && footer.frame.maxX == dock.bounds.width - 6)
            #expect(dock.column.frame.height == 34)
            dock.column.update(descriptors: [], ultrathink: false, locked: false, model: "Haiku")
            footer.update(descriptors: [], runtimeMode: .fullAccess)
            rig.lay()
            #expect(dock.column.frame.height == 0 && dock.naturalSize.height == height - 34)
        }
    }

    /// The default themes keep T3's column: a select is an option row with a side menu, and the footer adds no chip.
    @Test func defaultThemesKeepTheOptionRow() throws {
        try ModelPickerShrinkTests.withTheme(.standard, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(), dock = rig.dock
            let all = [RedesignPickerLayoutTests.levels, Self.context] + RedesignPickerLayoutTests.footerOptions
            dock.column.update(descriptors: all, ultrathink: false, locked: false, model: "Opus 5.5")
            dock.footer.update(descriptors: all, runtimeMode: .fullAccess)
            rig.lay()
            #expect(dock.column.rows.contains { $0.kind == .menu(label: "Context", value: "1M") })
            #expect(dock.footer.chips.isEmpty)
        }
    }

    /// Dragging the details card's left edge: the drag math clamps, commits once, and double-click restores the default.
    @Test func theDetailsCardResizes() throws {
        #expect(ModelDetailPaneResizeHandle.width(from: 276, startX: 500, to: 450, in: 240...332) == 326)
        #expect(ModelDetailPaneResizeHandle.width(from: 276, startX: 500, to: 300, in: 240...332) == 332)
        #expect(ModelDetailPaneResizeHandle.width(from: 276, startX: 500, to: 600, in: 240...332) == 240)
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(), dock = rig.dock
            let width = dock.bounds.width, height = dock.bounds.height
            #expect(dock.paneWidth == ModelDetailPaneView.width)
            #expect(dock.paneLimits.lowerBound == ModelDetailPaneView.minWidth)
            #expect(width - dock.paneLimits.upperBound - 18 - dock.picker.detailListLeft == DockedModelPickerView.minListWidth)
            // The 5pt strip sits in the gap between the cards.
            #expect(dock.paneHandle.frame.width == 5 && dock.paneHandle.frame.minX > dock.picker.frame.maxX && dock.paneHandle.frame.maxX < dock.pane.frame.minX)
            dock.paneHandle.onResize?(300)
            rig.lay()
            #expect(dock.pane.frame.width == 300 && dock.pane.frame.minX == width - 6 - 300)
            #expect(dock.picker.frame.maxX == dock.pane.frame.minX - 6)
            #expect(dock.bounds.width == width && dock.bounds.height == height, "the popup keeps its size while the cards trade width")
            #expect(RedesignPickerSettings.paneWidth == nil, "nothing saves mid-drag")
            dock.paneHandle.onCommit?()
            #expect(RedesignPickerSettings.paneWidth == 300)
            // A new popup opens at the saved width.
            let again = ModelPickerShrinkTests.Rig()
            #expect(again.dock.pane.frame.width == 300)
            dock.paneHandle.onReset?()
            #expect(RedesignPickerSettings.paneWidth == nil && dock.paneWidth == ModelDetailPaneView.width)
        }
    }

    @Test func theStackedPickerShowsSixRowsThenScrolls() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: true) {
            let six = ModelPickerShrinkTests.Rig(catalog: Self.catalog(6)).picker.naturalSize.height
            let thirty = ModelPickerShrinkTests.Rig(catalog: Self.catalog(30)).picker.naturalSize.height
            #expect(six == thirty)
        }
    }

    // MARK: Keyboard and pointer

    @Test func thePaneFollowsTheHighlightAndKeepsItOffTheRows() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(), dock = rig.dock
            #expect(dock.pane.content?.key == "claudeAgent:m1", "the selected model before anything is highlighted")
            dock.focus(.list)
            _ = dock.handleKey(.down)
            #expect(dock.pane.content?.key == "claudeAgent:m2")
            rig.hover(rig.picker.rowViews[2])
            #expect(dock.pane.content?.key == "claudeAgent:m3")
            rig.picker.pointerLeft()
            #expect(dock.pane.content?.key == "claudeAgent:m3", "the pointer crossing to the pane keeps it")
        }
    }

    @Test func rightPicksAndMovesToReasoningAndTabWalksSections() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(), dock = rig.dock
            var picked: String?
            rig.picker.onSelect = { _, slug in picked = slug }
            dock.focus(.list)
            _ = dock.handleKey(.down)
            _ = dock.handleKey(.right)
            #expect(picked == "m2")
            // The owner moves focus to the levels after a pick; with the selected model highlighted Right goes there itself.
            rig.picker.activeModel = "m2"
            dock.focus(.list)
            _ = dock.handleKey(.right)
            #expect(dock.section == .reasoning)
            dock.tab(backward: false)
            #expect(dock.section == .footer)
            dock.tab(backward: false)
            #expect(dock.section == .search)
            dock.tab(backward: false)
            #expect(dock.section == .list)
            _ = dock.handleKey(.left)
            #expect(dock.section == .tabs, "Left from the list goes to the rail")
        }
    }

    // MARK: The list shrinking (picker-crash, 1.15.1)

    @Test func showMoreAndShowLessTenTimes() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig()
            for _ in 0..<10 {
                rig.click(try #require(rig.legacyRow))
                rig.expectConsistent()
                rig.click(try #require(rig.legacyRow))
                rig.expectConsistent()
                #expect(rig.legacyExpanded == false)
                #expect(rig.dock.pane.content != nil)
            }
        }
    }

    @Test func aCatalogRefreshWhileOpenDropsAHighlightedModel() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(catalog: Self.catalog(8))
            rig.hover(rig.picker.rowViews[7])
            #expect(rig.dock.pane.content?.key == "claudeAgent:m8")
            rig.picker.catalog = Self.catalog(3)
            rig.lay()
            rig.expectConsistent()
            #expect(rig.dock.pane.content?.key == "claudeAgent:m1", "the shown model went away, so the selected one shows")
        }
    }

    @Test func aProviderSwitchWhileHovering() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(catalog: Self.catalog(8))
            rig.hover(rig.picker.rowViews[6])
            rig.picker.selectRail(.instance("codex"))
            rig.lay()
            rig.expectConsistent()
            #expect(rig.dock.pane.content?.key == "codex:gpt-6-astra")
            rig.hover(rig.picker.rowViews[0])
            rig.picker.selectRail(.instance("claudeAgent"))
            rig.lay()
            rig.expectConsistent()
        }
    }

    /// Switching tabs keeps the popup's size, so the rail under the pointer never moves (1.17.0 walk, 01f and 01g):
    /// a one-model tab and Favorites take the height the first tab set and scroll in it.
    @Test func switchingTabsKeepsThePopupsSize() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(catalog: Self.catalog(14))
            let size = rig.dock.naturalSize
            for rail in [ModelPickerRail.instance("codex"), .favorites, .instance("claudeAgent")] {
                rig.picker.selectRail(rail)
                rig.lay()
                #expect(rig.dock.naturalSize == size, "\(rail)")
            }
        }
    }

    /// A tab whose list is longer than the one the popup opened on grows the popup to fit it, up to the ceiling, so no
    /// row is clipped; going back to the shorter tab keeps that height, so the rail never moves twice.
    @Test func theHeightFollowsALongerList() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let codex = (1...9).map { ServerProviderModel(slug: "gpt-\($0)", name: "GPT Model #\($0)") }
            let catalog = ProviderCatalog([ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", models: [ServerProviderModel(slug: "m1", name: "Claude Model #1")]),
                                           ServerProvider(instanceId: "codex", driver: "codex", displayName: "Codex", models: codex)])
            let rig = ModelPickerShrinkTests.Rig(catalog: catalog)
            let opened = rig.dock.detailTopHeight
            rig.picker.selectRail(.instance("codex"))
            rig.lay()
            let list = rig.picker.naturalSize.height
            #expect(list > opened, "the fixture's second tab must need more room than the first")
            // At least the list; the details card can ask for more.
            let grown = rig.dock.detailTopHeight
            #expect(grown >= min(DockedModelPickerView.detailMaxHeight, list) && grown > opened)
            #expect(rig.picker.rowViews.allSatisfy { $0.frame.maxY <= ($0.superview?.bounds.height ?? 0) })
            rig.picker.selectRail(.instance("claudeAgent"))
            rig.lay()
            #expect(rig.dock.detailTopHeight == grown)
        }
    }

    /// The details card describes the selected model when nothing is highlighted, the first row when the selected
    /// model is not in the tab, and says so when the tab has no model, instead of going blank (1.17.0 walk, 01f, 01g).
    @Test func theDetailsCardIsNeverBlank() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let rig = ModelPickerShrinkTests.Rig(catalog: Self.catalog(4))
            rig.lay()
            #expect(rig.dock.pane.content?.key == rig.picker.listedItems.first { $0.isSelected }?.key)
            rig.picker.selectRail(.instance("codex"))
            rig.lay()
            #expect(rig.dock.pane.content?.key == "codex:gpt-6-astra")
            rig.picker.selectRail(.favorites)
            rig.lay()
            #expect(rig.picker.listedItems.isEmpty && rig.dock.pane.content == nil)
            let empty = try #require(rig.dock.pane.subviews.compactMap { $0 as? LabelView }.first { $0.text == "No model to show" })
            #expect(!empty.isHidden && empty.frame.minY > 0 && empty.frame.maxY < rig.dock.pane.bounds.height)
        }
    }

    /// Short of room the details card scrolls and keeps the whole description, never one clamped line (C7, round 2).
    @Test func aShortDetailsCardScrollsInsteadOfClamping() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let pane = ModelDetailPaneView(frame: NSRect(x: 0, y: 0, width: ModelDetailPaneView.width, height: 160))
            let long = String(repeating: "Fast model for responsive assistance and lightweight agents. ", count: 3)
            pane.show(ModelDetailContent(key: "k", name: "Model", provider: "Claude", driver: "claudeAgent", slug: "m", description: long,
                                         prices: [.init(label: "Input", value: "$1")], example: nil,
                                         facts: [.init(label: "Context", value: "1M"), .init(label: "Knowledge", value: "Jun 2026")], inputs: []),
                      card: nil)
            pane.layoutSubtreeIfNeeded()
            let about = try #require(pane.subviews.compactMap { $0 as? TextBlockView }.first)
            #expect(about.maxLines == 0 && about.frame.height > 40)
            #expect(pane.maxScroll > 0)
        }
    }

    // MARK: Small fixes, 2026-11-21

    /// A clamped description whose second line fits on its own still ends in an ellipsis.
    @Test func clampedDescriptionEndsInAnEllipsis() {
        let text = NSAttributedString(string: "Fast Claude model for responsive assistance, classification, and lightweight agents",
                                      attributes: [.font: DSFont.ui(13)])
        for width: CGFloat in stride(from: 220, through: 300, by: 4) {
            guard TextBlockLayout(text, width: width, lineHeight: 20).lines.count > 2 else { continue }
            let layout = TextBlockLayout(text, width: width, lineHeight: 20, maxLines: 2)
            guard let last = layout.lines.last, layout.lines.count == 2 else { continue }
            #expect(layout.widths.last! <= width + 0.5, "\(width)")
            #expect(Self.endsInEllipsis(last.line), "\(width)")
        }
    }

    static func endsInEllipsis(_ line: CTLine) -> Bool {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard let run = runs.last else { return false }
        let count = CTRunGetGlyphCount(run)
        var glyph = CGGlyph(0)
        CTRunGetGlyphs(run, CFRange(location: count - 1, length: 1), &glyph)
        let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        var chars: [UniChar] = Array("\u{2026}".utf16)
        var ellipsis = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font, &chars, &ellipsis, 1)
        return glyph == ellipsis
    }

    @Test func redesignEffortLabelsAreSentenceCase() {
        #expect(ComposerEffortColumnView.sentenceCase("Extra High") == "Extra high")
        #expect(ComposerEffortColumnView.sentenceCase("Max") == "Max")
        #expect(ComposerEffortColumnView.sentenceCase("GPT Mode") == "GPT mode")
        #expect(ComposerEffortColumnView.sentenceCase("Use XHIGH") == "Use XHIGH")
    }

    /// The NEW badge gives way before the name or the jump key lose room.
    @Test func newBadgeYieldsFirst() {
        let badge = NewBadgeView()
        let w = 8 + badge.intrinsicContentSize.width
        #expect(ModelRowView.newBadgeWidth(badge, name: 100, room: 100 + w) == w)
        #expect(!badge.isHidden)
        #expect(ModelRowView.newBadgeWidth(badge, name: 100, room: 100 + w - 1) == 0)
        #expect(badge.isHidden)
        #expect(ModelRowView.newBadgeWidth(nil, name: 100, room: 0) == 0)
    }
}
