import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct ProviderModelRowPerformanceTests {
    private var models: [ProvidersLogic.DisplayModel] {
        (0..<12).map { .init(slug: "model-\($0)", name: "Model \($0)", isCustom: false, capabilities: []) }
    }

    private func rows(_ view: ProviderModelsView) -> [ProviderModelsView.ModelRow] {
        view.subviews.compactMap { $0 as? ProviderModelsView.ModelRow }
    }

    @Test func favoritesOnlyReplaceTheChangedRow() {
        let view = ProviderModelsView(models: models, favorites: [], hidden: [], driver: "codex", canManage: true)
        let initial = rows(view)
        #expect(view.createdModelRows == 12)
        let reordered = [models[5]] + models.filter { $0.slug != "model-5" }
        view.update(models: reordered, favorites: ["model-5"], hidden: [])
        #expect(view.createdModelRows == 13)
        #expect(rows(view).filter { row in initial.contains { $0 === row } }.count == 11)
        view.update(models: reordered, favorites: ["model-5"], hidden: [])
        #expect(view.createdModelRows == 13)
        view.update(models: models, favorites: [], hidden: [])
        #expect(view.createdModelRows == 14)
    }

    @Test func filteringRetainsRowsAndUpdatesMoveControls() throws {
        let view = ProviderModelsView(models: models, favorites: [], hidden: [], driver: "codex", canManage: true)
        let initial = rows(view)
        let filter = try #require(view.subviews.compactMap { $0 as? InputView }.first { $0.placeholder == "Filter models" })
        for (query, expectedCount) in [("model", 12), ("model 1", 3), ("no matches", 0), ("", 12), ("Model 2", 1), ("", 12)] {
            filter.text = query
            filter.onChange?(query)
            #expect(view.createdModelRows == 12)
            #expect(rows(view).count == expectedCount)
            #expect(rows(view).allSatisfy { row in initial.contains { $0 === row } })
            for row in rows(view) {
                let moves = row.subviews.compactMap { $0 as? ButtonView }.filter { $0.icon == .arrowUp || $0.icon == .arrowDown }
                #expect(moves.count == 2)
                #expect(moves.allSatisfy { $0.isHidden == !query.isEmpty })
            }
        }
    }
}
