import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The `provider.consumeResetCredit` flow: confirm, redeem, then T3's outcome line (UsageLimits.tsx:205-290).
@MainActor
enum UsageResetCredit {
    static func outcomeText(_ outcome: String) -> String {
        switch outcome {
        case "reset": "Reset applied. Your windows have cleared."
        case "nothingToReset": "Nothing to reset right now."
        case "noCredit": "No reset credit left."
        case "alreadyRedeemed": "That credit was already redeemed."
        default: outcome
        }
    }

    /// Redeeming spends a credit the provider granted, so it never fires on a bare click.
    static func confirmAndUse(in window: NSWindow?, environments: Environments, environmentId: String, target: UsageResetCreditTarget,
                              update: @escaping @MainActor (_ busy: Bool, _ status: String?) -> Void) {
        guard let window else { return }
        let d = DialogView(kind: .alertDialog, title: "Use a reset credit?",
                           message: "This redeems one credit on your account and clears the current rate-limit windows. It cannot be undone.")
        let cancel = ButtonView("Cancel", variant: .outline)
        let use = ButtonView("Use credit")
        d.footerButtons = [cancel, use]
        let host = ModalHost.present(d, in: window)
        cancel.action = { [weak host] in host?.close() }
        use.action = { [weak host] in
            host?.close()
            update(true, nil)
            Task {
                do {
                    let r = try await environments.request(environmentId, "provider.consumeResetCredit", target.payload)
                    update(false, r["warning"]?.stringValue ?? outcomeText(r["outcome"]?.stringValue ?? ""))
                } catch {
                    update(false, (error as? LocalizedError)?.errorDescription ?? "Could not use the reset credit.")
                }
            }
        }
    }
}

/// Usage (`/usage`, UsagePage.tsx and state/usage.ts): asks every selected environment for its summary of the
/// window (`server.getUsageSummary`, then once more with `awaitRefresh` while a slow source refreshes), merges
/// them, and draws Cost, Tokens or Limits. Limits read each environment's providers and hubs from its config
/// and refresh them through `server.refreshProviders`, at most every five minutes automatically.
@MainActor
final class UsageController {
    let page = UsagePageView()
    private let environments: Environments
    private weak var composer: ComposerController?
    private weak var window: NSWindow?
    var onBack: (() -> Void)?

    private static let preferencesKey = "usagePage.preferences.v1"
    private var preferences: UsagePageOptions.Preferences
    private var window_ = UsageFormat.makeWindow(days: 30)
    private var selectedIds: Set<String>?
    private var breakdown = "model"
    private var selectedModelKey: String?
    private var refreshing = false
    private var limitsNowMs = TimestampFormat.nowMs()

    /// One environment's answer for one window (`EnvironmentUsageStatus`).
    struct Status {
        var summary: UsageSummary?
        var pending = false
        var error: String?
        var fetchedAt = Date.distantPast
    }
    private var statuses: [String: [UsageWindow: Status]] = [:]
    /// The last merged answer, kept on screen (muted) while a new window loads.
    private var shown: (window: UsageWindow, merged: MergedUsage, selection: Set<String>?, hidden: [UsageProviderKind])?
    private var limitsRefreshAfter: [String: Date] = [:]
    private var limitsRefreshing: Set<String> = []
    private var isVisible = false

