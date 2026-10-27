import Foundation
import Testing
import T3Protocol
@testable import Features

// Mirrors packages/shared/src/paletteSearch.test.ts, including its suite and case names.
private typealias PS = PaletteScoring
private typealias Subject = PS.ThreadSearchSubject
private typealias SearchRange = PS.SearchRange
private typealias Pick = ThreadOpens.Pick
private let now = 1_792_713_600_000.0 // Date.UTC(2026, 9, 23), in milliseconds
private let day = 24.0 * 60 * 60 * 1_000

private func thread(_ title: String, id: String? = nil, branch: String? = nil,
                    projectTitle: String? = nil, environmentLabel: String? = nil,
                    pullRequests: [Subject.PullRequest] = [], activityAt: Double = now - 30 * day,
                    opens: ThreadOpens? = nil) -> Subject {
    Subject(id: id, title: title, branch: branch, projectTitle: projectTitle,
            environmentLabel: environmentLabel, pullRequests: pullRequests, activityAt: activityAt, opens: opens)
}

@MainActor private func rankTitles(_ query: String, _ threads: [Subject]) -> [String] {
    let normalized = PS.foldSearchQuery(query)
    return PS.rankSearchItems(threads) { subject, typos in
        PS.scoreThreadSearch(normalized, subject, now: now, typos: typos)
    }.map { $0.item.title }
}

private func scoreMessageMatch(_ text: String, _ query: String) -> PS.MessageMatch? {
    PS.messageMatcher(query)(text)
}

// Accessors supply the optional fields omitted by the TypeScript fixtures.
private struct MessageHit {
    var key: String
    var quality: Double
    var hits: Int? = nil
}

@MainActor private func rankedMessages(_ matches: [MessageHit], subjects: [String: Subject], query: String,
                                      withoutTitleMatches: Bool = false) -> [String] {
    PS.rankMessageMatches(matches, quality: { $0.quality }, hits: { $0.hits }, messageCreatedAt: { _ in nil },
                          subjectOf: { subjects[$0.key] }, normalizedQuery: query, now: now,
                          withoutTitleMatches: withoutTitleMatches).map(\.key)
}

