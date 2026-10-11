import Foundation

// The usage contract (packages/contracts/src/usage.ts) and the client's merge and formatting
// (packages/shared/src/usageMerge.ts, usageFormat.ts). Decoded by hand from JSON: arrays are
// `ForwardCompatibleArray`, so an entry this build does not understand is skipped, never fatal.

/// `USAGE_CONTRACT_VERSION` (usage.ts:24) and `USAGE_MERGE_COMPATIBLE_SINCE` (usage.ts:32).
public enum UsageContract {
    public static let version = 6
    public static let mergeCompatibleSince = 4
}

/// `UsageProviderKind` in `PROVIDER_PRESENTATION` order (usageProviders.ts:16-45), the reading order of
/// every chart, table and hover row.
public enum UsageProviderKind: String, CaseIterable, Sendable, Hashable {
    case codex, claude, grok, cursor, opencode, antigravity

    public var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .grok: "Grok Build"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        }
    }

    /// The provider driver that draws the icon (`driverKind`).
    public var driverKind: String {
        switch self {
        case .claude: "claudeAgent"
        default: rawValue
        }
    }
}

/// `UsageTokenTotals` (usage.ts:76-83). `reasoningTokens` is a subset of `outputTokens`.
public struct UsageTokenTotals: Equatable, Sendable {
    public var uncachedInputTokens: Double = 0
    public var cachedInputTokens: Double = 0
    public var cacheCreationTokens: Double = 0
    public var outputTokens: Double = 0
    public var reasoningTokens: Double = 0
    public init() {}
    public init(uncached: Double, cached: Double, cacheCreation: Double, output: Double, reasoning: Double = 0) {
        uncachedInputTokens = uncached; cachedInputTokens = cached; cacheCreationTokens = cacheCreation
        outputTokens = output; reasoningTokens = reasoning
    }
    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        uncachedInputTokens = json["uncachedInputTokens"]?.doubleValue ?? 0
        cachedInputTokens = json["cachedInputTokens"]?.doubleValue ?? 0
        cacheCreationTokens = json["cacheCreationTokens"]?.doubleValue ?? 0
        outputTokens = json["outputTokens"]?.doubleValue ?? 0
        reasoningTokens = json["reasoningTokens"]?.doubleValue ?? 0
    }
}

/// `UsageCategoryCost` (usage.ts:89-95).
public struct UsageCategoryCost: Equatable, Sendable {
    public var input: Double, cacheRead: Double, cacheWrite: Double, output: Double
    public init(input: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, output: Double = 0) {
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output
    }
}

/// One `(day, hourStart?, provider, model)` cell (`UsageBucket`, usage.ts:107-145).
public struct UsageBucket: Equatable, Sendable {
    public var day: String
    public var hourStart: String?
    public var provider: UsageProviderKind
    public var model: String
    public var sourcePath: String?
    public var totals: UsageTokenTotals
    public var costUsd: Double
    public var cacheSavingsUsd: Double
    public var categoryCostUsd: UsageCategoryCost?
    public var fastCostUsd: Double?
    public var ultrafastCostUsd: Double?
    public var speedPremiumUsd: Double?
    /// `providerReported`, `modelPriced` or `unpriced`.
    public var costSource: String
    public var records: Double
    public var unpricedRecords: Double
    public var sessions: Double

    public init(day: String, hourStart: String? = nil, provider: UsageProviderKind, model: String, sourcePath: String? = nil,
                totals: UsageTokenTotals, costUsd: Double, cacheSavingsUsd: Double = 0, categoryCostUsd: UsageCategoryCost? = nil,
                fastCostUsd: Double? = nil, ultrafastCostUsd: Double? = nil, speedPremiumUsd: Double? = nil,
                costSource: String = "modelPriced", records: Double = 1, unpricedRecords: Double = 0, sessions: Double = 1) {
        self.day = day; self.hourStart = hourStart; self.provider = provider; self.model = model; self.sourcePath = sourcePath
        self.totals = totals; self.costUsd = costUsd; self.cacheSavingsUsd = cacheSavingsUsd; self.categoryCostUsd = categoryCostUsd
        self.fastCostUsd = fastCostUsd; self.ultrafastCostUsd = ultrafastCostUsd; self.speedPremiumUsd = speedPremiumUsd
        self.costSource = costSource; self.records = records; self.unpricedRecords = unpricedRecords; self.sessions = sessions
    }

