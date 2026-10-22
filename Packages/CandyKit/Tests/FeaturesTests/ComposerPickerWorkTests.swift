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

/// Redesign's model picker card shows only what the provider reported.
@MainActor @Test func ditherProviderCardInfo() {
    var p = ServerProvider(instanceId: "codex", driver: "codex", displayName: "Codex")
    var info = DitherProviderCardInfo(ProviderCatalog([p]).entries[0])
    #expect(info.email == nil && info.plan == nil && info.used == nil && info.statusText == "Connected")
    p.auth = .object(["email": .string("a@example.com"), "label": .string("Pro")])
    p.usageLimits = ProviderUsageLimits(checkedAt: "2026-10-22T00:00:00Z", windows: [
        UsageLimitWindow(id: "s", kind: "session", label: "5h", usedPercent: 12.4),
        UsageLimitWindow(id: "w", kind: "weekly", label: "Weekly", usedPercent: 21.2)])
    p.status = .error
    info = DitherProviderCardInfo(ProviderCatalog([p]).entries[0])
    #expect(info.email == "a@example.com" && info.plan == "Pro")
    #expect(info.used?.percent == 21 && info.used?.label == "Weekly")
    #expect(info.statusText == "Not connected")
}
