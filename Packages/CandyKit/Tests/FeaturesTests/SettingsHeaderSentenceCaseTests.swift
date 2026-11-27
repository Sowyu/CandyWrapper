import Testing
@testable import Features

/// Redesign's page pills use the sidebar's sentence case (round-1 review, X1: "Pull Requests" beside "Pull requests").
struct SettingsHeaderSentenceCaseTests {
    @Test func lowersTitleCaseWordsAndKeepsNames() {
        #expect(SettingsHeaderView.sentenceCase("Pull Requests") == "Pull requests")
        #expect(SettingsHeaderView.sentenceCase("Workflows") == "Workflows")
        #expect(SettingsHeaderView.sentenceCase("Open GitHub PR") == "Open GitHub PR")
        #expect(SettingsHeaderView.sentenceCase("Source control & issues") == "Source control & issues")
    }
}
