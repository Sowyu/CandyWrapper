import AppKit
import Testing
import T3Protocol
@testable import Features

/// The composer menus and chips against T3's own tests: composerSlashCommandSearch.test.ts,
/// composerInlineTokens.test.ts, composerContextReferences.test.ts and composer-logic.test.ts.
@MainActor
struct ComposerMenusTests {
    // MARK: Triggers

    @Test func triggers() {
        #expect(ComposerTriggers.detect("/mo", cursor: 3) == ComposerTrigger(kind: .slashCommand, query: "mo", rangeStart: 0, rangeEnd: 3))
        #expect(ComposerTriggers.detect("hi\n/", cursor: 4) == ComposerTrigger(kind: .slashCommand, query: "", rangeStart: 3, rangeEnd: 4))
        #expect(ComposerTriggers.detect("/model x", cursor: 8) == nil)
        // 3105 a01c48f86: a `/` token mid-message opens the command and skill menu.
        #expect(ComposerTriggers.detect("please /rev", cursor: 11) == ComposerTrigger(kind: .slashCommand, query: "rev", rangeStart: 7, rangeEnd: 11))
        #expect(ComposerTriggers.detect("see @src/Ch", cursor: 11) == ComposerTrigger(kind: .path, query: "src/Ch", rangeStart: 4, rangeEnd: 11))
        #expect(ComposerTriggers.detect("use $ui", cursor: 7) == ComposerTrigger(kind: .skill, query: "ui", rangeStart: 4, rangeEnd: 7))
        #expect(ComposerTriggers.detect("use €ui", cursor: 7)?.kind == .skill)
        #expect(ComposerTriggers.detect("fix #12", cursor: 7) == ComposerTrigger(kind: .pullRequest, query: "12", rangeStart: 4, rangeEnd: 7))
        #expect(ComposerTriggers.detect("fix #", cursor: 5)?.kind == .pullRequest)
        #expect(ComposerTriggers.detect("fix #-x", cursor: 7) == nil)
        #expect(ComposerTriggers.detect("plain", cursor: 5) == nil)
        // deb5b3941d: a path is not a command, also with the caret before the second slash.
        #expect(ComposerTriggers.detect("/tmp/build.sh", cursor: 13) == nil)
        #expect(ComposerTriggers.detect("/tmp/build.sh", cursor: 3) == nil)
        #expect(ComposerTriggers.detect("run /tmp/x", cursor: 7) == nil)
        #expect(ComposerTriggers.detect("/tmp next/", cursor: 4)?.query == "tmp")
        // The caret decides: before the token there is none.
        #expect(ComposerTriggers.detect("a @b", cursor: 1) == nil)
    }

    @Test func escapeKeepsTheMenuClosedUntilTheTokenChanges() {
        var state = ComposerTriggerState()
        let t = ComposerTrigger(kind: .path, query: "a", rangeStart: 0, rangeEnd: 2)
        state.set(t)
        state.dismiss()
        #expect(state.trigger == nil)
        state.set(ComposerTrigger(kind: .path, query: "ab", rangeStart: 0, rangeEnd: 3))
        #expect(state.trigger == nil)
        state.set(nil)
        state.set(t)
        #expect(state.trigger == t)
    }

    @Test func replacementTakesTheFollowingSpace() {
        #expect(ComposerTriggers.replacementEnd("@a b", rangeEnd: 2, replacement: "x ") == 3)
        #expect(ComposerTriggers.replacementEnd("@ab", rangeEnd: 3, replacement: "x ") == 3)
        #expect(ComposerTriggers.replacementEnd("@a b", rangeEnd: 2, replacement: "") == 2)
    }

    // MARK: Slash search (composerSlashCommandSearch.test.ts)

    static func command(_ name: String, _ description: String) -> ComposerMenuItem {
        ComposerMenuItem(id: "provider-slash-command:claudeAgent:\(name)", kind: .providerCommand(name), label: "/\(name)", description: description)
    }

