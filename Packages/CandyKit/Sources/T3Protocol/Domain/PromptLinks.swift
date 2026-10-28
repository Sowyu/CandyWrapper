import Foundation

/// Prompt links (packages/shared/src/promptLinks.ts, T3 3105 5fe7568e8): a link opens the app with a prompt ready
/// to send, and never sends it. CandyWrapper reads them on its own URL scheme, `<scheme>://new?...` and
/// `<scheme>://threads/<environmentId>/<threadId>?prompt=...`. The messages name CandyWrapper, not T3.
public enum PromptLinks {
    /// `PROMPT_LINK_MAX_PROMPT_LENGTH`, in UTF-16 units like JavaScript's `length`.
    public static let maxPromptLength = 8_000

    public struct Repository: Equatable, Sendable {
        public var owner: String
        public var name: String
        public init(owner: String, name: String) { self.owner = owner; self.name = name }
    }

    public struct PullRequest: Equatable, Sendable {
        public var repository: Repository
        public var number: Int
        public init(_ repository: Repository, number: Int) { self.repository = repository; self.number = number }
        /// `promptLinkPullRequestUrl`.
        public var url: String { "https://github.com/\(repository.owner)/\(repository.name)/pull/\(number)" }
    }

    /// `LinkedPrompt`: the prompt after hidden characters were removed, and how many there were.
    public struct Prompt: Equatable, Sendable {
        public var text: String
        public var hiddenCharacters: Int
        public init(text: String, hiddenCharacters: Int) { self.text = text; self.hiddenCharacters = hiddenCharacters }
    }

    /// `NewThreadLink`.
    public enum NewThread: Equatable, Sendable {
        case new(prompt: Prompt, repository: Repository?, provider: String?, model: String?)
        case pullRequest(PullRequest, prompt: Prompt?)
    }

    /// A link macOS handed the app (`promptLinkAppPath` for the app scheme), already read.
    public enum Link: Equatable, Sendable {
        case newThread(Result<NewThread, Failure>)
        case thread(environmentId: String, threadId: String, prompt: Result<Prompt?, Failure>)
    }

    public struct Failure: Error, Equatable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// `promptLinkAppPath` for `scheme://new` and `scheme://threads/<env>/<thread>`; nil for any other URL.
    public static func read(_ value: String, scheme: String) -> Link? {
        guard let c = URLComponents(string: value), c.scheme?.lowercased() == scheme.lowercased() else { return nil }
        let query = c.percentEncodedQuery ?? ""
        if c.host == "new", c.path.isEmpty || c.path == "/" { return .newThread(parseNewThread(query)) }
        guard c.host == "threads" else { return nil }
        let parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let segments = parts.last == "" ? Array(parts.dropLast()) : Array(parts)
        guard segments.count == 2, let env = segments[0].removingPercentEncoding, let thread = segments[1].removingPercentEncoding,
              !env.isEmpty, !thread.isEmpty else { return nil }
        return .thread(environmentId: env, threadId: thread, prompt: parseThreadPrompt(query))
    }

