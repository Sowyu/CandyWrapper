import AppKit
import Foundation
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// #30747 and #30857: PR composers complete `@login`, `#123` and GitLab `!123`
/// (4928 packages/shared/src/pullRequestComposerTrigger.ts, PullRequestMarkdownTextarea.tsx).
@MainActor
struct PullRequestCompletionTests {
    typealias L = PullRequestCompletionLogic
    static let all = L.Support(mentions: true, referenceSigils: ["#", "!"])

    @Test func detectsTokenAtCaret() {
        let t = L.detect("hi @oc", cursor: 6, support: Self.all)
        #expect(t == L.Trigger(kind: .mention, sigil: "@", query: "oc", rangeStart: 3, rangeEnd: 6))
        #expect(L.detect("hi @", cursor: 4, support: Self.all)?.query == "")
        #expect(L.detect("see #12", cursor: 7, support: Self.all)?.kind == .reference)
        #expect(L.detect("see !4", cursor: 6, support: Self.all)?.sigil == "!")
        // The caret must end the token, and the token must start after whitespace.
        #expect(L.detect("@octo cat", cursor: 3, support: Self.all) == nil)
        #expect(L.detect("a@b", cursor: 3, support: Self.all) == nil)
        #expect(L.detect("@.x", cursor: 3, support: Self.all) == nil)
        #expect(L.detect("#1 ", cursor: 2, support: Self.all)?.query == "1")
    }

    @Test func honoursHostSupport() {
        let mentionsOnly = L.Support(mentions: true, referenceSigils: [])
        #expect(L.detect("#1", cursor: 2, support: mentionsOnly) == nil)
        let github = L.Support(mentions: false, referenceSigils: ["#"])
        #expect(L.detect("@a", cursor: 2, support: github) == nil)
        #expect(L.detect("!1", cursor: 2, support: github) == nil)
        #expect(L.detect("#1", cursor: 2, support: github) != nil)
    }

    @Test func supportFromCapabilitiesIsNilWhenNothingCompletes() throws {
        let json = #"{"diff":true,"comment":true,"actions":[],"mergeMethods":[],"search":false,"review":{"inlineComment":false,"reply":false,"resolve":false,"verdicts":[]},"reviewers":{"request":false,"listCandidates":false}}"#
        var caps = try JSONDecoder().decode(PullRequestCapabilities.self, from: Data(json.utf8))
        #expect(L.Support(caps) == nil)
        caps.mentions = true
        caps.referenceSigils = ["#", "?"]
        #expect(L.Support(caps) == L.Support(mentions: true, referenceSigils: ["#"]))
    }

    @Test func insertsTokenAndSpace() {
        let t = L.detect("cc @oc", cursor: 6, support: Self.all)!
        let r = L.insert("cc @oc", t, token: "@octocat")
        #expect(r.text == "cc @octocat ")
        #expect(r.cursor == 12)
        // A space already there is kept and the caret steps past it.
        let t2 = L.detect("@oc there", cursor: 3, support: Self.all)!
        let r2 = L.insert("@oc there", t2, token: "@octocat")
        #expect(r2.text == "@octocat there")
        #expect(r2.cursor == 9)
        #expect(r2.replacement == "@octocat")
    }

    @Test func debounceSendsTheUnsearchedListFirst() {
        let t = L.Trigger(kind: .reference, sigil: "#", query: "12", rangeStart: 0, rangeEnd: 3)
        #expect(L.key(t) == "#12")
        #expect(L.search(t, debouncedKey: nil) == nil)
        #expect(L.search(t, debouncedKey: "@12") == nil)
        #expect(L.search(t, debouncedKey: "#1") == "1")
        #expect(L.search(t, debouncedKey: "#") == nil)
    }

    @Test func narrowsHostOptions() {
        let options = PullRequestFilterOptions(
            authors: [PullRequestActor(login: "octocat", name: "Mona"), PullRequestActor(login: "hubot", name: nil)],
            references: [
                PullRequestReferenceCandidate(reference: "#12", kind: "issue", number: 12, title: "Crash on start", state: "open"),
                PullRequestReferenceCandidate(reference: "#120", kind: "change-request", number: 120, title: "Fix", state: "merged"),
                PullRequestReferenceCandidate(reference: "!7", kind: "change-request", number: 7, title: "MR", state: "open"),
            ])
        let mention = L.Trigger(kind: .mention, sigil: "@", query: "mon", rangeStart: 0, rangeEnd: 4)
        #expect(L.completions(mention, options).map(\.token) == ["@octocat"])
        let ref = L.Trigger(kind: .reference, sigil: "#", query: "12", rangeStart: 0, rangeEnd: 3)
        #expect(L.completions(ref, options).map(\.token) == ["#12", "#120"])
        let crash = L.Trigger(kind: .reference, sigil: "#", query: "crash", rangeStart: 0, rangeEnd: 6)
        #expect(L.completions(crash, options).map(\.token) == ["#12"])
        let bang = L.Trigger(kind: .reference, sigil: "!", query: "", rangeStart: 0, rangeEnd: 1)
        #expect(L.completions(bang, options).map(\.token) == ["!7"])
        #expect(L.completions(nil, options).isEmpty)
    }

    @Test func filterOptionsDecodeWithoutReferences() throws {
        let old = #"{"labels":[],"authors":[{"login":"a","name":null,"avatarUrl":null}],"truncated":false}"#
        let o = try JSONDecoder().decode(PullRequestFilterOptions.self, from: Data(old.utf8))
        #expect(o.references.isEmpty)
        #expect(o.authors.first?.login == "a")
    }

    /// The textarea opens the list on `@`, arrows move it, Enter inserts, and the host is asked once per settled key.
    @Test func textareaCompletesThroughTheList() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let field = TextareaView()
        field.frame = NSRect(x: 20, y: 300, width: 400, height: 80)
        window.contentView?.addSubview(field)
        var asked: [PullRequestFilterOptionsInput] = []
        let scope = PullRequestCompletionScope(projectId: "p1", support: Self.all) { input in
            asked.append(input)
            return PullRequestFilterOptions(authors: [PullRequestActor(login: "octocat"), PullRequestActor(login: "octavia")])
        }
        let completion = PullRequestCompletion.attach(to: field, scope: { scope })
        window.makeFirstResponder(field)
        field.replaceText(in: NSRange(location: 0, length: 0), with: "hi @oct", caret: 7)
        try await Task.sleep(for: .milliseconds(50))
        #expect(asked.first?.kind == "authors")
        #expect(asked.first?.query == nil)
        #expect(asked.first?.projectId == "p1")
        #expect(completion.handle(.down))
        #expect(completion.handle(.enter))
        #expect(field.text == "hi @octavia ")
        #expect(!completion.handle(.down))
    }
}
