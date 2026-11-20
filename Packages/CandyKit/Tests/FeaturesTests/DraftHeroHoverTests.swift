import AppKit
import Testing
import DesignSystem
@testable import Features

/// The new thread page's project name and "or start without a project" never showed their hover in a real window.
/// HoverSync owns the headline's enter and exit, and AppKit sends `mouseMoved` only to areas it considers entered,
/// so `mouseMoved` never came. The headline now takes its hover from HoverSync's enter and pointer moves.
@MainActor @Suite struct DraftHeroHoverTests {
    @Test func enterAndPointerMovesDriveTheHover() throws {
        let hero = DraftHeroView(frame: NSRect(x: 0, y: 0, width: 700, height: DraftHeroView.height))
        let window = NSWindow(contentRect: hero.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hero
        hero.appearance = NSAppearance(named: .darkAqua)
        hero.projectTitle = "demo-repo"
        hero.onPickProject = { _ in }
        hero.onStartWithoutProject = {}
        hero.layoutSubtreeIfNeeded()
        _ = Snapshot.image(of: hero, size: hero.frame.size, scale: 2, dark: true)
        func enter(at point: NSPoint) throws -> NSEvent {
            let inWindow = hero.convert(point, to: nil)
            return try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: inWindow, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        #expect(hero is HoverSyncPointerClient)
        let project = hero.projectAnchor.frame
        #expect(!project.isEmpty)
        hero.mouseEntered(with: try enter(at: NSPoint(x: project.midX, y: project.midY)))
        #expect(hero.hovered && !hero.scratchHovered)
        hero.mouseExited(with: try enter(at: .zero))
        #expect(!hero.hovered)
        let link = hero.scratchLink
        #expect(!link.isEmpty)
        hero.mouseEntered(with: try enter(at: NSPoint(x: link.midX, y: link.midY)))
        #expect(hero.scratchHovered && !hero.hovered)
        hero.mouseExited(with: try enter(at: .zero))
        #expect(!hero.scratchHovered)
        window.close()
    }
}
