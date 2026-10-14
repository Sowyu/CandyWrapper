import Foundation
import Testing
@testable import T3Protocol

/// Cases from packages/shared/src/promptLinks.test.ts (T3 3105), on CandyWrapper's own scheme.
struct PromptLinksTests {
    @Test func removesHiddenCharacters() {
        let tagged = "rate me" + String(String.UnicodeScalarView([Unicode.Scalar(0xE0041)!, Unicode.Scalar(0xE0042)!]))
        #expect(PromptLinks.sanitize("a\u{200B}b\u{202E}c\u{FEFF}\(tagged)") == .init(text: "abcrate me", hiddenCharacters: 5))
        #expect(PromptLinks.sanitize("a\u{2028}b\u{2029}c") == .init(text: "a\nb\nc", hiddenCharacters: 0))
    }

    @Test func keepsEmojiSequences() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", heart = "\u{2764}\u{FE0F}"
        #expect(PromptLinks.sanitize("\(family) \(heart)") == .init(text: "\(family) \(heart)", hiddenCharacters: 0))
        #expect(PromptLinks.sanitize("a\u{200D}b").hiddenCharacters == 1)
        #expect(PromptLinks.sanitize("\u{1F468}\u{200D}").hiddenCharacters == 1)
        #expect(PromptLinks.sanitize("\u{20000}\u{200D}\u{20001}").hiddenCharacters == 1)
    }

    @Test func readsANewThreadLink() throws {
        let link = try PromptLinks.parseNewThread("?prompt=Rate+me&repo=https://github.com/pingdotgg/t3code.git&provider=Codex&model=gpt-5").get()
        #expect(link == .new(prompt: .init(text: "Rate me", hiddenCharacters: 0), repository: .init(owner: "pingdotgg", name: "t3code"),
                             provider: "codex", model: "gpt-5"))
    }

    @Test func readsAPullRequestLink() throws {
        for pr in ["pingdotgg/t3code/42", "pingdotgg/t3code%2342", "https://github.com/pingdotgg/t3code/pull/42/files"] {
            let link = try PromptLinks.parseNewThread("?pr=\(pr)").get()
            #expect(link == .pullRequest(.init(.init(owner: "pingdotgg", name: "t3code"), number: 42), prompt: nil), "\(pr)")
        }
    }

    @Test func refusesUnsafeLinks() {
        #expect((try? PromptLinks.parseNewThread("?repo=a/b").get()) == nil)
        #expect((try? PromptLinks.parseNewThread("?prompt=%E2%80%8B").get()) == nil)
        #expect((try? PromptLinks.parseThreadPrompt("?prompt=%E2%80%8B").get()) == nil)
        #expect((try? PromptLinks.parseNewThread("?prompt=x&repo=../etc").get()) == nil)
        #expect((try? PromptLinks.parseNewThread("?prompt=\(String(repeating: "x", count: 8_001))").get()) == nil)
        if case .failure(let f) = PromptLinks.parseNewThread("?prompt=%E2%80%8B") { #expect(!f.message.contains("T3")) }
    }

    @Test func readsAThreadLinkPrompt() throws {
        #expect(try PromptLinks.parseThreadPrompt("?prompt=Fix+it").get() == .init(text: "Fix it", hiddenCharacters: 0))
        #expect(try PromptLinks.parseThreadPrompt("?panel=diff").get() == nil)
    }

    @Test func readsOnlyTheAppsOwnScheme() {
        #expect(PromptLinks.read("candywrapper-x://new?prompt=hi", scheme: "candywrapper-x")
                == .newThread(.success(.new(prompt: .init(text: "hi", hiddenCharacters: 0), repository: nil, provider: nil, model: nil))))
        #expect(PromptLinks.read("t3code://threads/env-1/thread-1?prompt=go", scheme: "t3code")
                == .thread(environmentId: "env-1", threadId: "thread-1", prompt: .success(.init(text: "go", hiddenCharacters: 0))))
        #expect(PromptLinks.read("t3code://threads/env-1/thread-1/", scheme: "t3code") == .thread(environmentId: "env-1", threadId: "thread-1", prompt: .success(nil)))
        #expect(PromptLinks.read("t3code://new?prompt=hi", scheme: "candywrapper-x") == nil)
        #expect(PromptLinks.read("t3code://app/index.html", scheme: "t3code") == nil)
        #expect(PromptLinks.read("t3code://threads/env-1", scheme: "t3code") == nil)
        #expect(PromptLinks.read("https://app.t3.codes/new?prompt=hi", scheme: "t3code") == nil)
    }
}
