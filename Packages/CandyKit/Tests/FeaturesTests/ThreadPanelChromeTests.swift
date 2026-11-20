import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// The thread panel's header and the draft hero across column widths.
@MainActor
struct ThreadPanelChromeTests {
    /// The header keeps its panel toggles hidden while no thread shows, through layouts, so they and the details
    /// shortcut stay off before a thread loads.
    @Test func classicHeaderTogglesStayHiddenWithoutAThread() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
        window.contentView = panel
        panel.header.setThreadVisible(false)
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.header.toggles.allSatisfy { $0.isHidden })
        panel.setFrameSize(NSSize(width: 1200, height: 800))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.header.toggles.allSatisfy { $0.isHidden })
        window.contentView = nil
    }

    /// The draft headline wraps at spaces in a narrow column, as T3's `h1` does, keeps the project picker whole,
    /// and stays one line where it fits.
    @Test func draftHeadlineWrapsInANarrowColumn() {
        let hero = DraftHeroView(frame: .zero)
        hero.projectTitle = "demo-repo"
        #expect(hero.headlineLines(width: 900).count == 1)
        #expect(hero.height(forWidth: 900) == DraftHeroView.height)
        let lines = hero.headlineLines(width: 380)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.line.width <= 380 })
        let project = ("What should we build in " as NSString).length
        #expect(lines.contains { $0.start <= project && project + 9 <= $0.start + $0.length })
        #expect(hero.height(forWidth: 380) == DraftHeroView.height + 36)
    }

    /// Screen pass 3: "or start without a project" was drawn but inert (DraftHeroHeadline.tsx:189-203, 323-346 at 4928).
    @Test func startWithoutAProjectIsAButton() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 68), styleMask: [.borderless], backing: .buffered, defer: false)
        let hero = DraftHeroView(frame: NSRect(x: 0, y: 0, width: 800, height: 68))
        hero.projectTitle = "demo-repo"
        window.contentView = hero
        var started = 0
        hero.onStartWithoutProject = { started += 1 }
        hero.displayIfNeeded()
        func press(_ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: hero.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            hero.mouseDown(with: event)
        }
        // Hover: foreground text and an underline (`InlineButton tone="muted"`, button.tsx:103-113).
        func render() -> NSBitmapImageRep {
            let rep = hero.bitmapImageRepForCachingDisplay(in: hero.bounds)!
            hero.cacheDisplay(in: hero.bounds, to: rep)
            return rep
        }
        let resting = render().tiffRepresentation
        let move = NSEvent.mouseEvent(with: .mouseMoved, location: hero.convert(NSPoint(x: 400, y: 56), to: nil), modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        hero.mouseMoved(with: move)
        #expect(render().tiffRepresentation != resting)
        press(NSPoint(x: 400, y: 56))
        #expect(started == 1)
        press(NSPoint(x: 20, y: 56))
        #expect(started == 1)
    }
}