    static func skillItem(_ s: ServerProviderSkill, _ description: String) -> ComposerMenuItem {
        ComposerMenuItem(id: "skill:claudeAgent:\(s.name)", kind: .skill(name: s.name, sourceKind: .other, viaSlash: true),
                         label: "/skill:\(s.name)", description: description)
    }

    @Test func slashSearchRanksLikeT3() {
        let items = [
            ComposerMenuItem(id: "slash:default", kind: .builtIn("default"), label: "/default", description: "Switch this thread back to normal build mode"),
            Self.command("ui", "Explore, build, and refine UI."),
            Self.command("frontend-design", "Create distinctive, production-grade frontend interfaces"),
        ]
        #expect(ComposerMenus.searchSlash(items, query: "ui", skills: []).map(\.id) == ["provider-slash-command:claudeAgent:ui", "slash:default"])
        let fuzzy = [Self.command("gh-fix-ci", "Fix failing GitHub Actions"), Self.command("github", "General GitHub help")]
        #expect(ComposerMenus.searchSlash(fuzzy, query: "gfc", skills: []).map(\.id) == ["provider-slash-command:claudeAgent:gh-fix-ci"])

        let browser = ServerProviderSkill(name: "browser", path: "/skills/browser/SKILL.md", shortDescription: "Open and control the in-app browser")
        let b = [Self.skillItem(browser, "Open and control the in-app browser")]
        #expect(ComposerMenus.searchSlash(b, query: "browser", skills: [browser]).count == 1)
        #expect(ComposerMenus.searchSlash(b, query: "control", skills: [browser]).count == 1)
        #expect(ComposerMenus.searchSlash(b, query: "/skill:brow", skills: [browser]).count == 1)
        #expect(ComposerMenus.searchSlash(b, query: "/sk", skills: [browser]).count == 1)
        #expect(ComposerMenus.searchSlash(b, query: "/ill", skills: [browser]).isEmpty)

        let matt = ServerProviderSkill(name: "ask-matt", path: "/skills/ask-matt/SKILL.md", displayName: "Ask Matt", shortDescription: "Find the right skill or workflow")
        let m = [Self.skillItem(matt, "Find the right skill or workflow")]
        #expect(ComposerMenus.searchSlash(m, query: "ask matt", skills: [matt]).count == 1)
        #expect(ComposerMenus.searchSlash(m, query: "/skill:ask-matt", skills: [matt]).count == 1)
    }

    @Test func providerCommandsOnlyOpenThePrompt() {
        let commands = [ServerProviderSlashCommand(name: "compact", description: "Compact"), ServerProviderSlashCommand(name: "review")]
        let skills = [ServerProviderSkill(name: "review", path: "/r"), ServerProviderSkill(name: "off", path: "/o", enabled: false)]
        let start = ComposerTrigger(kind: .slashCommand, query: "", rangeStart: 0, rangeEnd: 1)
        let ids = ComposerMenus.slashItems(trigger: start, provider: "p", commands: commands, skills: skills, showSkills: true,
                                           planMode: false, compactAvailable: false).map(\.id)
        // `/compact` waits for an idle thread; a skill shadows the command of the same name; disabled skills stay out.
        #expect(ids == ["slash:model", "skill:p:review"])
        let later = ComposerTrigger(kind: .slashCommand, query: "", rangeStart: 5, rangeEnd: 6)
        let laterIds = ComposerMenus.slashItems(trigger: later, provider: "p", commands: commands, skills: [], showSkills: true,
                                                planMode: true, compactAvailable: true).map(\.id)
        #expect(laterIds == ["slash:model", "slash:plan", "slash:default"])
    }

