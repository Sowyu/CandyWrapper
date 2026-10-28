import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Actual 3824 browser screens at 1100 × 780, cropped to the 1020 × 700 route panel.
/// Keep the component suites: they check states that the full-screen capture does not contain.
@MainActor @Suite(.fidelity)
struct SettingsScreensFidelityTests {
    // Reuse the established SettingsPages and Usage ceilings, without exceptions.
    static let ceilings: FidelityCeilings = [
        "settings": .init(0.05),
        "usage": .init(0.095),
    ]

    static let settingsCases: [(String, SettingsSection, CGFloat)] = [
        ("16a-settings-general", .general, 0),
        ("16b-settings-general-mid", .general, 0.5),
        ("16c-settings-general-bottom", .general, 1),
        ("17-settings-appearance", .appearance, 0),
        ("18-settings-providers", .providers, 0.45),
        ("19-settings-keybindings", .keybindings, 0),
        ("32-settings-source-control", .sourceControl, 0),
        ("33-settings-projects", .projects, 0),
        ("34-settings-connections", .connections, 0),
        ("35-settings-archived", .archive, 0),
        ("36-settings-scheduled-tasks", .scheduledTasks, 0),
        ("37-settings-snapshots", .snapShots, 0),
        ("38-settings-storage", .maintenance, 0),
        ("39-settings-diagnostics", .diagnostics, 0),
        ("40-settings-integrations", .browser, 0),
        ("49-settings-modal-general", .general, 0),
    ]

