import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Redesign shows the round send button with the Compact toggle. With Settings > Redesign > Legacy > Compact and send
/// button on, it shows T3's first compact-before-send control instead: a "Compact and send" button with a
/// send-options menu in place of the round send button and the toggle.
@MainActor
struct DitherCompactSendTests {
    /// It applies the global `ThemeRuntime` and restores it in `defer`; keep the body synchronous on
    /// the main actor so no other test runs while the Dither theme is on.
    @Test func ditherSplitsCompactAndSend() {
        withLegacy {
            let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
            composer.text = "hello"
            composer.compactBeforeSendTokens = 128_000
            composer.layoutSubtreeIfNeeded()
            let pills = composer.subviews.compactMap { $0 as? MessageActionPill }.filter { !$0.isHidden }
            // Inside `withValue` the macros can't take a trailing-closure predicate, so the checks run first.
            let split = pills.contains { $0.title == "Compact and send" }
            #expect(split)
            #expect(composer.compactPill.isHidden)
        }
    }

    @Test func typingEnablesBothHalvesWithoutAnotherLayout() throws {
        try withLegacy { try typingEnablesBothHalves() }
    }

    private func typingEnablesBothHalves() throws {
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
        composer.compactBeforeSendTokens = 423_400
        composer.layoutSubtreeIfNeeded()
        let halves = composer.subviews.compactMap { $0 as? MessageActionPill }.filter { !$0.isHidden }
        #expect(halves.count == 2)
        #expect(halves.allSatisfy { !$0.isEnabled })
        composer.text = "Continue"
        #expect(composer.primary.isEnabled)
        #expect(halves.allSatisfy { $0.isEnabled })
        composer.text = ""
        #expect(halves.allSatisfy { !$0.isEnabled })
    }

    @Test(arguments: ["empty", "upload", "loading", "connecting", "permission", "environment", "provider", "busy", "length"])
    func disabledHalvesExplainTheBlockAndRecover(reason: String) throws {
        try withComposer { composer, send, menu in
            composer.text = "Continue"
            let expected: String
            switch reason {
            case "empty": composer.text = " \n "; expected = "Write a message or attach a file to send"
            case "environment": composer.environmentUnavailable = true; expected = "Environment disconnected"
            case "provider":
                composer.providerUnavailable = true
                composer.environmentUnavailable = true
                expected = "Enable a provider to send a message"
            case "busy": composer.isBusy = true; expected = "Submitting message"
            case "length":
                composer.text = String(repeating: "x", count: ComposerLogic.maxInputCharacters + 1)
                expected = try #require(ComposerLogic.lengthValidationMessage(composer.text))
            default:
                expected = switch reason {
                case "upload": "Uploading attachments"
                case "loading": "Loading thread"
                case "permission": "This connection cannot change threads."
                default: "Connecting"
                }
                composer.sendDisabledReason = expected
            }
            #expect(!send.isEnabled && !menu.isEnabled)
            #expect(send.tooltip == expected)
            #expect(menu.tooltip == expected)
            #expect(send.accessibilityHelp() == expected)
            #expect(menu.accessibilityHelp() == expected)
            #expect(!send.accessibilityPerformPress())
            #expect(!menu.accessibilityPerformPress())

            composer.text = "Continue"
            composer.sendDisabledReason = nil
            composer.environmentUnavailable = false
            composer.providerUnavailable = false
            composer.isBusy = false
            #expect(send.isEnabled && menu.isEnabled)
            #expect(send.tooltip == "Summarize 423k tokens of history, then send")
            #expect(menu.tooltip == "Send options")
        }
    }

    @Test func attachmentsEnableBothHalvesWithoutText() throws {
        try withComposer { composer, send, menu in
            composer.attachmentCount = 1
            #expect(send.isEnabled && menu.isEnabled)
            composer.attachmentCount = 0
            #expect(!send.isEnabled && !menu.isEnabled)
        }
    }

    @Test func runningAndResumableThreadsReplaceTheSplitAndIdleRestoresIt() throws {
        try withComposer { composer, send, menu in
            composer.runState = ComposerLogic.RunState(activeRunId: "run", running: true)
            composer.layoutSubtreeIfNeeded()
            #expect(send.isHidden && menu.isHidden)
            #expect(composer.primary.face == .stop)
            composer.runState = ComposerLogic.RunState(resumableRunId: "run")
            composer.layoutSubtreeIfNeeded()
            #expect(send.isHidden && menu.isHidden)
            #expect(composer.primary.face == .resume)
            composer.runState = ComposerLogic.RunState()
            composer.text = "Continue"
            composer.layoutSubtreeIfNeeded()
            #expect(!send.isHidden && !menu.isHidden)
            #expect(send.isEnabled && menu.isEnabled)
        }
    }

    @Test func splitActionsOpenTheMenuAndChooseCompactionOrFullHistory() throws {
        try withComposer { composer, send, menu in
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let content = try #require(window.contentView)
            content.addSubview(composer)
            let host = PopupHost.host(for: window)
            defer { host.closeAll() }
            var sends: [Bool] = []
            composer.onToggleKeepFullHistory = { composer.keepFullHistory.toggle() }
            composer.onSend = { text, mode, background in
                #expect(text == "Continue")
                #expect(mode == .auto && !background)
                sends.append(composer.compactsBeforeSend)
            }
            composer.text = "Continue"
            #expect(send.accessibilityPerformPress())
            #expect(menu.accessibilityPerformPress())
            let popup = try #require(host.popups.last?.content as? MenuPopupView)
            #expect(popup.items.count == 1)
            let item = try #require(popup.items.first)
            #expect(item.title == "Send with full history (423k tokens)")
            #expect(!item.isDisabled)
            item.action?()
            host.closeAll()
            #expect(send.accessibilityPerformPress())
            #expect(sends == [true, false, true])
            composer.onToggleKeepFullHistory = nil
            composer.onSend = nil
        }
    }

