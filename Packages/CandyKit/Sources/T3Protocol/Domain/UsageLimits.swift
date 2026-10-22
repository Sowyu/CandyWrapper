import Foundation

// Subscription limits: the contract (packages/contracts/src/providerUsageLimits.ts) and the pooling,
// pace and reset maths shared by every client (packages/shared/src/usageLimits.ts).

/// `ServerProviderUsageWindow` (providerUsageLimits.ts:20-27).
public struct UsageLimitWindow: Hashable, Sendable {
    public var id: String
    /// `session`, `weekly`, `monthly` or `other`.
    public var kind: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: String?
    public var windowDurationMins: Double?

    public init(id: String, kind: String, label: String, usedPercent: Double, resetsAt: String? = nil, windowDurationMins: Double? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.windowDurationMins = windowDurationMins
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let kind = json["kind"]?.stringValue,
              ["session", "weekly", "monthly", "other"].contains(kind), let label = json["label"]?.stringValue,
              let used = json["usedPercent"]?.doubleValue else { return nil }
        self.init(id: id, kind: kind, label: label, usedPercent: used, resetsAt: json["resetsAt"]?.stringValue,
                  windowDurationMins: json["windowDurationMins"]?.doubleValue)
    }

    var resetMs: Int64? { resetsAt.flatMap(T3Timestamp.parseEpochMs) }
}

/// `ServerProviderResetCredits`.
public struct UsageResetCredits: Hashable, Sendable {
    public var availableCount: Int
    public var nextExpiresAt: String?
    public var nextCreditId: String?
    public init(availableCount: Int, nextExpiresAt: String? = nil, nextCreditId: String? = nil) {
        self.availableCount = availableCount; self.nextExpiresAt = nextExpiresAt; self.nextCreditId = nextCreditId
    }
}

/// `ServerProviderUsageLimits` (providerUsageLimits.ts:52-80).
public struct ProviderUsageLimits: Hashable, Sendable {
    public var checkedAt: String
    public var windows: [UsageLimitWindow]
    public var credentialFingerprint: String?
    public var resetCredits: UsageResetCredits?
    public struct ExternalUsage: Hashable, Sendable { public var label: String; public var url: String }
    public var externalUsage: ExternalUsage?
    /// `unsupported` or `probeFailed`.
    public var unavailableReason: String?
    public var unavailableMessage: String?

    public init(checkedAt: String, windows: [UsageLimitWindow], credentialFingerprint: String? = nil, resetCredits: UsageResetCredits? = nil,
                unavailableReason: String? = nil, unavailableMessage: String? = nil) {
        self.checkedAt = checkedAt; self.windows = windows; self.credentialFingerprint = credentialFingerprint
        self.resetCredits = resetCredits; self.unavailableReason = unavailableReason; self.unavailableMessage = unavailableMessage
    }

    public init?(json: JSONValue?) {
        guard let json, case .object = json, let checkedAt = json["checkedAt"]?.stringValue else { return nil }
        self.checkedAt = checkedAt
        windows = (json["windows"]?.arrayValue ?? []).compactMap(UsageLimitWindow.init(json:))
        credentialFingerprint = json["credentialFingerprint"]?.stringValue
        if let r = json["resetCredits"], let count = r["availableCount"]?.intValue {
            resetCredits = UsageResetCredits(availableCount: count, nextExpiresAt: r["nextExpiresAt"]?.stringValue, nextCreditId: r["nextCreditId"]?.stringValue)
        }
        if let e = json["externalUsage"], let label = e["label"]?.stringValue, let url = e["url"]?.stringValue { externalUsage = ExternalUsage(label: label, url: url) }
        unavailableReason = json["unavailable"]?["reason"]?.stringValue
        unavailableMessage = json["unavailable"]?["message"]?.stringValue
    }

    var checkedMs: Int64 { T3Timestamp.parseEpochMs(checkedAt) ?? 0 }
}

/// `UsageLimitSourceAccount` (providerUsageLimits.ts:97-106).
public struct UsageLimitSourceAccount: Hashable, Sendable {
    public var id: String
    public var driver: String
    public var email: String?
    public var plan: String?
    /// The workspace whose quota this is, from 2994 on (0be20c86c, providerUsageLimits.ts:96).
    public var workspaceId: String?
    public var usageLimits: ProviderUsageLimits
    public init(id: String, driver: String, email: String? = nil, plan: String? = nil, workspaceId: String? = nil, usageLimits: ProviderUsageLimits) {
        self.id = id; self.driver = driver; self.email = email; self.plan = plan; self.workspaceId = workspaceId; self.usageLimits = usageLimits
    }
}

