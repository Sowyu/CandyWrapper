import AppKit

/// Owners of tracking areas whose hover HoverSync drives. Every DSView is one; plain NSViews and
/// controllers that track hover for a DSView conform explicitly.
@MainActor
public protocol HoverSyncClient: AnyObject {}

extension DSView: HoverSyncClient {}

/// Hover that follows the pointer the way Chromium's `:hover` does.
///
/// AppKit sends mouseEntered and mouseExited only when the pointer moves across an area edge. Content
/// that scrolls, relayouts, hides, gets recycled or gets covered by a popup under a still pointer kept
/// a stale hover. HoverSync takes over enter and exit delivery for `HoverSyncClient` owners: it swallows
/// AppKit's own enter and exit events and recomputes the hovered areas from the pointer position
/// (`mouseLocationOutsideOfEventStream`) after every pointer move, geometry change, key or active change,
/// mouse up and native menu, then sends enter and exit for what changed. Owners keep their
/// mouseEntered and mouseExited overrides and get them in pairs.
///
/// Idle cost is zero: work runs only on events and geometry changes, and a pass ends at once when the
/// pointer is outside the window and nothing is hovered.
@MainActor
public final class HoverSync: NSResponder {
    private static var syncs: [ObjectIdentifier: HoverSync] = [:]
    nonisolated(unsafe) private static var monitor: Any?

    private weak var window: NSWindow?
    private var pointerArea: NSTrackingArea?
    private var hovered: [Key: Entry] = [:]
    private var scheduled = false

    /// One entered area: its owner, the view it is installed on and its index among that view's
    /// managed areas for the owner, so an area that a view recreates in `updateTrackingAreas` keeps its hover.
    struct Key: Hashable {
        let owner: ObjectIdentifier
        let view: ObjectIdentifier
        let ordinal: Int
    }

    struct Entry {
        weak var owner: NSResponder?
        weak var view: NSView?
        weak var area: NSTrackingArea?
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Install

