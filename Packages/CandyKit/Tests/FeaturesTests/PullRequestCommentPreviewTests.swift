import Testing
@testable import Features

/// #32283: T3's own cases for `pullRequestCommentPreview` (4928 pullRequestMarkdown.logic.test.ts).
struct PullRequestCommentPreviewTests {
    @Test(arguments: [
        ("<!-- hidden -->\n> [!WARNING]\n**Guard** [this](https://example.com).", "Guard this."),
        ("<a href=\"https://example.com\"><img src=\"badge.svg\" /></a>\n<strong>Tasks keep the wrong computer</strong>", "Tasks keep the wrong computer"),
        ("<details><summary>Review &amp; fixes</summary><p>First<br>Second</p></details>", "Review & fixes First Second"),
        ("<p title=\"value > limit\">Keep <strong>this</strong> readable.</p>", "Keep this readable."),
        ("Use `<div>` and `Promise<void>`.\n\n```html\n<span>example</span>\n```", "Use <div> and Promise<void>. <span>example</span>"),
        ("![badge](https://example.com/badge.svg) **Review**", "badge Review"),
        ("```md\n[!TIP]\n> [!WARNING]\n```\n\n    [!NOTE]", "[!TIP] > [!WARNING] [!NOTE]"),
        ("Review :codex-file-citation{purpose='output'} safely.", "Review :codex-file-citation{purpose='output'} safely."),
        (":codex-followup[Prepare **print** version]", ":codex-followup[Prepare **print** version]"),
    ])
    func readableText(_ body: String, _ expected: String) {
        #expect(PullRequestDetailLogic.collapsedSummary(body) == expected)
    }
}
