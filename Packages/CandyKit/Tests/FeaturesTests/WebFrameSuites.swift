import Testing

/// The web frame suites share `ThreadWebFrameBudget`'s process-wide state (its live frames and data store), so
/// they run one at a time instead of evicting each other's frames.
@Suite(.serialized) @MainActor enum WebFrameSuites {}
