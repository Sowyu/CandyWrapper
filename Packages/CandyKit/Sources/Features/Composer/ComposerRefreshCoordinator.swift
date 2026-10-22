import DesignSystem

/// Prompt edits never invalidate thread-derived state. Coalesce their link and menu updates
/// after the typed frame; a full refresh consumes that work when other inputs change first.
@MainActor
public final class ComposerRefreshCoordinator {
    private let threadState: () -> Void
    private let promptState: () -> Void
    private let afterCommit: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var generation = 0
    private var pending = false

    public init(threadState: @escaping () -> Void, promptState: @escaping () -> Void,
                afterCommit: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { AfterCommit.run($0) }) {
        self.threadState = threadState
        self.promptState = promptState
        self.afterCommit = afterCommit
    }

    public func promptChanged() {
        guard !pending else { return }
        pending = true
        let scheduled = generation
        afterCommit { [weak self] in
            guard let self, pending, generation == scheduled else { return }
            pending = false
            promptState()
        }
    }

    public func refresh() {
        generation += 1
        pending = false
        threadState()
        promptState()
    }
}
