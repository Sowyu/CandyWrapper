import AppKit
import DesignSystem

/// The main window's layout as the app sees it, whichever presentation shows it: T3's custom-drawn one
/// (`SidebarLayoutView`) or Glass Native's toolbar and split view (`NativeSplitPresentation`). The sidebar and
/// page views stay the same objects across a swap, so the open thread, the draft, the scroll position and the
/// sidebar's selection go with them.
@MainActor
public protocol MainPresentation: AnyObject {
    /// The window's content view. Popups, modals, the palette and other overlays go on it.
    var root: NSView { get }
    /// The sidebar column's view: the thread sidebar, or Settings' navigation.
    var sidebarContent: NSView? { get set }
    /// The main column's page: the thread panel, Settings or a utility page.
    var mainContent: NSView? { get set }
    var isSidebarOpen: Bool { get }
    func toggleSidebar()
    /// Puts the presentation in `window`.
    func install(in window: NSWindow)
    /// Views on `root` that the presentation owns. Everything else on `root` is an overlay and moves on a swap.
    func ownsChrome(_ view: NSView) -> Bool
}

/// A sidebar or page view with custom chrome (titlebar row, header) that Glass Native's toolbar replaces.
@MainActor
public protocol CustomChromeHiding: AnyObject {
    var hidesCustomChrome: Bool { get set }
}

/// A page whose content scrolls under Glass Native's toolbar: it fills the column and keeps its own content clear
/// of the toolbar's `toolbarInset`.
@MainActor
public protocol ToolbarUnderlapping: AnyObject {
    var toolbarInset: CGFloat { get set }
}

extension ThreadPanelView: ToolbarUnderlapping {}

extension SidebarContentView: CustomChromeHiding {}
extension SettingsSidebarView: CustomChromeHiding {}
extension ThreadPanelView: CustomChromeHiding {}

extension SidebarLayoutView: MainPresentation {
    public var root: NSView { self }

    public var sidebarContent: NSView? {
        get { sidebar.content }
        set {
            (newValue as? CustomChromeHiding)?.hidesCustomChrome = false
            sidebar.content = newValue
        }
    }

    public var mainContent: NSView? {
        get { main.subviews.first }
        set {
            for view in main.subviews where view !== newValue { view.removeFromSuperview() }
            if let newValue, newValue.superview !== main {
                (newValue as? CustomChromeHiding)?.hidesCustomChrome = false
                main.addSubview(newValue)
            }
            needsLayout = true
        }
    }

    public var isSidebarOpen: Bool { isOpen }
    public func toggleSidebar() { toggle() }

    public func install(in window: NSWindow) {
        let frame = window.frame
        window.toolbar = nil
        window.titleVisibility = .hidden
        window.contentViewController = nil
        window.contentView = self
        window.setFrame(frame, display: false)
    }

    public func ownsChrome(_ view: NSView) -> Bool {
        view === main || view === sidebar || view === rail || view === collapsedTrigger || view is WindowGlassBackdropView
    }
}

@MainActor
public enum MainPresentationSwap {
    /// Moves the sidebar, the page and the overlays from `old` to `new` and installs `new` in `window`. Nothing
    /// keeps `old` afterwards, so it and its chrome deallocate once the caller drops it.
    public static func swap(from old: MainPresentation, to new: MainPresentation, in window: NSWindow) {
        let sidebar = old.sidebarContent, page = old.mainContent
        let overlays = old.root.subviews.filter { !old.ownsChrome($0) }
        let responder = window.firstResponder
        old.sidebarContent = nil
        old.mainContent = nil
        for view in overlays { view.removeFromSuperview() }
        new.install(in: window)
        new.sidebarContent = sidebar
        new.mainContent = page
        for view in overlays { new.root.addSubview(view) }
        // The focused view moved with its column; give it the focus back (the composer's draft keeps its caret).
        if let view = responder as? NSView, view.window === window { window.makeFirstResponder(view) }
    }
}