    @Test func skillSearch() {
        let skills = [ServerProviderSkill(name: "pdf-tools", path: "/a", scope: "user"), ServerProviderSkill(name: "commit", path: "/b", scope: "repo"),
                      ServerProviderSkill(name: "Commit", path: "/c")]
        let items = ComposerMenus.skillItems(query: "", provider: "p", skills: skills)
        #expect(items.map(\.label) == ["Pdf Tools", "Commit"])
        #expect(ComposerMenus.skillItems(query: "$com", provider: "p", skills: skills).map(\.label) == ["Commit"])
        #expect(ProviderSkills.sourceKind(skills[0]) == .personal)
        #expect(ProviderSkills.sourceKind(ServerProviderSkill(name: "x", path: "/u/.codex/plugins/x")) == .app)
    }

    @Test func threadAndPathItems() {
        let threads = [ComposerMenus.ThreadCandidate(id: "a", title: "Fix login", updatedAt: "2026-10-01", archived: false),
                       ComposerMenus.ThreadCandidate(id: "b", title: "Login copy", updatedAt: "2026-10-02", archived: false),
                       ComposerMenus.ThreadCandidate(id: "c", title: "login old", updatedAt: "2026-10-03", archived: true)]
        #expect(ComposerMenus.threadItems(query: "", threads: threads, excluding: nil).isEmpty)
        #expect(ComposerMenus.threadItems(query: "LOGIN", threads: threads, excluding: "b").map(\.id) == ["thread:a"])
        #expect(ComposerMenus.threadItems(query: "login", threads: threads, excluding: nil).map(\.id) == ["thread:b", "thread:a"])
        let paths = ComposerMenus.pathItems([("src/app/Chat.tsx", false), ("README.md", false), ("src", true)])
        #expect(paths.map(\.label) == ["Chat.tsx", "README.md", "src"])
        #expect(paths.map(\.description) == ["src/app", "", ""])
        #expect(paths[2].id == "path:directory:src")
    }

    @Test func pullRequestItems() {
        func entry(_ n: Int, _ title: String, _ updated: String) -> ComposerMenus.PullRequestEntry {
            .init(reference: PullRequestReference(number: n, title: title, url: "u", headBranch: "h\(n)", baseBranch: "main", state: "open", isDraft: false),
                  repository: "o/r", authorLogin: nil, updatedAt: updated)
        }
        let entries = [entry(12, "Login fix", "2026-10-01"), entry(1, "Docs", "2026-10-03"), entry(112, "Welcome wizard", "2026-10-02")]
        #expect(ComposerMenus.pullRequestItems(query: "12", entries: entries, hostSearched: false).map(\.label) == ["#12", "#112"])
        #expect(ComposerMenus.pullRequestItems(query: "", entries: entries, hostSearched: false).map(\.label) == ["#1", "#112", "#12"])
        #expect(ComposerMenus.pullRequestItems(query: "wizard welcome", entries: entries, hostSearched: true).map(\.label) == ["#112", "#1", "#12"])
    }

    // MARK: Tokens (composerInlineTokens.test.ts)

