import AppKit
import Testing
@testable import T3Protocol
@testable import Features

/// usagePriceForm.test.ts, usagePriceTable.test.ts, UsageProviderChart.test.ts and the share bar's flex sizing.
@MainActor
struct UsageLogicTests {
    static func target(_ id: String, prices: [String: UsageModelPrice]? = [:], aliases: [String: String]? = [:], unavailable: String? = nil) -> UsagePriceTarget {
        UsagePriceTarget(environmentId: id, label: id.uppercased(), prices: prices, aliases: aliases, unavailable: unavailable)
    }

    @Test func parsesPriceForms() {
        let ok = UsagePriceLogic.parse(model: " m ", [.input: "3", .output: "15", .cacheRead: "", .cacheWrite: "0"])
        #expect(ok?.model == "m")
        #expect(ok?.price == UsageModelPrice(input: 3, output: 15, cacheRead: nil, cacheWrite: 0))
        #expect(UsagePriceLogic.parse(model: "m", [.input: "3", .output: ""]) == nil)
        #expect(UsagePriceLogic.parse(model: "m", [.input: "-1", .output: "1"]) == nil)
        #expect(UsagePriceLogic.parse(model: "m", [.input: "1e2", .output: ".5"])?.price.input == 100)
        #expect(UsagePriceLogic.form(UsageModelPrice(input: 0.3, output: 15))[.input] == "0.3")
    }

    @Test func cellsReadMixedAndAutomatic() {
        let a = Self.target("a", prices: ["m": UsageModelPrice(input: 1, output: 2)])
        let b = Self.target("b", prices: ["m": UsageModelPrice(input: 1, output: 3)])
        #expect(UsagePriceLogic.priceCell([a, b], model: "m", field: .input) == .init(value: "1", placeholder: "0.00"))
        #expect(UsagePriceLogic.priceCell([a, b], model: "m", field: .output).placeholder == "Mixed")
        #expect(UsagePriceLogic.priceCell([a], model: "x", field: .input).placeholder == "Automatic")
        #expect(UsagePriceLogic.priceCell([a], model: "m", field: .cacheRead).placeholder == "Input rate")
        #expect(UsagePriceLogic.priceCell([Self.target("c", prices: nil)], model: "m", field: .input).placeholder == "Unavailable")
        #expect(UsagePriceLogic.aliasCell([Self.target("c", aliases: nil)], model: "m").placeholder == "Unavailable")
    }

    @Test func changesKeepUntouchedCells() {
        let a = Self.target("a", prices: ["m": UsageModelPrice(input: 1, output: 2, cacheRead: 0.1)])
        // Only the output was edited: the input and cache rates stay this environment's.
        let edit = UsagePriceDraft(id: "model:m", model: "m", isNew: false, values: [.output: "4"])
        let plan = UsagePriceLogic.changes(a, [edit])
        #expect(plan.changes == [.price(model: "m", UsageModelPrice(input: 1, output: 4, cacheRead: 0.1))])
        // Reset to automatic removes the price.
        #expect(UsagePriceLogic.changes(a, [UsagePriceDraft(id: "model:m", model: "m", isNew: false, removed: true)]).changes == [.price(model: "m", nil)])
        // Mapping drops the model's own price.
        let mapped = UsagePriceLogic.changes(a, [UsagePriceDraft(id: "model:m", model: "m", isNew: false, alias: "big")]).changes
        #expect(mapped == [.alias(model: "m", "big"), .price(model: "m", nil)])
        #expect(UsagePriceLogic.changes(a, [UsagePriceDraft(id: "n", model: "m", isNew: true, alias: "m")]).errors["n"] == "Map to a different model.")
        let missing = UsagePriceLogic.changes(Self.target("b"), [UsagePriceDraft(id: "n", model: "new", isNew: true, values: [.input: "1"])])
        #expect(missing.errors["n"] == "Output is required on B.")
        #expect(UsagePriceLogic.patch(mapped) == ["usagePriceOverrides": .object(["m": .null]), "usageModelAliases": .object(["m": .string("big")])])
        #expect(UsagePriceLogic.blocker(Self.target("c", aliases: nil), mapped) == "Update server to map models")
        let t = UsagePriceTarget.make(environmentId: "e", label: "E", connected: true, settings: .object([:]), capabilities: [], canWrite: true)
        #expect(t.unavailable == "Update server to edit prices")
    }