/// `UsageLimitSourceSnapshot` (providerUsageLimits.ts:113-120): one configured hub.
public struct UsageLimitSourceSnapshot: Hashable, Sendable {
    public var id: String
    public var label: String
    public var checkedAt: String
    public var accounts: [UsageLimitSourceAccount]
    public var error: String?
    public init(id: String, label: String, checkedAt: String = "", accounts: [UsageLimitSourceAccount], error: String? = nil) {
        self.id = id; self.label = label; self.checkedAt = checkedAt; self.accounts = accounts; self.error = error
    }

    public static func list(_ json: JSONValue?) -> [UsageLimitSourceSnapshot] {
        (json?.arrayValue ?? []).compactMap { s in
            guard let id = s["id"]?.stringValue, s["kind"]?.stringValue == "cliproxy", let label = s["label"]?.stringValue else { return nil }
            let accounts = (s["accounts"]?.arrayValue ?? []).compactMap { a -> UsageLimitSourceAccount? in
                guard let id = a["id"]?.stringValue, let driver = a["driver"]?.stringValue,
                      let limits = ProviderUsageLimits(json: a["usageLimits"]) else { return nil }
                return UsageLimitSourceAccount(id: id, driver: driver, email: a["email"]?.stringValue, plan: a["plan"]?.stringValue,
                                               workspaceId: a["workspaceId"]?.stringValue, usageLimits: limits)
            }
            return UsageLimitSourceSnapshot(id: id, label: label, checkedAt: s["checkedAt"]?.stringValue ?? "", accounts: accounts,
                                            error: s["error"]?.stringValue)
        }
    }
}

/// `ProviderConsumeResetCreditInput`: a native instance, or a hub's account and credit.
public enum UsageResetCreditTarget: Equatable, Sendable {
    case instance(String)
    case hub(sourceId: String, accountId: String, creditId: String)

    public var payload: JSONValue {
        switch self {
        case .instance(let id): .object(["instanceId": .string(id)])
        case .hub(let s, let a, let c): .object(["sourceId": .string(s), "accountId": .string(a), "creditId": .string(c)])
        }
    }
    var isHub: Bool { if case .hub = self { true } else { false } }
}

/// What the limits views read from one environment: its label, providers and hubs.
public struct UsageLimitsEnvironment: Sendable {
    public var environmentId: String
    public var label: String
    public var providers: [ServerProvider]
    public var sources: [UsageLimitSourceSnapshot]
    public init(environmentId: String, label: String, providers: [ServerProvider], sources: [UsageLimitSourceSnapshot]) {
        self.environmentId = environmentId; self.label = label; self.providers = providers; self.sources = sources
    }
}

/// One subscription account (`LimitAccount`, usageLimits.ts:126-150).
public struct UsageLimitAccount: Equatable, Sendable {
    public var key: String
    public var driver: String
    public var displayName: String?
    public var email: String?
    public var plan: String?
    public var accentColor: String?
    public var environments: [(environmentId: String, label: String)]
    public var sourceLabel: String?
    public var redeem: (environmentId: String, target: UsageResetCreditTarget)?
    public var limits: ProviderUsageLimits

    public static func == (l: Self, r: Self) -> Bool {
        l.key == r.key && l.driver == r.driver && l.displayName == r.displayName && l.email == r.email && l.plan == r.plan
            && l.environments.map(\.environmentId) == r.environments.map(\.environmentId) && l.sourceLabel == r.sourceLabel
            && l.redeem?.environmentId == r.redeem?.environmentId && l.redeem?.target == r.redeem?.target && l.limits == r.limits
    }
}

public enum UsageLimitPace: String, Sendable { case ahead, on, under }

/// One window pooled across accounts (`LimitPoolWindow`, usageLimits.ts:337-357).
public struct UsageLimitPoolWindow: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public var account: UsageLimitAccount
        public var window: UsageLimitWindow?
        /// `LimitPoolMember.refillPercent`: how much of the account's share its next reset hands back.
        public var refillPercent: Double = 0
    }
    public struct Reset: Equatable, Sendable {
        public var account: UsageLimitAccount
        public var window: UsageLimitWindow
        public var at: Int64
        public var restoresPercent: Int
    }
    public var id: String
    public var kind: String
    public var label: String
    public var columns: [Column]
    public var remainingPercent: Int
    public var usedPercent: Int
    public var pace: UsageLimitPace?
    public var resets: [Reset]
}

