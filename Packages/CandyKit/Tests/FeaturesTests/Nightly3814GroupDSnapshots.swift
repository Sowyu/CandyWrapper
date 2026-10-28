import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Optional offscreen review artifacts. Set CANDY_GROUP_D_SNAPSHOTS to a sandbox directory.
@MainActor
struct Nightly3814GroupDSnapshots {
    @Test func captureNativeViews() throws {
        guard let directory = ProcessInfo.processInfo.environment["CANDY_GROUP_D_SNAPSHOTS"] else { return }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        for redesign in [false, true] {
            var theme = previous
            theme.ditherLight = redesign; theme.ditherDark = redesign
            ThemeRuntime.apply(theme)
            for dark in [false, true] {
                let name = "\(redesign ? "redesign" : "default")-\(dark ? "dark" : "light")"
                let context = SettingsPageContext()
                context.scope = SettingsScopeState(environments: [.init(id: "sandbox", label: "Sandbox", settings:
                    ServerSettingsValues(.object(["guestSharingEnabled": .bool(false), "linkedEnvironmentsEnabled": .bool(false), "snoozePresets": .array(SnoozePresetSetting.defaults.map(\.json))])),
                    capabilities: ["threadAutoSettlement", "threadAutoSettlementScope", "threadRestartContinuation", "storageCleanup", "storageCleanupRun", "worktreesDirectory"])], primaryId: "sandbox")
                for section in [SettingsSection.general, .chat, .diffs, .threads, .worktrees, .maintenance, .about] {
                    let view = ConcernSettingsView(context: context, section: section)
                    view.refresh()
                    let height = min(1800, max(240, view.height(forWidth: 720)))
                    try save(view, size: NSSize(width: 720, height: height), dark: dark,
                             to: out.appendingPathComponent("\(name)-\(section.rawValue).png"))
                }
                try save(BetaSettingsView(context: context), size: NSSize(width: 720, height: 560), dark: dark,
                         to: out.appendingPathComponent("\(name)-labs.png"))
                try save(SettingsSidebarView(), size: NSSize(width: 256, height: 780), dark: dark,
                         to: out.appendingPathComponent("\(name)-navigation.png"))
                let snapshot = SidebarPreview.richSnapshot()
                let sidebar = SidebarContentView()
                sidebar.now = { SidebarPreview.referenceNow }
                var state = SidebarListState(activeThreadId: ThreadId(rawValue: "r3"))
                state.boringSidebarEnabled = true
                state.dither = redesign
                state.workingShelfEnabled = true
                state.snoozedExpanded = true
                if let group = SidebarModel.buildProjectGroups(snapshot.projects).first { state.collapsedProjects.insert(group.key) }
                sidebar.state = state
                sidebar.setSnapshot(snapshot, animated: false)
                try save(sidebar, size: NSSize(width: 256, height: 780), dark: dark,
                         to: out.appendingPathComponent("\(name)-folders.png"))
                let machine = UpdateEverythingLogicTests.machine("remote", "1", .bootService)
                let description = UpdateEverythingLogic.describe(localVersion: "2", servers: [machine], target: "2",
                    providerMachines: [("local", "Sandbox", ["Claude"]), ("remote", "Remote", ["Codex", "Claude"])],
                    localMachines: [("local", "Sandbox")], skipped: [.init(environmentId: "offline", label: "Offline", reason: "not connected")])
                let content = UpdateEverythingDialogContent(description, running: ["remote": 2])
                content.toggleSkipped()
                try save(content, size: NSSize(width: 528, height: 320), dark: dark,
                         to: out.appendingPathComponent("\(name)-updates.png"))
            }
        }
    }

    private func save(_ view: NSView, size: NSSize, dark: Bool, to url: URL) throws {
        let bitmap = Snapshot.image(of: view, size: size, scale: 2, dark: dark)
        try Snapshot.writePNG(bitmap, to: url)
    }
}
