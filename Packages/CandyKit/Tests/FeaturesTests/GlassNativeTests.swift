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

    /// The sidebar tracking separator leaves the toolbar while the sidebar is collapsed, so the breadcrumb follows
    /// the toggle in full screen, and comes back after the brand when it opens.
    @Test func collapsedSidebarDropsTheTrackingSeparator() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let native = NativeSplitPresentation(autosaveName: nil)
        native.install(in: window)
        func ids() -> [NSToolbarItem.Identifier] { native.toolbar.items.map(\.itemIdentifier) }
        #expect(ids().contains(.sidebarTrackingSeparator))
        native.sidebarItem.isCollapsed = true
        #expect(!ids().contains(.sidebarTrackingSeparator))
        native.sidebarItem.isCollapsed = false
        let items = ids()
        #expect(items.firstIndex(of: .sidebarTrackingSeparator) == items.firstIndex(of: NativeSplitPresentation.brand).map { $0 + 1 })
        window.toolbar = nil
        window.contentViewController = nil
    }

    /// The native sidebar takes T3's widths: 256 by default, at least 208, at most the window less 640.
    @Test func sidebarTakesT3sWidths() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let native = NativeSplitPresentation(autosaveName: nil)
        native.install(in: window)
        #expect(NativeSplitPresentation.sidebarPreferred == 256)
        let minimum = native.sidebarItem.minimumThickness
        #expect(minimum >= 208 && native.sidebarItem.maximumThickness == max(minimum, 1100 - 640))
        window.setContentSize(NSSize(width: 840, height: 780))
        native.root.frame.size = NSSize(width: 840, height: 780)
        #expect(native.sidebarItem.maximumThickness == native.sidebarItem.minimumThickness)
        window.toolbar = nil
        window.contentViewController = nil
    }

    /// A dialog makes the toolbar inert, as T3's backdrop covers its header, and closing it gives the clicks back.
    @Test func dialogsMakeTheToolbarInert() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let native = NativeSplitPresentation(autosaveName: nil)
        native.install(in: window)
        let toggle = native.toolbar.items.first { $0.itemIdentifier == NativeSplitPresentation.sidebarToggle }!
        #expect(!native.isInert && native.validateToolbarItem(toggle))
        let host = ModalHost.present(DialogView(kind: .alertDialog, title: "Delete thread?"), in: window, blurBackdrop: false)
        #expect(native.isInert && !native.validateToolbarItem(toggle))
        host.close(animated: false)
        #expect(!native.isInert)
        window.toolbar = nil
        window.contentViewController = nil
    }

    /// View > Zoom scales a column's content in place, and the content leaves the column unscaled.
    @Test func zoomScalesTheColumnsContent() {
        let column = NativeColumnView(detail: false)
        column.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let content = NSView()
        column.content = content
        column.scale = 1.2
        column.layoutSubtreeIfNeeded()
        #expect(abs(content.bounds.width - content.frame.width / 1.2) < 0.01)
        NSView().addSubview(content)
        #expect(content.bounds.size == content.frame.size)
    }

    /// Classic's header keeps its panel toggles hidden while no thread shows, through layouts and a round trip
    /// to Glass Native, so they and the details shortcut stay off before a thread loads.
    @Test func classicHeaderTogglesStayHiddenWithoutAThread() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
        window.contentView = panel
        panel.header.setThreadVisible(false)
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.header.toggles.allSatisfy { $0.isHidden })
        panel.hidesCustomChrome = true
        panel.layoutSubtreeIfNeeded()
        panel.hidesCustomChrome = false
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
}
