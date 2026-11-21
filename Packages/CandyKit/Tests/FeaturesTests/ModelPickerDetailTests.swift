import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign's detail layout (the user's layout 2, 2026-11-21): the cost line, the models.dev snapshot, the sizes, the
/// keyboard and the list shrinking under it.
@MainActor @Suite(.serialized) struct ModelPickerDetailTests {
    typealias Price = ThreadCostEstimate.Price
    static let sonnet = Price(input: 2, cachedInput: 0.1, output: 10)
    static let fable = Price(input: 8, cachedInput: 0.2, output: 40)
    static let haiku = Price(input: 0.1, cachedInput: 0.01, output: 0.5)

    // MARK: Cost line

    @Test func ownTurnsGiveTheMedianOfTheLatestForty() {
        // 50 turns: the first 10 are dear and fall out of the window, the latest 40 run 0.10 to 0.49.
        let turns = (0..<10).map { _ in 9.0 } + (0..<40).map { 0.10 + Double($0) / 100 }
        let line = ModelCostLine.make(.init(modelName: "Claude Fable 5.2", price: Self.fable, ownTurns: turns,
                                            reference: ("Sonnet 5.5", Self.sonnet), catalogPrices: [Self.sonnet]))
        #expect(line.kind == .ownUsage)
        #expect(line.headline == "About $0.30 a turn for you")
        #expect(line.explanation.contains("median of your last 40 finished turns"))
        #expect(line.detail == "$8 in · $40 out per 1M tokens")
    }