    @Test func inlineTokens() {
        let text = "Use $ui and inspect [Chat.tsx](src/Chat.tsx) with @AGENTS.md please"
        let tokens = ComposerInlineTokens.collect(text)
        #expect(tokens.map(\.source) == ["$ui", "[Chat.tsx](src/Chat.tsx)", "@AGENTS.md"])
        #expect(tokens.map(\.range.location) == [4, 20, 50])
        #expect(tokens[1].kind == .mention(path: "src/Chat.tsx"))
        for prefix in ["$", "€", "₹"] { #expect(ComposerInlineTokens.collect("Use \(prefix)2spec next").first?.kind == .skill(name: "2spec")) }
        for money in ["I'll pay $20 tomorrow", "Budget is $1_000 total", "Budget is $20k tomorrow", "Cost is $100M total", "Limit is $1e6 here"] {
            #expect(ComposerInlineTokens.collect(money).isEmpty)
        }
        #expect(ComposerInlineTokens.collect("Use $ui").isEmpty)
        #expect(ComposerInlineTokens.collect("Inspect @AGENTS.md").isEmpty)
        #expect(ComposerInlineTokens.collect("Read [docs](https://example.com) first").isEmpty)
        #expect(ComposerInlineTokens.collect("Install @expo/ui next").isEmpty)
        #expect(ComposerInlineTokens.collect("入力 @expo/ui\u{3000}を追加").isEmpty)
        #expect(ComposerInlineTokens.collect("Inspect [sub](@scope/pkg/sub) next").first?.kind == .mention(path: "@scope/pkg/sub"))
        #expect(ComposerInlineTokens.collect("Inspect @\"expo/ui\" next").first?.kind == .mention(path: "expo/ui"))
        let link = "[Fix login](t3-context://v1/thread/thread_abc)"
        let ctx = ComposerInlineTokens.collect("see \(link)")
        #expect(ctx.first?.kind == .context(kind: "thread", contextId: "thread_abc", label: "Fix login"))
        #expect(ctx.first?.range == NSRange(location: 4, length: (link as NSString).length))
    }

    @Test func fileLinksRoundTrip() {
        #expect(ComposerInlineTokens.fileLink("src/a b/Chat (1).tsx") == "[Chat (1).tsx](src/a%20b/Chat%20%281%29.tsx)")
        #expect(ComposerInlineTokens.fileLink("docs/[x].md") == "[\\[x\\].md](docs/%5Bx%5D.md)")
        let token = ComposerInlineTokens.collect(ComposerInlineTokens.fileLink("src/a b/Chat (1).tsx") + " ").first
        #expect(token?.kind == .mention(path: "src/a b/Chat (1).tsx"))
    }

    // MARK: Context ids and records (composerContextReferences.test.ts)

    @Test func contextIds() {
        #expect(ComposerContext.kindScopedId("image", "x") == "image_x")
        #expect(ComposerContext.contextId("file-comment-1700-1") == "file-comment-1700-1")
        let folded = ComposerContext.contextId("pull-request-selection:src/a.ts:4-9")
        #expect(folded.range(of: "^pull-request-selection-src-a-ts-4-9-[0-9a-f]{16}$", options: .regularExpression) != nil)
        #expect(ComposerContext.contextId("::").range(of: "^ctx-[0-9a-f]{16}$", options: .regularExpression) != nil)
        // `pr-reference:7` folds like T3: the same id always.
        #expect(ComposerContext.kindScopedId("review-comment", "pr-reference:7") == ComposerContext.contextId("review-comment_pr-reference:7"))
        #expect(ComposerContext.reference(.init(kind: "thread", contextId: "thread_a", label: "A [b]\nc")) == "[A b c](t3-context://v1/thread/thread_a)")
    }

    @Test func messageContextKeepsReferencedRecordsInOrder() {
        let pr = PullRequestReference(number: 7, title: "Fix", url: "https://x/7", headBranch: "f", baseBranch: "main", state: "open", isDraft: true)
        let prRecord = ComposerContext.pullRequestRecord(pr)
        let thread = ComposerContext.threadRecord(threadId: "abc", title: "Login", environmentId: "env")
        let prompt = "look " + ComposerMenus.replacement(for: .init(id: "t", kind: .thread(id: "abc", title: "Login"), label: "", description: ""))
            + ComposerMenus.replacement(for: .init(id: "p", kind: .pullRequest(pr), label: "", description: ""))
        let records = [thread["contextId"]!.stringValue!: thread, prRecord["contextId"]!.stringValue!: prRecord, "unused": .null]
        let context = ComposerContext.messageContext(prompt: prompt, records: records)
        guard case .array(let list)? = context?["records"] else { Issue.record("no records"); return }
        #expect(list.map { $0["kind"]?.stringValue } == ["thread", "review-comment"])
        #expect(ComposerContext.pullRequest(in: prRecord)?.displayState == "draft")
        #expect(ComposerContext.messageContext(prompt: "plain", records: records) == nil)
        #expect(ComposerContext.stripReferences(prompt).trimmingCharacters(in: .whitespaces) == "look")
    }

    @Test func questionAnswersSendThreadChipsAsThreadLinks() {
        let thread = ComposerContext.threadRecord(threadId: "abc", title: "Login", environmentId: "env")
        let answer = "see [Login](t3-context://v1/thread/thread_abc) and [Gone](t3-context://v1/thread/thread_zzz)"
        #expect(ComposerContext.projectAnswer(answer, records: ["thread_abc": thread])
            == "see [Login](t3-thread://v1/abc) and [Gone](t3-context://v1/thread/thread_zzz)")
        #expect(ComposerContext.threadLink("abc", label: "a [b]\nc") == "[a b c](t3-thread://v1/abc)")
        #expect(ComposerContext.threadLink("abc", label: " ") == "[abc](t3-thread://v1/abc)")
    }

