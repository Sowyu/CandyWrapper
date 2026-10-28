import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct ThreadNowTests {
    @Test func defaultThemesPutThreadStateInTimelineOrderAndKeepEnvironmentNotices() {
        ThemeRuntime.apply(ThemeRuntimeInput())
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        panel.childInputKey = "child"
        panel.childInputBanner.apply(.init(variant: .neutral, icon: .messageCircle, title: "Subagent needs input", actions: ["Open question"]))
        panel.showsBackgroundWork = true
        panel.backgroundWorkBanner.apply(.init(variant: .neutral, icon: .terminal, title: "Running tests", actions: ["Stop"]))
        panel.showsGoal = true
        panel.goalBanner.apply(.init(variant: .neutral, icon: .target, title: "Working toward goal", actions: ["Clear"]))
        panel.showsActivity = true
        panel.showsEnvironmentBanner = true
        panel.serverUpdateNotice = .init(status: .available(serverVersion: "old", clientVersion: "new"))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.timelineStatusIds == ["attention", "work", "sync", "goal"])
        let banners = panel.bannerStackItems(docked: true, composerVisible: true).map(\.id)
        #expect(banners == ["environment-unavailable"])
        #expect(panel.timeline.layoutProblems().isEmpty)
        panel.showsGoal = false
        panel.showsActivity = false
        panel.showsBackgroundWork = false
        panel.childInputKey = nil
        panel.layoutSubtreeIfNeeded()
        #expect(panel.timelineStatusIds.isEmpty)
    }

    @Test func redesignKeepsItsComposerStatusAttachments() {
        var theme = ThemeRuntimeInput()
        theme.ditherDark = true; theme.ditherLight = true
        ThemeRuntime.apply(theme)
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        panel.showsGoal = true
        panel.goalBanner.apply(.init(variant: .neutral, icon: .target, title: "Working toward goal", actions: ["Clear"]))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.timelineStatusIds.isEmpty)
        #expect(panel.bannerStackItems(docked: true, composerVisible: true).contains { $0.id.hasPrefix("goal:") })
    }
}
