import DesignSystem
import Testing
@testable import Features

/// A theme mutation must end before an async test yields the main actor to another suite.
@MainActor func withTheme<T>(_ input: ThemeRuntimeInput, _ body: () throws -> T) rethrows -> T {
    let previous = ThemeRuntime.input
    ThemeRuntime.apply(input)
    defer { ThemeRuntime.apply(previous) }
    return try body()
}

/// Layout tests choose a design without changing the theme that concurrent tests draw with.
struct ThreadDesignTrait: TestTrait, SuiteTrait, TestScoping {
    let modern: Bool
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await ThreadDesign.$layoutUses3814.withValue(modern) { try await function() }
    }
}

extension Trait where Self == ThreadDesignTrait {
    static func threadDesign(_ modern: Bool) -> Self { Self(modern: modern) }
}