    init?(json: JSONValue) {
        guard let day = json["day"]?.stringValue, let raw = json["provider"]?.stringValue, let provider = UsageProviderKind(rawValue: raw),
              let model = json["model"]?.stringValue, let totals = UsageTokenTotals(json: json["totals"]) else { return nil }
        self.day = day
        hourStart = json["hourStart"]?.stringValue
        self.provider = provider
        self.model = model
        sourcePath = json["sourcePath"]?.stringValue
        self.totals = totals
        costUsd = json["costUsd"]?.doubleValue ?? 0
        cacheSavingsUsd = json["cacheSavingsUsd"]?.doubleValue ?? 0
        if let c = json["categoryCostUsd"], case .object = c {
            categoryCostUsd = UsageCategoryCost(input: c["input"]?.doubleValue ?? 0, cacheRead: c["cacheRead"]?.doubleValue ?? 0,
                                                cacheWrite: c["cacheWrite"]?.doubleValue ?? 0, output: c["output"]?.doubleValue ?? 0)
        }
        fastCostUsd = json["fastCostUsd"]?.doubleValue
        ultrafastCostUsd = json["ultrafastCostUsd"]?.doubleValue
        speedPremiumUsd = json["speedPremiumUsd"]?.doubleValue
        costSource = json["costSource"]?.stringValue ?? "unpriced"
        records = json["records"]?.doubleValue ?? 0
        unpricedRecords = json["unpricedRecords"]?.doubleValue ?? 0
        sessions = json["sessions"]?.doubleValue ?? 0
    }

    /// `bucketTokens`: reasoning is inside output and never added again.
    var tokens: Double { totals.uncachedInputTokens + totals.cachedInputTokens + totals.cacheCreationTokens + totals.outputTokens }
}

/// `UsageSourceFingerprint` (usage.ts:155-171).
public struct UsageSourceFingerprint: Equatable, Sendable {
    public var hostId: String
    public var provider: UsageProviderKind
    public var resolvedHomePath: String
    public var volumeId: String
    public init(hostId: String, provider: UsageProviderKind, resolvedHomePath: String, volumeId: String = "") {
        self.hostId = hostId; self.provider = provider; self.resolvedHomePath = resolvedHomePath; self.volumeId = volumeId
    }
    /// `fingerprintKey` (usageMerge.ts:146-153).
    var key: String { [hostId, provider.rawValue, resolvedHomePath, volumeId].joined(separator: " ") }
}

/// `UsageSource` (usage.ts:176-200).
public struct UsageSource: Equatable, Sendable {
    public var fingerprint: UsageSourceFingerprint
    /// `ok`, `missing`, `partial` or `failed`.
    public var status: String
    public var distinctSessions: Double
    public var message: String?
    /// `enableCursorKeychain` when the source can be enabled from the client.
    public var action: String?
    public var refreshing: Bool

    public init(fingerprint: UsageSourceFingerprint, status: String = "ok", distinctSessions: Double = 0, message: String? = nil,
                action: String? = nil, refreshing: Bool = false) {
        self.fingerprint = fingerprint; self.status = status; self.distinctSessions = distinctSessions
        self.message = message; self.action = action; self.refreshing = refreshing
    }

    init?(json: JSONValue) {
        let f = json["fingerprint"]
        guard let hostId = f?["hostId"]?.stringValue, let raw = f?["provider"]?.stringValue, let provider = UsageProviderKind(rawValue: raw),
              let home = f?["resolvedHomePath"]?.stringValue, let status = json["status"]?.stringValue else { return nil }
        fingerprint = UsageSourceFingerprint(hostId: hostId, provider: provider, resolvedHomePath: home, volumeId: f?["volumeId"]?.stringValue ?? "")
        self.status = status
        distinctSessions = json["distinctSessions"]?.doubleValue ?? 0
        message = json["message"]?.stringValue
        action = json["action"]?.stringValue
        refreshing = json["refreshing"]?.boolValue == true
    }
}

/// `UsageSummary` (usage.ts:240-251), with `pricing` kept as sent.
public struct UsageSummary: Equatable, Sendable {
    public var contractVersion: Int
    public var readAt: String
    public var timeZone: String
    public var sinceDay: String
    public var untilDay: String
    public var buckets: [UsageBucket]
    public var sources: [UsageSource]
    public var scanDurationMs: Double

