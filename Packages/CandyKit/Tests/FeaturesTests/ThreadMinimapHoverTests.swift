import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// The rail stayed in its hovered fisheye after the card closed or the pointer left (v1.14.14, Redesign). Every exit
/// that can be driven offscreen must leave the rail pixel-identical to one that was never hovered.
@MainActor
struct ThreadMinimapHoverTests {
    private func makeRail() -> (NSWindow, ThreadMinimapView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let content = DSView(frame: window.contentLayoutRect)
        window.contentView = content
        let map = ThreadMinimapView(frame: NSRect(x: 12, y: 100, width: 40, height: 72))
        content.addSubview(map)
        map.items = (0..<10).map { ThreadMinimapItem(id: "\($0)", rowIndex: $0 * 2, userText: "Turn \($0)", assistantText: "Reply \($0)") }
        map.inView = IndexSet(7...9)
        return (window, map)
    }

    private func pixels(_ map: ThreadMinimapView) throws -> Data {
        let rep = try #require(map.bitmapImageRepForCachingDisplay(in: map.bounds))
        map.cacheDisplay(in: map.bounds, to: rep)
        return try #require(rep.tiffRepresentation)
    }

    private func key(_ code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    enum Exit: CaseIterable { case cardClosedFromOutside, exitOverTheRail, focusLeaves, railHides }

    @Test(arguments: Exit.allCases)
    func everyExitReturnsTheRailToRest(_ exit: Exit) throws {
        let (window, map) = makeRail()
        let host = try #require(map.popupHost)
        defer { host.closeAll(); map.removeFromSuperview(); window.close() }
        let resting = try pixels(map)
        // Hover the fifth turn from the keyboard: the fisheye and the card show.
        window.makeFirstResponder(map)
        for _ in 0..<5 { map.keyDown(with: key(125, in: window)) }
        #expect(try pixels(map) != resting, "the hover draws the fisheye")
        #expect(host.popups.count == 1, "the hover opens the card")
        switch exit {
        case .cardClosedFromOutside:
            // A click anywhere, Escape or another hover card closes the card through the host.
            host.closeAll()
        case .exitOverTheRail:
            // HoverSync's exit carries the pointer position, which can still be on the rail or the card.
            let point = map.convert(NSPoint(x: 4, y: 36), to: nil)
            map.mouseExited(with: try #require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
                                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        case .focusLeaves:
            window.makeFirstResponder(nil)
        case .railHides:
            map.isHidden = true
            map.isHidden = false
        }
        #expect(host.popups.isEmpty, "the card closes")
        #expect(try pixels(map) == resting, "the rail is back to rest")
    }
    /// Screen pass 2026-11-20: hover a turn, then move right over the messages or onto the card and rest there. The
    /// fisheye and the card stayed, because the hover area kept a 352pt band and the card. At 4928 the card is
    /// display-only (TimelineMinimap.tsx:229) and the hit strip at most 40pt wide (MessagesTimeline.logic.ts:482-497),
    /// so both points have left the strip and the card closes.
    @Test func theHoverAreaEndsAtTheStripAndItsArrows() throws {
        let (window, map) = makeRail()
        let host = try #require(map.popupHost)
        defer { host.closeAll(); map.removeFromSuperview(); window.close() }
        window.makeFirstResponder(map)
        for _ in 0..<5 { map.keyDown(with: key(125, in: window)) }
        let card = try #require(host.popups.first?.content)
        let content = try #require(window.contentView)
        // HoverSync enters and exits the rail by the sibling view that carries the rail's tracking area.
        let zone = try #require(content.subviews.first { $0 !== map && $0.trackingAreas.contains { $0.owner === map } })
        host.layoutSubtreeIfNeeded()
        let cardRect = content.convert(card.bounds, from: card)
        #expect(cardRect.width >= 300, "the card is laid out")
        #expect(!zone.frame.contains(NSPoint(x: cardRect.midX, y: cardRect.midY)), "a pointer resting on the card has left the strip")
        #expect(!zone.frame.contains(NSPoint(x: map.frame.maxX + 40, y: map.frame.midY)), "a pointer over the messages has left the strip")
        #expect(zone.frame.contains(NSPoint(x: map.frame.minX - 2, y: map.frame.maxY + 16)), "the arrows keep their own hover")
    }

    enum Theme: CaseIterable { case standard, redesign }

    /// T3's resting strips are dim and the strips of turns on screen bright. In every theme, over the background behind
    /// the rail (T3's panel, or the brightest dot dark and the darkest dot light of Redesign's art),
    /// a resting strip keeps at least T3's contrast ratio to an on-screen one, and stays visible over both extremes.
    @Test(arguments: Theme.allCases, [false, true])
    func restingStripsAreDimmerThanOnScreenOnes(_ theme: Theme, dark: Bool) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = theme == .redesign; input.ditherDark = theme == .redesign
        ThemeRuntime.apply(input)
        let (window, map) = makeRail()
        defer { map.removeFromSuperview(); window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let cached = try #require(map.bitmapImageRepForCachingDisplay(in: map.bounds))
        map.cacheDisplay(in: map.bounds, to: cached)
        let rep = try #require(cached.converting(to: .sRGB, renderingIntent: .default))
        let scale = CGFloat(rep.pixelsWide) / map.bounds.width
        func lum(_ c: SIMD3<Double>) -> Double { BackdropMarks.luminance(c) }
        func strip(_ i: Int, over ground: SIMD3<Double>) throws -> Double {
            let y = Int((CGFloat(i) / 9 * (map.bounds.height - 2) + 1) * scale)
            let c = try #require(rep.colorAt(x: Int(4 * scale), y: y))
            let a = Double(c.alphaComponent)
            #expect(a > 0, "strip \(i) draws")
            return lum(SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) * a + ground * (1 - a))
        }
        let t3 = BackdropMarks.reference(ThreadMinimapView.strips, dark: dark)
        let t3Ratio = BackdropMarks.contrast(t3.states[2], t3.states[0])
        let panel = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.srgb
        let solid = SIMD3(panel.x, panel.y, panel.z)
        let grounds: [SIMD3<Double>]
        if let worst = BackdropMarks.worstBackground(dark: dark) {
            #expect(theme != .standard)
            grounds = [SIMD3(repeating: worst), solid]
        } else {
            #expect(theme == .standard)
            grounds = [solid]
        }
        for ground in grounds {
            let rest = try strip(0, over: ground), on = try strip(9, over: ground)
            #expect(BackdropMarks.contrast(on, rest) >= t3Ratio * 0.97, "\(theme) dark \(dark): \(BackdropMarks.contrast(on, rest)) < T3's \(t3Ratio)")
            #expect(BackdropMarks.contrast(rest, lum(ground)) >= BackdropMarks.contrast(t3.states[0], t3.background) * 0.97,
                    "\(theme) dark \(dark): the resting strip is fainter than T3's")
            #expect(dark ? on > rest : on < rest)
            // Redesign's resting strip is a target, so it keeps a graphic's 3:1 on the panel's plain ground (T10, round 2).
            if theme == .redesign, ground == solid {
                #expect(BackdropMarks.contrast(rest, lum(ground)) >= 3, "redesign dark \(dark): resting strip \(BackdropMarks.contrast(rest, lum(ground)))")
            }
        }
        // Over light Redesign's worst dot the resting strip stands clearly further out than T3's, so it never reads as a
        // stray mark. Dark has no room for that: the on-screen strip already keeps T3's ratio to it only up to white.
        if theme == .redesign, !dark, let worst = BackdropMarks.worstBackground(dark: dark) {
            let rest = try strip(0, over: SIMD3(repeating: worst))
            #expect(BackdropMarks.contrast(rest, lum(SIMD3(repeating: worst))) >= BackdropMarks.contrast(t3.states[0], t3.background) * 1.3)
        }
    }
}
