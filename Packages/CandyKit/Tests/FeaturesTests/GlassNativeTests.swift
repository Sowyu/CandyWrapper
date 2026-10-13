import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Glass Native, phase 1 (docs/glass-native.md): the theme card and its gate, the readable muted text over thin
/// frost, and the swap between the classic and native presentations.
@MainActor
struct GlassNativeTests {
    @Test func glassNativeIsGlassWithTheNativePresentation() {
        let native = ThemeDefinition.glassNative
        #expect(ThemeDefinition.pickerBuiltIns.contains(native) == ThemeDefinition.glassNativeAvailable)
        #expect(ThemePalette.reservedIds.contains(native.id))
        #expect(native.isWindowGlass && native.isGlassNative && !ThemeDefinition.glass.isGlassNative)
        #expect(ThemeCardDefinition(native).previews == ThemeCardDefinition.standard.previews)

        let defaults = UserDefaults(suiteName: "cw.glassnative.tests.\(UUID().uuidString)")!
        let library = ThemeLibrary(defaults: defaults, pinned: nil)
        defaults.set(native.id, forKey: "theme.preference")
        let (input, forced) = library.runtimeInput(client: .defaults)
        #expect(input.glassLight && input.glassDark && input.light == nil && input.dark == nil)
        #expect(forced == "system")
        #expect(library.usesNativePresentation == ThemeDefinition.glassNativeAvailable)
        defaults.set(ThemeDefinition.glass.id, forKey: "theme.preference")
        #expect(!library.usesNativePresentation)

        // Below macOS 26 a stored Glass Native reads as Glass.
        #expect(ThemePalette.normalizedId(native.id, glassNativeAvailable: false) == ThemeDefinition.glass.id)
        #expect(ThemePalette.normalizedId(native.id, glassNativeAvailable: true) == native.id)

        // `CANDY_THEME` wins over the stored choice and its mix.
        defaults.set(try! JSONSerialization.data(withJSONObject: ["dark": "ocean"]), forKey: "theme.halves.v1")
        let pinned = ThemeLibrary(defaults: defaults, pinned: "ember")
        #expect(pinned.preference == "ember" && pinned.halves == ThemeLibrary.Halves())
    }

    @Test func mutedTextStaysReadableOverThinFrost() {
        for dark in [false, true] {
            let tuned = dark ? WindowGlass.mutedDark : WindowGlass.mutedLight
            // The default opacity and above keep the measured colors, so the fidelity references hold.
            #expect(WindowGlass.readableMutedTarget(dark: dark, opacity: 0.8) == tuned)
            #expect(WindowGlass.readableMutedTarget(dark: dark, opacity: 1) == tuned)
            var last = WindowGlass.luminance(tuned)
            for opacity in [0.6, 0.4, 0.2, 0.1] {
                let l = WindowGlass.luminance(WindowGlass.readableMutedTarget(dark: dark, opacity: opacity))
                // Thinner frost moves the text further from the background.
                #expect(dark ? l > last : l < last)
                last = l
            }
            // At 10% the color reads at 4.5:1 against the stock background at 7.5% over the modeled frost.
            let stock = WindowGlass.luminance(dark ? Tokens.dark.background : Tokens.light.background)
            let lt = WindowGlass.luminance(tuned)
            let atTuned = dark ? (lt + 0.05) / 4.5 - 0.05 : 4.5 * (lt + 0.05) - 0.05
            let frost = (atTuned - 0.6 * stock) / 0.4
            let background = 0.075 * stock + 0.925 * frost
            let ratio = dark ? (last + 0.05) / (background + 0.05) : (background + 0.05) / (last + 0.05)
            #expect(ratio >= 4.49)
        }
    }

    @Test func aSwapMovesTheViewsAndReleasesTheOldPresentation() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let defaults = UserDefaults(suiteName: "cw.glassnative.swap.\(UUID().uuidString)")!
        let sidebar = SidebarContentView()
        let page = DSView()
        let overlay = DSView()
        weak var oldClassic: SidebarLayoutView?
        weak var oldNative: NativeSplitPresentation?
        weak var oldRoot: NSView?
        weak var oldSplitView: NSView?
        var current: MainPresentation?
        // Views stay out of `#expect` and its autorelease pool, which would keep them alive past the swap.
        func placed(native: Bool) -> Bool {
            guard let root = current?.root else { return false }
            return window.contentView === root && (window.toolbar != nil) == native && sidebar.hidesCustomChrome == native
                && sidebar.isDescendant(of: root) && page.isDescendant(of: root) && overlay.superview === root
        }
        autoreleasepool {
            let classic = SidebarLayoutView(defaults: defaults)
            classic.sidebarContent = sidebar
            classic.mainContent = page
            classic.install(in: window)
            classic.root.addSubview(overlay)
            let native = NativeSplitPresentation(autosaveName: nil)
            MainPresentationSwap.swap(from: classic, to: native, in: window)
            native.root.layoutSubtreeIfNeeded()
            oldClassic = classic
            current = native
        }
        #expect(oldClassic == nil)
        let nativePlaced = autoreleasepool { placed(native: true) }
        #expect(nativePlaced)
        let sidebarOpen = autoreleasepool { current?.isSidebarOpen == true }
        #expect(sidebarOpen)

        autoreleasepool {
            let native = current as! NativeSplitPresentation
            oldNative = native
            oldRoot = native.root
            oldSplitView = native.split.view
            let classic = SidebarLayoutView(defaults: defaults)
            MainPresentationSwap.swap(from: native, to: classic, in: window)
            current = classic
        }
        #expect(oldNative == nil && oldRoot == nil && oldSplitView == nil)
        #expect(placed(native: false))
        window.contentView = nil
    }
}
