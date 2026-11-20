import Testing
@testable import Features

/// #35100: Auto-compact after takes 100,000 to 1,000,000 or nothing (contracts settings.ts:764).
@MainActor @Suite struct ProviderFieldValidationTests {
    @Test func autoCompactWindowPattern() throws {
        let field = try #require(ProvidersLogic.fields("claudeAgent").first { $0.key == "autoCompactWindow" })
        for ok in ["", "  ", "100000", "300000", " 999999 ", "1000000"] { #expect(field.accepts(ok), "\(ok)") }
        for bad in ["99999", "1000001", "300k", "0300000", "-100000"] { #expect(!field.accepts(bad), "\(bad)") }
        // Fields without a pattern accept anything.
        #expect(ProvidersLogic.fields("claudeAgent").first { $0.key == "launchArgs" }?.accepts("--anything") == true)
    }
}
