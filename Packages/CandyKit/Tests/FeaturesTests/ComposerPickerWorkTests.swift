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

    @Test func switchingProvidersKeepsTheTallestTabHeight() throws {
        let config = try PickersFidelityTests.recordedConfig()
        var claude = try #require(config.providers.first { $0.instanceId == "claudeAgent" })
        var codex = try #require(config.providers.first { $0.instanceId == "codex" })
        claude.models = Array(claude.models.filter { $0.isLegacy != true }.prefix(3))
        codex.models = [ServerProviderModel(slug: "test-model", name: "Test model")]
        try #require(claude.models.count == 3)
        claude.status = .ready; claude.enabled = true; claude.availability = nil
        codex.status = .ready; codex.enabled = true; codex.availability = nil
        let view = ModelPickerView(catalog: ProviderCatalog([claude, codex]), favorites: [],
                                   active: claude.instanceId, activeModel: claude.models[0].slug, preferences: .object([:]))
        let size = view.naturalSize
        let catalog = view.catalog
        #expect(claude.models.count > codex.models.count)
        #expect(size.height < ModelPickerView.maxHeight)
        for entry in catalog.entries where entry.isVisibleInPicker && entry.isReady {
            view.selectRail(.instance(entry.id))
            #expect(view.naturalSize == size)
        }
        view.selectRail(.favorites)
        #expect(view.naturalSize == size)
        view.frame = NSRect(origin: .zero, size: size)
        view.setQuery("no matching model here")
        #expect(view.naturalSize == size)
        view.setQuery("")
        #expect(view.naturalSize == size)
        for entry in catalog.entries.filter({ $0.isVisibleInPicker && $0.isReady }).prefix(2) {
            view.selectRail(.instance(entry.id))
            try Fidelity.capture(view, name: "model-picker-\(entry.id.rawValue)", size: size)
        }
    }

    @Test func tallestTabRespectsHiddenModels() throws {
        let view = try picker()
        view.preferences = .object(Dictionary(uniqueKeysWithValues: view.catalog.entries.map { entry in
            (entry.id.rawValue, JSONValue.object(["hiddenModels": .array(entry.models.map { .string($0.slug) })]))
        }))
        #expect(view.naturalSize.height == ModelPickerView.searchHeight + 36)
        view.selectRail(.favorites)
        #expect(view.naturalSize.height == ModelPickerView.searchHeight + 36)
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
