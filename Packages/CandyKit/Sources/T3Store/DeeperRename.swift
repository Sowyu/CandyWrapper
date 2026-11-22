import Foundation
import T3Protocol

/// "Deeper rename": when the server's Regenerate title keeps a title that no longer fits a long thread, CandyWrapper
/// asks a side chat of the thread for a short title and sends it as an ordinary rename. Only commands T3's own clients
/// send: `thread.fork` with `sideChat: true` (like /btw), `message.dispatch`, `thread.metadata.update` with a title,
/// and `thread.delete`. T3 clients keep side chats out of the sidebar, search and notifications (`lineage.isListed`).
public enum DeeperRename {
    /// The helper side chat's title, which marks it as this feature's: a launch deletes leftovers only when they are
    /// side chats with this exact title. /btw side chats are titled "Side chat".
    public static let helperTitle = "Title helper"
    /// How long the helper may take before the rename gives up and deletes it.
    public static let timeout: TimeInterval = 30
    /// T3's regenerate prompt asks for "3-8 words, fewer than 40 characters" (provider-core textGenerationPrompts.ts:383);
    /// the user wants shorter: at most 5 words and 40 characters.
    public static let maxWords = 5
    public static let maxCharacters = 40

    /// The one message the helper gets. No tools: the reply is read and sent as a rename by this client, which is one
    /// model call (about 57k cached tokens on the sandbox) where letting the agent rename through its MCP tool took
    /// four calls and four times the input.
    public static let prompt = """
        Write a new title for the parent thread, the conversation before this side chat, so the user can recognize it \
        weeks later. Title what its recent work is about: when the topic changed, title the latest durable goal, not \
        the first message. Rules: \(maxWords) words at most, fewer than \(maxCharacters) characters, a compact noun \
        phrase or action phrase, no quotes, labels or trailing punctuation, never the project name. Do not use any \
        tools. Reply with only the title.
        """