    /// `parseNewThreadLink`.
    public static func parseNewThread(_ query: String) -> Result<NewThread, Failure> {
        let params = Self.params(query)
        let prompt: Prompt?
        switch readPrompt(params) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): prompt = value
        }
        if let pr = first(params, "pr") {
            guard let pullRequest = parsePullRequest(pr) else { return .failure(Failure("This link names a pull request CandyWrapper cannot read.")) }
            return .success(.pullRequest(pullRequest, prompt: prompt))
        }
        guard let prompt else { return .failure(Failure("This link has no prompt.")) }
        let repo = first(params, "repo")
        let repository = repo.flatMap(parseRepository)
        if repo != nil, repository == nil { return .failure(Failure("This link names a repository CandyWrapper cannot read.")) }
        return .success(.new(prompt: prompt, repository: repository, provider: optional(params, "provider")?.lowercased(),
                             model: optional(params, "model")))
    }

    /// `parseThreadLinkPrompt`: nil when the link carries no prompt.
    public static func parseThreadPrompt(_ query: String) -> Result<Prompt?, Failure> { readPrompt(params(query)) }

    /// `sanitizeLinkedPrompt`: removes characters a reader cannot see, and counts them.
    public static func sanitize(_ raw: String) -> Prompt {
        var hidden = 0
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        let visible = Array(normalized.unicodeScalars).filter { s in
            if isHidden(s.value) { hidden += 1; return false }
            return true
        }
        // A zero-width joiner is visible work only inside an emoji sequence, such as a family.
        var kept = String.UnicodeScalarView()
        for (i, s) in visible.enumerated() {
            if s.value == 0x200D {
                let before = i > 0 ? visible[i - 1].value : nil, after = i + 1 < visible.count ? visible[i + 1].value : nil
                guard isEmojiPart(before), isEmojiPart(after) else { hidden += 1; continue }
            }
            kept.append(s)
        }
        return Prompt(text: String(kept).trimmingCharacters(in: .whitespacesAndNewlines), hiddenCharacters: hidden)
    }

    /// `parsePromptLinkRepository`: `owner/name` or a GitHub repository URL.
    public static func parseRepository(_ value: String) -> Repository? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = t.wholeMatch(of: /(?i)https?:\/\/(?:www\.)?github\.com\/([^\/?#]+)\/([^\/?#]+)\/?/).map { (String($0.1), String($0.2)) }
            ?? t.wholeMatch(of: /([^\/\s]+)\/([^\/\s]+)/).map { (String($0.1), String($0.2)) }
        return m.flatMap { repository($0.0, $0.1) }
    }

    /// `parsePromptLinkPullRequest`: `owner/name/123`, `owner/name#123` or a GitHub pull request URL.
    static func parsePullRequest(_ value: String) -> PullRequest? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = t.wholeMatch(of: /(?i)https?:\/\/(?:www\.)?github\.com\/([^\/?#]+)\/([^\/?#]+)\/pull\/(\d+)(?:[\/?#].*)?/)
            .map { (String($0.1), String($0.2), String($0.3)) }
            ?? t.wholeMatch(of: /([^\/\s#]+)\/([^\/\s#]+)(?:\/|#)(\d+)/).map { (String($0.1), String($0.2), String($0.3)) }
        guard let m, let repo = repository(m.0, m.1), let number = Int(m.2), number > 0 else { return nil }
        return PullRequest(repo, number: number)
    }

    // MARK: Private

    private static func repository(_ owner: String, _ name: String) -> Repository? {
        let trimmed = name.replacing(/(?i)\.git$/, with: "")
        guard owner.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9-]{0,38}/) != nil, trimmed.wholeMatch(of: /[A-Za-z0-9._-]{1,100}/) != nil,
              trimmed.wholeMatch(of: /\.+/) == nil else { return nil }
        return Repository(owner: owner, name: trimmed)
    }

    private static func readPrompt(_ params: [(String, String)]) -> Result<Prompt?, Failure> {
        guard let raw = first(params, "prompt") else { return .success(nil) }
        if raw.utf16.count > maxPromptLength {
            return .failure(Failure("This prompt is longer than 8,000 characters, so CandyWrapper did not open it."))
        }
        let prompt = sanitize(raw)
        if prompt.text.isEmpty, prompt.hiddenCharacters > 0 {
            return .failure(Failure("This prompt had only hidden characters, so it may be malicious. CandyWrapper did not open it."))
        }
        return .success(prompt.text.isEmpty ? nil : prompt)
    }

    /// `URLSearchParams`: `+` is a space, then percent decoding.
    private static func params(_ query: String) -> [(String, String)] {
        let q = query.hasPrefix("?") ? String(query.dropFirst()) : query
        return q.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            return (decode(kv[0]), kv.count > 1 ? decode(kv[1]) : "")
        }
    }

    private static func first(_ params: [(String, String)], _ key: String) -> String? { params.first { $0.0 == key }?.1 }

    private static func optional(_ params: [(String, String)], _ key: String) -> String? {
        guard let v = first(params, key)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /// `HIDDEN_CHARACTERS`: zero-width and bidi controls, tag and variation-selector blocks, and others that render as nothing.
    /// U+FE0E and U+FE0F stay, since emoji use them.
    private static func isHidden(_ v: UInt32) -> Bool {
        switch v {
        case 0x0000...0x0008, 0x000B, 0x000C, 0x000E...0x001F, 0x007F...0x009F, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160,
             0x17B4, 0x17B5, 0x180B...0x180F, 0x200B, 0x200C, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164,
             0xFE00...0xFE0D, 0xFEFF, 0xFFA0, 0xFFF0...0xFFFB, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF:
            true
        default: false
        }
    }

    /// `isEmojiPart`: pictographs, symbols, skin tones and the emoji presentation selector.
    private static func isEmojiPart(_ v: UInt32?) -> Bool {
        guard let v else { return false }
        return (0x1F000...0x1FAFF).contains(v) || (0x2190...0x2BFF).contains(v) || v == 0xFE0F
    }
}

// MARK: Resolution against what this client knows (packages/client-runtime/src/promptLinks.ts)

extension PromptLinks {
    /// A link's `owner/name` is GitHub's. GitCafe syncs a repository two-way with GitHub under the same path, so a
    /// checkout cloned from git.cafe counts as the linked repository (promptLinks.ts:21-23 at 3814).
    static let repositoryHosts = ["github.com", "git.cafe", "staging.git.cafe"]

    /// `findPromptLinkProjects`: `projects` come most recently active first. A fork matches only its own owner.
    public static func project(in projects: [ProjectShell], for repository: Repository) -> ProjectShell? {
        let path = "\(repository.owner)/\(repository.name)".lowercased()
        let keys = Set(repositoryHosts.map { "\($0)/\(path)" })
        return projects.first { $0.repositoryIdentity.map { keys.contains($0.groupingKey.lowercased()) } ?? false }
    }

    /// `findPromptLinkPullRequestThread`: the most recently updated thread linked to the pull request.
    public static func thread(in threads: [ThreadShell], for pullRequest: PullRequest) -> ThreadShell? {
        let key = ThreadPullRequestKey(host: "github.com", repository: "\(pullRequest.repository.owner)/\(pullRequest.repository.name)",
                                       number: pullRequest.number).normalized
        var latest: ThreadShell?
        for thread in threads {
            if let latest, (thread.updatedAt.epochMs ?? 0) <= (latest.updatedAt.epochMs ?? 0) { continue }
            let keys: [ThreadPullRequestKey] = if let links = thread.pullRequests {
                ThreadPullRequests.visible(links).map(\.key)
            } else if let legacy = thread.linkedPullRequest {
                // `legacyThreadPullRequestKey`, short of its Azure DevOps authority rules.
                [ChangeRequestURL.parse(legacy.url)?.key ?? ThreadPullRequestKey(host: "github.com", repository: legacy.repository, number: legacy.number)]
            } else { [] }
            if keys.contains(where: { $0.normalized == key }) { latest = thread }
        }
        return latest
    }
}