    /// Installs hover sync for `window`. DSView calls it whenever it joins a window; repeat calls are cheap.
    public static func install(in window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let existing = syncs[id] {
            existing.ensurePointerArea()
            return
        }
        let sync = HoverSync(window: window)
        syncs[id] = sync
        sync.ensurePointerArea()
        installGlobalObservers()
        let center = NotificationCenter.default
        center.addObserver(sync, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(sync, selector: #selector(windowStateChanged(_:)), name: name, object: window)
        }
    }

    /// Marks `window` for a hover pass on the next run loop turn. Views call it when they hide, leave
    /// the window, or change what sits under the pointer without a geometry change.
    public static func setNeedsSync(_ window: NSWindow?) {
        guard let window, let sync = syncs[ObjectIdentifier(window)] else { return }
        sync.setNeedsSync()
    }

    /// Runs a hover pass for `window` now.
    public static func syncNow(_ window: NSWindow?) {
        guard let window, let sync = syncs[ObjectIdentifier(window)] else { return }
        sync.sync()
    }

    private func ensurePointerArea() {
        guard let content = window?.contentView else { return }
        if let pointerArea, content.trackingAreas.contains(pointerArea) { return }
        // One area over the whole content view: pointer moves anywhere in the window re-run the pass,
        // and leaving the window drops every hover.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        content.addTrackingArea(area)
        pointerArea = area
    }

    private static func installGlobalObservers() {
        guard monitor == nil else { return }
        // AppKit's own enter and exit events for client areas are dropped here; the pass delivers them.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseEntered, .mouseExited, .leftMouseUp, .rightMouseUp, .otherMouseUp]) { event in
            nonisolated(unsafe) let event = event
            let drop = MainActor.assumeIsolated { HoverSync.handle(event) }
            return drop ? nil : event
        }
        let center = NotificationCenter.default
        let observer = GeometryObserver.shared
        // Every view posts these by default; together they cover layout, scrolling and resizing.
        center.addObserver(observer, selector: #selector(GeometryObserver.geometryChanged(_:)), name: NSView.frameDidChangeNotification, object: nil)
        center.addObserver(observer, selector: #selector(GeometryObserver.geometryChanged(_:)), name: NSView.boundsDidChangeNotification, object: nil)
        center.addObserver(observer, selector: #selector(GeometryObserver.everything(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(observer, selector: #selector(GeometryObserver.everything(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(observer, selector: #selector(GeometryObserver.everything(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(observer, selector: #selector(GeometryObserver.everything(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    /// True when the monitor should drop `event`.
    private static func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // A drag ended: areas skipped while the button was down catch up.
            setNeedsSync(event.window)
            return false
        default:
            guard let area = event.trackingArea, let window = event.window,
                  let sync = syncs[ObjectIdentifier(window)], isManaged(area, on: nil) else { return false }
            sync.setNeedsSync()
            return true
        }
    }

    @objc private func windowWillClose(_ note: Notification) {
        for entry in hovered.values { deliver(.mouseExited, entry) }
        hovered.removeAll()
        if let window { Self.syncs[ObjectIdentifier(window)] = nil }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowStateChanged(_ note: Notification) { setNeedsSync() }

    public override func mouseMoved(with event: NSEvent) { sync() }
    public override func mouseEntered(with event: NSEvent) { sync() }
    public override func mouseExited(with event: NSEvent) { sync() }

    private func setNeedsSync() {
        guard !scheduled else { return }
        scheduled = true
        // Next turn: after this turn's layout has moved things.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                self.sync()
            }
        }
    }

    // MARK: The pass

    /// An area HoverSync drives: enter and exit, a client owner, and a rect the pass can find by walking
    /// the views under the pointer (the visible rect, or a rect inside its view).
    static func isManaged(_ area: NSTrackingArea, on view: NSView?) -> Bool {
        guard area.options.contains(.mouseEnteredAndExited), area.owner is HoverSyncClient else { return false }
        if area.options.contains(.inVisibleRect) { return true }
        // ponytail: an area that reaches outside its view stays with AppKit's own enter and exit; walk wider if one needs sync
        guard let host = view ?? (area.owner as? NSView), host.trackingAreas.contains(area) else { return false }
        return host.bounds.contains(area.rect)
    }

    func sync() {
        guard let window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        let buttonsDown = NSEvent.pressedMouseButtons != 0
        var now: [Key: Entry] = [:]
        if pointerIsInside(window, at: point), let content = window.contentView {
            let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            // A tooltip under the pointer covers nothing: its trigger keeps the hover that keeps it open.
            let popups = content.subviews.lazy.compactMap { $0 as? PopupHost }.first?.popups ?? []
            let passive = hit.map { h in popups.contains { $0.isPassive && h.isDescendant(of: $0.container) } } ?? false
            let hitLayer = passive ? nil : hit.map { stackKey(of: $0, in: content) }
            collect(content, point: point, window: window, content: content, hitLayer: hitLayer, into: &now)
        }
        // While a button is down AppKit sends enter and exit only to areas that ask for it; keep the rest as they are.
        if buttonsDown {
            for (key, entry) in hovered where !(entry.area?.options.contains(.enabledDuringMouseDrag) ?? false) {
                if entry.view?.window === window { now[key] = entry } else { now[key] = nil }
            }
            for (key, entry) in now where hovered[key] == nil && !(entry.area?.options.contains(.enabledDuringMouseDrag) ?? false) {
                now[key] = nil
            }
        }
        let exits = hovered.filter { now[$0.key] == nil }
        let enters = now.filter { hovered[$0.key] == nil }
        // Keep the newest area for areas that were recreated.
        for (key, entry) in now { hovered[key] = entry }
        for key in exits.keys { hovered[key] = nil }
        for entry in exits.values { deliver(.mouseExited, entry) }
        for entry in enters.values { deliver(.mouseEntered, entry) }
    }

    private func pointerIsInside(_ window: NSWindow, at point: NSPoint) -> Bool {
        guard window.isVisible, !window.isMiniaturized, let content = window.contentView,
              content.convert(content.bounds, to: nil).contains(point) else { return false }
        // A window, menu or panel above this one at the pointer takes the hover.
        let screen = window.convertPoint(toScreen: point)
        return NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    /// Walks the views whose bounds hold the point and gathers their managed areas that hold it too.
    private func collect(_ view: NSView, point: NSPoint, window: NSWindow, content: NSView, hitLayer: [Int]?,
                         into result: inout [Key: Entry]) {
        let local = view.convert(point, from: nil)
        guard view.bounds.contains(local) else { return }
        var ordinals: [ObjectIdentifier: Int] = [:]
        for area in view.trackingAreas where Self.isManaged(area, on: view) {
            guard let owner = area.owner as? NSResponder else { continue }
            let ownerID = ObjectIdentifier(owner)
            let ordinal = ordinals[ownerID, default: 0]
            ordinals[ownerID] = ordinal + 1
            let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
            guard rect.contains(local), isActive(area, view: view, window: window) else { continue }
            // Chromium hovers only what is under the top layer: a popup, dialog or palette covers what lies below it.
            if let hitLayer, Self.isAbove(hitLayer, stackKey(of: view, in: content)) { continue }
            result[Key(owner: ownerID, view: ObjectIdentifier(view), ordinal: ordinal)] = Entry(owner: owner, view: view, area: area)
        }
        for sub in view.subviews where !sub.isHidden {
            collect(sub, point: point, window: window, content: content, hitLayer: hitLayer, into: &result)
        }
    }

    private func isActive(_ area: NSTrackingArea, view: NSView, window: NSWindow) -> Bool {
        let o = area.options
        if o.contains(.activeAlways) { return true }
        if o.contains(.activeInActiveApp) { return NSApp.isActive }
        if o.contains(.activeInKeyWindow) { return window.isKeyWindow }
        if o.contains(.activeWhenFirstResponder) { return window.isKeyWindow && window.firstResponder === view }
        return true
    }

    /// Stacking position of a view: its top-level index under the content view, plus the popup index when
    /// it lives in the popup host. Overlays (popups, dialogs, the command palette) are top-level siblings.
    private func stackKey(of view: NSView, in content: NSView) -> [Int] {
        var chain: [NSView] = []
        var v: NSView? = view
        while let current = v, current !== content {
            chain.append(current)
            v = current.superview
        }
        guard v === content, let top = chain.last, let index = content.subviews.firstIndex(of: top) else { return [] }
        if top is PopupHost, chain.count >= 2, let popup = top.subviews.firstIndex(of: chain[chain.count - 2]) {
            return [index, popup]
        }
        return [index]
    }

    static func isAbove(_ a: [Int], _ b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    private func deliver(_ type: NSEvent.EventType, _ entry: Entry) {
        guard let owner = entry.owner else { return }
        let window = self.window
        // The tracking number is the area itself for AppKit's own events, so `event.trackingArea` still works.
        let number = entry.area.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        guard let event = NSEvent.enterExitEvent(with: type, location: window?.mouseLocationOutsideOfEventStream ?? .zero,
                                                 modifierFlags: NSEvent.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                 trackingNumber: number, userData: nil) else { return }
        if type == .mouseEntered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
    }
}

/// Receives the app-wide geometry notifications. Kept apart from HoverSync instances so one observer serves every window.
@MainActor
private final class GeometryObserver: NSObject {
    static let shared = GeometryObserver()

    @objc func geometryChanged(_ note: Notification) {
        HoverSync.setNeedsSync((note.object as? NSView)?.window)
    }

    @objc func everything(_ note: Notification) {
        for window in NSApp.windows { HoverSync.setNeedsSync(window) }
    }
}