    public init(contractVersion: Int = UsageContract.version, readAt: String = "", timeZone: String = "UTC", sinceDay: String = "",
                untilDay: String = "", buckets: [UsageBucket] = [], sources: [UsageSource] = [], scanDurationMs: Double = 0) {
        self.contractVersion = contractVersion; self.readAt = readAt; self.timeZone = timeZone; self.sinceDay = sinceDay
        self.untilDay = untilDay; self.buckets = buckets; self.sources = sources; self.scanDurationMs = scanDurationMs
    }

    public init?(json: JSONValue) {
        guard case .object = json, let version = json["contractVersion"]?.doubleValue else { return nil }
        contractVersion = Int(version)
        readAt = json["readAt"]?.stringValue ?? ""
        timeZone = json["timeZone"]?.stringValue ?? "UTC"
        sinceDay = json["sinceDay"]?.stringValue ?? ""
        untilDay = json["untilDay"]?.stringValue ?? ""
        buckets = (json["buckets"]?.arrayValue ?? []).compactMap(UsageBucket.init(json:))
        sources = (json["sources"]?.arrayValue ?? []).compactMap(UsageSource.init(json:))
        scanDurationMs = json["scanDurationMs"]?.doubleValue ?? 0
    }

    /// True while a slow source answered from its cache; ask again with `awaitRefresh`.
    public var hasRefreshingSource: Bool { sources.contains { $0.refreshing } }
}

/// `UsageSummaryInput` (usage.ts:207-232): the window the page asks for.
public struct UsageWindow: Equatable, Hashable, Sendable {
    public var sinceDay: String
    public var untilDay: String
    public var timeZone: String
    /// `day` or `hour`.
    public var resolution: String
    public var sinceTime: String?
    public var untilTime: String?

    public init(sinceDay: String, untilDay: String, timeZone: String, resolution: String = "day", sinceTime: String? = nil, untilTime: String? = nil) {
        self.sinceDay = sinceDay; self.untilDay = untilDay; self.timeZone = timeZone; self.resolution = resolution
        self.sinceTime = sinceTime; self.untilTime = untilTime
    }

    public var isHourly: Bool { resolution == "hour" }

    /// The `server.getUsageSummary` payload.
    public func payload(awaitRefresh: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["sinceDay": .string(sinceDay), "untilDay": .string(untilDay), "timeZone": .string(timeZone),
                                      "resolution": .string(resolution)]
        if let sinceTime { o["sinceTime"] = .string(sinceTime) }
        if let untilTime { o["untilTime"] = .string(untilTime) }
        if awaitRefresh { o["awaitRefresh"] = .bool(true) }
        return .object(o)
    }
}

// MARK: - Merge (usageMerge.ts)

/// One environment's answer (`EnvironmentUsage`).
public struct EnvironmentUsage: Sendable {
    public var environmentId: String
    public var label: String
    public var summary: UsageSummary
    public init(environmentId: String, label: String, summary: UsageSummary) {
        self.environmentId = environmentId; self.label = label; self.summary = summary
    }
}

public struct UsageByProvider: Equatable, Sendable {
    public var costUsd: Double = 0
    public var totalTokens: Double = 0
    public init(costUsd: Double = 0, totalTokens: Double = 0) { self.costUsd = costUsd; self.totalTokens = totalTokens }
}

/// `DailyTotals` and `HourlyTotals`: `hourStart` is set for hourly periods.
public struct UsagePeriodTotals: Equatable, Sendable {
    public var day: String
    public var hourStart: String?
    public var costUsd: Double
    public var totalTokens: Double
    public var byProvider: [UsageProviderKind: UsageByProvider]
    /// The key the chart and the table look a period up by.
    public var periodKey: String { hourStart ?? day }
}

public struct UsageProviderTotals: Equatable, Sendable {
    public var provider: UsageProviderKind
    public var costUsd: Double
    public var totalTokens: Double
    public var records: Double
    public var sessions: Double
    public var costShare: Double
    public var tokenShare: Double
}

public struct UsageModelTotals: Equatable, Sendable {
    public var model: String
    public var provider: UsageProviderKind
    public var costUsd: Double
    public var totalTokens: Double
    public var tokens: UsageTokenTotals
    public var records: Double
    public var unpricedRecords: Double
    public var unpricedTokens: Double
    public var costShare: Double
    public var tokenShare: Double

