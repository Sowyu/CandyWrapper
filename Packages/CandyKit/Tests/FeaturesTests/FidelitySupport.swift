import AppKit
import Foundation
import Testing
import DesignSystem

// A copy of DesignSystemTests/FidelitySupport.swift: the two test targets can't share code.

/// What every fidelity test shares: pinned global render state, a per-run output folder and per-case ceilings.
enum Fidelity {
    /// ref, ours and diff PNGs plus reports. `CW_FIDELITY_OUT` picks the folder; otherwise each run gets its own
    /// temporary one, so parallel runs never overwrite each other.
    static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["CW_FIDELITY_OUT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("candywrapper-fidelity-\(getpid())")
    }()

    /// Renders depend on these globals. Reset them so the machine's Reduce Motion setting or a test that left a
    /// theme or font behind can't change the pixels.
    @MainActor static func pin() {
        Motion.reducedOverride = false
        SettingsPanelMotion.durationMs = 0
        ThemeRuntime.apply(ThemeRuntimeInput())
        FontRuntime.apply(FontRuntimeInput())
    }
}

/// `@Suite(.fidelity)` pins the render state before every test in the suite.
struct FidelityTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await MainActor.run { Fidelity.pin() }
        try await function()
    }
}

extension Trait where Self == FidelityTrait {
    static var fidelity: Self { FidelityTrait() }
}

/// Per-case ceilings on the share of pixels that differ, one entry per test: a base for every case plus named
/// exceptions. Values are a measured run plus margin, about max(diff * 1.5, diff + 0.02).
struct FidelityCeilings: ExpressibleByDictionaryLiteral {
    struct Ceiling {
        var base: Double
        var except: [String: Double]
        init(_ base: Double, except: [String: Double] = [:]) { self.base = base; self.except = except }
    }

    let tests: [String: Ceiling]
    init(dictionaryLiteral elements: (String, Ceiling)...) { tests = Dictionary(uniqueKeysWithValues: elements) }

    /// Fails each case over its ceiling, an empty run, and an exception naming no case.
    func check(_ test: String, _ cases: [(String, Double)], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!cases.isEmpty, "\(test): no cases rendered", sourceLocation: sourceLocation)
        let file = Test.current?.sourceLocation.fileID ?? "?"
        for (name, diff) in cases { print(String(format: "FIDELITY-CASE\t%@\t%@\t%@\t%.4f", file, test, name, diff)) }
        guard let ceiling = tests[test] else {
            Issue.record("\(test): no ceilings", sourceLocation: sourceLocation)
            return
        }
        for (name, diff) in cases {
            let limit = ceiling.except[name] ?? ceiling.base
            #expect(diff <= limit, "\(test) \(name): \(String(format: "%.2f%% differ, ceiling %.2f%%", diff * 100, limit * 100))",
                    sourceLocation: sourceLocation)
        }
        let names = Set(cases.map(\.0))
        for name in ceiling.except.keys where !names.contains(name) {
            Issue.record("\(test): ceiling for \(name), which didn't render", sourceLocation: sourceLocation)
        }
    }
}
