import AppKit
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct ComposerPickerWorkTests {
    private func picker() throws -> ModelPickerView {
        let config = try PickersFidelityTests.recordedConfig()
        return ModelPickerView(catalog: ProviderCatalog(config.providers), favorites: [],
                               active: "claudeAgent", activeModel: "claude-haiku-5-5", preferences: .object([:]))
    }

    @Test func unchangedSearchResultsCreateNoRows() throws {
        let view = try picker()
        view.setQuery("haiku")
        let previous = view.rowViews
        #expect(!previous.isEmpty)
        view.setQuery("haik")
        let created = view.rowViews.filter { row in !previous.contains { $0 === row } }.count
        #expect(created == 0)
        #expect(view.rowViews.count == previous.count)
    }

    @Test func reusedRowsFollowTheirNewIndexAndSelection() throws {
        let view = try picker()
        let previous = view.rowViews
        view.setQuery("haiku")
        #expect(!view.rowViews.isEmpty)
        var reused = 0
        for (index, row) in view.rowViews.enumerated() {
            // Searching also exposes legacy models hidden under the collapsed group.
            if let old = previous.first(where: { $0.row == row.row }) {
                #expect(old === row)
                reused += 1
            }
            #expect(row.index == index)
            #expect(row.row == view.sections.rows[index])
        }
        #expect(reused > 0)
        let previousSelected = view.rowViews.filter { $0.isAccessibilitySelected() }
        view.selectedKeys = []
        #expect(view.rowViews.allSatisfy { !$0.isAccessibilitySelected() })
        #expect(previousSelected.allSatisfy { old in !view.rowViews.contains { $0 === old } })
    }

    @Test func changedJumpLabelsRebuildTheirRows() throws {
        let view = try picker()
        view.jumpLabel = { String($0 + 1) }
        let previous = view.rowViews
        view.jumpLabel = { "⌘\($0 + 1)" }
        let models = view.rowViews.filter { if case .model = $0.row { true } else { false } }
        #expect(!models.isEmpty)
        #expect(models.prefix(9).allSatisfy { row in !previous.contains { $0 === row } })
    }
}