    /// `isModelCostUnknown`: every record lacked rates, so the cost is unknown, not zero.
    public var isCostUnknown: Bool { records > 0 && unpricedRecords >= records }
    public var key: String { "\(provider.rawValue):\(model)" }
}

public struct UsageCategorySplit: Equatable, Sendable {
    public var input = 0.0, cacheRead = 0.0, cacheWrite = 0.0, output = 0.0, unsplit = 0.0
}

public struct UsageSpeedCost: Equatable, Sendable {
    public var standard = 0.0, fast = 0.0, ultrafast = 0.0, premium = 0.0
}

public struct UsageContractMismatch: Equatable, Sendable {
    public var environmentId: String
    /// `serverBehind` or `clientBehind`.
    public var direction: String
    public var contractVersion: Int
}

/// `MergedUsage` (usageMerge.ts:121-142).
public struct MergedUsage: Equatable, Sendable {
    public var costUsd = 0.0
    public var uncachedInputTokens = 0.0
    public var cachedInputTokens = 0.0
    public var cacheCreationTokens = 0.0
    public var outputTokens = 0.0
    public var reasoningTokens = 0.0
    public var totalTokens = 0.0
    public var records = 0.0
    public var sessions = 0.0
    public var providers: [UsageProviderTotals] = []
    public var models: [UsageModelTotals] = []
    public var daily: [UsagePeriodTotals] = []
    public var hourly: [UsagePeriodTotals] = []
    public var providerReportedShare = 0.0
    public var modelPricedShare = 0.0
    public var unpricedShare = 0.0
    public var cacheSavingsUsd = 0.0
    public var categoryCost = UsageCategorySplit()
    public var speedCost = UsageSpeedCost()
    public var duplicateSources: [String] = []
    public var contributingEnvironments: [String] = []
    public var contractMismatches: [UsageContractMismatch] = []
    public init() {}

    public var tokenTotals: UsageTokenTotals {
        UsageTokenTotals(uncached: uncachedInputTokens, cached: cachedInputTokens, cacheCreation: cacheCreationTokens, output: outputTokens,
                         reasoning: reasoningTokens)
    }
}

public enum UsageMerge {
    /// `isCompatibleUsageContractVersion`.
    public static func isCompatible(_ version: Int, expected: Int = UsageContract.version) -> Bool {
        version >= UsageContract.mergeCompatibleSince && version <= expected
    }

    /// `bucketsForSource`: indices of the summary's buckets read from this source.
    private static func bucketsForSource(_ summary: UsageSummary, _ source: UsageSource) -> [Int] {
        let providerSources = summary.sources.filter { $0.fingerprint.provider == source.fingerprint.provider }.count
        return summary.buckets.indices.filter { i in
            let b = summary.buckets[i]
            return b.provider == source.fingerprint.provider
                && (b.sourcePath == source.fingerprint.resolvedHomePath || (b.sourcePath == nil && providerSources == 1))
        }
    }

    private static func bucketKey(_ b: UsageBucket) -> String { "\(b.day)\u{1}\(b.hourStart ?? "")\u{1}\(b.provider.rawValue)\u{1}\(b.model)" }

    private static func readAtMs(_ e: EnvironmentUsage) -> Int64 { T3Timestamp.parseEpochMs(e.summary.readAt) ?? 0 }

