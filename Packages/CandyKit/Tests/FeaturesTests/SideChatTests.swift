import AppKit
import Testing
import T3Protocol
import T3Store
@testable import DesignSystem
@testable import Features

/// Side chats (4928 #26901): the `/side` and `/btw` rows, the pane's header and the tab's state dot.
@MainActor
struct SideChatTests {
    private let start = ComposerTrigger(kind: .slashCommand, query: "", rangeStart: 0, rangeEnd: 1)

    @Test func sideAndBtwOnlyOpenThePrompt() {
        let ids = ComposerMenus.slashItems(trigger: start, provider: "p", commands: [], skills: [], showSkills: false, compactAvailable: false,
                                           freshSessionAvailable: true, sideChat: .init()).map(\.id)
        // useComposerMenuItems.ts:254-290: /model, /side, /btw, /clear.
        #expect(ids == ["slash:model", "slash:side", "slash:btw", "slash:clear"])
        let later = ComposerTrigger(kind: .slashCommand, query: "", rangeStart: 4, rangeEnd: 5)
        #expect(ComposerMenus.slashItems(trigger: later, provider: "p", commands: [], skills: [], showSkills: false, compactAvailable: false,
                                         sideChat: .init()).map(\.id) == ["slash:model"])
        // Where side chats aren't offered (a 3824 server, a draft) the rows stay out.
        #expect(!ComposerMenus.slashItems(trigger: start, provider: "p", commands: [], skills: [], showSkills: false, compactAvailable: false)
            .contains { $0.id == "slash:side" })
    }

    @Test func aReasonReplacesTheDescriptions() throws {
        let items = ComposerMenus.slashItems(trigger: start, provider: "p", commands: [], skills: [], showSkills: false, compactAvailable: false,
                                             sideChat: .init(disabledReason: "Available once the thread's worktree is set up."))
        let side = try #require(items.first { $0.id == "slash:side" })
        #expect(side.description == "Available once the thread's worktree is set up.")
        #expect(ComposerMenus.replacement(for: side) == "/side ")
        let query = ComposerTrigger(kind: .slashCommand, query: "bt", rangeStart: 0, rangeEnd: 3)
        let btw = ComposerMenus.slashItems(trigger: query, provider: "p", commands: [], skills: [], showSkills: false, compactAvailable: false, sideChat: .init())
        #expect(btw.first?.id == "slash:btw" && btw.first?.description == "Same as /side")
    }

    @Test func headerLaysOutLikeSideChatPane() {
        let pane = SideChatPaneView(threadId: "side")
        pane.frame = NSRect(x: 0, y: 0, width: 482, height: 600)
        pane.layoutSubtreeIfNeeded()
        // `h-9 pr-1 pl-3 gap-1`: close and delete are 24pt icon-xs buttons at the right.
        #expect(pane.close.frame == NSRect(x: 482 - 4 - 24, y: 5.5, width: 24, height: 24))
        #expect(pane.delete.frame.maxX == pane.close.frame.minX - 4)
        #expect(pane.bringBack.frame.maxX == pane.delete.frame.minX - 4)
        #expect(pane.titleLabel.frame.minX == 12 && pane.titleLabel.text == "Side chat")
        pane.apply(.init(title: "Why is the sky blue", bringBackBlockedReason: "Available after a finished reply."))
        #expect(pane.titleLabel.text == "Why is the sky blue")
        #expect(pane.bringBack.alphaValue == 0.64 && pane.bringBack.toolTip == "Available after a finished reply.")
        pane.apply(.init(title: "x"))
        #expect(pane.bringBack.alphaValue == 1 && pane.bringBack.toolTip == "Adds this side chat to the main thread's next message.")
        pane.apply(.init(deleted: true))
        #expect(!pane.delete.isEnabled)
    }

    @Test func blockedBringBackDoesNothing() {
        let pane = SideChatPaneView(threadId: "side")
        var calls = 0
        pane.onBringBack = { calls += 1 }
        pane.apply(.init(bringBackBlockedReason: "Available when the main thread is idle."))
        pane.bringBack.action?()
        #expect(calls == 0)
        pane.apply(.init())
        pane.bringBack.action?()
        #expect(calls == 1)
    }

    @Test func tabDotFollowsTheState() {
        #expect(SideChatTabIcon(state: nil).layer?.sublayers?.last?.isHidden == true)
        let running = SideChatTabIcon(state: .running)
        #expect(running.layer?.sublayers?.last?.isHidden == false && running.accessibilityLabel() == "running")
    }

    enum Exit: CaseIterable { case paneLeaves, focusLeaves }

    /// Hover on the header buttons clears when the pane goes away under a still pointer, as it does when its tab hides
    /// or another side chat takes it, and when the window loses focus (the rule bb98b824 follows).
    @Test(arguments: [0, 1, 2], Exit.allCases) func headerHoverClears(_ index: Int, _ exit: Exit) throws {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = SideChatHostView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = host
        defer { window.close() }
        let pane = SideChatPaneView(threadId: "side")
        host.show(pane)
        host.layoutSubtreeIfNeeded()
        let button = [pane.bringBack, pane.delete, pane.close][index]
        let resting = try pixels(button)
        var hovered = button.state
        hovered.hovered = true
        button.previewState(hovered)
        #expect(try pixels(button) != resting, "the hover draws")
        switch exit {
        case .paneLeaves:
            host.show(nil)
            host.show(pane)
        case .focusLeaves:
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        #expect(!button.state.hovered)
        #expect(try pixels(button) == resting, "the button is back to rest")
    }

    private func pixels(_ view: NSView) throws -> Data {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.tiffRepresentation)
    }
}