    static func context(dark: Bool = false) -> SettingsPageContext {
        let context = SettingsPageContext()
        context.desktopAvailable = false
        // The browser fixture uses T3's default order; CandyWrapper defaults to manual ordering.
        context.client = ClientSettings(decoding: .object(["sidebarProjectSortOrder": .string("updated_at")]))
        context.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(
            id: "sandbox", label: "miniko", machine: "mac-mini", settings: ServerSettingsValues(.object([:])),
            capabilities: ["threadAutoSettlement", "threadRestartContinuation", "projectSettingsOverrides", "storageCleanup", "storageCleanupRun"])], primaryId: "sandbox",
            projects: [SettingsScopeProject(key: "demo", displayName: "demo-repo", members: [
                .init(environmentId: "sandbox", projectId: "demo", title: "demo-repo",
                      workspaceRoot: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("CandyWrapper-research/sandbox-3824-ref/demo-repo").path)])])
        context.scheduledTasks = ["sandbox": .loaded([])]
        context.subscribeResourceTelemetry = { _, receive in receive(telemetryFixture(dark: dark)); return nil }
        return context
    }

    static func telemetryFixture(dark: Bool) -> JSONValue {
        func group(_ cpu: Double, _ memory: Double, _ count: Int, _ read: Double, _ write: Double) -> JSONValue {
            .object(["currentCpuPercent": .number(cpu), "currentRssBytes": .number(memory * 1_048_576),
                     "processCount": .number(Double(count)), "processStarts": .number(Double(count)), "processExits": .number(0),
                     "peakRssBytes": .number((dark ? 537 : 585) * 1_048_576), "cpuTimeMs": .number(dark ? 990 : 2610),
                     "ioReadBytesPerSecond": .number(read * 1_048_576), "ioWriteBytesPerSecond": .number(write * 1024),
                     "ioReadBytes": .number((dark ? 59.4 : 169) * 1_048_576), "ioWriteBytes": .number((dark ? 96 : 508) * 1024)])
        }
        return .object(["sampleIntervalMs": .number(1000), "readAt": .string(UsageFormat.isoString(TimestampFormat.nowMs())),
                        "power": .object(["thermalState": .string("unknown")]),
                        "health": .object(["native": .object(["status": .string("healthy")])]),
                        "groups": .object(["allT3": group(dark ? 39.9 : 59, dark ? 508 : 584, 5, dark ? 26 : 44.7, dark ? 15.6 : 47.1),
                                           "backend": group(dark ? 38.1 : 57.5, dark ? 501 : 577, 4, dark ? 26 : 44.7, dark ? 15.6 : 47.1),
                                           "electron": group(0, 0, 0, 0, 0), "monitor": group(dark ? 1.8 : 1.5, dark ? 6.48 : 7.11, 1, 0, 0)])])
    }

    static func providerFixture(_ context: SettingsPageContext) {
        let names = ["Opus 5.5", "Sonnet 5.5", "Fable 5.1", "Fable 5", "Opus 5", "Opus 4.8", "Opus 4.7",
                     "Opus 4.6", "Opus 4.5", "Sonnet 5", "Sonnet 4.6", "Haiku 5.5", "Haiku 4.5"]
        let models = names.map { name in
            var options = [ProviderOptionDescriptor(id: name == "Haiku 4.5" ? "thinking" : "reasoningEffort", label: "Reasoning", type: .select)]
            if ["Opus 5.5", "Opus 5", "Opus 4.8", "Opus 4.7", "Opus 4.6"].contains(name) {
                options.insert(ProviderOptionDescriptor(id: "fastMode", label: "Fast mode", type: .boolean), at: 0)
            }
            return ServerProviderModel(slug: "claude-" + name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ".", with: "-"), name: "Claude " + name,
                                       optionDescriptors: options)
        }
        var claude = ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", models: models)
        claude.version = "2.1.312"
        claude.auth = .object(["status": .string("authenticated"), "label": .string("Claude Max Subscription"),
                               "email": .string("account@example.invalid")])
        var codex = ServerProvider(instanceId: "codex", driver: "codex")
        codex.version = "0.164.0"
        codex.auth = .object(["status": .string("authenticated"), "label": .string("ChatGPT Pro 100 Subscription")])
        let settings = JSONValue.object(["idleCompaction": .string("onReturn"), "favorites": .array([])])
        var config = ServerProviderConfig(providers: [codex, claude], settings: ServerThreadDefaults(raw: settings))
        config.platformOS = "darwin"
        context.configs = ["sandbox": config]
        context.scope.environments[0].settings = ServerSettingsValues(settings)
    }

    static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    static func settings(_ section: SettingsSection, fraction: CGFloat, dark: Bool) -> AppRouteModalView {
        let context = context(dark: dark)
        if section == .providers { providerFixture(context) }
        let page = SettingsPageView()
        page.header.isRouteModal = true
        page.header.section = section
        page.header.restore.isHidden = section != .general
        page.header.restore.isEnabled = false
        let body: NSView & SettingsGroupRow
        if ConcernSettingsView.sections.contains(section) {
            body = ConcernSettingsView(context: context, section: section)
        } else {
            body = switch section {
            case .appearance: AppearanceSettingsView(context: context)
            case .keybindings: KeybindingsSettingsView(context: context)
            case .projects: ProjectSettingsView(context: context)
            case .archive: ArchiveSettingsView(context: context)
            case .scheduledTasks: ScheduledTasksSettingsView(context: context)
            case .snapShots: SnapShotSettingsView(context: context)
            case .diagnostics: DiagnosticsSettingsView(context: context)
            default: ConnectionsSettingsView()
            }
        }
        if let connections = body as? ConnectionsSettingsView { connections.showsAccess = false }
        (body as? SettingsPageBase)?.refresh()
        (body as? SettingsPageBase)?.onHeightChange = { [weak page] in page?.pageChanged() }
        if let appearance = body as? AppearanceSettingsView { appearance.splitDiffsPage() }
        if section == .providers {
            descendants(body).compactMap { $0 as? ProviderListRow }.dropFirst().first?.onSelect?()
        }
        page.page = body
        let nav = SettingsSidebarView()
        nav.stage = .none
        nav.isRouteModal = true
        nav.selected = section
        let modal = AppRouteModalView(label: "Settings", content: page, navigation: nav)
        modal.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        modal.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        modal.layoutSubtreeIfNeeded()
        let scroll = page.subviews.compactMap { $0 as? ScrollAreaView }.first!
        // main-3824.log records 665.5px for screen 18. Use the captured viewport rather than a
        // fraction of native content: account status and offscreen sections have different heights.
        let scrollY = section == .providers ? 665.5 : max(0, scroll.scrollView.documentView!.frame.height - scroll.scrollView.contentView.bounds.height) * fraction
        scroll.scroll(to: NSPoint(x: 0, y: scrollY))
        return modal
    }

    static func panel(_ image: NSBitmapImageRep) -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: image.cgImage!.cropping(to: CGRect(x: 80, y: 80, width: 2040, height: 1400))!)
    }

    static func compare(_ name: String, view: NSView, dark: Bool) throws -> (String, Double) {
        let theme = dark ? "dark" : "light"
        let base = "\(name).\(theme)"
        let reference = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo
            .appendingPathComponent("design/reference-3824/\(base).png"))))
        let ref = panel(reference)
        let ours = panel(Snapshot.image(of: view, size: NSSize(width: 1100, height: 780), scale: 2, dark: dark))
        let (score, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
        let out = Fidelity.root.appendingPathComponent("settings-screens")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Snapshot.writePNG(ref, to: out.appendingPathComponent(base + ".ref.png"))
        try Snapshot.writePNG(ours, to: out.appendingPathComponent(base + ".ours.png"))
        try Snapshot.writePNG(diff, to: out.appendingPathComponent(base + ".diff.png"))
        return (base, score)
    }

    static func renderSettings(_ cases: [(String, SettingsSection, CGFloat)]) throws {
        let previous = FontRuntime.input
        defer { FontRuntime.apply(previous) }
        var fonts = FontRuntimeInput()
        fonts.smoothing = false // The app's default fontSmoothing setting, as in the browser screens.
        FontRuntime.apply(fonts)
        var scores: [(String, Double)] = []
        for (name, section, fraction) in cases {
            for dark in [false, true] {
                scores.append(try Self.compare(name, view: Self.settings(section, fraction: fraction, dark: dark), dark: dark))
            }
        }
        Self.ceilings.check("settings", scores)
    }

    @Test func settings() throws {
        try Self.renderSettings(Self.settingsCases.filter { $0.1 != .providers })
    }

    @Test func providers() throws {
        try Self.renderSettings(Self.settingsCases.filter { $0.1 == .providers })
    }

    @Test func usage() throws {
        let previous = FontRuntime.input
        defer { FontRuntime.apply(previous) }
        var fonts = FontRuntimeInput()
        fonts.smoothing = false
        FontRuntime.apply(fonts)
        var scores: [(String, Double)] = []
        for (name, metric) in [("26-usage-limits", "limits"), ("26b-usage-cost", "cost"), ("26b-usage-tokens", "tokens")] {
            for dark in [false, true] {
                let page = UsagePageView()
                page.header.isRouteModal = true
                var model = UsagePageView.Model()
                model.metric = metric
                model.providerLabel = "No providers"
                model.body = metric == "limits" ? .limits : .usage
                page.limits.model = UsageLimitsModel()
                model.window = UsageWindow(sinceDay: "2026-09-29", untilDay: "2026-10-28", timeZone: "UTC")
                page.model = model
                let modal = AppRouteModalView(label: "Usage", content: page)
                modal.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
                scores.append(try Self.compare(name, view: modal, dark: dark))
            }
        }
        Self.ceilings.check("usage", scores)
    }
}
