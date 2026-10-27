import AppKit
import QuartzCore
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct ProviderUpdatePresentationTests {
    final class VisibleWindow: NSWindow {
        var shown = true
        override var isVisible: Bool { shown }
        override var occlusionState: NSWindow.OcclusionState { shown ? .visible : [] }
    }

    private func context(status: String = "running", message: String? = "Updating to 2.1.312...") -> SettingsPageContext {
        let context = SettingsPageContext()
        context.scope = SettingsScopeState(environments: [SettingsLogicTests.env("sandbox", "Sandbox")], primaryId: "sandbox")
        var provider = ServerProvider(instanceId: .init("claudeAgent"), driver: "claudeAgent")
        provider.version = "2.1.311"
        provider.versionAdvisory = .object([
            "status": .string("behind_latest"), "latestVersion": .string("2.1.312"),
            "canUpdate": .bool(true), "updateCommand": .string("claude update")
        ])
        provider.updateState = .init(status: status, finishedAt: nil, message: message)
        context.configs["sandbox"] = ServerProviderConfig(providers: [provider])
        return context
    }

    private func claudeRow(_ page: ProvidersSettingsView) throws -> ProviderListRow {
        try #require(page.providers.list.first { row in
            row.subviews.compactMap { $0 as? LabelView }.contains { $0.text == "Claude" }
        })
    }

    @Test func progressAppearsOnceAndFinishedUpdatesRestoreStatus() throws {
        for (state, message, expected) in [
            ("running", "Updating to 2.1.312...", "Updating to 2.1.312..."),
            ("queued", "Waiting for active runs", "Waiting for active runs"),
            ("running", nil, "Starting update")
        ] as [(String, String?, String)] {
            let context = context(status: state, message: message)
            let page = ProvidersSettingsView(context: context)
            let row = try claudeRow(page)
            #expect(row.subviews.compactMap { $0 as? TextBlockView }.first?.text == expected)
            #expect(row.advisory?.showsSpinner == true)
            context.configs["sandbox"]!.providers[0].updateState = .init(status: "succeeded", finishedAt: nil, message: "Updated")
            page.refresh()
            let finished = try claudeRow(page)
            #expect(finished.advisory?.showsSpinner == false)
            #expect(finished.subviews.compactMap { $0 as? TextBlockView }.first?.text != expected)
        }
    }

    @Test func updatePopoverUsesTheSharedSpinner() throws {
        let presentation = try #require(ProviderVersionAdvisoryLogic.presentation(context().configs["sandbox"]?.providers.first, enabled: true))
        let popover = ProviderVersionAdvisoryPopover(presentation, updating: true, progress: "Updating to 2.1.312...", problem: nil, run: {}, copy: { _ in })
        let button = try #require(popover.subviews.compactMap { $0 as? ButtonView }.first { $0.title == "Updating" })
        #expect(button.showsSpinner)
        #expect(!button.isEnabled)
        #expect(button.subviews.contains { $0 is SpinnerView })
    }

    @Test func updateSpinnerRunsAndSurvivesUnchangedRefreshesInEveryAppearance() throws {
        let previous = ThemeRuntime.input
        let reduced = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = reduced }
        Motion.reducedOverride = false
        for redesign in [false, true] {
            var theme = ThemeRuntimeInput()
            theme.ditherLight = redesign; theme.ditherDark = redesign
            ThemeRuntime.apply(theme)
            for dark in [false, true] {
                let context = context()
                let page = ProvidersSettingsView(context: context)
                let window = VisibleWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [], backing: .buffered, defer: true)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = page
                page.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
                page.layoutSubtreeIfNeeded()
                let row = try claudeRow(page)
                let button = try #require(row.advisory)
                let spinner = try #require(button.subviews.compactMap { $0 as? SpinnerView }.first)
                let arc = try #require(spinner.layer?.sublayers?.first)
                let spin = try #require(arc.animation(forKey: "spin") as? CABasicAnimation)
                #expect(spin.keyPath == "transform.rotation.z")
                #expect(spin.duration == 1 && spin.repeatCount == .infinity)
                #expect(spinner.frame.size == NSSize(width: 14, height: 14))
                #expect(button.hitTest(row.convert(NSPoint(x: spinner.bounds.midX, y: spinner.bounds.midY), from: spinner)) === button)
                context.configs["sandbox"]!.providers[0].checkedAt = "later"
                page.refresh()
                #expect(try claudeRow(page) === row)
                #expect(button.subviews.compactMap { $0 as? SpinnerView }.first === spinner)
                #expect(arc.animation(forKey: "spin") != nil)
                Motion.reducedOverride = true
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
                #expect(arc.animation(forKey: "spin") == nil)
                Motion.reducedOverride = false
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
                #expect(arc.animation(forKey: "spin") != nil)
                row.isHidden = true
                #expect(arc.animation(forKey: "spin") == nil)
                row.isHidden = false
                #expect(arc.animation(forKey: "spin") != nil)
                window.shown = false
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                #expect(arc.animation(forKey: "spin") == nil)
                window.contentView = nil
                #expect(arc.animation(forKey: "spin") == nil)
            }
        }
    }
}