public struct UsageLimitPool: Equatable, Sendable {
    public var driver: String
    public var accounts: [UsageLimitAccount]
    public var windows: [UsageLimitPoolWindow]
}

/// `UsageLimitsReport` (providerUsageLimits.ts:152-176): the `/usage-limits` panel's snapshot.
public struct UsageLimitsReport: Equatable, Sendable {
    public struct Account: Equatable, Sendable {
        public var id: String
        public var driver: String
        public var label: String
        public var plan: String?
        public var email: String?
        public var sourceLabel: String?
        public var instanceId: String?
        public var resetCreditTarget: UsageResetCreditTarget?
        public var displayName: String?
        public var accentColor: String?
        public var limits: ProviderUsageLimits
    }
    public var createdAt: String
    public var accounts: [Account]
    public var notices: [String]
}

public enum UsageLimitsLogic {
    public static let chatGptUsageURL = "https://chatgpt.com/#settings/Usage"

    /// `CURSOR_USAGE_WINDOWS` (usageLimits.ts:32-48).
    public static let cursorWindows: [(id: String, label: String, description: String)] = [
        ("totalPercentUsed", "Overall", "Combined usage across both allowances, not a third quota."),
        ("autoPercentUsed", "Cursor Models", "Grok and Composer use this first. Auto can use either pool."),
        ("apiPercentUsed", "Other Models", "Claude, GPT, and Gemini use this pool. Grok and Composer fall back here."),
    ]

    public static func cursorWindowDetails(_ id: String) -> (label: String, description: String)? {
        cursorWindows.first { $0.id == id }.map { ($0.label, $0.description) }
    }

    static let kindOrder = ["session": 0, "weekly": 1, "monthly": 2, "other": 3]

    /// `providersWithLimits`: enabled, installed, available and reporting usage at all.
    public static func providersWithLimits(_ providers: [ServerProvider]) -> [ServerProvider] {
        providers.filter { $0.enabled && $0.installed && $0.availability != "unavailable" && $0.usageLimits != nil }
    }

    static func authStatus(_ p: ServerProvider) -> String? { p.auth?["status"]?.stringValue }
    static func authEmail(_ p: ServerProvider) -> String? { p.auth?["email"]?.stringValue }
    static func authLabel(_ p: ServerProvider) -> String? { p.auth?["label"]?.stringValue }
    static func authWorkspace(_ p: ServerProvider) -> String? { p.auth?["workspaceId"]?.stringValue }

    /// `usesChatGptSharing`.
    public static func usesChatGptSharing(_ p: ServerProvider) -> Bool {
        authStatus(p) == "authenticated" && p.auth?["subscriptionSharing"]?.boolValue == true
    }

    /// `collectExternalUsageLinks`: one destination per service.
    public static func externalUsageLinks(_ environments: [UsageLimitsEnvironment]) -> [(label: String, url: String, message: String?)] {
        var order: [String] = []
        var links: [String: (label: String, url: String, message: String?)] = [:]
        for env in environments {
            for p in providersWithLimits(env.providers) {
                guard let external = p.usageLimits?.externalUsage, authStatus(p) == "authenticated" else { continue }
                if links[external.url] == nil { order.append(external.url) }
                links[external.url] = (external.label, external.url, p.usageLimits?.unavailableMessage)
            }
        }
        return order.compactMap { links[$0] }
    }

    /// `accountKey`: the reported email, else an identical credential.
    static func accountKey(_ driver: String, _ email: String?, _ limits: ProviderUsageLimits?) -> String? {
        if let e = email?.trimmingCharacters(in: .whitespaces).lowercased(), !e.isEmpty { return "\(driver):\(e)" }
        return limits?.credentialFingerprint.map { "\(driver):credential:\($0)" }
    }

    /// `AccountReport` (usageLimits.ts:128-140 in 2994): what a provider or hub says about one login.
    struct AccountReport {
        var driver: String, email: String?, workspaceId: String?, limits: ProviderUsageLimits?
        init(_ p: ServerProvider) { driver = p.driver; email = authEmail(p); workspaceId = authWorkspace(p); limits = p.usageLimits }
        init(_ a: UsageLimitSourceAccount) { driver = a.driver; email = a.email; workspaceId = a.workspaceId; limits = a.usageLimits }
    }