@Suite @MainActor
struct PaletteScoringTests {
    @Suite("scoreThreadSearch") @MainActor
    struct ScoreThreadSearch {
        @Test("ranks whole words over prefixes over newer mid-word matches")
        func wholeWordsOverPrefixes() {
            #expect(rankTitles("auth", [
                thread("Fix oauth redirect", activityAt: now),
                thread("Authentication cleanup"),
                thread("Share auth across worktrees"),
            ]) == ["Share auth across worktrees", "Authentication cleanup", "Fix oauth redirect"])
        }

        @Test("treats camelCase, kebab, path, and digit boundaries as word starts")
        func wordStarts() throws {
            func starts(_ title: String, _ query: String) -> [SearchRange]? {
                PS.scoreThreadSearch(query, thread(title), now: now)?.ranges
            }
            #expect(starts("useThreadSearch hook", "search") == [SearchRange(start: 9, end: 15)])
            #expect(starts("fix/sidebar-perf", "perf") == [SearchRange(start: 12, end: 16)])
            #expect(starts("Upgrade to pnpm12", "12") == [SearchRange(start: 15, end: 17)])
            #expect(starts("Fix JSONSchema parsing", "sch") == [SearchRange(start: 8, end: 11)])
            #expect(starts("Fix HTTPServer crash", "ser") == [SearchRange(start: 8, end: 11)])
            #expect(starts("Rename index.ts", ".ts") == [SearchRange(start: 12, end: 15)])
            // A match is whole only where a word ends.
            let quality = try #require(PS.scoreThreadSearch("githuba", thread("GitHubActions setup"), now: now)?.quality)
            #expect(quality < 1)
            #expect(rankTitles(".ts", [thread("Fix parser.tsx"), thread("Rename index.ts")]) == [
                "Rename index.ts", "Fix parser.tsx",
            ])
            #expect(PS.scoreThreadSearch("ci", thread("Decision log"), now: now) == nil)
        }

        @Test("lets recent activity and frequent opens decide between equal matches")
        func activityAndOpens() {
            #expect(rankTitles("goldbug", [
                thread("Goldbug epilogue", activityAt: now - 20 * day),
                thread("Goldbug processes", activityAt: now - day),
            ]) == ["Goldbug processes", "Goldbug epilogue"])
            #expect(rankTitles("goldbug", [
                thread("Goldbug processes", activityAt: now - day),
                thread("Goldbug notes", activityAt: now - 40 * day,
                       opens: ThreadOpens(openedAt: now - day, score: 12, picks: [])),
            ]) == ["Goldbug notes", "Goldbug processes"])
        }

        @Test("puts the thread picked for a query first when that query is typed again")
        func queryPicks() {
            let threads = [
                thread("Release checklist", opens: ThreadOpens(openedAt: now - 5 * day, score: 1,
                       picks: [Pick(query: "rel", at: now - 5 * day)])),
                thread("Relay pairing", activityAt: now),
            ]
            #expect(rankTitles("rel", threads) == ["Release checklist", "Relay pairing"])
            // A pick never lifts a mid-word match above a word match.
            #expect(rankTitles("auth", [
                thread("Fix oauth redirect", opens: ThreadOpens(openedAt: now - day, score: 1,
                       picks: [Pick(query: "auth", at: now - day)])),
                thread("Share auth across worktrees"),
            ]) == ["Share auth across worktrees", "Fix oauth redirect"])
            #expect(rankTitles("re", threads) == ["Relay pairing", "Release checklist"])
            #expect(rankTitles("rela", threads) == ["Relay pairing"])
            let stale = [
                thread("Release checklist", opens: ThreadOpens(openedAt: now - 90 * day, score: 1,
                       picks: [Pick(query: "rel", at: now - 90 * day)])),
                thread("Relay pairing", activityAt: now),
            ]
            #expect(rankTitles("rel", stale) == ["Relay pairing", "Release checklist"])
            // Opening an old pick another way does not revive it.
            let reopened = [
                thread("Release checklist", opens: ThreadOpens(openedAt: now - day, score: 2,
                       picks: [Pick(query: "rel", at: now - 30 * day)])),
                thread("Relay pairing", opens: ThreadOpens(openedAt: now - day, score: 1,
                       picks: [Pick(query: "rel", at: now - day)])),
            ]
            #expect(rankTitles("rel", reopened) == ["Relay pairing", "Release checklist"])
            let repicked = [
                thread("Deploy", opens: ThreadOpens(openedAt: now - day, score: 1,
                       picks: [Pick(query: "deploy", at: now - day)])),
                thread("Deploy timeout on Railway", opens: ThreadOpens(openedAt: now, score: 1,
                       picks: [Pick(query: "deploy", at: now)])),
            ]
            #expect(rankTitles("deploy", repicked) == ["Deploy timeout on Railway", "Deploy"])
            let exact = [
                thread("Fix browser", opens: ThreadOpens(openedAt: now, score: 2, picks: [
                    Pick(query: "fix browser", at: now), Pick(query: "fix", at: now - 2 * day),
                ])),
                thread("Fix sidebar", opens: ThreadOpens(openedAt: now - day, score: 1,
                       picks: [Pick(query: "fix", at: now - day)])),
            ]
            #expect(rankTitles("fix", exact) == ["Fix sidebar", "Fix browser"])
            let named = [
                thread("Lakebed perf audit", opens: ThreadOpens(openedAt: now, score: 1,
                       picks: [Pick(query: "lakebed perf", at: now)])),
                thread("Lakebed"),
            ]
            #expect(rankTitles("lakebed", named) == ["Lakebed", "Lakebed perf audit"])
        }

        @Test("finds a branch pasted with the app's worktree prefix")
        func pastedBranch() {
            let subject = thread("Cmd+K search", branch: "t3/cmdk-search-v2")
            #expect(PS.scoreThreadSearch(PS.foldSearchQuery("t3/cmdk-search-v2"), subject, now: now) != nil)
            #expect(PS.scoreThreadSearch(PS.foldSearchQuery("t3/cmdk"), subject, now: now) != nil)
        }

        @Test("ranks a title holding the words above the app's own branch prefix and project name")
        func titleOverContext() {
            let busy = ThreadOpens(openedAt: now, score: 6, picks: [])
            #expect(rankTitles("t3 connect", [
                thread("Diagnose Connect provisioning failures", branch: "t3/diagnose-connect",
                       projectTitle: "t3code", activityAt: now, opens: busy),
                thread("T3 Connect Tunnel Lifecycle Review", projectTitle: "t3code"),
            ]).first == "T3 Connect Tunnel Lifecycle Review")
            #expect(rankTitles("t3code", [
                thread("Fix sidebar lag", branch: "t3code/sidebar", projectTitle: "t3code", activityAt: now, opens: busy),
                thread("T3 Code vs Gemini Token Volume", projectTitle: "slophouse"),
            ]).first == "T3 Code vs Gemini Token Volume")
        }

        @Test("matches pull request numbers, branches, and projects with every token somewhere")
        func pullRequestsAndFields() {
            let subject = thread("Trim model lists", branch: "t3/trim-mcp-models", projectTitle: "t3code",
                                 pullRequests: [.init(number: 22889, title: "Smaller MCP payloads")])
            for query in ["#22889", "22889", "trim mcp", "payloads t3code", "models trim"] {
                #expect(PS.scoreThreadSearch(PS.foldSearchQuery(query), subject, now: now) != nil, "\(query)")
            }
            #expect(PS.scoreThreadSearch("trim lakebed", subject, now: now) == nil)
        }

        @Test("forgives one typo only when nothing matches exactly")
        func typos() {
            let threads = [thread("Hosting alternatives to Railway"), thread("Trim MCP model lists")]
            #expect(rankTitles("railwya", threads) == ["Hosting alternatives to Railway"])
            #expect(rankTitles("trim mpc", threads) == ["Trim MCP model lists"])
            #expect(rankTitles("drga", [thread("Restore drag handles"), thread("Organize indicators")]) == ["Restore drag handles"])
            #expect(rankTitles("22889", [thread("Stats", pullRequests: [.init(number: 22189)])]) == [])
            #expect(rankTitles("t3coed", [thread("t3code perf audit"), thread("Other")]) == ["t3code perf audit"])
            #expect(rankTitles("oath2", [thread("Fix oauth2 redirect")]) == ["Fix oauth2 redirect"])
            #expect(rankTitles("ilde", [thread("Typesafe App Builder"), thread("De-risk idle tunnel cleanup")]) == [
                "De-risk idle tunnel cleanup", "Typesafe App Builder",
            ])
            #expect(rankTitles("ing", [thread("Nightly build fix")]) == [])
            #expect(rankTitles("srv", [thread("Server restart"), thread("Other")]) == ["Server restart"])
            #expect(rankTitles("sidb", [thread("Fix sidebar lag")]) == ["Fix sidebar lag"])
            #expect(rankTitles("cron", [thread("Config cleanup")]) == [])
            #expect(rankTitles("fix the sidebar", [thread("Fix Sidebar Lag")]) == ["Fix Sidebar Lag"])
            #expect(rankTitles("the", [thread("Fix sidebar lag")]) == [])
            #expect(rankTitles("don't", [thread("Don’t merge yet")]) == ["Don’t merge yet"])
            #expect(rankTitles("githbu", [thread("GitHub API usage"), thread("Other")]) == ["GitHub API usage"])
            #expect(rankTitles("macso", [thread("Fix macOS window"), thread("Other")]) == ["Fix macOS window"])
            #expect(rankTitles("cmd enter", [thread("Fix Cmd+Enter"), thread("Open links external")]) == ["Fix Cmd+Enter"])
        }
    }

    @Suite("queries that fold to empty words") @MainActor
    struct EmptyWords {
        @Test("returns for a hash and a space, or marks that fold to nothing")
        func emptyWords() {
            #expect(rankTitles("# fix", [thread("Fix sidebar lag")]) == ["Fix sidebar lag"])
            #expect(rankTitles("#", [thread("Fix sidebar lag")]) == [])
            #expect(rankTitles("´´´", [thread("Fix sidebar lag")]) == [])
            #expect(PS.scoreSearchTerms("# fix", ["Fix sidebar"]) == nil)
            #expect(PS.findSearchTokenRanges("Fix sidebar", query: "´´´") == [])
            #expect(scoreMessageMatch("Fix sidebar", "´´´") == nil)
        }
    }

    @Suite("scoreThreadSearch beyond Latin text and titles") @MainActor
    struct BeyondLatin {
        @Test("leaves out a row whose words only meet across unrelated fields")
        func unrelatedFields() {
            let scattered = thread("eMudhra certificate update request", pullRequests: [
                .init(number: 22645, title: "fix model picker"), .init(number: 22649, title: "CI speedups"),
            ])
            #expect(PS.scoreThreadSearch("fix ci", scattered, now: now) == nil)
            let lakebed = thread("Weekly notes", projectTitle: "lakebed", pullRequests: [
                .init(number: 243, title: "perf: faster cold starts"),
            ])
            #expect(PS.scoreThreadSearch("lakebed perf", lakebed, now: now)?.explain?() == PS.SearchMatchHint(
                label: "PR", text: "#243 perf: faster cold starts", ranges: [SearchRange(start: 5, end: 9)]))
        }

        @Test("says which field matched when the title does not")
        func matchHints() {
            let subject = thread("Trim model lists", branch: "t3/cleanup-payloads", pullRequests: [
                .init(number: 22889, title: "Smaller MCP payloads"),
            ])
            for query in ["#22889", "pr 22889", "pr22889", "pull request #22889"] {
                #expect(PS.scoreThreadSearch(PS.foldSearchQuery(query), subject, now: now)?.explain?() == PS.SearchMatchHint(
                    label: "PR", text: "#22889 Smaller MCP payloads", ranges: [SearchRange(start: 1, end: 6)]), "\(query)")
            }
            #expect(PS.scoreThreadSearch("cleanup", subject, now: now)?.explain?() == PS.SearchMatchHint(
                label: "Branch", text: "cleanup-payloads", ranges: [SearchRange(start: 0, end: 7)]))
            #expect(PS.scoreThreadSearch("trim", subject, now: now)?.explain?() == nil)
        }

        @Test("reads letters and numbers typed together, without forgiving typos in numbers")
        func joinedNumbers() {
            let threads = [thread("Upgrade to pnpm 12"), thread("GPT-5 eval"), thread("iOS 26 support"), thread("Other")]
            #expect(rankTitles("pnpm12", threads) == ["Upgrade to pnpm 12"])
            #expect(rankTitles("gpt5", threads) == ["GPT-5 eval"])
            #expect(rankTitles("ios26", threads) == ["iOS 26 support"])
            #expect(rankTitles("pnpm13", threads) == [])
        }

        @Test("reads whole words typed together, but not scattered letters")
        func joinedWords() {
            let threads = [thread("VS Code extension settings"), thread("Fix UI bug in sidebar"),
                           thread("I plan to open source all of lakebed in the next few weeks")]
            #expect(rankTitles("vscode", threads) == ["VS Code extension settings"])
            #expect(rankTitles("fixuibug", threads) == ["Fix UI bug in sidebar"])
            #expect(rankTitles("lint", threads) == [])
            #expect(rankTitles("inth", [thread("Show skill names in thread overview")]) == [])
            #expect(rankTitles("tos", [thread("Move Client State to Server")]) == [])
            #expect(rankTitles("t3co", [thread("T3 Code vs Gemini")]) == ["T3 Code vs Gemini"])
            #expect(rankTitles("\"sidebar lag\"", [thread("Fix sidebar lag")]) == ["Fix sidebar lag"])
            #expect(rankTitles("cafe\u{0301}", [thread("Café menu")]) == ["Café menu"])
            #expect(rankTitles("gomod", [thread("Migrate to Go modules")]) == ["Migrate to Go modules"])
            #expect(PS.scoreThreadSearch("vscode", thread("Fixvscode and VS Code"), now: now)?.quality == 0.6)
            #expect(rankTitles("vscode", [
                thread("VS Code remote support"), thread("Old work", branch: "vscode", activityAt: now - 400 * day),
            ]).contains("VS Code remote support"))
        }

        @Test("stores picked queries without splitting an emoji")
        func pickedQueries() {
            #expect(PS.pickedQuery(String(repeating: "a", count: 31) + "🚀") == String(repeating: "a", count: 31))
            #expect(PS.pickedQuery("  Upl ") == "upl")
            let spaced = "investigate    workspace thread reset bug"
            #expect(PS.pickedQuery(spaced) == PS.pickedQuery(PS.foldSearchQuery(spaced)))
        }

        @Test("matches emoji in titles")
        func emoji() {
            #expect(rankTitles("🚀", [thread("🚀 Launch checklist"), thread("Launch notes")]) == ["🚀 Launch checklist"])
        }

        @Test("treats each Chinese or Japanese character as a word start")
        func cjk() {
            #expect(PS.scoreThreadSearch("搜索", thread("实现全文搜索"), now: now) != nil)
            #expect(PS.scoreThreadSearch("検索", thread("新しい検索機能"), now: now) != nil)
        }
    }

    @Suite("scoreThreadSearch with heavy use and loose input") @MainActor
    struct HeavyUse {
        @Test("keeps a whole word on a quiet thread above a mid-word hit on a thread opened daily")
        func dailyOpens() {
            var opens = PS.recordThreadOpen(nil, at: now - 60 * day, query: nil)
            for offset in stride(from: 59, through: 1, by: -1) {
                opens = PS.recordThreadOpen(opens, at: now - Double(offset) * day, query: nil)
            }
            #expect(rankTitles("auth", [
                thread("Fix oauth redirect", activityAt: now, opens: opens),
                thread("Share auth across worktrees", activityAt: now - 90 * day),
            ]) == ["Share auth across worktrees", "Fix oauth redirect"])
        }

        @Test("reads a word and the start of the next typed together, highlighting each part")
        func joinedPrefixRanges() {
            let threads = [thread("Fix sidebar lag"), thread("Unrelated work")]
            #expect(rankTitles("fixsid", threads) == ["Fix sidebar lag"])
            #expect(rankTitles("fixsid", [thread("Feature: Fix sidebar lag")]) == ["Feature: Fix sidebar lag"])
            #expect(PS.scoreThreadSearch("fixsid", threads[0], now: now)?.ranges == [
                SearchRange(start: 0, end: 3), SearchRange(start: 4, end: 7),
            ])
            #expect(rankTitles("fsl", threads) == [])
        }

        @Test("finds nothing rather than an unrelated thread when no word matches")
        func noMatch() {
            let threads = [
                thread("Projectless threads without Git"), thread("Concern about connection setup"),
                thread("Simplify worktree thread creation"), thread("Start a new conversation"),
                thread("Setting up the sentinel"), thread("I plan to open source all of lakebed in the next few weeks"),
                thread("Design notes"), thread("Link pull request to thread"),
            ]
            for query in ["posthog", "cron", "stripe", "gpu", "fxsb", "lint", "deno"] {
                #expect(rankTitles(query, threads) == [], "\(query)")
            }
        }

        @Test("matches pieces of references that hold a number, and environment names")
        func references() {
            let subject = thread("Trim model lists", id: "thread-5fe6f59c-4976", environmentLabel: "BeeBox",
                                 pullRequests: [.init(number: 22889, references: [
                                    "pingdotgg/t3code#22889", "https://github.com/pingdotgg/t3code/pull/22889",
                                 ])])
            for query in [
                "t3code#22889", "github.com/pingdotgg/t3code/pull/22889",
                "https://github.com/pingdotgg/t3code/pull/22889/files", "5fe6f59c", "beebox",
            ] {
                #expect(PS.scoreThreadSearch(PS.foldSearchQuery(query), subject, now: now) != nil, "\(query)")
            }
            #expect(PS.scoreThreadSearch("github.com", subject, now: now) == nil)
            for query in ["github.com/pingdotgg/t3code/pull/2288", "t3code#2288"] {
                #expect(PS.scoreThreadSearch(PS.foldSearchQuery(query), subject, now: now) == nil, "\(query)")
            }
        }
    }

    @Suite("rankMessageMatches") @MainActor
    struct RankMessageMatches {
        @Test("merges environments by word match, then picks, then quality and use")
        func mergedEnvironments() {
            let subjects = [
                "a-word": thread("A word"), "a-word-2": thread("A word too"), "b-prefix": thread("B prefix"),
                "b-recent": thread("B recent", activityAt: now),
                "b-picked": thread("B picked", opens: ThreadOpens(openedAt: now - day, score: 1,
                                   picks: [Pick(query: "needle", at: now - day)])),
            ]
            let matches = [
                MessageHit(key: "a-word", quality: 1), MessageHit(key: "a-word-2", quality: 1),
                MessageHit(key: "b-prefix", quality: 0.8), MessageHit(key: "b-recent", quality: 1),
                MessageHit(key: "b-picked", quality: 0.8),
            ]
            #expect(rankedMessages(matches, subjects: subjects, query: "needle") == [
                "b-picked", "b-recent", "a-word", "a-word-2", "b-prefix",
            ])
            var titled = subjects
            titled["c-titled"] = thread("Needle cleanup")
            #expect(!rankedMessages([MessageHit(key: "c-titled", quality: 1)] + matches,
                                    subjects: titled, query: "needle", withoutTitleMatches: true).contains("c-titled"))
        }

        @Test("ranks a thread that keeps using the word above a passing mention of equal quality")
        func repeatedHits() {
            let subjects = [
                "mention": thread("Mention", activityAt: now - 3 * day,
                                  opens: ThreadOpens(openedAt: now, score: 1, picks: [])),
                "about": thread("About it", activityAt: now - 48 * day),
            ]
            let matches = [MessageHit(key: "mention", quality: 1, hits: 1), MessageHit(key: "about", quality: 1, hits: 21)]
            #expect(rankedMessages(matches, subjects: subjects, query: "tailscale") == ["about", "mention"])
        }

        @Test("keeps matches inside words below word matches, however used")
        func midWordBelowWhole() {
            let busy = thread("Busy", activityAt: now, opens: ThreadOpens(openedAt: now, score: 20, picks: []))
            let matches = [MessageHit(key: "busy", quality: 0.3), MessageHit(key: "quiet", quality: 1)]
            let subjects = ["busy": busy, "quiet": thread("Quiet")]
            #expect(rankedMessages(matches, subjects: subjects, query: "rust") == ["quiet", "busy"])
        }
    }

    @Suite("rankSearchGroups") @MainActor
    struct RankSearchGroups {
        @Test("orders groups by their best match and keeps the given order on ties")
        func groupOrder() {
            let groups = PS.rankSearchGroups([
                (group: "actions", items: ["Open settings", "New thread"]),
                (group: "threads", items: ["Settings sync rewrite", "Thread settings"]),
                (group: "projects", items: ["Settings app"]),
            ]) { item, typos, _ in PS.scoreSearchTerms("settings", [item], typos: typos) }
            // An Equatable row preserves the tuple-array comparison from TypeScript.
            struct Row: Equatable {
                var group: String
                var items: [String]
            }
            #expect(groups.map { Row(group: $0.group, items: $0.ranked.map(\.item)) } == [
                Row(group: "actions", items: ["Open settings"]),
                Row(group: "threads", items: ["Settings sync rewrite", "Thread settings"]),
                Row(group: "projects", items: ["Settings app"]),
            ])
        }
    }

    @Suite("rankSearchGroups with keywords and picks") @MainActor
    struct KeywordsAndPicks {
        @Test("matches inside a word only in thread titles")
        func midWordTitlesOnly() {
            #expect(PS.scoreSearchTerms("arch", ["Search project contents"]) == nil)
            #expect(PS.scoreThreadSearch("arch", thread("Notes", branch: "research-extension-system"), now: now) == nil)
            #expect(PS.scoreThreadSearch("arch", thread("Research notes"), now: now)?.quality == 0.3)
        }

        @Test("forgives typos in names but not in hidden keywords")
        func hiddenKeywordTypos() {
            let groups = PS.rankSearchGroups([
                (group: "actions", items: [["Open settings", "preferences", "keybindings"]]),
                (group: "settings", items: [["Keybindings", "General"]]),
            ]) { terms, typos, _ in PS.scoreSearchTerms("keybindngs", terms, typos: typos) }
            #expect(groups.map(\.group) == ["settings"])
            #expect(PS.scoreSearchTerms("duckdb", ["Search engine", "duckduckgo"], typos: true) == nil)
            #expect(PS.scoreSearchTerms("rust", ["GitHub sharing", "trusted"]) == nil)
            #expect(PS.scoreSearchTerms("the ci", ["Context window indicator", "circle"]) == nil)
        }

        private enum Item {
            case command([String])
            case thread(Subject)
        }

        @Test("lists a thread named for the query above a command with it as a keyword")
        func threadOverKeyword() {
            func rank(_ command: [String], _ subject: Subject) -> [String] {
                PS.rankSearchGroups([
                    (group: "actions", items: [Item.command(command)]),
                    (group: "threads", items: [Item.thread(subject)]),
                ]) { item, typos, _ in
                    switch item {
                    case .command(let terms): PS.scoreSearchTerms("mcp", terms, typos: typos)
                    case .thread(let subject): PS.scoreThreadSearch("mcp", subject, now: now, typos: typos)
                    }
                }.map(\.group)
            }
            let named = thread("Trim MCP model lists")
            let picked = thread("Trim MCP model lists", opens: ThreadOpens(openedAt: now, score: 1,
                                picks: [Pick(query: "mcp", at: now)]))
            #expect(rank(["Restart agent session", "reload", "mcp"], named) == ["threads", "actions"])
            #expect(rank(["Reload MCP servers"], named) == ["actions", "threads"])
            #expect(rank(["Reload MCP servers"], picked) == ["actions", "threads"])
        }
    }

    @Suite("recordThreadOpen") @MainActor
    struct RecordThreadOpen {
        @Test("decays the open count, merges quick reopens, and keeps the latest picked queries")
        func recordsOpens() {
            let first = PS.recordThreadOpen(nil, at: now, query: "  Upl ")
            #expect(first == ThreadOpens(openedAt: now, score: 1, picks: [Pick(query: "upl", at: now)]))
            let reopened = PS.recordThreadOpen(first, at: now + 60_000, query: "uploadthing")
            #expect(reopened == ThreadOpens(openedAt: now, score: 1, picks: [
                Pick(query: "uploadthing", at: now + 60_000), Pick(query: "upl", at: now),
            ]))
            let later = PS.recordThreadOpen(reopened, at: now + PS.searchRecencyHalfLifeMs, query: String(repeating: "x", count: 50))
            #expect(later.score == 1.5)
            #expect(later.picks.map(\.query) == [String(repeating: "x", count: 32), "uploadthing", "upl"])
            let repicked = PS.recordThreadOpen(later, at: later.openedAt + day, query: "upl")
            #expect(repicked.picks == [
                Pick(query: "upl", at: later.openedAt + day), Pick(query: String(repeating: "x", count: 32), at: later.openedAt),
                Pick(query: "uploadthing", at: now + 60_000),
            ])
        }

        @Test("drops picks that no longer count when the thread is opened again")
        func dropsExpiredPicks() {
            let opens = ThreadOpens(openedAt: now - 30 * day, score: 1, picks: [Pick(query: "old", at: now - 30 * day)])
            #expect(PS.recordThreadOpen(opens, at: now, query: "new").picks == [Pick(query: "new", at: now)])
        }

        @Test("does not renew a query's pick when the thread is picked for another one")
        func preservesPickAge() {
            let deploy = [
                thread("Deploy notes", opens: ThreadOpens(openedAt: now, score: 2, picks: [
                    Pick(query: "scripts", at: now), Pick(query: "deploy", at: now - 60 * day),
                ])),
                thread("Deploy timeout", opens: ThreadOpens(openedAt: now - day, score: 1,
                       picks: [Pick(query: "deploy", at: now - day)])),
            ]
            #expect(rankTitles("deploy", deploy) == ["Deploy timeout", "Deploy notes"])
        }
    }

    @Suite("findSearchTokenRanges") @MainActor
    struct FindSearchTokenRanges {
        @Test("maps folded matches back to the source text and skips short tokens")
        func foldedRanges() {
            let text = "Le Café résumé ci"
            #expect(PS.findSearchTokenRanges(text, query: "CAFE resume ci") == [
                SearchRange(start: 3, end: 7), SearchRange(start: 8, end: 14),
            ])
        }

        @Test("highlights a three-letter token only where it starts a word")
        func shortTokenRanges() {
            #expect(PS.findSearchTokenRanges("drafts, enableFTS", query: "fts") == [SearchRange(start: 14, end: 17)])
            #expect(PS.findSearchTokenRanges("Open handlers.ts", query: ".ts") == [SearchRange(start: 13, end: 16)])
        }
    }

    @Suite("scoreMessageMatch") @MainActor
    struct ScoreMessageMatch {
        @Test("needs short words at a word start and ranks other words found inside words lower")
        func messageQuality() throws {
            let text = "Saved the drafts. \(String(repeating: "More notes. ", count: 40))Then enableFTS and Enable FTS."
            let fts = scoreMessageMatch(text, "fts")
            #expect(fts?.quality == 1)
            let ftsOffset = try #require(fts?.offset)
            #expect((text as NSString).substring(from: ftsOffset).hasPrefix("FTS and"))
            #expect(scoreMessageMatch("saved two drafts", "fts") == nil)
            #expect(scoreMessageMatch("We trust the build", "rust") == PS.MessageMatch(quality: 0.3, offset: 4))
            #expect(scoreMessageMatch("Rust and trust", "rust") == PS.MessageMatch(quality: 1, offset: 0))
            #expect(scoreMessageMatch("Use the sidebar", "\"sidebar\"") == PS.MessageMatch(quality: 1, offset: 8))
            let together = "Run the tests, then vp run dev to check"
            #expect(scoreMessageMatch(together, "vp run dev") == PS.MessageMatch(
                quality: 1.25, offset: (together as NSString).range(of: "vp run dev").location))
            #expect(scoreMessageMatch("dev notes: vp is slow, run it", "vp run dev")?.quality == 1.1)
            let far = "run the tests. \(String(repeating: "More notes. ", count: 10))Then dev mode, then vp"
            #expect(scoreMessageMatch(far, "vp run dev")?.quality == 1)
            #expect(scoreMessageMatch("I don\u{2019}t know why", "don't know")?.quality == 1.25)
            #expect(scoreMessageMatch("Le Café open late", "cafe open")?.quality == 1.25)
            #expect(scoreMessageMatch("The cafe open late", "café open")?.quality == 1.25)
            let phrase = "The plan. \(String(repeating: "More notes. ", count: 10))Since the last fix, the sidebar works"
            #expect(scoreMessageMatch(phrase, "fix the sidebar")?.offset == (phrase as NSString).range(of: "fix,").location)
            let apart = "The lakebed app. \(String(repeating: "Notes. ", count: 30))Lakebed page perf is slow"
            let apartOffset = try #require(scoreMessageMatch(apart, "lakebed perf")?.offset)
            #expect((apart as NSString).substring(from: apartOffset).hasPrefix("Lakebed page"))
            let prefix = "fix \(String(repeating: "unrelated words ", count: 40))prefix has CI"
            #expect(scoreMessageMatch(prefix, "fix ci")?.offset == 0)
            #expect(scoreMessageMatch("see commit 7cafe52bb8", "cafe") == nil)
            #expect(scoreMessageMatch("see commit 7cafe52bb8", "7cafe52") == PS.MessageMatch(quality: 1, offset: 11))
            #expect(scoreMessageMatch("7cafe52bb8, then the cafe", "cafe")?.quality == 1)
            #expect(scoreMessageMatch("model settings", "mode")?.quality == 0.8)
            #expect(scoreMessageMatch("The model and the mode switch", "mode") == PS.MessageMatch(quality: 1, offset: 18))
            #expect(scoreMessageMatch("v12rc build", "rc")?.quality == 1)
            #expect(scoreMessageMatch("Fix the CLIAdapter state", "ada")?.quality == 0.8)
            #expect(scoreMessageMatch("Switch off the connection", "switch on") == nil)
            #expect(scoreMessageMatch("Upgrade pnpm 512 today", "pnpm 12") == nil)
            #expect(scoreMessageMatch("Upgrade to pnpm12 today", "pnpm 12")?.quality == 1)
            #expect(scoreMessageMatch("Fix circle rendering", "fix ci")?.quality == 1)
            #expect(scoreMessageMatch("Fix CI failures", "fix ci")?.quality == 1.25)
            #expect(scoreMessageMatch("Upgrade pnpm 123 today", "pnpm 12")?.quality == 1)
            #expect(scoreMessageMatch("Rename the file to index.ts", ".ts")?.quality == 1)
        }

        @Test("finds words through case and accents, also after the same letters inside a word")
        func accentsAndOffsets() {
            #expect(scoreMessageMatch("This addresses Résumé indexing", "res")?.offset == 15)
            #expect(scoreMessageMatch("Le CAFÉ ouvert", "cafe") == PS.MessageMatch(quality: 1, offset: 3))
            #expect(scoreMessageMatch("The cafeteria, then the Café", "cafe") == PS.MessageMatch(quality: 1, offset: 24))
            #expect(scoreMessageMatch("I presume this. Résumé indexing", "resume") == PS.MessageMatch(quality: 1, offset: 16))
            #expect(scoreMessageMatch("明天部署到生产环境", "部署")?.offset == 2)
            #expect(scoreMessageMatch("Properties: tiếng Việt support", "tie")?.offset == 12)
            #expect(scoreMessageMatch("Properties: tie\u{0301}ng support", "tie")?.offset == 12)
            #expect(scoreMessageMatch("İ Enable fts and model", "fts")?.offset == 9)
            #expect(scoreMessageMatch("İ Enable fts and model", "model")?.quality == 1)
            #expect(scoreMessageMatch("Trip to İstanbul", "İstanbul") == PS.MessageMatch(quality: 1, offset: 8))
        }
    }
}
