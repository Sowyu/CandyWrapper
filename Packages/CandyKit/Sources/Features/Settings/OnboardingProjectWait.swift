import Foundation

/// T3 3814 WelcomeWizard.tsx:1241-1260 and state/entities.ts:251-271.
/// Shell arrivals and the ten-second deadline race to finish setup once.
@MainActor
public final class OnboardingProjectWait {
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private var open: (() -> Bool)?
    private var finish: ((Bool) -> Void)?
    public init() {}
    public func start(open: @escaping () -> Bool, finish: @escaping (Bool) -> Void,
                      wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(10)) }) {
        cancel()
        self.open = open; self.finish = finish
        let current = generation
        deadline = Task { [weak self] in
            do { try await wait() } catch { return }
            guard let self, generation == current, !Task.isCancelled else { return }
            complete(self.open?() ?? false)
        }
        projectChanged()
    }
    public func projectChanged() { if open?() == true { complete(true) } }
    public func cancel() {
        generation = UUID()
        deadline?.cancel(); deadline = nil
        open = nil; finish = nil
    }
    private func complete(_ opened: Bool) {
        let callback = finish
        cancel()
        callback?(opened)
    }
}
