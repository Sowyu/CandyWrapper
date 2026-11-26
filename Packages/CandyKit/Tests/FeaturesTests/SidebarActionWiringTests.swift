import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SidebarActionWiringTests {
    func host(_ content: SidebarContentView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        content.layoutSubtreeIfNeeded()
        return window
    }

    @Test func rowButtonsReachTheAppActions() {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        var calls: [String] = []
        // Set after the rows exist: rows read the current actions when they fire.
        content.setSnapshot(SidebarPreview.richSnapshot(), animated: false)
        content.list.layoutSubtreeIfNeeded()
        content.actions.settle = { calls.append("settle \($0.rawValue)") }
        content.actions.unpin = { calls.append("unpin \($0.rawValue)") }
        // r1 is pinned: its pin glyph is the unpin button.
        let card = content.list.rowView("thread:r1") as? SidebarCardRowView
        #expect(card?.pin.isHidden == false)
        card?.pin.performAction()
        card?.settleButton.performAction()
        #expect(calls == ["unpin r1", "settle r1"])
        window.contentView = nil
    }

    /// A woken row keeps its Woke pill beside the hover actions, never under them, and the pill dismisses the wake.
    @Test func wokePillSitsBesideTheActionsAndDismisses() throws {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        var calls: [String] = []
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("w1", "Add a mode", project: "p1", kind: .read, minutesAgo: 400,
                                  extra: ["snoozedUntil": SidebarPreview.iso(10), "snoozedAt": SidebarPreview.iso(60)]),
        ]), animated: false)
        content.list.layoutSubtreeIfNeeded()
        content.actions.acknowledgeWake = { calls.append("wake \($0.rawValue)") }
        let card = try #require(content.list.rowView("thread:w1") as? SidebarCardRowView)
        #expect(card.row?.topStatus == .woke && !card.wokeButton.isHidden)
        var hot = card.state
        hot.hovered = true
        card.previewState(hot)
        card.layoutSubtreeIfNeeded()
        let actions = card.snoozeButton.isHidden ? card.settleButton.frame : card.snoozeButton.frame
        #expect(card.wokeButton.frame.width > 20 && card.wokeButton.frame.maxX <= actions.minX)
        card.wokeButton.performAction()
        #expect(calls == ["wake w1"])
        window.contentView = nil
    }

    /// T3 4928 sidebar/SidebarChrome.tsx:310: the notice fills the utility row, so the list keeps its size.
    @Test func undoNoticeFillsTheFooterRowWithoutShrinkingTheList() throws {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        defer { window.contentView = nil }
        content.setSnapshot(SidebarPreview.richSnapshot(), animated: false)
        content.layoutSubtreeIfNeeded()
        let viewport = content.scrollArea.frame
        let tops = content.list.tops
        content.undoNoticeText = "Settled,"
        content.layoutSubtreeIfNeeded()
        #expect(content.scrollArea.frame == viewport)
        #expect(content.list.tops == tops)
        #expect(content.undoNotice.superview === content)
        #expect(content.undoNotice.frame.minX == content.usageButton.frame.maxX + 4)
        #expect(content.undoNotice.frame.midY == content.usageButton.frame.midY)
        // A narrow sidebar drops the summary first, then shows only the undo icon.
        content.undoNotice.frame.size.width = content.undoNotice.button.preferredWidth + 10
        content.undoNotice.layoutSubtreeIfNeeded()
        #expect(content.undoNotice.button.frame.width == content.undoNotice.button.preferredWidth && !content.undoNotice.button.showsIcon)
        content.undoNotice.frame.size.width = 20
        content.undoNotice.layoutSubtreeIfNeeded()
        #expect(content.undoNotice.button.showsIcon && content.undoNotice.button.frame.width == 20)
        content.undoNoticeText = nil
        content.layoutSubtreeIfNeeded()
        #expect(content.undoNotice.isHidden)
    }

    @Test func environmentLabelKeepsTheRowClickable() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(.init())
        let items = SidebarListBuilder.items(snapshot: SidebarPreview.richSnapshot(), state: SidebarListState(), nowMs: 0)
        var model = try #require(items.compactMap { if case .row(let row) = $0, row.variant == .card { row } else { nil } }.first)
        model.environmentLabel = "This Mac"
        let row = SidebarCardRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 82))
        row.configure(.row(model))
        row.layoutSubtreeIfNeeded()
        #expect(row.hitTest(NSPoint(x: 64, y: 65)) === row)
    }

    /// SidebarThreadRow.tsx:1604-1621 at 5258: a card's status slot turns `pointer-events-none` while the row is hovered,
    /// so its "Pending" opens no tooltip; the slim row's time slot keeps "Waiting to sync with its environment".
    @Test func pendingTooltipOnlyWhereT3TakesThePointer() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(.init())
        let snapshot = SidebarPreview.richSnapshot()
        var state = SidebarListState()
        state.pendingSync = Set(snapshot.threads.map(\.id))
        let rows = SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: 0).compactMap { if case .row(let r) = $0 { r } else { nil } }
        func pendingTips(_ view: NSView) -> [String?] {
            view.subviews.flatMap { sub -> [String?] in
                ((sub as? LabelView).flatMap { $0.text == "Pending" && !$0.isHidden ? [$0.currentTooltip] : nil } ?? []) + pendingTips(sub)
            }
        }
        let cardModel = try #require(rows.first { $0.variant == .card && $0.isPendingSync && $0.topStatus != .woke })
        let card = SidebarCardRowView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarItem.row(cardModel).height))
        card.configure(.row(cardModel))
        #expect(pendingTips(card).allSatisfy { $0 == nil || $0 == "" })
        if let slimModel = rows.first(where: { $0.variant != .card && $0.isPendingSync }) {
            let slim = SidebarSlimRowView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarItem.row(slimModel).height))
            slim.configure(.row(slimModel))
            #expect(pendingTips(slim).contains("Waiting to sync with its environment"))
        }
    }

    /// A card without a meta line is 64pt tall, and its highlight once kept the 78pt of a full card, so the
    /// selected row covered the first line of the row below.
    @Test func cardSurfaceStaysInsideItsRow() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(.init())
        let items = SidebarListBuilder.items(snapshot: SidebarPreview.richSnapshot(), state: SidebarListState(), nowMs: 0)
        var model = try #require(items.compactMap { if case .row(let row) = $0, row.variant == .card { row } else { nil } }.first)
        for meta in [true, false] {
            model.environmentLabel = meta ? "This Mac" : nil
            model.pullRequestBadge = nil; model.issueBadge = nil
            model.terminalProcessCount = 0; model.timeInMeta = false
            #expect(model.hasMetaLine == meta)
            let height = SidebarItem.row(model).height
            #expect(height == (meta ? 82 : 64))
            let row = SidebarCardRowView(frame: NSRect(x: 0, y: 0, width: 240, height: height))
            row.configure(.row(model))
            row.layoutSubtreeIfNeeded()
            #expect(row.surfaceFrame == CGRect(x: 0, y: 2, width: 240, height: height - 4))
        }
    }

    @Test func undoNoticeAndUtilityFooter() {
        let content = SidebarContentView()
        let window = host(content)
        var undone = 0
        content.actions.undo = { undone += 1 }
        content.undoNoticeText = "Settled,"
        content.layoutSubtreeIfNeeded()
        #expect(!content.undoNotice.isHidden)
        #expect(content.undoNotice.frame.height == 24) // SidebarThreadUndoNotice.tsx:51: `h-6`.
        #expect(content.undoNotice.frame.minY == content.settingsButton.frame.minY + 4)
        #expect(content.scrollArea.frame.maxY <= content.settingsButton.frame.minY)
        content.undoNotice.button.performAction()
        #expect(undone == 1)
        content.undoNoticeText = nil
        content.isOnUtilityPage = true
        content.layoutSubtreeIfNeeded()
        #expect(content.undoNotice.isHidden && content.settingsButton.isHidden && !content.backButton.isHidden)
        window.contentView = nil
    }
}