    /// `claimSources` (usageMerge.ts:185-266): which environment owns each transcript directory.
    private static func claim(_ environments: [EnvironmentUsage])
        -> (owner: [String: String], supplemental: [String: Set<Int>], sessions: [String: Double], duplicates: [String]) {
        var owner: [String: String] = [:]
        var ownerScan: [String: (env: EnvironmentUsage, source: UsageSource)] = [:]
        var seenKeys: [String: Set<String>] = [:]
        var supplemental: [String: Set<Int>] = [:]
        var sessions: [String: Double] = [:]
        var duplicates: [String] = []
        let ordered = environments.enumerated().sorted { l, r in
            let a = readAtMs(l.element), b = readAtMs(r.element)
            if a != b { return a > b }
            if l.element.environmentId != r.element.environmentId { return l.element.environmentId < r.element.environmentId }
            return l.offset < r.offset
        }.map(\.element)

        for status in ["ok", "partial", "failed"] {
            for env in ordered {
                for source in env.summary.sources where source.status == status {
                    let key = source.fingerprint.key
                    if owner[key] != nil {
                        duplicates.append("\(env.label): \(source.fingerprint.resolvedHomePath)")
                        continue
                    }
                    owner[key] = env.environmentId
                    ownerScan[key] = (env, source)
                    sessions[key] = source.distinctSessions
                }
            }
        }

        for env in ordered {
            for source in env.summary.sources where source.status == "partial" {
                let key = source.fingerprint.key
                guard let o = ownerScan[key], o.source.status == "ok", readAtMs(env) > readAtMs(o.env) else { continue }
                var seen = seenKeys[key] ?? Set(bucketsForSource(o.env.summary, o.source).map { bucketKey(o.env.summary.buckets[$0]) })
                var added = false
                var mine = supplemental[env.environmentId] ?? []
                for i in bucketsForSource(env.summary, source) {
                    let cell = bucketKey(env.summary.buckets[i])
                    if seen.contains(cell) { continue }
                    seen.insert(cell)
                    mine.insert(i)
                    added = true
                }
                seenKeys[key] = seen
                guard added else { continue }
                supplemental[env.environmentId] = mine
                sessions[key] = max(sessions[key] ?? 0, source.distinctSessions)
            }
        }
        return (owner, supplemental, sessions, duplicates)
    }

