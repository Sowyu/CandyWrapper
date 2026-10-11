import Foundation
import T3Protocol

/// The window's route history, as Electron's `window.history` holds T3's routes: threads, drafts,
/// Settings pages and the Pull Requests and Usage pages. `navigation.back` and `navigation.forward`
/// move through it like a browser's buttons (AppSidebarLayout.tsx:168-213).
@MainActor
public final class RouteHistory {
    public enum Route: Equatable {
        case thread(ThreadId)
        case draft(String)
        case settings(SettingsSection)
        case pullRequests
        case usage
    }

    public private(set) var entries: [Route] = []
    public private(set) var index = -1
    /// True while a back or forward navigation applies its route, so it records nothing.
    private var moving = false
    /// Shows a route; false when it no longer exists (a deleted thread, a sent draft).
    public var apply: (Route) -> Bool = { _ in false }

    // ponytail: 100 entries; Chromium keeps 50 per tab, cap differently if memory reviews care
    static let limit = 100

    public init() {}

    /// A navigation happened: a new route pushes and drops the forward entries.
    public func record(_ route: Route?) {
        guard !moving, let route, index < 0 || entries[index] != route else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(route)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    /// `history.back()`: the nearest earlier route that still exists. Returns false at the start.
    @discardableResult
    public func back() -> Bool { move(by: -1) }

    /// `history.forward()`.
    @discardableResult
    public func forward() -> Bool { move(by: 1) }

    private func move(by step: Int) -> Bool {
        var i = index + step
        while entries.indices.contains(i) {
            moving = true
            let shown = apply(entries[i])
            moving = false
            if shown { index = i; return true }
            entries.remove(at: i)
            if step < 0 { index -= 1; i -= 1 }
        }
        return false
    }
}
