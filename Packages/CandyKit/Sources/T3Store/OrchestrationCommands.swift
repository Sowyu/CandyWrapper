import Foundation
import T3Protocol

/// The command payloads the composer, the Orchestrator and the helper send, in one place so they stay alike.
public enum OrchestrationCommands {
    /// Any Encodable as a JSONValue, like a `ModelSelection`.
    public static func encode(_ input: some Encodable) -> JSONValue {
        guard let data = try? JSONEncoder().encode(input), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .object([:]) }
        return json
    }

    /// The `dispatchMode` and `deliveryIntent` for a send (I-composer-flow 1.3.1), assuming the server declares
    /// `serverResolvedCommandContext`: a queued send goes as `queue_after_active` without an intent, the rest start
    /// immediately and name the intent (`auto` or `steer`).
    public static func dispatchMode(queue: Bool, intent: String = "auto") -> (mode: JSONValue, deliveryIntent: String?) {
        queue ? (.object(["type": .string("queue_after_active")]), nil) : (.object(["type": .string("start_immediately")]), intent)
    }

    /// A plain `message.dispatch` with no attachments, queued behind a running turn when `queue`.
    /// `idleCompaction` marks a `/compact` T3 Code sends on the user's behalf (useComposerSend.ts:1197-1209).
    public static func message(threadId: String, messageId: String, text: String, selection: ModelSelection, queue: Bool,
                               idleCompaction: String? = nil) -> JSONValue {
        let (dispatchMode, deliveryIntent) = dispatchMode(queue: queue)
        var command: [String: JSONValue] = [
            "type": .string("message.dispatch"), "commandId": .string(UUID().uuidString.lowercased()),
            "threadId": .string(threadId), "messageId": .string(messageId),
            "createdBy": .string("user"), "creationSource": .string("web"), "text": .string(text),
            "attachments": .array([]), "dispatchMode": dispatchMode, "modelSelection": encode(selection)]
        if let deliveryIntent { command["deliveryIntent"] = .string(deliveryIntent) }
        if let idleCompaction { command["idleCompaction"] = .string(idleCompaction) }
        return .object(command)
    }

    /// `orchestration.launchThread`'s input (commands.ts:660-700).
    public static func launchThread(commandId: String, threadId: String, projectId: String, title: String,
                                    modelSelection: JSONValue, runtimeMode: String, interactionMode: String,
                                    messageId: String, text: String, context: JSONValue? = nil,
                                    attachments: [JSONValue] = [],
                                    workspaceStrategy: JSONValue = .object(["type": .string("root")]),
                                    generateTitle: Bool = true) -> JSONValue {
        var message: [String: JSONValue] = ["messageId": .string(messageId), "text": .string(text), "attachments": .array(attachments)]
        // Inline chips' records ride only when there are any (commands.ts:680-684).
        if let context { message["context"] = context }
        return .object([
            "commandId": .string(commandId), "creationSource": .string("web"), "threadId": .string(threadId),
            "projectId": .string(projectId), "title": .string(title), "generateTitle": .bool(generateTitle),
            "modelSelection": modelSelection, "runtimeMode": .string(runtimeMode),
            "interactionMode": .string(interactionMode), "workspaceStrategy": workspaceStrategy,
            "initialMessage": .object(message),
        ])
    }
}
