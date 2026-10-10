import AppKit
import Testing
import T3Protocol
@testable import Features

/// The viewer's input mapping (ServerBrowserSurface.tsx `pagePoint`, `handleKey`) and the mini
/// player's placement (previewMiniPlayerLayout.ts).
@MainActor
struct BrowserLogicTests {
    @Test func pointerMapping() {
        // A 1000x500 frame letterboxed in a 400x400 box: 400x200 at y 100.
        let box = CGSize(width: 400, height: 400), image = CGSize(width: 1000, height: 500), viewport = CGSize(width: 500, height: 250)
        #expect(BrowserPointerMap.fittedRect(box: box, image: image) == CGRect(x: 0, y: 100, width: 400, height: 200))
        #expect(BrowserPointerMap.pagePoint(CGPoint(x: 200, y: 200), box: box, image: image, viewport: viewport, clamp: false) == CGPoint(x: 250, y: 125))
        #expect(BrowserPointerMap.pagePoint(CGPoint(x: 200, y: 50), box: box, image: image, viewport: viewport, clamp: false) == nil)
        #expect(BrowserPointerMap.pagePoint(CGPoint(x: 200, y: 50), box: box, image: image, viewport: viewport, clamp: true) == CGPoint(x: 250, y: 0))
    }

    func key(_ chars: String, ignoring: String? = nil, code: UInt16, flags: NSEvent.ModifierFlags = [], up: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code)!
    }

    @Test func keyMapping() {
        #expect(BrowserKeyMap.input(for: key("a", code: 0), action: "down")
                == .key(action: "down", key: "a", code: "KeyA", keyCode: 65, text: "a", modifiers: 0))
        #expect(BrowserKeyMap.input(for: key("A", ignoring: "a", code: 0, flags: .shift), action: "down")
                == .key(action: "down", key: "A", code: "KeyA", keyCode: 65, text: "A", modifiers: 8))
        #expect(BrowserKeyMap.input(for: key("\r", code: 36), action: "down")
                == .key(action: "down", key: "Enter", code: "Enter", keyCode: 13, text: "\r", modifiers: 0))
        #expect(BrowserKeyMap.input(for: key("\u{7F}", code: 51, up: true), action: "up")
                == .key(action: "up", key: "Backspace", code: "Backspace", keyCode: 8, text: nil, modifiers: 0))
        // Shortcuts carry no text.
        #expect(BrowserKeyMap.input(for: key("c", code: 8, flags: .command), action: "down")
                == .key(action: "down", key: "c", code: "KeyC", keyCode: 67, text: nil, modifiers: 4))
        #expect(BrowserKeyMap.input(for: key("\u{F702}", code: 123), action: "down")
                == .key(action: "down", key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, text: nil, modifiers: 0))
        #expect(BrowserKeyMap.input(for: key("1", code: 18), action: "down")
                == .key(action: "down", key: "1", code: "Digit1", keyCode: 49, text: "1", modifiers: 0))
    }

    @Test func miniPlayerPlacement() {
        #expect(BrowserMiniPlayerView.size(source: CGSize(width: 1280, height: 800)) == CGSize(width: 320, height: 200 + ServerBrowserView.barHeight))
        let container = CGRect(x: 0, y: 52, width: 800, height: 600)
        let size = CGSize(width: 320, height: 233)
        #expect(BrowserMiniPlayerView.frame(size: size, origin: nil, container: container).origin == CGPoint(x: 468, y: 64))
        #expect(BrowserMiniPlayerView.frame(size: size, origin: CGPoint(x: -50, y: 900), container: container).origin == CGPoint(x: 12, y: 52 + 600 - 12 - 233))
    }

    @Test func zoomMenu() {
        let actions = BrowserMoreMenu.Actions(hardReload: {}, setColorScheme: { _ in }, zoom: { _ in }, clearCookies: {}, clearCache: {})
        let items = BrowserMoreMenu.items(enabled: true, zoomFactor: 1.25, colorScheme: "dark", deviceToolbarVisible: false,
                                          profileName: "Default", actions: actions)
        #expect(items.map(\.title) == ["Hard reload", "Show device toolbar", "Appearance", "", "Zoom", "", "Profile: Default", "Clear cookies", "Clear cache"])
        #expect(items[4].keepsOpen)
        guard case .submenu(let schemes) = items[2].kind else { Issue.record("no submenu"); return }
        #expect(schemes.map { if case .radio(let on) = $0.kind { on } else { false } } == [false, false, true])
    }
}