    /// `accountKeyResolver` (usageLimits.ts:142-166 in 2994): one email in two workspaces is two
    /// accounts. A report without a workspace (a hub, an older server) joins the only workspace
    /// known for its email, and gets no key when there are several. With no workspace anywhere,
    /// as on servers before 2994, this is `accountKey`.
    static func accountKeyResolver(_ reports: [AccountReport]) -> (AccountReport) -> String? {
        var workspaces: [String: Set<String>] = [:]
        for r in reports {
            if let key = accountKey(r.driver, r.email, r.limits), let w = r.workspaceId { workspaces[key, default: []].insert(w) }
        }
        return { r in
            guard let key = accountKey(r.driver, r.email, r.limits) else { return nil }
            if let w = r.workspaceId { return "\(key):\(w)" }
            guard let known = workspaces[key] else { return key }
            return known.count == 1 ? "\(key):\(known.first!)" : nil
        }
    }

    /// `limitsNotice`: the line shown when there are no bars.
    public static func notice(_ limits: ProviderUsageLimits) -> String? {
        if limits.unavailableReason == "unsupported" { return limits.unavailableMessage ?? "This account has no subscription limits." }
        if limits.unavailableReason == "probeFailed" { return limits.unavailableMessage ?? "Could not read limits." }
        return limits.windows.isEmpty ? "No limits reported." : nil
    }

