import AppKit

/// A view built the first time something shows it, so hidden surfaces cost nothing at launch.
/// Wiring and settings given before then wait and run on the new view in the order they came;
/// `set` keeps only the last value per property. `release()` drops the view, and the next `view`
/// builds a fresh one with the same wiring and settings.
@MainActor
public final class LazyView<V: NSView> {
    private let make: () -> V
    private var setups: [(key: AnyKeyPath?, apply: (V) -> Void)] = []
    public private(set) var loaded: V?
    /// Runs once on each new view, after the waiting setups (the owner adds it to its tree here).
    public var onLoad: ((V) -> Void)?

    public init(_ make: @escaping () -> V) { self.make = make }

    /// The view, built now if it isn't yet.
    public var view: V {
        if let loaded { return loaded }
        let built = make()
        loaded = built
        for setup in setups { setup.apply(built) }
        onLoad?(built)
        return built
    }

    /// Wiring that every built view gets: runs now on a loaded view and on each later one.
    public func configure(_ setup: @escaping (V) -> Void) {
        setups.append((nil, setup))
        if let loaded { setup(loaded) }
    }

    /// A property every built view gets; a later value replaces the earlier one.
    public func set<T>(_ path: ReferenceWritableKeyPath<V, T>, _ value: T) {
        let apply: (V) -> Void = { $0[keyPath: path] = value }
        if let i = setups.firstIndex(where: { $0.key == path }) { setups[i].apply = apply } else { setups.append((path, apply)) }
        loaded?[keyPath: path] = value
    }

    /// Drops the view; its state goes with it.
    public func release() {
        loaded?.removeFromSuperview()
        loaded = nil
    }
}
