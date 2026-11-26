import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign's quiet sidebar (after Capy): two-line rows by default, One line on request, and color only where a thread
/// needs the user.
@MainActor
struct SidebarQuietRowTests {
    @Test func statusMapping() {
        func status(_ top: SidebarTopStatus?, pending: Bool = false) -> SidebarRowModel.QuietStatus {
            var r = SidebarRowModel(id: ThreadId("t"), variant: .card, action: .settle, section: .active, title: "t",
                                    status: .ready, topStatus: top, isGoal: false, isUnread: false, isWoke: false, isPinned: false,
                                    recedes: false, isActive: false, isRegeneratingTitle: false, timeLabel: "2m", providers: [])
            r.isPendingSync = pending
            return r.quietStatus
        }
        #expect(status(.input) == .glyph(.messageCircleQuestion, .info))
        #expect(status(.approval) == .glyph(.shieldQuestion, .warning))
        #expect(status(.failed) == .glyph(.circleAlert, .error))
        #expect(status(.working) == .working)
        #expect(status(.waiting) == .working)
        #expect(status(.woke) == .woke)
        // A finished thread shows nothing; its title's weight says it is unread.
        #expect(status(.done) == .none)
        #expect(status(nil) == .none)
        #expect(status(.input, pending: true) == .pending)
    }

    @Test func oneLineAndTwoLineLayouts() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        for twoLines in [false, true] {
            let content = SidebarContentView()
            content.hideWorkingShelf()
            content.now = { SidebarPreview.referenceNow }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = content
            content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
            content.state.redesignOneLineRows = !twoLines
            content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
                SidebarPreview.thread("d1", "Finished story", project: "p1", kind: .done, minutesAgo: 3),
                SidebarPreview.thread("i1", "Asks a question", project: "p1", kind: .input, minutesAgo: 5),
                SidebarPreview.thread("r1", "Read notes", project: "p1", kind: .read, minutesAgo: 9),
            ]), animated: false)
            content.layoutSubtreeIfNeeded()
            content.list.layoutSubtreeIfNeeded()
            let done = try #require(content.list.rowView("thread:d1") as? SidebarCardRowView)
            let input = try #require(content.list.rowView("thread:i1") as? SidebarCardRowView)
            done.layoutSubtreeIfNeeded(); input.layoutSubtreeIfNeeded()
            func label(_ v: NSView, _ text: String) -> LabelView? { v.subviews.compactMap { $0 as? LabelView }.first { $0.text == text && !$0.isHidden } }
            let title = try #require(label(done, "Finished story"))
            // No green chip in either mode.
            #expect(!done.subviews.compactMap { $0 as? LabelView }.contains { $0.text == "Done" && $0.color == SB.status(.done) })
            if twoLines {
                #expect(done.frame.height == 48)
            } else {
                #expect(done.frame.height == SidebarItem.oneLineHeight)
                // The title sits on the nav rows' label edge and is quiet; the age at the right, on the title's line.
                #expect(title.frame.minX == 8 + 16 + RedesignTokens.Space.s)
                // A read thread rests at 400; an unread one (Done here) is 500.
                let read = try #require(content.list.rowView("thread:r1") as? SidebarCardRowView)
                read.layoutSubtreeIfNeeded()
                #expect(label(read, "Read notes")?.font.weightTrait == .regular)
                #expect(title.font.weightTrait == .medium)
                #expect(label(done, "Done") == nil)
                let age = try #require(done.subviews.compactMap { $0 as? LabelView }.first { !$0.isHidden && $0 !== title && !$0.text.isEmpty })
                #expect(age.frame.maxX <= done.bounds.width - 8 + 1)
                #expect(abs(age.frame.midY - title.frame.midY) <= 2)
                // The input row's title is 500, and the accessibility label still says the status and the age.
                #expect(label(input, "Asks a question")?.font.weightTrait == .medium)
                #expect(input.accessibilityLabel()?.contains("Input") == true)
                #expect(input.accessibilityLabel()?.contains("5m") == true)
            }
            window.contentView = nil
        }
    }
}

private extension NSFont {
    var weightTrait: NSFont.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let w = (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        return abs(w - NSFont.Weight.medium.rawValue) < 0.05 ? .medium : abs(w) < 0.05 ? .regular : NSFont.Weight(w)
    }
}