    @Test func tooFewTurnsFallBackToTheReference() {
        let line = ModelCostLine.make(.init(modelName: "Claude Fable 5.2", price: Self.fable, ownTurns: [0.3, 0.4],
                                            reference: ("Sonnet 5.5", Self.sonnet)))
        #expect(line.kind == .relative)
        // Typical turn: Fable 15K*8 + 85K*0.2 + 2K*40 = 0.217, Sonnet 0.0585, so 3.7x, rounded to 4.
        #expect(line.headline == "About 4x the cost of Sonnet 5.5")
        #expect(ModelCostLine.make(.init(modelName: "Haiku", price: Self.haiku, reference: ("Sonnet 5.5", Self.sonnet))).headline
                == "Under a tenth of the cost of Sonnet 5.5")
        #expect(ModelCostLine.relative(0.5, to: "X") == "About half of the cost of X")
        #expect(ModelCostLine.relative(1.05, to: "X") == "About the same cost as X")
        #expect(ModelCostLine.relative(1.5, to: "X") == "About 1.5x the cost of X")
    }

    @Test func withoutAReferenceTheMeterPlacesTheModel() {
        let all = [Self.haiku, Self.sonnet, Self.fable, Price(input: 4, cachedInput: 0.2, output: 20)]
        let dear = ModelCostLine.make(.init(modelName: "Fable", price: Self.fable, catalogPrices: all))
        #expect(dear.kind == .meter && dear.meter == 4 && dear.headline == "Cost")
        #expect(ModelCostLine.make(.init(modelName: "Haiku", price: Self.haiku, catalogPrices: all)).meter == 1)
        #expect(dear.accessibilityText.hasPrefix("Cost 4 of 4"))
    }

    @Test func aPlanComparesModelsAndKeepsDollarsAsTheAPIEquivalent() {
        let turns = Array(repeating: 0.5, count: 12)
        let line = ModelCostLine.make(.init(modelName: "Fable", price: Self.fable, ownTurns: turns, reference: ("Sonnet 5.5", Self.sonnet),
                                            billing: .subscription(plan: "Claude Max Subscription")))
        #expect(line.kind == .relative && line.headline == "About 4x the cost of Sonnet 5.5")
        #expect(line.detail == "About $0.50 a turn at API prices")
        #expect(line.explanation.contains("Claude Max Subscription pays for these turns"))
        let alone = ModelCostLine.make(.init(modelName: "Fable", price: Self.fable, ownTurns: turns, billing: .subscription(plan: nil)))
        #expect(alone.headline == "About $0.50 a turn at API prices")
    }

    @Test func anUnpricedModelSaysSo() {
        let line = ModelCostLine.make(.init(modelName: "Muse Spark", price: nil, ownTurns: [1, 2, 3, 4, 5]))
        #expect(line.kind == .unpriced && line.headline == "No price known" && line.detail == nil && line.meter == nil)
    }

    @Test func billingReadsTheProvidersAuth() {
        var p = ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", models: [])
        #expect(ModelDetailContent.billing(p) == .api)
        p.auth = .object(["status": .string("authenticated"), "type": .string("apiKey"), "label": .string("Claude API Key")])
        #expect(ModelDetailContent.billing(p) == .api)
        p.auth = .object(["status": .string("authenticated"), "type": .string("max"), "label": .string("Claude Max Subscription")])
        #expect(ModelDetailContent.billing(p) == .subscription(plan: "Claude Max Subscription"))
    }

    // MARK: Snapshot

    @Test func theBundledSnapshotLoadsAndCreditsModelsDev() throws {
        let source = try #require(ModelNotes.source)
        #expect(source.name == "models.dev" && source.licence == "MIT" && !source.fetched.isEmpty)
        let sonnet = try #require(ModelNotes.note(driver: "claudeAgent", slug: "claude-sonnet-5-5"))
        #expect(sonnet.context == 1_000_000 && sonnet.tools && sonnet.description?.isEmpty == false)
        #expect((sonnet.description?.count ?? 0) <= 121)
        #expect(ModelNotes.note(driver: "claudeAgent", slug: "claude-sonnet-5-5[1m]") == sonnet)
    }

    @Test func lookupMatchesOnlyWhatIsSurelyTheModel() {
        let note = ModelNote(name: "N", description: "D", tools: true, reasoning: false)
        let models = ["anthropic/claude-x": note, "google/gemini-9-flash": note, "opencode/big-pickle": note, "openai/gpt-9": note]
        #expect(ModelNotes.lookup(driver: "claudeAgent", slug: "claude-x-20251001", in: models) == note)
        #expect(ModelNotes.lookup(driver: "antigravity", slug: "gemini-9-flash-high", in: models) == note)
        #expect(ModelNotes.lookup(driver: "opencode", slug: "opencode/big-pickle", in: models) == note)
        #expect(ModelNotes.lookup(driver: "cursor", slug: "gpt-9", in: models) == note, "one lab has it")
        #expect(ModelNotes.lookup(driver: "antigravity", slug: "gemini-pro-agent", in: models) == nil)
        #expect(ModelNotes.lookup(driver: "claudeAgent", slug: "claude-x-high", in: models) == nil, "effort variants only for Gemini")
    }

    @Test func factsFormatPlainly() {
        let note = ModelNote(name: "N", context: 1_050_000, output: 128_000, knowledge: "2026-06", released: "2026-11-09",
                             input: ["text", "image", "pdf"], tools: true, reasoning: true)
        let facts = ModelNotes.facts(note).map { "\($0.0)=\($0.1)" }
        #expect(facts == ["Context=1.05M", "Max output=128K", "Knowledge=Jun 2026", "Released=Nov 2026", "Reads=text, image, PDF",
                          "Supports=tools, reasoning"])
        #expect(ModelNotes.facts(ModelNote(name: "N", tools: false, reasoning: false)).isEmpty)
    }

    @Test func aModelModelsDevLacksShowsNameAndCostOnly() throws {
        try ModelPickerShrinkTests.withTheme(.redesign, stacked: false) {
            let house = ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude",
                                       models: [ServerProviderModel(slug: "house-model", name: "House")])
            let rig = ModelPickerShrinkTests.Rig(catalog: ProviderCatalog([house]), activeModel: "house-model")
            let content = try #require(rig.dock.pane.content)
            #expect(content.name == "House" && content.description == nil && content.facts.isEmpty && content.cost.kind == .unpriced)
        }
    }

    @Test func theLedgerKeepsEachTurnOnceAndTheLatestForty() {
        let ledger = ModelTurnCosts(defaults: nil)
        let turns = (0..<45).map { ThreadCostEstimate.FinishedTurn(id: "t\($0)", model: "claude-opus-5-5", completedAt: String(format: "2026-11-21T10:%02d:00Z", $0), usd: Double($0)) }
        ledger.record(Array(turns.prefix(10)))
        ledger.record(turns)
        let kept = ledger.turns("claude-opus-5-5[1m]")
        #expect(kept.count == 40 && kept.first == 5 && kept.last == 44)
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
}
