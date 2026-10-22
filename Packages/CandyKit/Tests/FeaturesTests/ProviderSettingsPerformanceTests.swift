import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct ProviderSettingsPerformanceTests {
    private func makeContext() -> SettingsPageContext {
        let context = SettingsPageContext()
        context.scope = SettingsScopeState(environments: [SettingsLogicTests.env("sandbox", "Sandbox")], primaryId: "sandbox")
        context.configs["sandbox"] = ServerProviderConfig(providers: [
            ServerProvider(instanceId: .init("codex"), driver: "codex"),
            ServerProvider(instanceId: .init("claudeAgent"), driver: "claudeAgent")
        ])
        return context
    }

    @Test func timestampsDoNotRebuildCardsOrModels() {
        let context = makeContext()
        for i in context.configs["sandbox"]!.providers.indices {
            context.configs["sandbox"]!.providers[i].usageLimits = .init(checkedAt: "initial", windows: [])
            context.configs["sandbox"]!.providers[i].versionAdvisory = .object(["checkedAt": .string("initial")])
        }
        let page = ProvidersSettingsView(context: context)
        let rows = page.providers.list
        let editor = page.providers.editor
        for stamp in ["first", "second", "third"] {
            for i in context.configs["sandbox"]!.providers.indices {
                context.configs["sandbox"]!.providers[i].checkedAt = stamp
                context.configs["sandbox"]!.providers[i].usageLimits?.checkedAt = stamp
                context.configs["sandbox"]!.providers[i].versionAdvisory = .object(["checkedAt": .string(stamp)])
            }
            page.refresh()
            #expect(page.providers.list.count == rows.count)
            #expect(zip(rows, page.providers.list).filter { $0 !== $1 }.count == 0)
            #expect(editor === page.providers.editor)
        }
        #expect(!rows.isEmpty)
        #expect(editor != nil)
    }

    @Test func equalReconnectSnapshotKeepsCardsAndEditor() {
        let context = makeContext()
        let page = ProvidersSettingsView(context: context)
        let rows = page.providers.list
        let editor = page.providers.editor
        context.configs = self.makeContext().configs
        page.refresh()
        #expect(page.providers.list.count == rows.count)
        #expect(zip(rows, page.providers.list).filter { $0 !== $1 }.count == 0)
        #expect(editor === page.providers.editor)
    }

    @Test func anotherProviderOnlyRebuildsItsCard() {
        let context = makeContext()
        let page = ProvidersSettingsView(context: context)
        let rows = page.providers.list
        let editor = page.providers.editor
        context.configs["sandbox"]!.providers[1].message = "Needs attention"
        page.refresh()
        #expect(zip(rows, page.providers.list).filter { $0 !== $1 }.count == 1)
        #expect(editor === page.providers.editor)
        let changed = page.providers.list
        let models = page.providers.editor?.sections.last
        context.configs["sandbox"]!.providers[0].version = "2.0"
        page.refresh()
        #expect(zip(changed, page.providers.list).filter { $0 !== $1 }.count == 1)
        #expect(editor !== page.providers.editor)
        #expect(models != nil)
        #expect(models === page.providers.editor?.sections.last)
    }

    @Test func modelPreferencesRefreshTheSelectedEditor() throws {
        let context = makeContext()
        context.configs["sandbox"]!.providers[0].models = (0..<12).map { .init(slug: "model-\($0)", name: "Model \($0)") }
        var favorites: [ModelFavorite] = []
        context.modelPreferences = { _ in (favorites, .object([:])) }
        let page = ProvidersSettingsView(context: context)
        let editor = page.providers.editor
        let models = editor?.sections.last
        let section = try #require(models as? SettingsSectionView)
        let list = try #require(section.group.rows.first as? ProviderModelsView)
        #expect(list.createdModelRows == 12)
        favorites = [.init(provider: .init("codex"), model: "model-5")]
        page.refresh()
        #expect(editor !== page.providers.editor)
        #expect(models === page.providers.editor?.sections.last)
        #expect(list.createdModelRows == 13)
    }
}
