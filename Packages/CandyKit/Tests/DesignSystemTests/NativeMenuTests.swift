import AppKit
import Testing

@testable import DesignSystem

@MainActor
struct NativeMenuTests {
    @Test func shortcutsBecomeKeyEquivalents() {
        let k = NativeMenu.keyEquivalent("⇧⌘K")
        #expect(k?.key == "k")
        #expect(k?.modifiers == [.shift, .command])
        #expect(NativeMenu.keyEquivalent("T")?.modifiers == [])
        #expect(NativeMenu.keyEquivalent("⌘↵")?.key == "\r")
        #expect(NativeMenu.keyEquivalent("Ctrl+K") == nil)
    }

    @Test func itemsMapToNSMenu() {
        var hits: [String] = []
        var open = MenuItem("Open", icon: .folder, shortcut: "⌘O")
        open.action = { hits.append("open") }
        let items: [MenuItem] = [.label("Section"), open, .separator,
                                 .checkbox("Wrap", checked: true) { hits.append("wrap \($0)") },
                                 MenuItem("Gone", disabled: true), .separator]
        let menu = NativeMenu.make(items)
        #expect(menu.items.count == 5) // the trailing separator is dropped
        #expect(menu.items[0].isSectionHeader)
        #expect(menu.items[1].keyEquivalent == "o" && menu.items[1].image?.isTemplate == true)
        #expect(menu.items[3].state == .on)
        #expect(!menu.items[4].isEnabled)
        for i in [1, 3] { _ = (menu.items[i].target as? NSObject)?.perform(menu.items[i].action, with: menu.items[i]) }
        #expect(hits == ["open", "wrap false"])
    }

    @Test func iconImagesHaveInk() throws {
        let image = try #require(NativeMenu.image(IconName.files.definition, size: 16, color: nil))
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        var ink = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 } }
        #expect(ink > 10)
    }

    @Test func richRowsStayCustom() {
        var confirm = MenuItem("Delete")
        confirm.keepsOpen = true
        #expect(!NativeMenu.canExpress([confirm]))
        #expect(!NativeMenu.canExpress([.note("Read only")]))
        #expect(!NativeMenu.canExpress([.submenu("More", [confirm])]))
    }

    /// Classic keeps the menu open on a checkbox and on a radio that doesn't close on click, and shows trailing
    /// text like "Anyone": an NSMenu would close on each and turn the text into nothing or a live key.
    @Test func stayOpenRowsAndTrailingTextStayCustom() {
        #expect(NativeMenu.canExpress([MenuItem("Open", shortcut: "⌘O"), .separator, MenuItem("Gone", disabled: true)]))
        #expect(!NativeMenu.canExpress([.checkbox("Wrap", checked: true) { _ in }]))
        #expect(!NativeMenu.canExpress([MenuItem("Author", shortcut: "Anyone")]))
        var radio = MenuItem("Newest", kind: .radio(true))
        #expect(!NativeMenu.canExpress([radio]))
        #expect(NativeMenu.canExpress([radio], select: true))
        radio.closesOnClick = true
        #expect(NativeMenu.canExpress([radio]))
    }
}