    @Test func chartScaleAndCurve() {
        #expect(UsageChartLogic.niceScale(0).max == 0)
        #expect(UsageChartLogic.niceScale(7.3).max == 8)
        #expect(UsageChartLogic.niceScale(7.3).ticks == [0, 2, 4, 6, 8])
        #expect(UsageChartLogic.niceScale(93).max == 100)
        #expect(abs(UsageChartLogic.niceScale(0.042).max - 0.06) < 1e-12)
        let loading = UsageChartLogic.scale([], loading: true)
        #expect(!loading.labeled && loading.ticks.count == 5)
        // Monotone curves never overshoot: every control point stays between its ends.
        let pts = [CGPoint(x: 0, y: 260), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 250), CGPoint(x: 30, y: 250)]
        for (a, c1, c2, b) in UsageChartLogic.curve(pts) {
            let lo = min(a.y, b.y), hi = max(a.y, b.y)
            #expect(c1.y >= lo - 0.001 && c1.y <= hi + 0.001 && c2.y >= lo - 0.001 && c2.y <= hi + 0.001)
        }
        let day = UsagePeriodTotals(day: "2026-10-10", hourStart: nil, costUsd: 3, totalTokens: 30,
                                    byProvider: [.claude: UsageByProvider(costUsd: 2, totalTokens: 10), .codex: UsageByProvider(costUsd: 1, totalTokens: 20)])
        let cols = UsageChartLogic.columns(["2026-10-09", "2026-10-10"], ["2026-10-10": day], tokens: true)
        #expect(cols[0].total == 0 && cols[1].value(.codex) == 20 && cols[1].total == 30)
        #expect(UsageChartLogic.scale(cols, loading: false).max == 20)
    }

    @Test func shareStripFlexFloor() {
        let w = UsageShareStripView.widths([1000, 1], total: 402)
        #expect(w[1] == 4)
        #expect(abs(w[0] - 396) < 0.001)
    }

    @Test func breakdownHelpers() {
        let m = UsageModelTotals(model: "m", provider: .claude, costUsd: 2, totalTokens: 2_000_000,
                                 tokens: UsageTokenTotals(uncached: 300, cached: 600, cacheCreation: 100, output: 1000), records: 4, unpricedRecords: 0,
                                 unpricedTokens: 1_000_000, costShare: 0.5, tokenShare: 0.25)
        #expect(UsageBreakdown.cacheHitRate(m) == 0.6)
        #expect(UsageBreakdown.costPerMillion(m) == 2)
        #expect(UsageBreakdown.share(m, tokens: true) == 0.25)
        var unknown = m; unknown.unpricedRecords = 4
        #expect(UsageBreakdown.share(unknown, tokens: false) == nil)
        #expect(UsageBreakdown.costSegments(UsageCategorySplit(unsplit: 0.004)).last?.value == 0)
        #expect(UsageHubLogic.sourceId("https://Hub.example.ts.net:8318/x") == "cliproxy-hub.example.ts.net-8318")
        // Seven providers since 2994 added Pi (usage.ts:41).
        #expect(UsagePageOptions.providerFilterLabel(hidden: [.cursor]) == "6 providers")
        #expect(UsagePageOptions.Preferences(json: nil).metric == "limits")
        #expect(UsageRedactedTextView.placeholder("ab@c.d").count == 6)
    }

    @Test func scheduledTaskScope() {
        let env = SettingsScopeEnvironment(id: "a", label: "A", settings: ServerSettingsValues(.object([:])))
        let member = SettingsScopeProject.Member(environmentId: "a", projectId: "p", title: "P", workspaceRoot: "/p")
        let all = SettingsScopeState(environments: [env], primaryId: "a", projects: [SettingsScopeProject(key: "k", displayName: "P", members: [member])])
        #expect(ScheduledTaskScope.matches(all, environmentId: "a", projectId: "q"))
        var project = all
        project.selection = SettingsScopeSelection(project: "k")
        #expect(ScheduledTaskScope.matches(project, environmentId: "a", projectId: "p"))
        #expect(!ScheduledTaskScope.matches(project, environmentId: "a", projectId: "q"))
    }
}
