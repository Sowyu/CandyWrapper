import Foundation
import Testing
import T3Protocol
@testable import Features

/// The composer context clipboard's import, against useComposerContextImport.browser.test.tsx at 4928.
@MainActor
struct ComposerContextImportTests {
    private func counter() -> () -> String {
        var n = 0
        return { n += 1; return "minted\(n)" }
    }

    /// "preserves thread identity across repeated pastes" (#30583), both variants.
    @Test(arguments: [false, true]) func threadsKeepTheirIdentityAcrossRepeatedPastes(otherEnvironment: Bool) throws {
        let first = ComposerContext.threadRecord(threadId: "same-id", title: "First", environmentId: "thread-source")
        let pasted = otherEnvironment
            ? ComposerContext.threadRecord(threadId: "same-id", title: "Second", environmentId: "other-thread-source") : first
        let firstId = try #require(first["contextId"]?.stringValue), pastedId = try #require(pasted["contextId"]?.stringValue)
        var draft = [firstId: first]
        let mint = counter()
        let plan = ComposerContextImport.plan(.init(records: [pasted], sourceEnvironmentId: "thread-source"), existing: draft,
                                              environmentId: "thread-source", linkedEnvironments: ["other-thread-source"], mint: mint)
        let imported = try #require(plan.rewritten[pastedId])
        draft.merge(plan.records) { $1 }
        #expect(draft[imported]?["environmentId"] == pasted["environmentId"] && draft[imported]?["threadId"] == pasted["threadId"])
        #expect(draft.count == (otherEnvironment ? 2 : 1))
        #expect(draft[firstId] == first)
        let repeated = ComposerContextImport.plan(.init(records: [pasted], sourceEnvironmentId: "thread-source"), existing: draft,
                                                  environmentId: "thread-source", linkedEnvironments: ["other-thread-source"], mint: mint)
        #expect(repeated.rewritten[pastedId] == imported)
        #expect(repeated.records.isEmpty)
    }

    @Test func threadsFromMachinesTheAgentCannotReadAreDropped() {
        let record = ComposerContext.threadRecord(threadId: "t", title: "T", environmentId: "far")
        let plan = ComposerContextImport.plan(.init(records: [record], sourceEnvironmentId: "far"), existing: [:], environmentId: "here")
        #expect(plan.rewritten.isEmpty && plan.records.isEmpty)
    }

    @Test func machinesStayOutOfQuestionAnswers() {
        let record = ComposerContext.environmentRecord(environmentId: "there", label: "Build server")
        #expect(ComposerContextImport.plan(.init(records: [record], sourceEnvironmentId: "here"), existing: [:], environmentId: "here", isQuestion: true).records.isEmpty)
        #expect(ComposerContextImport.plan(.init(records: [record], sourceEnvironmentId: "here"), existing: [:], environmentId: "here").records.count == 1)
    }

    /// "Producer ids fold into context ids, so two different excerpts can collide": the same payload
    /// keeps its chip, a different one is reminted so both survive.
    @Test func collidingRecordsAreRemintedAndSamePayloadsKept() throws {
        let selection = ComposerContext.TerminalSelection(terminalId: "default", terminalLabel: "Terminal 1", lineStart: 1, lineEnd: 2, text: "ls")
        let record = ComposerContext.terminalRecord(id: "a", selection)
        let id = try #require(record["contextId"]?.stringValue)
        var relabelled = record
        if case .object(var f) = relabelled { f["label"] = .string("other"); relabelled = .object(f) }
        let same = ComposerContextImport.plan(.init(records: [relabelled], sourceEnvironmentId: "e"), existing: [id: record], environmentId: "e")
        #expect(same.rewritten.isEmpty && same.records.isEmpty)
        var changed = record
        if case .object(var f) = changed { f["text"] = .string("pwd"); changed = .object(f) }
        let plan = ComposerContextImport.plan(.init(records: [changed], sourceEnvironmentId: "e"), existing: [id: record], environmentId: "e", mint: counter())
        let next = try #require(plan.rewritten[id])
        #expect(next != id && plan.records[next]?["text"] == .string("pwd") && plan.records[next]?["contextId"] == .string(next))
    }

    /// Pasted attachment chips get a fresh draft id and bring their bytes; the text follows.
    @Test func attachmentsImportUnderNewIdsAndTheTextFollows() throws {
        let attachment = ComposerAttachment(id: "src", kind: .image, name: "shot.png", mimeType: "image/png", sizeBytes: 10,
                                            fileURL: URL(fileURLWithPath: "/tmp/shot.png"), environmentId: "e")
        let record = attachment.clipboardRecord
        #expect(record["attachmentId"] == .string("src"))
        let text = "look \(attachment.reference) here"
        let html = try #require(ComposerContext.clipboardHTML(text: text, records: [record], environmentId: "e"))
        let fragment = try #require(ComposerContext.pastedFragment(html: html, pastedText: text))
        #expect(fragment.sourceEnvironmentId == "e")
        let plan = ComposerContextImport.plan(fragment, existing: [:], environmentId: "e", mint: counter())
        let imported = try #require(plan.attachments.first)
        #expect(imported.localId == "minted1" && imported.name == "shot.png" && imported.attachmentId == "src")
        #expect(plan.rewritten[attachment.contextId] == imported.contextId)
        let rewritten = ComposerContextImport.rewrite(text, ids: plan.rewritten)
        #expect(ComposerContext.referencedIds(rewritten) == [imported.contextId])
        #expect(rewritten.hasPrefix("look ![shot.png](") && rewritten.hasSuffix(") here"))
        // Back into the draft that holds the copied bytes, the chip stays as it was.
        let back = ComposerContextImport.plan(fragment, existing: [attachment.contextId: record], environmentId: "e", alreadyAttached: { _ in true })
        #expect(back.attachments.isEmpty && back.rewritten.isEmpty)
        // Without a source the chip keeps its id unless it collides.
        let sourceless = ComposerContextImport.plan(.init(records: [record], sourceEnvironmentId: nil), existing: [:], environmentId: "e")
        #expect(sourceless.rewritten == [attachment.contextId: attachment.contextId] && sourceless.attachments.isEmpty)
    }

    /// #37771: a snapshot's capture details travel with its record.
    @Test func snapshotSourcesTravelWithTheRecord() {
        var attachment = ComposerAttachment(id: "s", kind: .image, name: "Window.png", mimeType: "image/png", sizeBytes: 1,
                                            fileURL: URL(fileURLWithPath: "/tmp/w.png"), environmentId: "e")
        attachment.snapShotSource = .object(["appName": .string("Notes")])
        #expect(attachment.clipboardRecord["source"]?["appName"] == .string("Notes"))
        let plan = ComposerContextImport.plan(.init(records: [attachment.clipboardRecord], sourceEnvironmentId: "e"), existing: [:], environmentId: "e")
        #expect(plan.attachments.first?.record["source"]?["appName"] == .string("Notes"))
    }
}