    /// 3473 and 3669 recordings, plus a forward-compatible 3754 descriptor with an unknown capability.
    /// Compaction follows the provider's advertised command, independently of threadStop or version.
    @Test(arguments: ["3473", "3669", "3754"])
    func capabilityVersionsKeepCompactionAndSendAvailable(build: String) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = build == "3473" ? "22-nightly-3473" : "23-nightly-3669"
        let lines = try String(contentsOf: root.appendingPathComponent("fixtures/transcripts/\(fixture).jsonl"), encoding: .utf8)
        var recorded: JSONValue?
        for line in lines.split(separator: "\n") {
            let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            if frame["dir"] == .string("recv"), frame["body"]?["requestId"] == .string("1"),
               let config = frame["body"]?["exit"]?["value"] { recorded = config; break }
        }
        var configJSON = try #require(recorded)
        if build == "3754" {
            var environment = try #require(configJSON["environment"]?.objectValue)
            environment["serverVersion"] = .string("0.1.3-nightly.20261028.3754")
            var capabilities = try #require(environment["capabilities"]?.objectValue)
            capabilities["futureCapability"] = .bool(true)
            environment["capabilities"] = .object(capabilities)
            var fields = try #require(configJSON.objectValue)
            fields["environment"] = .object(environment)
            configJSON = .object(fields)
        }
        let config = try configJSON.decode(as: ServerProviderConfig.self)
        #expect(config.capabilities.contains("threadStop"))
        let provider = try #require(config.providers.first { $0.driver == "claudeAgent" })
        var gate = ComposerCompaction.Gate()
        gate.hasProject = true; gate.isServerThread = true; gate.hasCompactableConversation = true
        gate.providerAvailable = ComposerCompaction.hasAvailableProvider(config.providers, driver: provider.driver,
            instanceId: provider.instanceId, lockedInstanceId: provider.instanceId)
        #expect(!gate.disabled)
        var withoutStop = config
        withoutStop.capabilities.remove("threadStop")
        #expect(ComposerCompaction.hasAvailableProvider(withoutStop.providers, driver: provider.driver,
            instanceId: provider.instanceId, lockedInstanceId: provider.instanceId))
        let now = Date()
        let tokens = ComposerCompaction.resumeTokens(
            usage: ThreadContextWindowUsage(used: 423_400, maximum: 1_000_000, automatically: true,
                                           updatedAt: now.addingTimeInterval(-7200)),
            driver: provider.driver, dismissed: false, compactDisabled: gate.disabled,
            hasHeldQueuedRuns: false, multipleModels: false, now: now)
        #expect(tokens == 423_400)
        try withComposer { composer, send, menu in
            composer.compactBeforeSendTokens = tokens
            composer.text = "Continue"
            #expect(send.isEnabled && menu.isEnabled)
        }
    }

    private func withComposer(_ body: (ComposerView, MessageActionPill, MessageActionPill) throws -> Void) throws {
        try withLegacy {
            let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
            composer.compactBeforeSendTokens = 423_400
            composer.layoutSubtreeIfNeeded()
            let halves = composer.subviews.compactMap { $0 as? MessageActionPill }.filter { !$0.isHidden }
            let sendHalf = halves.first { $0.title == "Compact and send" }, menuHalf = halves.first { $0.half == .trailing }
            let send = try #require(sendHalf)
            let menu = try #require(menuHalf)
            try body(composer, send, menu)
        }
    }

    /// Redesign with Settings > Redesign > Legacy > Compact and send button on, or `legacy` as given.
    private func withLegacy(_ legacy: Bool = true, _ body: () throws -> Void) rethrows {
        var input = ThemeRuntimeInput()
        input.ditherDark = true; input.ditherLight = true
        ThemeRuntime.apply(input)
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        try ComposerView.$legacyCompactSendOverride.withValue(legacy) { try body() }
    }

    /// Off, the default, Redesign shows 5258's round send button with the Compact toggle; on brings the split back.
    @Test func legacySwitchPicksTheControl() {
        for legacy in [false, true] {
            withLegacy(legacy) {
                let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
                composer.text = "hello"
                composer.compactBeforeSendTokens = 412_000
                composer.layoutSubtreeIfNeeded()
                let split = composer.subviews.compactMap { $0 as? MessageActionPill }.filter { !$0.isHidden && $0.title == "Compact and send" }
                #expect(split.isEmpty == !legacy)
                #expect(composer.compactPill.isHidden == legacy)
                #expect(composer.primary.isHidden == legacy)
            }
        }
    }

    @Test func compactToggleLabelFollowsTheState() {
        withLegacy(false) {
            let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
            composer.text = "hello"
            composer.compactBeforeSendTokens = 412_000
            composer.layoutSubtreeIfNeeded()
            #expect(composer.compactPill.label == "Compact 412k")
            #expect(composer.primary.accessibilityLabel() == "Compact and send")
            composer.keepFullHistory = true
            composer.layoutSubtreeIfNeeded()
            #expect(composer.compactPill.label == "Keep 412k")
        }
    }
}