    /// `collectLimitAccounts` (usageLimits.ts:157-284).
    public static func accounts(_ environments: [UsageLimitsEnvironment]) -> [UsageLimitAccount] {
        var order: [String] = []
        var accounts: [String: UsageLimitAccount] = [:]
        var creditSources: [String: UsageLimitAccount] = [:]
        var hubRedeems: [String: UsageLimitAccount] = [:]
        func merge(_ key: String, _ next: UsageLimitAccount) {
            if let r = next.redeem, r.target.isHub, hubRedeems[key].map({ next.limits.checkedMs > $0.limits.checkedMs }) ?? true {
                hubRedeems[key] = next
            }
            if next.limits.resetCredits != nil, creditSources[key].map({ next.limits.checkedMs > $0.limits.checkedMs }) ?? true {
                creditSources[key] = next
            }
            guard let previous = accounts[key] else { accounts[key] = next; order.append(key); return }
            let fresher = next.limits.checkedMs > previous.limits.checkedMs
            var envs = previous.environments
            for e in next.environments where !envs.contains(where: { $0.environmentId == e.environmentId }) { envs.append(e) }
            let winner = fresher ? next : previous
            let creditSource = creditSources[key]
            var merged = previous
            merged.displayName = previous.displayName ?? next.displayName
            merged.plan = previous.plan ?? next.plan
            merged.accentColor = previous.accentColor ?? next.accentColor
            merged.environments = envs
            merged.sourceLabel = envs.isEmpty ? (previous.sourceLabel ?? next.sourceLabel) : nil
            merged.redeem = hubRedeems[key]?.redeem ?? (creditSource != nil ? creditSource!.redeem : (winner.redeem ?? previous.redeem ?? next.redeem))
            var limits = winner.limits
            limits.resetCredits = creditSource?.limits.resetCredits
            merged.limits = limits
            accounts[key] = merged
        }
        let resolveKey = accountKeyResolver(environments.flatMap { env in
            env.providers.filter(\.enabled).map(AccountReport.init) + env.sources.flatMap(\.accounts).map(AccountReport.init)
        })
        for env in environments {
            for p in providersWithLimits(env.providers) {
                guard let limits = p.usageLimits, notice(limits) == nil else { continue }
                let display = p.displayName?.trimmingCharacters(in: .whitespaces)
                merge(resolveKey(AccountReport(p)) ?? "\(env.environmentId):\(p.instanceId.rawValue)",
                      UsageLimitAccount(key: "\(env.environmentId):\(p.instanceId.rawValue)", driver: p.driver,
                                        displayName: display?.isEmpty == false ? display : nil, email: authEmail(p), plan: authLabel(p),
                                        accentColor: p.accentColor, environments: [(env.environmentId, env.label)], sourceLabel: nil,
                                        redeem: (env.environmentId, .instance(p.instanceId.rawValue)), limits: limits))
            }
        }
        let labelEnvironment = environments.count > 1
        for env in environments {
            for source in env.sources {
                let sourceLabel = labelEnvironment ? "\(env.label) · \(source.label)" : source.label
                for a in source.accounts where notice(a.usageLimits) == nil {
                    let display: String? = a.email == nil ? a.id.replacingOccurrences(of: #"\.json$"#, with: "", options: [.regularExpression, .caseInsensitive]) : nil
                    let redeem = a.usageLimits.resetCredits?.nextCreditId.map {
                        (env.environmentId, UsageResetCreditTarget.hub(sourceId: source.id, accountId: a.id, creditId: $0))
                    }
                    let key = "\(source.id):\(a.id)" + (a.workspaceId.map { ":\($0)" } ?? "")
                    merge(resolveKey(AccountReport(a)) ?? key,
                          UsageLimitAccount(key: key, driver: a.driver, displayName: display, email: a.email, plan: a.plan,
                                            accentColor: nil, environments: [], sourceLabel: sourceLabel, redeem: redeem, limits: a.usageLimits))
                }
            }
        }
        return order.compactMap { accounts[$0] }
    }

    /// `collectLimitNotices`: hubs and providers that could not be read.
    public static func notices(_ environments: [UsageLimitsEnvironment]) -> [String] {
        func label(_ env: String, _ subject: String) -> String { environments.count > 1 ? "\(env) · \(subject)" : subject }
        var out: [String] = []
        for env in environments {
            for p in providersWithLimits(env.providers) {
                if p.usageLimits?.unavailableReason == "unsupported" { continue }
                let display = p.displayName?.trimmingCharacters(in: .whitespaces)
                let name = display?.isEmpty == false ? display! : p.driver
                if let limits = p.usageLimits, let n = notice(limits) { out.append("\(label(env.label, name)): \(n)") }
            }
            for s in env.sources {
                if let error = s.error { out.append("\(label(env.label, s.label)): \(error)") }
                else if s.accounts.isEmpty { out.append("\(label(env.label, s.label)): No accounts reported.") }
            }
        }
        return out
    }

    /// `remainingPercent`: quota left, 0...100.
    public static func remainingPercent(_ w: UsageLimitWindow) -> Int { Int(UsageFormat.jsRound(100 - max(0, min(100, w.usedPercent)))) }

    /// `elapsedShare`: how far into the window the clock is, 0...1, or nil without a length or reset.
    public static func elapsedShare(_ w: UsageLimitWindow, nowMs: Int64) -> Double? {
        guard let reset = w.resetMs, let mins = w.windowDurationMins else { return nil }
        let length = mins * 60_000
        guard length > 0 else { return nil }
        return max(0, min(1, (length - Double(reset - nowMs)) / length))
    }

    static func pace(used: Double, elapsed: Double) -> UsageLimitPace {
        let gap = used - elapsed * 100
        return gap > 5 ? .ahead : gap < -5 ? .under : .on
    }

    /// `paceOf`: within five points of the clock is on pace.
    public static func pace(_ w: UsageLimitWindow, nowMs: Int64) -> UsageLimitPace? {
        elapsedShare(w, nowMs: nowMs).map { pace(used: w.usedPercent, elapsed: $0) }
    }

    /// `formatDuration`: `2h 13m`, `3d 4h`, `12m`.
    public static func duration(_ ms: Double) -> String {
        let r = max(0, ms)
        let days = Int(r / 86_400_000), hours = Int(r.truncatingRemainder(dividingBy: 86_400_000) / 3_600_000)
        let minutes = Int(r.truncatingRemainder(dividingBy: 3_600_000) / 60_000)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// `formatResetsIn` (packages/shared/src/usageLimits.ts:606-613 in 2994): "Resets momentarily" in the
    /// last minute, where "resets in 0m" used to show (262532709). T3 capitalizes only that one.
    public static func resetsIn(_ w: UsageLimitWindow, nowMs: Int64) -> String? {
        guard let reset = w.resetMs else { return nil }
        if reset <= nowMs { return "resets now" }
        if reset - nowMs < 60_000 { return "Resets momentarily" }
        return "resets in \(duration(Double(reset - nowMs)))"
    }

    /// `resetCreditsSummary`.
    public static func resetCreditsSummary(_ c: UsageResetCredits, nowMs: Int64, compact: Bool = false) -> String {
        let expiresIn = c.nextExpiresAt.flatMap(T3Timestamp.parseEpochMs).map { duration(Double($0 - nowMs)) }
        if c.availableCount == 0 { return "No reset credits banked" }
        if compact { return "\(c.availableCount) banked" + (expiresIn.map { " · expires in \($0)" } ?? "") }
        return "\(c.availableCount) \(c.availableCount == 1 ? "reset credit" : "reset credits") banked" + (expiresIn.map { " · next expires in \($0)" } ?? "")
    }

    /// `collectLimitPools` (usageLimits.ts:386-417): accounts by driver, ordered by the session reset.
    public static func pools(_ accounts: [UsageLimitAccount], nowMs: Int64) -> [UsageLimitPool] {
        var drivers: [String] = []
        var byDriver: [String: [UsageLimitAccount]] = [:]
        for a in accounts {
            if byDriver[a.driver] == nil { drivers.append(a.driver) }
            byDriver[a.driver, default: []].append(a)
        }
        return drivers.map { driver in
            let members = byDriver[driver]!
            let orderWindow = members.flatMap(\.limits.windows).enumerated()
                .min { l, r in (kindOrder[l.element.kind] ?? 3, l.offset) < (kindOrder[r.element.kind] ?? 3, r.offset) }?.element
            // The next refill, which for an account out of weekly quota is when its session is usable again.
            func orderReset(_ a: UsageLimitAccount) -> Double {
                guard let o = orderWindow, let w = a.limits.windows.first(where: { $0.kind == o.kind && $0.id == o.id }),
                      let at = poolMember(a, w, nowMs: nowMs).window.resetMs else {
                    return .infinity
                }
                return Double(at)
            }
            func sortName(_ a: UsageLimitAccount) -> String { (a.displayName ?? a.email ?? a.key).lowercased() }
            let sorted = members.enumerated().sorted { l, r in
                let a = orderReset(l.element), b = orderReset(r.element)
                if a != b { return a < b }
                let na = sortName(l.element), nb = sortName(r.element)
                if na != nb { return na.localizedCompare(nb) == .orderedAscending }
                if l.element.key != r.element.key { return l.element.key < r.element.key }
                return l.offset < r.offset
            }.map(\.element)
            return UsageLimitPool(driver: driver, accounts: sorted, windows: poolWindows(sorted, nowMs: nowMs))
        }
    }

    /// `poolMember` (usageLimits.ts:416-457, T3 5b72385065): with no weekly quota left (Claude's `seven_day`, Codex's
    /// weekly window) an account's session shows 0% left. Its refill depends on both resets: a spent session must also
    /// reset, and a partly spent one only gets its unused part back when the week resets. A stale or missing reset
    /// time gives no estimate.
    static func poolMember(_ account: UsageLimitAccount, _ reported: UsageLimitWindow, nowMs: Int64)
        -> (window: UsageLimitWindow, refillPercent: Double) {
        let spentWeekly = reported.kind == "session" ? account.limits.windows.first { w in
            w.usedPercent >= 100 && (account.driver == "claudeAgent" ? w.id == "seven_day" : account.driver == "codex" && w.kind == "weekly")
        } : nil
        guard let spentWeekly else { return (reported, reported.usedPercent) }
        var resetsAt: String?
        var refill: Double = 0
        // `Date.parse` of a bad checkedAt is NaN, and every comparison with it fails.
        if let weekly = spentWeekly.resetMs, let session = reported.resetMs, let checked = T3Timestamp.parseEpochMs(account.limits.checkedAt) {
            let cutoff = max(nowMs, checked)
            if weekly > cutoff && session > cutoff {
                if session <= weekly {
                    resetsAt = spentWeekly.resetsAt; refill = 100
                } else if reported.usedPercent >= 100 {
                    resetsAt = reported.resetsAt; refill = 100
                } else {
                    resetsAt = spentWeekly.resetsAt; refill = 100 - max(0, min(100, reported.usedPercent))
                }
            }
        }
        // Suppression is not session spending, so it has no session pace clock.
        var window = reported
        window.usedPercent = 100
        window.resetsAt = resetsAt
        window.windowDurationMins = nil
        return (window, refill)
    }

    static func poolWindows(_ accounts: [UsageLimitAccount], nowMs: Int64) -> [UsageLimitPoolWindow] {
        var keys: [String] = []
        var byKey: [String: [(account: UsageLimitAccount, window: UsageLimitWindow, refill: Double)]] = [:]
        for a in accounts {
            for reported in a.limits.windows {
                let (w, refill) = poolMember(a, reported, nowMs: nowMs)
                let key = "\(w.kind):\(w.id)"
                if byKey[key] == nil { keys.append(key) }
                byKey[key, default: []].append((a, w, refill))
            }
        }
        let pools = keys.map { key -> UsageLimitPoolWindow in
            let members = byKey[key]!
            let first = members[0].window
            let used = members.reduce(0) { $0 + $1.window.usedPercent } / Double(members.count)
            let timed = members.compactMap { m in elapsedShare(m.window, nowMs: nowMs).map { (used: m.window.usedPercent, elapsed: $0) } }
            let timedUsed = timed.reduce(0) { $0 + $1.used } / Double(max(1, timed.count))
            let meanElapsed = timed.isEmpty ? nil : timed.reduce(0) { $0 + $1.elapsed } / Double(timed.count)
            let resets = members.compactMap { m -> UsageLimitPoolWindow.Reset? in
                guard let at = m.window.resetMs else { return nil }
                return .init(account: m.account, window: m.window, at: at,
                             restoresPercent: Int(UsageFormat.jsRound(m.refill / Double(members.count))))
            }.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
            return UsageLimitPoolWindow(
                id: first.id, kind: first.kind, label: first.label,
                columns: accounts.map { a in
                    let m = members.first { $0.account.key == a.key }
                    return .init(account: a, window: m?.window, refillPercent: m?.refill ?? 0)
                },
                remainingPercent: Int(UsageFormat.jsRound(100 - used)), usedPercent: Int(UsageFormat.jsRound(used)),
                pace: meanElapsed.map { pace(used: timedUsed, elapsed: $0) }, resets: resets)
        }
        return pools.enumerated().sorted { l, r in
            (kindOrder[l.element.kind] ?? 3, l.offset) < (kindOrder[r.element.kind] ?? 3, r.offset)
        }.map(\.element)
    }

    /// `displayLimitWindows`: Cursor's two pools instead of the combined figure when both are there.
    public static func displayWindows(_ pool: UsageLimitPool) -> [UsageLimitPoolWindow] {
        guard pool.driver == "cursor" else { return pool.windows }
        let both = pool.windows.contains { $0.id == "autoPercentUsed" } && pool.windows.contains { $0.id == "apiPercentUsed" }
        func rank(_ id: String) -> Int { cursorWindows.firstIndex { $0.id == id } ?? cursorWindows.count }
        return pool.windows.filter { !both || $0.id != "totalPercentUsed" }.enumerated()
            .sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }.map(\.element)
    }

    /// `hasProviderUsageLimits`: whether Limits has anything to say about this driver.
    public static func hasLimits(driver: String, providers: [ServerProvider], sources: [UsageLimitSourceSnapshot]) -> Bool {
        providersWithLimits(providers).contains { $0.driver == driver }
            || sources.contains { s in s.accounts.contains { $0.driver == driver } || (s.error != nil && s.accounts.isEmpty) }
    }

    /// `isUsageLimitsCommand`.
    public static func isUsageLimitsCommand(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/usage-limits"
    }

    /// `collectProviderUsageLimits` (usageLimits.ts:611-729): a point-in-time report for one instance.
    public static func report(instanceId: String, providers: [ServerProvider], sources: [UsageLimitSourceSnapshot], nowMs: Int64) -> UsageLimitsReport? {
        guard let selected = providers.first(where: { $0.instanceId.rawValue == instanceId }),
              hasLimits(driver: selected.driver, providers: providers, sources: sources) else { return nil }
        let resolveKey = accountKeyResolver(providers.filter(\.enabled).map(AccountReport.init) + sources.flatMap(\.accounts).map(AccountReport.init))
        // One account on several instances counts once (usageLimits.ts:669-697, T3 780b62dd26): a usable reading beats
        // one with a notice, else the fresher one wins, and the freshest reading with reset credits supplies them.
        typealias Snapshot = (provider: ServerProvider, limits: ProviderUsageLimits)
        var order: [String] = []
        var byAccount: [String: (usage: Snapshot, credits: Snapshot?)] = [:]
        for p in providersWithLimits(providers) where p.driver == selected.driver {
            guard let limits = p.usageLimits else { continue }
            let snapshot: Snapshot = (p, limits)
            let key = resolveKey(AccountReport(p)) ?? "instance:\(p.instanceId.rawValue)"
            let previous = byAccount[key]
            let previousUsable = previous.map { notice($0.usage.limits) == nil } ?? false
            let usable = notice(limits) == nil
            let wins = previous.map { (usable && !previousUsable) || (usable == previousUsable && limits.checkedMs > $0.usage.limits.checkedMs) } ?? true
            let previousCredits = previous?.credits ?? nil
            let credits = limits.resetCredits != nil && previousCredits.map({ limits.checkedMs > $0.limits.checkedMs }) ?? true
                ? snapshot : previousCredits
            if previous == nil { order.append(key) }
            byAccount[key] = (wins ? snapshot : previous!.usage, credits)
        }
        let native = order.compactMap { byAccount[$0] }
        let nativeAccounts = Set(native.compactMap { n -> String? in
            guard let key = resolveKey(AccountReport(n.usage.provider)), !n.usage.limits.windows.isEmpty,
                  n.usage.limits.unavailableReason == nil else { return nil }
            return key
        })
        var accounts: [UsageLimitsReport.Account] = []
        var notices: [String] = []
        for (usage, credits) in native {
            let p = usage.provider, limits = usage.limits
            let key = resolveKey(AccountReport(p))
            let hub = sources.flatMap { s in s.accounts.map { (source: s, account: $0) } }
                .filter { key != nil && resolveKey(AccountReport($0.account)) == key
                    && $0.account.usageLimits.resetCredits != nil && notice($0.account.usageLimits) == nil }
                .enumerated().sorted { ($1.element.account.usageLimits.checkedMs, $0.offset) < ($0.element.account.usageLimits.checkedMs, $1.offset) }
                .first?.element
            let hubCreditId = hub?.account.usageLimits.resetCredits?.nextCreditId
            let showHubCredits = hub.map { h in credits.map { h.account.usageLimits.checkedMs > $0.limits.checkedMs } ?? true } ?? false
            let display = p.displayName?.trimmingCharacters(in: .whitespaces)
            var shown = limits
            if let c = showHubCredits ? hub?.account.usageLimits.resetCredits : credits?.limits.resetCredits { shown.resetCredits = c }
            accounts.append(.init(
                id: p.instanceId.rawValue, driver: p.driver,
                label: "\(display?.isEmpty == false ? display! : p.driver) [\(p.instanceId.rawValue)]",
                plan: authLabel(p).flatMap { $0.isEmpty ? nil : $0 }, email: authEmail(p), sourceLabel: nil, instanceId: p.instanceId.rawValue,
                resetCreditTarget: hubCreditId.flatMap { id in hub.map { .hub(sourceId: $0.source.id, accountId: $0.account.id, creditId: id) } }
                    ?? .instance(credits?.provider.instanceId.rawValue ?? p.instanceId.rawValue),
                displayName: p.displayName.flatMap { $0.isEmpty ? nil : $0 }, accentColor: p.accentColor.flatMap { $0.isEmpty ? nil : $0 }, limits: shown))
        }
        for s in sources {
            let matching = s.accounts.filter { $0.driver == selected.driver }
            for a in matching {
                if let key = resolveKey(AccountReport(a)), nativeAccounts.contains(key) { continue }
                accounts.append(.init(
                    id: "\(s.id):\(a.id)", driver: a.driver, label: "\(s.label) · \(a.id)", plan: a.plan, email: a.email, sourceLabel: "CLI Proxy",
                    instanceId: nil,
                    resetCreditTarget: a.usageLimits.resetCredits?.nextCreditId.map { .hub(sourceId: s.id, accountId: a.id, creditId: $0) },
                    displayName: nil, accentColor: nil, limits: a.usageLimits))
            }
            if let error = s.error, !matching.isEmpty || s.accounts.isEmpty { notices.append("\(s.label): \(error)") }
        }
        return UsageLimitsReport(createdAt: UsageFormat.isoString(nowMs), accounts: accounts, notices: notices)
    }

    /// `accountLabel` (ComposerUsageLimits.tsx:13-24): the driver, then the instance when it adds something.
    public static func reportAccountLabel(_ a: UsageLimitsReport.Account, driverLabel: String) -> String {
        guard let instanceId = a.instanceId else { return a.label }
        let display = a.displayName?.trimmingCharacters(in: .whitespaces)
        let instance = display?.isEmpty == false ? display! : (instanceId != a.driver ? instanceId : "")
        return !instance.isEmpty && instance.lowercased() != driverLabel.lowercased() ? "\(driverLabel) · \(instance)" : driverLabel
    }

    /// `accountInitials`: `someone@example.com` to `SE`.
    public static func accountInitials(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let s = "\(parts.first?.first.map(String.init) ?? "")\(parts.count > 1 ? parts[1].first.map(String.init) ?? "" : "")".uppercased()
        return s.isEmpty ? "?" : s
    }

    /// `accountHue`: a stable hue per address, JS `(hash * 31 + code) | 0` over UTF-16 units.
    public static func accountHue(_ email: String) -> Int {
        var hash: Int32 = 0
        for u in email.utf16 { hash = hash &* 31 &+ Int32(u) }
        return Int(abs(Int64(hash)) % 360)
    }
}
