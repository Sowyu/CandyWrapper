import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
import T3Store
@testable import Features

/// Small T3 parity texts and states: provider setup button, goal and plan fallbacks, the Codex feedback
/// guard, SnapShot data in the image preview, the account label, panel toggles and VoiceOver names.
@MainActor
struct NicheGapsBTests {
    @Test func codexFeedbackCommand() {
        // threadFeedback.ts:22-29.
        for text in ["/feedback", "  /feedback  ", "/FEEDBACK it broke", "/feedback\nline two"] {
            #expect(ComposerLogic.isCodexFeedbackCommand(text), "\(text)")
        }
        for text in ["/feedbacks", "send /feedback", "/feed back", ""] {
            #expect(!ComposerLogic.isCodexFeedbackCommand(text), "\(text)")
        }
    }

    @Test func commandFailureFallsBack() {
        #expect(ComposerFeedback.surface(for: .command(nil, fallback: "Failed to resume goal.")) == .banner("Failed to resume goal."))
        #expect(ComposerFeedback.surface(for: .command("Provider offline", fallback: "Failed to clear goal.")) == .banner("Provider offline"))
    }

    @Test func providerUnavailableReplacesThePickers() {
        let pickers = ComposerPickers(store: ComposerSelectionStore(defaults: nil), draftKey: "",
                                      context: ComposerSelectionContext(catalog: ProviderCatalog([])))
        let controls = pickers.controlsView
        controls.frame = NSRect(x: 0, y: 0, width: 400, height: 28)
        controls.unavailableTitle = "Open provider settings"
        controls.layout()
        #expect(!controls.unavailable.isHidden)
        #expect(controls.model.isHidden && controls.access.isHidden)
        #expect(controls.unavailable.title == "Open provider settings")
        // Icon 16 less the -mx-0.5 overhang, gap, label, padding and border; no chevron.
        let label = controls.unavailable.width(showingLabel: true) - 2 - 20 - 12 - 6
        #expect(label > 0)
        #expect(controls.unavailable.frame.width == (controls.unavailable.naturalWidth * 2).rounded() / 2)
        controls.unavailableTitle = nil
        controls.layout()
        #expect(controls.unavailable.isHidden && !controls.model.isHidden)
    }

    @Test func snapShotAccessibilityPresence() {
        #expect(SnapShotContents.includesAccessibility(.object(["accessibleText": .string(" hi ")])))
        #expect(!SnapShotContents.includesAccessibility(.object(["accessibleText": .string("  ")])))
        #expect(SnapShotContents.includesAccessibility(.object(["accessibility": .object(["format": .string("element-tree")])])))
        #expect(!SnapShotContents.includesAccessibility(.object(["accessibility": .null])))
        let empty = SnapShotContents.button(.object(["appName": .string("Notes")]))
        #expect(empty.accessibilityLabel() == "No accessibility data")
        let text = SnapShotContents.button(.object(["accessibleText": .string("Hello")]))
        #expect(text.accessibilityLabel() == "View accessibility data")
    }

    @Test func previewTogglesBetweenScreenshotAndData() throws {
        func buttons(_ view: NSView) -> [ButtonView] { view.subviews.compactMap { $0 as? ButtonView } }
        let flat: JSONValue = .object(["kind": .string("snap-shot"), "appName": .string("Notes"), "accessibleText": .string("Hello")])
        let preview = ExpandedImagePreviewView(items: [.init(key: "a", name: "Snapshot.png", source: flat) { _ in nil }], index: 0)
        preview.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let toggle = try #require(buttons(preview).first { $0.accessibilityLabel() == "Show extracted text" })
        toggle.action?()
        #expect(toggle.accessibilityLabel() == "Show screenshot")
        toggle.action?()
        #expect(toggle.accessibilityLabel() == "Show extracted text")

        let tree: JSONValue = .object(["kind": .string("snap-shot"), "accessibility": .object(["format": .string("element-tree"), "root": .object([:])])])
        let json = ExpandedImagePreviewView(items: [.init(key: "b", name: "b.png", source: tree) { _ in nil }], index: 0)
        #expect(buttons(json).contains { $0.accessibilityLabel() == "Show accessibility JSON" })

        // No readable data: the data popover button, as on the tile.
        let bare = ExpandedImagePreviewView(items: [.init(key: "c", name: "c.png", source: .object(["appName": .string("X")])) { _ in nil }], index: 0)
        #expect(buttons(bare).contains { $0.accessibilityLabel() == "No accessibility data" })
        // Plain images get no button.
        let plain = ExpandedImagePreviewView(items: [.init(key: "d", name: "d.png") { _ in nil }], index: 0)
        #expect(!buttons(plain).contains { ["Show extracted text", "No accessibility data"].contains($0.accessibilityLabel() ?? "") })
    }

    @Test func accountLabelRevealsLikeT3() {
        let account = UsageLimitsReport.Account(id: "codex", driver: "codex", label: "me@example.com", plan: "Plus", email: nil, sourceLabel: nil,
                                                instanceId: nil, resetCreditTarget: nil, displayName: nil, accentColor: nil,
                                                limits: ProviderUsageLimits(checkedAt: "2026-10-10T11:59:00.000Z", windows: []))
        let summary = UsageAccountSummaryView(account, lineHeight: 24)
        let redacted = summary.subviews.compactMap { $0 as? UsageRedactedTextView }.first
        #expect(redacted?.accessibilityLabel() == "Toggle account label visibility")
    }

    @Test func headerTogglesNameThemselves() {
        let header = ThreadHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 52))
        #expect(header.toggles.map { $0.accessibilityLabel() ?? "" } == ["Toggle thread details panel", "Toggle terminal drawer", "Toggle right panel"])
        header.threadTitle = "Fix login"
        #expect(header.subviews.contains { $0.accessibilityLabel() == "Thread actions for Fix login" })
    }
}