    /// `mergeUsage` (usageMerge.ts:356-645).
    public static func merge(_ environments: [EnvironmentUsage], expected: Int = UsageContract.version) -> MergedUsage {
        var out = MergedUsage()
        guard !environments.isEmpty else { return out }
        var current: [EnvironmentUsage] = []
        for env in environments {
            if isCompatible(env.summary.contractVersion, expected: expected) { current.append(env) }
            else {
                out.contractMismatches.append(UsageContractMismatch(
                    environmentId: env.environmentId, direction: env.summary.contractVersion < expected ? "serverBehind" : "clientBehind",
                    contractVersion: env.summary.contractVersion))
            }
        }
        let claims = claim(current)

        var providerReportedRecords = 0.0, unpricedRecords = 0.0
        var category = UsageCategoryCost()
        var providerOrder: [UsageProviderKind] = []
        var providerAcc: [UsageProviderKind: (cost: Double, tokens: Double, records: Double, sessions: Double)] = [:]
        var modelOrder: [String] = []
        var modelAcc: [String: UsageModelTotals] = [:]
        var dayAcc: [String: UsagePeriodTotals] = [:]
        var hourAcc: [String: UsagePeriodTotals] = [:]

        func providerEntry(_ p: UsageProviderKind) -> (cost: Double, tokens: Double, records: Double, sessions: Double) {
            if let e = providerAcc[p] { return e }
            providerOrder.append(p)
            return (0, 0, 0, 0)
        }

        for env in current {
            // `ownedContribution` (usageMerge.ts:269-308).
            var ownedProviders = Set<UsageProviderKind>()
            var ownedSources = Set<String>()
            var sessionOrder: [UsageProviderKind] = []
            var sessionsByProvider: [UsageProviderKind: Double] = [:]
            for source in env.summary.sources where source.status != "missing" {
                let key = source.fingerprint.key
                guard claims.owner[key] == env.environmentId else { continue }
                let p = source.fingerprint.provider
                ownedProviders.insert(p)
                ownedSources.insert("\(p.rawValue)\u{0}\(source.fingerprint.resolvedHomePath)")
                if sessionsByProvider[p] == nil { sessionOrder.append(p) }
                sessionsByProvider[p, default: 0] += claims.sessions[key] ?? source.distinctSessions
            }
            let supplemental = claims.supplemental[env.environmentId] ?? []
            let buckets = env.summary.buckets.indices.filter { i in
                let b = env.summary.buckets[i]
                if supplemental.contains(i) { return true }
                if let path = b.sourcePath { return ownedSources.contains("\(b.provider.rawValue)\u{0}\(path)") }
                return ownedProviders.contains(b.provider)
            }.map { env.summary.buckets[$0] }
            if !buckets.isEmpty { out.contributingEnvironments.append(env.environmentId) }

            for p in sessionOrder {
                let s = sessionsByProvider[p] ?? 0
                out.sessions += s
                if s == 0 { continue }
                var e = providerEntry(p)
                e.sessions += s
                providerAcc[p] = e
            }

            for b in buckets {
                let tokens = b.tokens
                out.costUsd += b.costUsd
                out.cacheSavingsUsd += b.cacheSavingsUsd
                out.uncachedInputTokens += b.totals.uncachedInputTokens
                out.cachedInputTokens += b.totals.cachedInputTokens
                out.cacheCreationTokens += b.totals.cacheCreationTokens
                out.outputTokens += b.totals.outputTokens
                out.reasoningTokens += b.totals.reasoningTokens
                out.records += b.records
                unpricedRecords += b.unpricedRecords
                if b.costSource == "providerReported" { providerReportedRecords += b.records }
                if let c = b.categoryCostUsd {
                    category.input += c.input; category.cacheRead += c.cacheRead; category.cacheWrite += c.cacheWrite; category.output += c.output
                }
                out.speedCost.fast += b.fastCostUsd ?? 0
                out.speedCost.ultrafast += b.ultrafastCostUsd ?? 0
                out.speedCost.premium += b.speedPremiumUsd ?? 0

                var pe = providerEntry(b.provider)
                pe.cost += b.costUsd; pe.tokens += tokens; pe.records += b.records
                providerAcc[b.provider] = pe

                let modelKey = "\(b.provider.rawValue) \(b.model)"
                var m = modelAcc[modelKey] ?? {
                    modelOrder.append(modelKey)
                    return UsageModelTotals(model: b.model, provider: b.provider, costUsd: 0, totalTokens: 0, tokens: UsageTokenTotals(),
                                            records: 0, unpricedRecords: 0, unpricedTokens: 0, costShare: 0, tokenShare: 0)
                }()
                m.costUsd += b.costUsd
                m.totalTokens += tokens
                m.tokens.uncachedInputTokens += b.totals.uncachedInputTokens
                m.tokens.cachedInputTokens += b.totals.cachedInputTokens
                m.tokens.cacheCreationTokens += b.totals.cacheCreationTokens
                m.tokens.outputTokens += b.totals.outputTokens
                m.tokens.reasoningTokens += b.totals.reasoningTokens
                m.records += b.records
                m.unpricedRecords += b.unpricedRecords
                if b.records > 0 { m.unpricedTokens += tokens * b.unpricedRecords / b.records }
                modelAcc[modelKey] = m

                var d = dayAcc[b.day] ?? UsagePeriodTotals(day: b.day, hourStart: nil, costUsd: 0, totalTokens: 0, byProvider: [:])
                d.costUsd += b.costUsd
                d.totalTokens += tokens
                d.byProvider[b.provider, default: UsageByProvider()].costUsd += b.costUsd
                d.byProvider[b.provider, default: UsageByProvider()].totalTokens += tokens
                dayAcc[b.day] = d

                if let hourStart = b.hourStart {
                    var h = hourAcc[hourStart] ?? UsagePeriodTotals(day: b.day, hourStart: hourStart, costUsd: 0, totalTokens: 0, byProvider: [:])
                    h.costUsd += b.costUsd
                    h.totalTokens += tokens
                    h.byProvider[b.provider, default: UsageByProvider()].costUsd += b.costUsd
                    h.byProvider[b.provider, default: UsageByProvider()].totalTokens += tokens
                    hourAcc[hourStart] = h
                }
            }
        }

        out.totalTokens = out.uncachedInputTokens + out.cachedInputTokens + out.cacheCreationTokens + out.outputTokens
        let cost = out.costUsd, total = out.totalTokens
        let providerRows: [(Int, UsageProviderTotals)] = providerOrder.enumerated().map { index, p -> (Int, UsageProviderTotals) in
            let e = providerAcc[p]!
            let costShare: Double = cost == 0 ? 0 : e.cost / cost
            let tokenShare: Double = total == 0 ? 0 : e.tokens / total
            return (index, UsageProviderTotals(provider: p, costUsd: e.cost, totalTokens: e.tokens, records: e.records, sessions: e.sessions,
                                               costShare: costShare, tokenShare: tokenShare))
        }
        out.providers = providerRows.sorted { l, r in l.1.costUsd != r.1.costUsd ? l.1.costUsd > r.1.costUsd : l.0 < r.0 }.map(\.1)
        out.models = modelOrder.enumerated().map { index, key -> (Int, UsageModelTotals) in
            var m = modelAcc[key]!
            m.costShare = cost == 0 ? 0 : m.costUsd / cost
            m.tokenShare = total == 0 ? 0 : m.totalTokens / total
            return (index, m)
        }.sorted { l, r in
            if l.1.costUsd != r.1.costUsd { return l.1.costUsd > r.1.costUsd }
            if l.1.totalTokens != r.1.totalTokens { return l.1.totalTokens > r.1.totalTokens }
            return l.0 < r.0
        }.map(\.1)
        out.daily = dayAcc.values.sorted { $0.day < $1.day }
        out.hourly = hourAcc.values.sorted { ($0.hourStart ?? "") < ($1.hourStart ?? "") }
        let records = out.records
        out.providerReportedShare = records == 0 ? 0 : providerReportedRecords / records
        out.unpricedShare = records == 0 ? 0 : unpricedRecords / records
        out.modelPricedShare = records == 0 ? 0 : (records - providerReportedRecords - unpricedRecords) / records
        out.categoryCost = UsageCategorySplit(input: category.input, cacheRead: category.cacheRead, cacheWrite: category.cacheWrite,
                                              output: category.output,
                                              unsplit: max(0, cost - category.input - category.cacheRead - category.cacheWrite - category.output))
        out.speedCost.standard = max(0, cost - out.speedCost.fast - out.speedCost.ultrafast)
        out.duplicateSources = claims.duplicates
        return out
    }