    init(environments: Environments, composer: ComposerController?, window: NSWindow?) {
        self.environments = environments
        self.composer = composer
        self.window = window
        let saved = (UserDefaults.standard.data(forKey: Self.preferencesKey)).flatMap { try? JSONValue(parsing: $0) }
        preferences = UsagePageOptions.Preferences(json: saved)
        window_ = Self.window(for: preferences.windowDays)
        page.onMetric = { [weak self] m in self?.selectMetric(m) }
        page.onWindow = { [weak self] d in self?.selectWindow(d) }
        page.onRefresh = { [weak self] in self?.refreshWindow() }
        page.onEnvironmentMenu = { [weak self] trigger in self?.showEnvironmentMenu(trigger) }
        page.onProviderMenu = { [weak self] trigger in self?.showProviderMenu(trigger) }
        page.onBreakdown = { [weak self] b in self?.breakdown = b; self?.render() }
        page.onSelectModel = { [weak self] key in self?.openModel(key) }
        page.onEnableCursor = { [weak self] env in self?.enableCursor(env) }
        page.limits.onUseReset = { [weak self] account in self?.useReset(account) }
        page.limits.onOpenURL = { url in if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        composer?.configObservers.append { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.render()
        }
        _ = environments.observe { [weak self] in
            guard let self, self.isVisible else { return }
            self.load()
            self.render()
        }
    }

    static func window(for days: Int) -> UsageWindow { UsageFormat.makeWindow(days: days, resolution: days == 1 ? "hour" : "day") }

    // MARK: Lifecycle

    func didShow() {
        isVisible = true
        if preferences.metric == "limits" { limitsNowMs = TimestampFormat.nowMs() }
        load()
        render()
        if preferences.metric == "limits" { refreshLimits(automatic: true) }
        page.scrollToTop()
    }

    func didHide() { isVisible = false }

    private var allIds: [String] { environments.environmentIds }
    private var selected: [String] { allIds.filter { selectedIds?.contains($0) ?? true } }
    private func label(_ id: String) -> String { environments.label(id) ?? id }
    private func connected(_ id: String) -> Bool { environments.state(id)?.status == .connected }
    private var hidden: Set<UsageProviderKind> { Set(preferences.hiddenProviders) }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences.json) { UserDefaults.standard.set(data, forKey: Self.preferencesKey) }
    }

    // MARK: Loading

    /// Asks each selected, connected environment that has no fresh answer for the window (60s stale time).
    private func load(force: Bool = false) {
        guard preferences.metric != "limits" else { return }
        let w = window_
        for id in selected where connected(id) {
            var s = statuses[id]?[w] ?? Status()
            if s.pending || (!force && s.summary != nil && Date().timeIntervalSince(s.fetchedAt) < 60) { continue }
            s.pending = true
            statuses[id, default: [:]][w] = s
            fetch(id, w, awaitRefresh: false)
        }
    }

    private func fetch(_ id: String, _ w: UsageWindow, awaitRefresh: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let json = try await self.environments.request(id, "server.getUsageSummary", w.payload(awaitRefresh: awaitRefresh))
                var s = self.statuses[id]?[w] ?? Status()
                let summary = UsageSummary(json: json)
                s.summary = summary ?? s.summary
                s.error = summary == nil ? "This environment could not report usage." : nil
                s.fetchedAt = Date()
                // A slow source answered from its cache: show it, and wait for the refreshed one.
                let follow = !awaitRefresh && summary?.hasRefreshingSource == true
                s.pending = follow
                self.statuses[id, default: [:]][w] = s
                if follow { self.fetch(id, w, awaitRefresh: true) }
            } catch {
                var s = self.statuses[id]?[w] ?? Status()
                s.pending = false
                if awaitRefresh, s.summary != nil {
                    // The cached summary is still the best data.
                } else {
                    let text = "\(error)"
                    s.error = text.contains("EnvironmentAuthorizationError") ? "This connection does not have access to diagnostics and usage."
                        : "This environment could not report usage."
                }
                self.statuses[id, default: [:]][w] = s
            }
            self.render()
        }
    }

    // MARK: Choices

    private func selectMetric(_ m: String) {
        if m == "limits" { limitsNowMs = TimestampFormat.nowMs() }
        preferences.metric = m
        savePreferences()
        load()
        render()
        if m == "limits" { refreshLimits(automatic: true) }
    }

    private func selectWindow(_ days: Int) {
        guard UsagePageOptions.windows.contains(where: { $0.days == days }) else { return }
        preferences.windowDays = days
        savePreferences()
        window_ = Self.window(for: days)
        load()
        render()
    }

    /// Refresh: rescan with fresh rates on the selected environments, or re-check every provider and hub on Limits.
    private func refreshWindow() {
        guard !refreshing else { return }
        refreshing = true
        render()
        if preferences.metric == "limits" {
            refreshLimits(automatic: false) { [weak self] in self?.refreshing = false; self?.limitsNowMs = TimestampFormat.nowMs(); self?.render() }
            return
        }
        let next = Self.window(for: preferences.windowDays)
        if next != window_ { window_ = next }
        let w = window_
        let ids = selected.filter(connected)
        Task { [weak self] in
            guard let self else { return }
            // ponytail: environments refresh one after another; run them concurrently if several slow scans add up
            for id in ids {
                do {
                        _ = try? await self.environments.request(id, "server.refreshUsageRates", .object([:]))
                        var s = self.statuses[id]?[w] ?? Status()
                        s.pending = true
                        self.statuses[id, default: [:]][w] = s
                        do {
                            let json = try await self.environments.request(id, "server.getUsageSummary", w.payload(awaitRefresh: true))
                            s.summary = UsageSummary(json: json) ?? s.summary
                            s.error = nil
                            s.fetchedAt = Date()
                        } catch { s.error = "This environment could not report usage." }
                        s.pending = false
                        self.statuses[id, default: [:]][w] = s
                }
            }
            self.refreshing = false
            self.render()
        }
    }

    /// `refreshUsageLimits`: one check per environment at a time, automatic checks at most every five minutes.
    private func refreshLimits(automatic: Bool, done: (() -> Void)? = nil) {
        let ids = selected.filter(connected)
        let now = Date()
        let due = ids.filter { !limitsRefreshing.contains($0) && (!automatic || now >= (limitsRefreshAfter[$0] ?? .distantPast)) }
        guard !due.isEmpty else { done?(); return }
        due.forEach { limitsRefreshing.insert($0) }
        Task { [weak self] in
            guard let self else { return }
            for id in due {
                _ = try? await self.environments.request(id, "server.refreshProviders", .object([:]))
                self.limitsRefreshing.remove(id)
                self.limitsRefreshAfter[id] = Date().addingTimeInterval(5 * 60)
            }
            self.limitsNowMs = TimestampFormat.nowMs()
            done?()
            self.render()
        }
    }

    // MARK: Model

    private struct EnvStatus {
        var id: String, label: String, connected: Bool, status: Status?
    }

    private func envStatuses() -> [EnvStatus] {
        allIds.map { EnvStatus(id: $0, label: label($0), connected: connected($0), status: statuses[$0]?[window_]) }
    }

    func render() {
        guard isVisible else { return }
        var m = UsagePageView.Model()
        m.metric = preferences.metric
        m.windowDays = preferences.windowDays
        let all = envStatuses()
        let chosen = all.filter { selectedIds?.contains($0.id) ?? true }
        m.environmentLabel = UsagePageOptions.environmentFilterLabel(allSelected: selectedIds == nil, selectedLabels: chosen.map(\.label))
        m.providerLabel = UsagePageOptions.providerFilterLabel(hidden: hidden)
        m.refreshing = refreshing
        m.shortcutTitles = shortcutTitles()
        let limits = preferences.metric == "limits"
        if all.isEmpty || chosen.isEmpty {
            m.body = .message(all.isEmpty ? "Connect an environment to see \(limits ? "limits" : "usage")."
                              : "Select an environment to see \(limits ? "limits" : "usage").")
        } else if limits {
            m.body = .limits
            page.limits.model = limitsModel(chosen.map(\.id))
        }
        // Usage: merge whatever answered, hidden providers left out.
        let answered = chosen.compactMap { e -> EnvironmentUsage? in
            guard let s = e.status?.summary else { return nil }
            return EnvironmentUsage(environmentId: e.id, label: e.label, summary: UsageMerge.withoutProviders(s, hidden))
        }
        let merged = UsageMerge.merge(answered)
        let stillReporting = chosen.filter { $0.connected && $0.status?.summary == nil && $0.status?.error == nil }
        let pendingAll = answered.isEmpty && !stillReporting.isEmpty
        let hiddenList = preferences.hiddenProviders
        var shownWindow = window_, shownMerged = merged, keptOld = false
        if !answered.isEmpty {
            shown = (window_, merged, selectedIds, hiddenList)
        } else if let s = shown, s.selection == selectedIds, s.hidden == hiddenList, pendingAll {
            shownWindow = s.window; shownMerged = s.merged; keptOld = true
        }
        m.environmentIssue = chosen.contains { $0.status?.error != nil } || !merged.contractMismatches.isEmpty
        if !limits, !(all.isEmpty || chosen.isEmpty) {
            let errored = chosen.filter { $0.status?.error != nil }
            if pendingAll && !keptOld { m.body = .skeleton }
            else if answered.isEmpty && !errored.isEmpty && stillReporting.isEmpty {
                m.body = .errors(errored.map { (chosen.count > 1 ? "\($0.label): " : "") + ($0.status?.error ?? "") })
            } else { m.body = .usage }
        }
        m.windowLabel = UsagePageOptions.windowLabel(shownWindow)
        m.merged = shownMerged
        m.window = shownWindow
        // `usageLoadingState`: a summary that has not answered, or a manual refresh, mutes everything.
        let everyLoading = keptOld || refreshing || chosen.contains { $0.connected && $0.status?.error == nil && ($0.status?.summary == nil) }
        var loadingProviders = Set<UsageProviderKind>()
        for e in chosen where e.status?.pending == true {
            for src in e.status?.summary?.sources ?? [] where src.refreshing && !hidden.contains(src.fingerprint.provider) { loadingProviders.insert(src.fingerprint.provider) }
        }
        m.everyProviderLoading = everyLoading
        m.loadingProviders = loadingProviders
        m.partial = everyLoading || !loadingProviders.isEmpty
        m.providersWithData = UsageMerge.providersWithUsage(shownMerged.providers)
        m.activeProviders = UsageProviderKind.allCases.filter { m.providersWithData.contains($0) || loadingProviders.contains($0) }
        m.sourceMessages = Array(NSOrderedSet(array: chosen.flatMap { e in
            (e.status?.summary?.sources ?? []).compactMap { s -> String? in
                guard let msg = s.message, s.action == nil, !hidden.contains(s.fingerprint.provider),
                      s.status == "partial" || s.status == "failed" || s.fingerprint.provider == .cursor else { return nil }
                return msg
            }
        })) as? [String] ?? []
        let cursor = hidden.contains(.cursor) ? [] : cursorEnvironments(chosen)
        m.cursorRows = cursor.map { ($0.id, $0.label) }
        m.cursorShowsEnvironment = chosen.count > 1
        m.breakdown = breakdown
        m.refreshEnabled = true
        page.model = m
    }

    /// `cursorKeychainAccessEnvironments`: offer Keychain access where a ready Cursor provider could use it,
    /// unless some environment already reads a Cursor account.
    private func cursorEnvironments(_ chosen: [EnvStatus]) -> [EnvStatus] {
        let hasAccount = chosen.contains { $0.status?.summary?.sources.contains { $0.fingerprint.provider == .cursor && $0.fingerprint.hostId == "cursor.com" } == true }
        guard !hasAccount else { return [] }
        return chosen.filter { e in
            e.status?.summary?.sources.contains { $0.action == "enableCursorKeychain" } == true
                && (composer?.allConfigs[e.id]?.providers.contains { $0.driver == "cursor" && $0.status == .ready } ?? false)
        }
    }

    private func limitsModel(_ ids: [String]) -> UsageLimitsModel {
        let hiddenDrivers = Set(hidden.map(\.driverKind))
        let envs = ids.compactMap { id -> UsageLimitsEnvironment? in
            guard connected(id), let config = composer?.allConfigs[id] else { return nil }
            // Hidden drivers leave native and hub accounts alike; a hub left with nothing visible goes.
            let providers = config.providers.filter { !hiddenDrivers.contains($0.driver) }
            let sources = config.usageLimitSources.compactMap { s -> UsageLimitSourceSnapshot? in
                var s = s
                let accounts = s.accounts.filter { !hiddenDrivers.contains($0.driver) }
                if accounts.isEmpty && !s.accounts.isEmpty { return nil }
                s.accounts = accounts
                return s
            }
            return UsageLimitsEnvironment(environmentId: id, label: label(id), providers: providers, sources: sources)
        }
        var lm = UsageLimitsModel()
        lm.pools = UsageLimitsLogic.pools(UsageLimitsLogic.accounts(envs), nowMs: limitsNowMs)
        lm.notices = UsageLimitsLogic.notices(envs)
        lm.externalLinks = UsageLimitsLogic.externalUsageLinks(envs)
        lm.nowMs = limitsNowMs
        let chosen = envStatuses().filter { ids.contains($0.id) }
        lm.cursorPrompt = hidden.contains(.cursor) ? [] : cursorEnvironments(chosen).map { ($0.id, $0.label) }
        return lm
    }

    private func shortcutTitles() -> [String: String] {
        var out: [String: String] = [:]
        let options: [(String, String)] = UsagePageOptions.metrics.map { ($0.command, $0.label) } + UsagePageOptions.windows.map { ($0.command, $0.label) }
        for (command, label) in options {
            let shortcut = ActiveKeymap.label(for: command, context: KeybindingContext(["usagePageOpen": true]))
            out[command] = shortcut.map { "\(label) (\($0))" } ?? label
        }
        return out
    }

    // MARK: Menus and dialogs

    /// `UsageEnvironmentFilter`: All environments, each environment with its scan status, coverage notes, Model prices.
    private func showEnvironmentMenu(_ trigger: NSView) {
        let usage = preferences.metric != "limits"
        let all = envStatuses()
        var items: [MenuItem] = []
        var allItem = MenuItem.checkbox("All environments", checked: selectedIds == nil) { [weak self] on in
            self?.selectedIds = on ? nil : []
            self?.afterSelection()
        }
        allItem.keepsOpen = true
        items.append(allItem)
        items.append(.separator)
        for e in all {
            let status: String = e.status?.error != nil ? "Unavailable"
                : e.status?.summary.map { !UsageMerge.isCompatible($0.contractVersion) } == true ? "Update required"
                : !e.connected ? "Connecting…"
                : e.status?.summary == nil ? "Scanning…"
                : refreshing ? "Refreshing…"
                : e.status?.pending == true ? updating(e.status?.summary) : "Ready"
            var item = MenuItem.checkbox(e.label, checked: selectedIds?.contains(e.id) ?? true) { [weak self] on in
                guard let self else { return }
                var next = Set(self.selected)
                if on { next.insert(e.id) } else { next.remove(e.id) }
                self.selectedIds = next.count == self.allIds.count ? nil : next
                self.afterSelection()
            }
            if usage { item.subtitle = status }
            items.append(item)
        }
        if all.isEmpty { items.append(.note("No environments connected.")) }
        if usage {
            let chosen = all.filter { selectedIds?.contains($0.id) ?? true }
            if chosen.contains(where: { $0.connected && $0.status?.summary == nil && $0.status?.error == nil }) && chosen.contains(where: { $0.status?.summary != nil }) {
                items.append(.note("Totals are partial while selected environments scan."))
            }
            let merged = page.model.merged
            for e in chosen { if let err = e.status?.error { items.append(.note("\(e.label): \(err)")) } }
            for mm in merged.contractMismatches { items.append(.note(UsageFormat.contractMismatch(label(mm.environmentId), direction: mm.direction))) }
            if !merged.duplicateSources.isEmpty {
                items.append(.note("Counted once across environments sharing a transcript directory: \(merged.duplicateSources.joined(separator: ", "))"))
            }
        }
        items.append(.separator)
        items.append(MenuItem("Model prices", icon: .slidersHorizontal) { [weak self] in self?.openPrices(model: nil) })
        MenuPopupView.show(items, from: trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none))
    }

    private func updating(_ summary: UsageSummary?) -> String {
        let providers = Array(NSOrderedSet(array: (summary?.sources ?? []).filter(\.refreshing).map(\.fingerprint.provider.rawValue))) as? [String] ?? []
        if providers.isEmpty { return "Refreshing…" }
        return providers.count == 1 ? "Updating \(UsageProviderKind(rawValue: providers[0])?.label ?? providers[0])…" : "Updating \(providers.count) providers…"
    }

    private func afterSelection() {
        shown = nil
        load()
        render()
        if preferences.metric == "limits" { refreshLimits(automatic: true) }
    }

    /// `UsageProviderFilter`: provider visibility, stored as the hidden set.
    private func showProviderMenu(_ trigger: NSView) {
        let order = UsageProviderKind.allCases
        var items: [MenuItem] = []
        var allItem = MenuItem.checkbox("All providers", checked: hidden.isEmpty) { [weak self] on in
            self?.setHidden(on ? [] : order)
        }
        allItem.keepsOpen = true
        items.append(allItem)
        items.append(.separator)
        for p in order {
            var item = MenuItem.checkbox(p.label, checked: !hidden.contains(p)) { [weak self] on in
                guard let self else { return }
                self.setHidden(order.filter { $0 == p ? !on : self.hidden.contains($0) })
            }
            item.keepsOpen = true
            items.append(item)
        }
        MenuPopupView.show(items, from: trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none))
    }

    private func setHidden(_ list: [UsageProviderKind]) {
        preferences.hiddenProviders = list
        savePreferences()
        shown = nil
        render()
    }

    private func presentDialog(_ d: DialogView) -> ModalHost? {
        guard let window else { return nil }
        let host = ModalHost.present(d, in: window)
        d.onClose = { [weak host] in host?.close() }
        return host
    }

    private func openModel(_ key: String) {
        guard preferences.metric != "limits", let model = page.model.merged.models.first(where: { $0.key == key }) else { return }
        selectedModelKey = key
        let chosen = envStatuses().filter { selectedIds?.contains($0.id) ?? true }
        let narrowed = chosen.compactMap { e -> EnvironmentUsage? in
            guard var s = e.status?.summary else { return nil }
            s.buckets = s.buckets.filter { $0.provider == model.provider && $0.model == model.model }
            return EnvironmentUsage(environmentId: e.id, label: e.label, summary: s)
        }
        var host: ModalHost?
        let d = UsageModelDialog.make(model: model, usage: UsageMerge.merge(narrowed), tokens: preferences.metric == "tokens", window: page.model.window) { [weak self] in
            host?.close()
            self?.openPrices(model: model.model)
        }
        host = presentDialog(d)
    }

    private func priceTargets() -> [UsagePriceTarget] {
        allIds.map { id in
            let config = composer?.allConfigs[id]
            return UsagePriceTarget.make(environmentId: id, label: label(id), connected: connected(id), settings: config?.settings.raw,
                                         capabilities: config?.capabilities ?? [], canWrite: true)
        }
    }

    /// `UsagePriceOverrides`, opened from Model prices or Set price.
    private func openPrices(model: String?) {
        let table = UsagePriceTableView(initialModel: model)
        table.targets = priceTargets()
        table.selectedIds = selectedIds
        table.dropInitialIfExisting()
        table.knownModels = Array(Set(statuses.values.flatMap { $0.values.compactMap(\.summary).flatMap { $0.buckets.map(\.model) } })).sorted()
        let d = DialogView(title: "Custom model prices", message: "Prices and mappings apply to all past and future usage on the environments you select.")
        d.maxWidth = 896
        let block = UsageDialogBlockHost(table)
        d.panelContent = [block]
        let discard = ButtonView("Discard changes", variant: .ghost)
        let save = ButtonView("Save changes")
        let note = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        note.lineHeight = 16
        d.footerVariant = .bare
        let host = presentDialog(d)
        let refreshFooter: @MainActor () -> Void = { [weak d, weak table] in
            guard let d, let table else { return }
            let failed = table.failedDestinations
            let has = !table.staged.isEmpty
            let sel = table.selected
            note.text = has ? "Changes apply to \(sel.count == 1 ? sel[0].label : "\(sel.count) environments")" : ""
            note.frame.size = NSSize(width: ceil(note.textWidth) + 1, height: 16)
            discard.title = failed.isEmpty ? "Discard changes" : "Discard pending changes"
            discard.isHidden = !has
            save.title = table.pending ? "Saving…" : failed.isEmpty ? "Save changes" : "Retry failed saves"
            save.isEnabled = !table.pending && (has || !failed.isEmpty) && (!failed.isEmpty || (table.errors.isEmpty && !sel.isEmpty))
            d.footerButtons = [UsageFixedSize(note)] + (has ? [discard] : []) + [save]
            d.footerLeadingCount = 1
            d.panelContent = [block]
        }
        table.onChange = refreshFooter
        table.onSelectEnvironments = { [weak self, weak table] trigger in
            guard let self, let table else { return }
            var items = [MenuItem.checkbox("All environments", checked: table.selectedIds == nil) { on in table.selectedIds = on ? nil : []; refreshFooter() }]
            items.append(.separator)
            for t in table.targets {
                var item = MenuItem.checkbox(t.label, checked: table.selectedIds?.contains(t.environmentId) ?? true) { on in
                    var next = Set(table.selected.map(\.environmentId))
                    if on { next.insert(t.environmentId) } else { next.remove(t.environmentId) }
                    table.selectedIds = next.count == table.targets.count ? nil : next
                    refreshFooter()
                }
                item.subtitle = t.unavailable
                items.append(item)
            }
            _ = self
            MenuPopupView.show(items, from: trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none))
        }
        discard.action = { [weak table] in table?.discard(); refreshFooter() }
        save.action = { [weak self, weak table] in
            guard let self, let table else { return }
            self.savePrices(table, retry: !table.failedDestinations.isEmpty, refreshFooter: refreshFooter)
        }
        _ = host
        refreshFooter()
    }

    /// `save`: each destination settles on its own; a retry writes only to the ones that failed.
    private func savePrices(_ table: UsagePriceTableView, retry: Bool, refreshFooter: @escaping @MainActor () -> Void) {
        let edits = retry ? table.attempt?.drafts ?? [] : table.staged
        let destinations: [(id: String, label: String)] = retry ? table.failedDestinations : table.selected.map { ($0.environmentId, $0.label) }
        guard !destinations.isEmpty, !edits.isEmpty else { return }
        var results = retry ? table.attempt?.results ?? [:] : [:]
        for d in destinations { results[d.id] = .some(nil) }
        table.attempt = (edits, retry ? table.attempt?.destinations ?? destinations : destinations, results)
        table.pending = true
        refreshFooter()
        let targets = priceTargets()
        Task { [weak self] in
            guard let self else { return }
            var failed = false
            for d in destinations {
                let target = targets.first { $0.environmentId == d.id } ?? UsagePriceTarget(environmentId: d.id, label: d.label, prices: nil, aliases: nil,
                                                                                            unavailable: "Environment removed")
                let plan = UsagePriceLogic.changes(target, edits)
                var result: String
                if let blocker = UsagePriceLogic.blocker(target, plan.changes) ?? plan.errors.values.first {
                    result = "failed:\(blocker)"
                } else if plan.changes.isEmpty {
                    result = "saved"
                } else {
                    do {
                        let r = try await self.environments.request(d.id, "server.updateSettings", .object(["patch": .object(UsagePriceLogic.patch(plan.changes))]))
                        self.composer?.applySettings(d.id, r)
                        result = "saved"
                    } catch { result = "failed:Could not save. Try again." }
                }
                if result.hasPrefix("failed:") { failed = true }
                if var a = table.attempt { a.results[d.id] = .some(result); table.attempt = a }
            }
            table.pending = false
            if !failed { table.clearDrafts() }
            table.targets = self.priceTargets()
            refreshFooter()
            self.render()
        }
    }

    private func enableCursor(_ env: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.environments.request(env, "server.updateSettings", .object(["patch": .object(["cursorKeychainUsageEnabled": .bool(true)])]))
                self.composer?.applySettings(env, r)
                self.load(force: true)
                self.limitsRefreshAfter[env] = nil
                self.refreshLimits(automatic: false)
            } catch {}
            self.render()
        }
    }

    private func useReset(_ account: UsageLimitAccount) {
        guard let redeem = account.redeem else { return }
        UsageResetCredit.confirmAndUse(in: window, environments: environments, environmentId: redeem.environmentId, target: redeem.target) { [weak self] _, status in
            if let status { self?.composer?.toastPublic(.info, status) }
            if status != nil { self?.refreshLimits(automatic: false) }
        }
    }

    // MARK: Keys

    /// `usage.cost` and friends while the page is open; periods do nothing on Limits.
    func handle(_ command: String) -> Bool {
        if let m = UsagePageOptions.metrics.first(where: { $0.command == command }) { selectMetric(m.value); return true }
        if let w = UsagePageOptions.windows.first(where: { $0.command == command }) {
            if preferences.metric != "limits" { selectWindow(w.days) }
            return true
        }
        return false
    }
}

/// A dialog panel child that takes its height from a price table's `height(forWidth:)`.
final class UsageDialogBlockHost: DSView {
    let table: UsagePriceTableView
    init(_ table: UsagePriceTableView) { self.table = table; super.init(frame: .zero); addSubview(table) }
    override var intrinsicContentSize: NSSize { table.intrinsicContentSize }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        table.frame = NSRect(origin: .zero, size: NSSize(width: newSize.width, height: table.intrinsicContentSize.height))
        invalidateIntrinsicContentSize()
    }
    override func layout() { super.layout(); table.frame = bounds }
}

/// A label kept at its frame size in a dialog footer.
final class UsageFixedSize: DSView {
    let content: NSView
    init(_ content: NSView) { self.content = content; super.init(frame: NSRect(origin: .zero, size: content.frame.size)); addSubview(content) }
    override var intrinsicContentSize: NSSize { content.frame.size }
    override func layout() { super.layout(); content.frame = bounds }
}
