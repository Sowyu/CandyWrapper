import AppKit
import Testing
import DesignSystem
@testable import T3Store
@testable import Features

/// Cmd+K lists the open thread's menu actions (T3 5258 CommandPaletteThreadActions.tsx, #40742).
@MainActor
struct PaletteThreadActionsTests {
    @Test func menuBecomesPaletteRows() {
        var state = ThreadActionMenu.State()
        state.branch = "main"
        state.canRewriteTitle = true
        state.snoozePresets = [SnoozePreset(id: "tomorrow", label: "Tomorrow", whenLabel: "9:00 AM", snoozedUntil: Date())]
        var ran: [String] = []
        let entries = PaletteThreadActions.entries(ThreadActionMenu.items(state)) { ran.append($0) }
        let values = entries.map(\.value)
        // Rename and Project settings have their own palette rows; the rest keep the menu's order.
        #expect(values == ["thread-action:new-thread-on-branch", "thread-action:pin", "thread-action:settle", "thread-action:snooze",
                           "thread-action:rewrite-title", "thread-action:mark-unread", "thread-action:auto-settle",
                           "thread-action:copy", "thread-action:archive", "thread-action:delete"])
        let settle = entries[2]
        #expect(settle.title == "Settle thread" && settle.icon == .circleCheck && settle.shortcutCommand == "thread.settle")
        #expect(entries[4].shortcutCommand == "thread.regenerateTitle" && entries[4].description == ThreadActionMenu.rewriteTitleTooltip)
        guard case .submenu(let copy) = entries[7].action else { Issue.record("Copy is a submenu"); return }
        #expect(copy.addonIcon == .copy && copy.groups.first?.label == "Copy")
        #expect(copy.groups.first?.items.map(\.value) == ["thread-action:copy-path", "thread-action:copy-branch", "thread-action:copy-thread", "thread-action:copy-thread-id"])
        if case .run(let run, let keepOpen) = settle.action { run(); #expect(!keepOpen) }
        #expect(ran == ["settle"])
    }

    @Test func disabledParentDisablesItsChildren() {
        var state = ThreadActionMenu.State()
        state.canSnoozeNow = false
        state.snoozePresets = [SnoozePreset(id: "later", label: "Later", whenLabel: "6:00 PM", snoozedUntil: Date())]
        let snooze = PaletteThreadActions.entries(ThreadActionMenu.items(state)) { _ in }.first { $0.value == "thread-action:snooze" }
        #expect(snooze?.isDisabled == true)
        guard case .submenu(let page)? = snooze?.action else { Issue.record("Snooze is a submenu"); return }
        #expect(page.groups[0].items.allSatisfy { $0.isDisabled })
        // CommandPaletteThreadActions.tsx:100-107: the preset's time is the row's description.
        #expect(page.groups[0].items.first?.title == "Later" && page.groups[0].items.first?.description == "6:00 PM")
    }
}

/// CommandPalette.tsx at 5258: a held Escape or Backspace repeats and must not step back (#42279, #42205).
@MainActor
struct PaletteKeyRepeatTests {
    func key(_ repeatFlag: Bool, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: repeatFlag, keyCode: 51)!
    }

    @Test func onlyAFreshPlainPressCounts() {
        #expect(CommandPaletteController.isFreshPlainKey(key(false)))
        #expect(!CommandPaletteController.isFreshPlainKey(key(true)))
        #expect(!CommandPaletteController.isFreshPlainKey(key(false, .shift)))
        #expect(CommandPaletteController.isFreshPlainKey(nil))
    }
}