    /// `providersWithUsage` (usageProviders.ts:51-63): providers with real activity, in reading order.
    public static func providersWithUsage(_ totals: [UsageProviderTotals]) -> [UsageProviderKind] {
        let active = Set(totals.filter { $0.totalTokens > 0 || $0.costUsd > 0 }.map(\.provider))
        return UsageProviderKind.allCases.filter(active.contains)
    }

    /// `withoutProviders` (state/usage.ts:150-170): hidden providers' buckets and sources leave before the merge.
    public static func withoutProviders(_ summary: UsageSummary, _ hidden: Set<UsageProviderKind>) -> UsageSummary {
        guard !hidden.isEmpty else { return summary }
        var s = summary
        s.buckets.removeAll { hidden.contains($0.provider) }
        s.sources.removeAll { hidden.contains($0.fingerprint.provider) }
        return s
    }
}

// MARK: - Formatting (usageFormat.ts)

public enum UsageFormat {
    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
    private static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// `formatUsd`: `$1,234.56`.
    public static func usd(_ value: Double) -> String { currency.string(from: NSNumber(value: value)) ?? "$0.00" }

    /// `formatCount`.
    public static func count(_ value: Double) -> String { integer.string(from: NSNumber(value: jsRound(value))) ?? "0" }

    /// JS `Math.round`: halves go up, also for negatives.
    public static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    /// `formatTokens`: three significant figures with a unit (`19.9B`, `76.7M`, `804K`).
    public static func tokens(_ value: Double) -> String {
        let a = abs(value)
        if a >= 1e12 { return trim(value / 1e12) + "T" }
        if a >= 1e9 { return trim(value / 1e9) + "B" }
        if a >= 1e6 { return trim(value / 1e6) + "M" }
        if a >= 1e3 { return trim(value / 1e3) + "K" }
        return count(value)
    }

    // ponytail: printf rounding, JS toFixed differs on exact binary ties (0.125); port toFixed if a tie shows
    private static func trim(_ value: Double) -> String {
        let a = abs(value)
        let digits = a >= 100 ? 0 : a >= 10 ? 1 : 2
        let s = String(format: "%.\(digits)f", value)
        // `/\.0+$/`: only an all-zero fraction goes.
        if let dot = s.firstIndex(of: "."), s[s.index(after: dot)...].allSatisfy({ $0 == "0" }) { return String(s[..<dot]) }
        return s
    }

    /// `formatPercent(share, digits)`.
    public static func percent(_ share: Double, digits: Int = 1) -> String {
        let p = share * 100
        let smallest = pow(10, Double(-digits))
        if p > 0 && p < smallest { return "<" + String(format: "%.\(digits)f", smallest) + "%" }
        return String(format: "%.\(digits)f", p) + "%"
    }