    @Test func clipboardFragmentRoundTrip() throws {
        let thread = ComposerContext.threadRecord(threadId: "abc", title: "Login", environmentId: "env")
        let text = "see [Login](t3-context://v1/thread/thread_abc) <b>"
        let html = try #require(ComposerContext.clipboardHTML(text: text, records: [thread], environmentId: "env"))
        #expect(html.hasSuffix("see [Login](t3-context://v1/thread/thread_abc) &lt;b&gt;</pre>"))
        #expect(ComposerContext.pastedRecords(html: html, pastedText: text)["thread_abc"] == thread)
        // Only records whose links were pasted come through.
        #expect(ComposerContext.pastedRecords(html: html, pastedText: "see").isEmpty)
        #expect(ComposerContext.pastedRecords(html: "<pre data-t3-context-fragment=\"%7B%7D\">x</pre>", pastedText: text).isEmpty)
    }

    // MARK: Editor chips

    @Test func chipsCollapseExpandAndDeleteAsOneUnit() {
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        composer.text = "Use $ui and [Chat.tsx](src/Chat.tsx) now"
        let editor = composer.editor
        #expect(editor.string == "Use \u{FFFC} and \u{FFFC} now")
        #expect(composer.text == "Use $ui and [Chat.tsx](src/Chat.tsx) now")
        // Backspace after a chip removes the whole token.
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.deleteBackward(nil)
        #expect(composer.text == "Use  and [Chat.tsx](src/Chat.tsx) now")
        // Typing a finished token turns it into a chip.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" $review ", replacementRange: editor.selectedRange())
        #expect(editor.string.filter { $0 == "\u{FFFC}" }.count == 2)
        #expect(composer.text.hasSuffix("now $review "))
        // Copy writes the expanded text.
        let pboard = NSPasteboard(name: NSPasteboard.Name("candy-test-\(UUID().uuidString)"))
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        #expect(editor.writeSelection(to: pboard, types: [.string]))
        #expect(pboard.string(forType: .string) == composer.text)
        pboard.releaseGlobally()
    }

    @Test func menuPickReplacesTheTrigger() {
        let menu = ComposerCommandMenuView()
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        let controller = ComposerMenuController(composer: composer, menu: menu)
        let item = ComposerMenuItem(id: "path:file:src/Chat.tsx", kind: .path(path: "src/Chat.tsx", isDirectory: false), label: "Chat.tsx", description: "src")
        controller.itemsProvider = { _ in .init(items: [item], emptyText: "") }
        composer.text = "see @cha"
        composer.editor.setSelectedRange(NSRange(location: 8, length: 0))
        controller.update()
        #expect(controller.isOpen)
        #expect(menu.activeItemId == item.id)
        controller.select(item)
        #expect(composer.text == "see [Chat.tsx](src/Chat.tsx) ")
        #expect(composer.displayText == "see \u{FFFC} ")
        #expect(!controller.isOpen)
    }
}
