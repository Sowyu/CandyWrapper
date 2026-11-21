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
        let models = (1...count).map { ServerProviderModel(slug: "m\($0)", name: "Claude Model \($0)") }
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
            #expect(rig.dock.naturalSize.width == ModelPickerView.detailListWidth + ModelDetailPaneView.width)
            // The Reasoning row is one 28pt track with its heading on the same line.
            #expect(rig.dock.column.frame.height == CGFloat(8 + 28 + 8), "\(rig.dock.column.frame) lines \(rig.dock.column.levelLines.map(\.frame))")
            #expect(rig.dock.pane.frame.minX == ModelPickerView.detailListWidth)
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
            #expect(rig.dock.column.frame.height == 0)
            #expect(rig.dock.naturalSize.height == with - 44)
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
