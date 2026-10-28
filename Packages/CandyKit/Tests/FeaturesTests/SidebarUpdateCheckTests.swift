import AppKit
import QuartzCore
import Testing
import DesignSystem
@testable import Features

@MainActor
struct SidebarUpdateCheckTests {
    @MainActor final class Gate {
        var continuation: CheckedContinuation<Bool, Never>?
        func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
        func finish(_ success: Bool = true) { continuation?.resume(returning: success); continuation = nil }
    }

    @Test func waitsForEverySourceAndIgnoresDuplicateChecks() async {
        let check = SidebarUpdateCheck()
        let app = Gate(), server = Gate(), providers = Gate()
        var transitions: [SidebarUpdateCheck.State] = []
        check.onChange = { transitions.append($0) }
        #expect(check.state == .idle)
        let task = Task { await check.run(checks: [{ await app.wait() }, { await server.wait() }, { await providers.wait() }], hasUpdates: { false }) }
        while providers.continuation == nil || server.continuation == nil || app.continuation == nil { await Task.yield() }
        #expect(check.state == .checking)
        await check.run(checks: [{ Issue.record("A second click must not start another check"); return false }], hasUpdates: { false })
        app.finish(); server.finish()
        #expect(check.state == .checking)
        providers.finish()
        await task.value
        #expect(check.state == .upToDate)
        #expect(transitions == [.checking, .upToDate])
        await check.run(checks: [{ true }], hasUpdates: { true })
        #expect(check.state == .updatesAvailable)
        await check.run(checks: [{ true }, { false }], hasUpdates: { false })
        #expect(check.state == .failed)
    }

    @Test func footerGlyphsReachTheBitmap() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        for redesign in [false, true] {
            var theme = ThemeRuntimeInput()
            theme.ditherLight = redesign; theme.ditherDark = redesign
            ThemeRuntime.apply(theme)
            for dark in [false, true] {
                let container = SidebarContainerView()
                let sidebar = SidebarContentView()
                container.content = sidebar
                let pill = sidebar.updatePill
                pill.update = DesktopUpdateState(currentVersion: "1", channel: .nightly, enabled: true)
                let idle = Snapshot.image(of: container, size: NSSize(width: 256, height: 780), dark: dark)
                let rect = pill.convert(pill.bounds, to: container)
                pill.isCheckingForUpdates = true
                let checking = Snapshot.image(of: container, size: NSSize(width: 256, height: 780), dark: dark)
                var changed = 0
                for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
                    for x in Int(rect.minX * 2)..<Int(rect.maxX * 2) {
                        if idle.colorAt(x: x, y: y) != checking.colorAt(x: x, y: y) { changed += 1 }
                    }
                }
                #expect(changed > 20, "Refresh and spinner must draw above the account surface")
            }
        }
    }

    @Test func footerSpinnerAndSlotStayStableInEveryAppearance() throws {
        let previous = ThemeRuntime.input, reduced = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = reduced }
        Motion.reducedOverride = false
        for redesign in [false, true] {
            var theme = ThemeRuntimeInput()
            theme.ditherLight = redesign; theme.ditherDark = redesign
            ThemeRuntime.apply(theme)
            for dark in [false, true] {
                let window = ProviderUpdatePresentationTests.VisibleWindow(contentRect: NSRect(x: 0, y: 0, width: 256, height: 780), styleMask: [], backing: .buffered, defer: true)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let sidebar = SidebarContentView()
                window.contentView = sidebar
                sidebar.frame = NSRect(x: 0, y: 0, width: 256, height: 780)
                let pill = sidebar.updatePill
                let base = DesktopUpdateState(currentVersion: "1", channel: .nightly, enabled: true)
                pill.update = base
                var clicks = 0
                pill.onCheck = { clicks += 1 }
                sidebar.layoutSubtreeIfNeeded()
                let frame = pill.frame
                let accountFrame = sidebar.accountRow.frame
                #expect(!pill.isHidden && pill.iconStatus == .idle && pill.tooltipText == "Check for updates")
                pill.performAction()
                #expect(clicks == 1)
                pill.isCheckingForUpdates = true
                sidebar.layoutSubtreeIfNeeded()
                #expect(pill.iconStatus == .checking && pill.isInteractionDisabled)
                #expect(pill.tooltipText == "Checking for updates…")
                let spinner = try #require(pill.subviews.flatMap(\.subviews).compactMap { $0 as? SpinnerView }.first)
                let arc = try #require(spinner.layer?.sublayers?.first)
                #expect(arc.animation(forKey: "spin") != nil)
                #expect(pill.frame == frame && sidebar.accountRow.frame == accountFrame)
                pill.performAction()
                #expect(clicks == 1)
                Motion.reducedOverride = true
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
                #expect(arc.animation(forKey: "spin") == nil)
                Motion.reducedOverride = false
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
                #expect(arc.animation(forKey: "spin") != nil)
                pill.isHidden = true
                #expect(arc.animation(forKey: "spin") == nil)
                pill.isHidden = false
                #expect(arc.animation(forKey: "spin") != nil)
                window.shown = false
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                #expect(arc.animation(forKey: "spin") == nil)
                window.shown = true
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                pill.update = base.onUpdateAvailable("2", at: Date())
                #expect(pill.iconStatus == .checking)
                pill.isCheckingForUpdates = false
                #expect(pill.iconStatus == .available && arc.animation(forKey: "spin") == nil)
                pill.setEverything(summary: "Update server", pending: .init(servers: 1))
                #expect(pill.iconStatus == .everything)
                sidebar.layoutSubtreeIfNeeded()
                #expect(pill.frame == frame && sidebar.accountRow.frame == accountFrame)
                pill.setEverything(summary: nil, pending: .init(providers: 2))
                pill.update = base.onNoUpdate(at: Date())
                #expect(pill.iconStatus == .idle && !pill.isHidden)
                sidebar.layoutSubtreeIfNeeded()
                #expect(pill.frame == frame)
                window.contentView = nil
            }
        }
    }
}
