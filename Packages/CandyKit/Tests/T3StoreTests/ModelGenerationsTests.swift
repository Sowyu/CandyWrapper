import Testing
import T3Protocol
@testable import T3Store

/// Redesign's Older models rule (`ModelGenerations.older`): the newest version of each tier stays, the rest fold away.
struct ModelGenerationsTests {
    private func model(_ name: String, slug: String? = nil, custom: Bool = false, legacy: Bool? = nil) -> ServerProviderModel {
        ServerProviderModel(slug: slug ?? name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, isCustom: custom, isLegacy: legacy)
    }

    @Test func gptTiersKeepTheirNewestVersion() {
        let models = ["GPT-6.2-Sol", "GPT-6.1-Sol", "GPT-6-Sol", "GPT-5.6-Sol", "GPT-6 Astra", "GPT-5.5 Astra", "GPT-6.2"].map { model($0) }
        #expect(ModelGenerations.older(models) == ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.5-astra"])
        #expect(ModelGenerations.tierAndVersion("GPT-6.2-Sol")! == ("gpt sol", [6, 2]))
        #expect(ModelGenerations.compare([6, 2], [6, 1]) > 0 && ModelGenerations.compare([6], [5, 6]) > 0 && ModelGenerations.compare([6], [6, 0]) == 0)
    }

    @Test func claudeTiersAndNamesWithoutAVersion() {
        let models = ["Claude Opus 5.5", "Claude Opus 5.1", "Claude Opus 5", "Claude Sonnet 5.5", "Claude Haiku 5.5", "Claude Haiku 4.5",
                      "Big Pickle"].map { model($0) }
        #expect(ModelGenerations.older(models) == ["claude-opus-5.1", "claude-opus-5", "claude-haiku-4.5"])
        #expect(ModelGenerations.tierAndVersion("Big Pickle") == nil, "no version: always current")
    }

    @Test func selectedFavoritesCustomAndServerLegacy() {
        let models = [model("Claude Opus 5.5"), model("Claude Opus 5.1"), model("Claude Opus 4.8"), model("Claude Opus 4", custom: true),
                      model("House Model", legacy: true)]
        // The selected model and a favourite stay in the main list; a custom model is current; the server's flag still folds.
        #expect(ModelGenerations.older(models, keep: ["claude-opus-5.1", "claude-opus-4.8"]) == ["house-model"])
        #expect(ModelGenerations.older(models) == ["claude-opus-5.1", "claude-opus-4.8", "house-model"])
    }

    @MainActor @Test func sectionsFoldOlderModelsUnderOneRowOnlyWhenAsked() {
        let models = ["Claude Opus 5.5", "Claude Opus 5.1", "Claude Opus 5", "Claude Sonnet 5.5"].map { model($0) }
        let catalog = ProviderCatalog([ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", models: models)])
        func rows(groups: Bool, expanded: Bool = false, active: String = "claude-opus-5.5", query: String = "", favorites: [ModelFavorite] = []) -> [String] {
            ModelPickerSections(catalog: catalog, active: "claudeAgent", activeModel: active, favorites: favorites, rail: .instance("claudeAgent"),
                                query: query, expandedLegacy: expanded ? ["claudeAgent"] : [], groupsOlder: groups).rows.map {
                switch $0 {
                case .model(let item): item.model.slug
                case .legacy(_, let count, let open): "older \(count) \(open)"
                case .subProvider: "sub"
                }
            }
        }
        #expect(rows(groups: false) == ["claude-opus-5.5", "claude-opus-5.1", "claude-opus-5", "claude-sonnet-5.5"], "default themes unchanged")
        #expect(rows(groups: true) == ["claude-opus-5.5", "claude-sonnet-5.5", "older 2 false"])
        #expect(rows(groups: true, expanded: true) == ["claude-opus-5.5", "claude-sonnet-5.5", "claude-opus-5.1", "claude-opus-5", "older 2 true"])
        #expect(rows(groups: true, active: "claude-opus-5") == ["claude-opus-5.5", "claude-opus-5", "claude-sonnet-5.5", "older 1 false"])
        #expect(rows(groups: true, favorites: [ModelFavorite(provider: "claudeAgent", model: "claude-opus-5.1")]).first == "claude-opus-5.1")
        #expect(rows(groups: true, query: "opus").count == 3, "search finds older models with no group row")
    }
}