    /// The prompt with the user's "Thread title instructions" (Settings > Text generation) appended under the heading
    /// T3's own title prompt gives them (`threadTitlePromptSuffix`, provider-core textGenerationPrompts.ts:482-486).
    public static func prompt(instructions: String?) -> String {
        guard let text = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return prompt }
        return prompt + "\n\nTitle instructions from the user:\n" + String(text.prefix(20_000))
    }

    /// The helper's `message.dispatch`: the prompt on the rewrite's model with its options, as a composer send carries them.
    public static func helperMessage(helper: ThreadId, messageId: String, model: ModelSelection, instructions: String?) -> JSONValue {
        OrchestrationCommands.message(threadId: helper.rawValue, messageId: messageId, text: prompt(instructions: instructions),
                                      selection: model, queue: false)
    }

    /// The model the helper runs on: the cheapest of the parent's provider. Claude Haiku 5.5 costs $0.10 a million input
    /// tokens against Opus 5.5's $4 cached at $0.20, so even a cold million-token read ($0.125 to write the cache) costs
    /// less than Opus's cache hit; it has the same 1M context. Other providers keep the parent's model.
    public static func model(for parent: ModelSelection) -> ModelSelection {
        guard parent.model.hasPrefix("claude-") else { return parent }
        return ModelSelection(instanceId: parent.instanceId, model: claudeModel)
    }
    /// The default on a Claude thread.
    public static let claudeModel = "claude-haiku-5-5"

    /// The client setting that picks the model Rewrite title runs on (Settings > Title rewrite model); empty is the default.
    public static let settingKey = "titleRewriteModel"

    /// The model a rewrite runs on: the chosen one while the server still offers it, else `model(for:)`, and whether
    /// it fell back from a choice the server no longer offers.
    public static func model(chosen: ModelSelection?, parent: ModelSelection, providers: [ServerProvider]) -> (selection: ModelSelection, fellBack: Bool) {
        guard let chosen else { return (model(for: parent), false) }
        return isOffered(chosen, providers) ? (chosen, false) : (model(for: parent), true)
    }

    /// The client setting with the rewrite's model options (Settings > Title rewrite model's options menu), as
    /// selections like `[{"id": "effort", "value": "high"}]`; an option without one uses `defaultOptions`.
    public static let optionsKey = "titleRewriteOptions"

    /// A title is a small job: the lowest reasoning level and the fastest speed. Other options keep the model's default.
    public static func defaultOptions(_ descriptors: [ProviderOptionDescriptor]) -> [ProviderOptionSelection] {
        descriptors.compactMap { d in
            switch d.type {
            case .boolean where d.isReasoningControl: return ProviderOptionSelection(id: d.id, value: .bool(false))
            case .boolean where d.id == "fastMode": return ProviderOptionSelection(id: d.id, value: .bool(true))
            case .select where d.isReasoningControl:
                return d.options.first { d.promptInjectedValues?.contains($0.id) != true }.map { ProviderOptionSelection(id: d.id, value: .string($0.id)) }
            case .select where d.id == "serviceTier":
                let fastest = d.options.first { $0.label == "Ultrafast" } ?? d.options.first { $0.label == "Fast" }
                return fastest.map { ProviderOptionSelection(id: d.id, value: .string($0.id)) }
            default: return nil
            }
        }
    }

    /// The options a rewrite on `model` sends: each saved value the model accepts, else that option's default. A model
    /// that lacks a saved value (the user picked another model) gets its own defaults.
    public static func options(saved: JSONValue, model: ServerProviderModel?) -> [ProviderOptionSelection] {
        let descriptors = model?.optionDescriptors ?? []
        let saved = (try? saved.decode(as: [ProviderOptionSelection].self)) ?? []
        let defaults = defaultOptions(descriptors)
        return descriptors.compactMap { d in
            if let s = saved.first(where: { $0.id == d.id }), accepts(d, s.value) { return s }
            return defaults.first { $0.id == d.id }
        }
    }

    static func accepts(_ d: ProviderOptionDescriptor, _ value: ProviderOptionValue) -> Bool {
        switch (d.type, value) {
        case (.boolean, .bool): return true
        case (.select, .string(let id)): return d.options.contains { $0.id == id } && d.promptInjectedValues?.contains(id) != true
        default: return false
        }
    }

    /// `selection` carrying the rewrite's options for its model.
    public static func withOptions(_ selection: ModelSelection, saved: JSONValue, providers: [ServerProvider]) -> ModelSelection {
        let model = providers.first { $0.instanceId == selection.instanceId }?.models.first { $0.slug == selection.model }
        let options = options(saved: saved, model: model)
        var out = selection
        out.options = options.isEmpty ? nil : try? JSONValue(encoding: options)
        return out
    }

    /// The setting's stored value as a selection, nil when unset.
    public static func chosen(_ value: JSONValue) -> ModelSelection? {
        guard let id = value["instanceId"]?.stringValue, let model = value["model"]?.stringValue else { return nil }
        return ModelSelection(instanceId: ProviderInstanceId(rawValue: id), model: model)
    }

    public static func isOffered(_ selection: ModelSelection, _ providers: [ServerProvider]) -> Bool {
        providers.contains { $0.instanceId == selection.instanceId && $0.enabled && $0.models.contains { $0.slug == selection.model } }
    }

    /// "claude-haiku-5-5" reads "Claude Haiku 5.5" in the menu and the toast.
    public static func modelLabel(_ model: String) -> String {
        let parts = model.split(separator: "-")
        guard parts.count >= 3, parts[0] == "claude" else { return model }
        let version = parts.dropFirst(2).joined(separator: ".")
        return "Claude \(parts[1].capitalized) \(version)"
    }

    /// The reply as a title: its first non-empty line without quotes, labels or trailing punctuation, cut at a word
    /// boundary to the caps. Nil when nothing usable is left.
    public static func title(fromReply reply: String) -> String? {
        guard var line = reply.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        if let colon = line.range(of: ": "), line[..<colon.lowerBound].lowercased().hasSuffix("title") { line = String(line[colon.upperBound...]) }
        let strip = CharacterSet(charactersIn: "\"'“”‘’`*_#.!?,;:。 ")
        line = line.trimmingCharacters(in: strip)
        var words: [Substring] = []
        for word in line.split(separator: " ").prefix(maxWords) {
            let next = (words + [word]).joined(separator: " ")
            if next.count > maxCharacters { break }
            words.append(word)
        }
        // A cut that ends on "and" or "the" reads broken; drop such trailing words.
        let dangling: Set<String> = ["and", "or", "of", "the", "a", "an", "for", "with", "to", "in", "on", "&"]
        while words.count > 1, let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        let title = words.joined(separator: " ").trimmingCharacters(in: strip)
        return title.isEmpty ? nil : title
    }

    public static func renameCommand(_ id: ThreadId, original: String, current: String?, suggestion: String) -> JSONValue? {
        guard current == original, suggestion != current else { return nil }
        return ThreadCommands.rename(id, title: suggestion)
    }

    /// A side chat this feature made and did not get to delete.
    public static func isLeftover(_ shell: ThreadShell, owned: Set<ThreadId>) -> Bool {
        owned.contains(shell.id) && shell.lineage.sideChat == true && shell.title == helperTitle && shell.activeRunId == nil
    }

    /// The helper's reply: the newest assistant message of its projection.
    public static func reply(in projection: ThreadProjection) -> String? {
        projection.messages.last { $0.role == "assistant" && !$0.streaming }?.text
    }
}