    /// `formatUsageContractMismatch`.
    public static func contractMismatch(_ label: String, direction: String) -> String {
        direction == "serverBehind"
            ? "\(label) runs an older server version and is excluded from totals."
            : "This client is older than the server on \(label); its usage is excluded from totals."
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `formatDayShort`: `2026-08-07` to `Aug 7`.
    public static func dayShort(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(months[parts[1] - 1]) \(parts[2])"
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func dayStart(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func dayString(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `enumerateDays`: inclusive `YYYY-MM-DD` list.
    public static func enumerateDays(_ since: String, _ until: String) -> [String] {
        guard let start = dayStart(since), let end = dayStart(until), end >= start else { return [] }
        var out: [String] = []
        var cursor = start
        while cursor <= end {
            out.append(dayString(cursor))
            cursor = cursor.addingTimeInterval(86_400)
        }
        return out
    }

    /// `Date.toISOString`: `2026-10-10T12:00:00.000Z`.
    public static func isoString(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let millis = Int(((ms % 1000) + 1000) % 1000)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
                      c.second ?? 0, millis)
    }

    /// `enumerateHourStarts`: every hour bucket start in `[since, until)`.
    public static func enumerateHourStarts(_ since: String, _ until: String) -> [String] {
        guard let s = T3Timestamp.parseEpochMs(since), let e = T3Timestamp.parseEpochMs(until), e > s else { return [] }
        var out: [String] = []
        var cursor = s
        while cursor < e {
            out.append(isoString(cursor))
            cursor += 3_600_000
        }
        return out
    }

    private static func formatter(_ format: String, _ timeZone: String?, locale: String = "en_US") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.dateFormat = format
        f.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return f
    }

    private static func date(_ iso: String) -> Date? { T3Timestamp.parseEpochMs(iso).map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    /// `formatHourShort`: `2 PM`, with the zone name on a repeated fall-back hour.
    public static func hourShort(_ hourStart: String, timeZone: String?) -> String {
        guard let d = date(hourStart) else { return hourStart }
        let wall = formatter("yyyy-MM-dd HH", timeZone)
        let w = wall.string(from: d)
        let repeated = [-3600.0, 3600.0].contains { wall.string(from: d.addingTimeInterval($0)) == w }
        return formatter(repeated ? "h a zzz" : "h a", timeZone).string(from: d)
    }

    /// `formatDateTimeShort`: `Aug 11, 2 PM`.
    public static func dateTimeShort(_ iso: String, timeZone: String?) -> String {
        guard let d = date(iso) else { return iso }
        return formatter("MMM d, h a", timeZone).string(from: d)
    }

    /// `formatRelativeHourShort`: `2 PM today`, `2 PM yesterday`, else `Aug 11, 2 PM`.
    public static func relativeHourShort(_ hourStart: String, relativeTo: String, timeZone: String?) -> String {
        guard let d = date(hourStart), let r = date(relativeTo) else { return dateTimeShort(hourStart, timeZone: timeZone) }
        let f = formatter("yyyy-MM-dd", timeZone)
        guard let a = dayStart(f.string(from: d)), let b = dayStart(f.string(from: r)) else { return dateTimeShort(hourStart, timeZone: timeZone) }
        let ago = Int((b.timeIntervalSince(a) / 86_400).rounded())
        let hour = hourShort(hourStart, timeZone: timeZone)
        if ago == 0 { return "\(hour) today" }
        if ago == 1 { return "\(hour) yesterday" }
        return dateTimeShort(hourStart, timeZone: timeZone)
    }

    /// `makeWindow(days, now, resolution)`: calendar days in the viewer's zone, or a rolling 24 hours.
    public static func makeWindow(days: Int, now: Date = Date(), resolution: String = "day", timeZone: TimeZone = .current) -> UsageWindow {
        let zone = timeZone.identifier
        let f = formatter("yyyy-MM-dd", zone)
        let untilDay = f.string(from: now)
        if resolution == "hour" {
            let untilMs = Int64((now.timeIntervalSince1970 * 1000 / 60_000).rounded(.down)) * 60_000
            let sinceMs = untilMs - 24 * 3_600_000
            let since = Date(timeIntervalSince1970: Double(sinceMs) / 1000), until = Date(timeIntervalSince1970: Double(untilMs) / 1000)
            return UsageWindow(sinceDay: f.string(from: since), untilDay: f.string(from: until), timeZone: zone, resolution: "hour",
                               sinceTime: isoString(sinceMs), untilTime: isoString(untilMs))
        }
        let end = dayStart(untilDay) ?? now
        let start = end.addingTimeInterval(-Double(days - 1) * 86_400)
        return UsageWindow(sinceDay: dayString(start), untilDay: untilDay, timeZone: zone, resolution: "day")
    }
}
