import AppKit
import Foundation
import SpaceCrypto
import SpaceEngine
import SpaceLocal
import SpaceModel
import Testing
@testable import Features

@MainActor
struct PersistentSpacePageStoreTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("space-workspace-test-\(UUID().uuidString)")
    }

    @Test func setupRecoverySaveRelaunchLoadAndDisable() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let first = PersistentSpacePageStore()
        let setup = try await first.open(applicationSupport: root, keyStore: keys)
        let recovery = try #require(setup.recoveryKey)
        #expect(try keys.load(spaceId: setup.header.spaceId.rawValue) == RecoveryKey.decode(recovery))
        #expect(setup.keys.verifyCheck(setup.header.check))
        try setup.acknowledgeRecovery()
        let parent = first.createPage(title: "Local secret parent")
        let child = first.createPage(in: parent, title: "Local secret child")
        first.rename(child, "Local secret renamed")
        first.trash(parent)
        first.restore(parent)
        #expect(first.isSaving)
        let expected = first.pages
        try await first.close()
        #expect(first.pages.isEmpty)
        #expect(try keys.load(spaceId: setup.header.spaceId.rawValue) != nil)
        let next = PersistentSpacePageStore()
        let reopened = try await next.open(applicationSupport: root, keyStore: keys)
        #expect(reopened.header == setup.header)
        #expect(reopened.device == setup.device)
        #expect(reopened.recoveryKey == nil)
        #expect(next.pages == expected)
        #expect(next.pages[child]?.parent == parent)
        let local = try await reopened.local.load()
        #expect(local.pending.isEmpty)
        #expect(local.confirmedSequence == 5)
        try await next.close()
    }

    /// The page editor's blocks, to-dos and undo go through the encrypted writer and come back after a reopen.
    @Test func editorBlocksAndUndoSurviveReopen() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let first = PersistentSpacePageStore()
        _ = try await first.open(applicationSupport: root, keyStore: keys)
        let page = first.createPage(title: "Weekly plan")
        let editor = SpacePageEditor(store: first, page: page)
        for c in "# Notes" { editor.textView.insertText(String(c), replacementRange: editor.textView.selectedRange()) }
        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        for c in "[] Pay rent" { editor.textView.insertText(String(c), replacementRange: editor.textView.selectedRange()) }
        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        for c in "Gone" { editor.textView.insertText(String(c), replacementRange: editor.textView.selectedRange()) }
        editor.flushTyping()
        editor.performUndo()
        let expected = first.content(of: page)
        #expect(expected.count == 3, "heading, the to-do, and the empty to-do left after undoing its typing")
        try await first.close()
        let next = PersistentSpacePageStore()
        _ = try await next.open(applicationSupport: root, keyStore: keys)
        #expect(next.content(of: page) == expected)
        guard case .block(_, let heading)? = next.content(of: page).first else { Issue.record("no heading"); return }
        #expect(heading.type == .h1 && heading.text.t == "Notes")
        #expect(next.pages[page]?.isTodoList == true)
        try await next.close()
    }

    /// The "Edited" line reads the same times after a relaunch: a block edit marks its page, a child page its parent.
    @Test func editedTimesSurviveReopen() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let first = PersistentSpacePageStore()
        _ = try await first.open(applicationSupport: root, keyStore: keys)
        let parent = PageID(), child = PageID(), other = PageID()
        first.edit([try RecordChange.page(parent, PageRecord(order: OrderKey("a0"), title: "Week", created: 0)),
                    try RecordChange.page(other, PageRecord(order: OrderKey("a1"), title: "Other", created: 0))], at: 1_000)
        first.edit([try RecordChange.page(child, PageRecord(parent: parent, order: OrderKey("a0"), title: "Lab", created: 0))], at: 2_000)
        first.edit([try RecordChange.block(BlockID(), BlockRecord(page: other, order: OrderKey("a0"), type: .p, text: RichText(t: "Hi")))], at: 3_000)
        let expected = first.edited
        #expect(expected == [parent: 2_000, child: 2_000, other: 3_000])
        try await first.close()
        let next = PersistentSpacePageStore()
        _ = try await next.open(applicationSupport: root, keyStore: keys)
        #expect(next.edited == expected)
        try await next.close()
    }

    /// Saved edits leave the screen's pending list, so memory doesn't grow with every edit, and undo still works.
    @Test func confirmedEditsLeaveTheScreenAndUndoStillWorks() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PersistentSpacePageStore()
        _ = try await first.open(applicationSupport: root, keyStore: SpaceKeyStore.inMemory())
        let page = first.createPage(title: "Plan")
        let editor = SpacePageEditor(store: first, page: page)
        for word in ["one", " two", " three"] {
            for c in word { editor.textView.insertText(String(c), replacementRange: editor.textView.selectedRange()) }
            editor.flushTyping()
        }
        let before = first.content(of: page)
        try await first.flush()
        #expect(first.local.replica.pending.isEmpty, "every saved op left the screen's queue")
        #expect(first.local.replica.confirmed.seq == 4)
        #expect(first.content(of: page) == before, "the screen didn't change")
        editor.performUndo()
        #expect(first.content(of: page) != before, "undo still writes its inverse change")
        try await first.flush()
        #expect(first.local.replica.pending.isEmpty)
        try await first.close()
    }

    @Test func recoveryReturnsUntilExplicitlyAcknowledged() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let first = PersistentSpacePageStore()
        let setup = try await first.open(applicationSupport: root, keyStore: keys)
        try await first.close()
        let next = PersistentSpacePageStore()
        let reopened = try await next.open(applicationSupport: root, keyStore: keys)
        #expect(reopened.recoveryKey == setup.recoveryKey)
        try await next.close()
    }

    @Test func removedOptionalKeysAndPermanentRemovalSurviveRestart() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let first = PersistentSpacePageStore()
        _ = try await first.open(applicationSupport: root, keyStore: keys)
        let parent = first.createPage(title: "Parent")
        let child = first.createPage(in: parent, title: "Child")
        first.trash(child, now: 100)
        first.restore(child)
        #expect(first.move(child, to: nil, before: nil))
        var record = try #require(first.pages[child])
        record.extra["future"] = .object(["kept": .bool(true)])
        first.put([child: record])
        first.remove(parent)
        try await first.close()
        let next = PersistentSpacePageStore()
        _ = try await next.open(applicationSupport: root, keyStore: keys)
        #expect(next.pages[parent] == nil)
        #expect(next.pages[child]?.parent == nil)
        #expect(next.pages[child]?.trashedAt == nil)
        #expect(next.pages[child]?.extra["future"] == .object(["kept": .bool(true)]))
        try await next.close()
    }

    @Test func resumesDurablePendingAfterInterruptedSave() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let setup = try SpaceLocalSetup(applicationSupport: root, keyStore: keys)
        let id = PageID()
        let record = PageRecord(order: try OrderKey("a0"), title: "Pending secret", created: 1)
        let op = SpacePendingOperation(op: OpID(), dev: setup.device,
                                       recs: [RecordRevision(id: id, base: nil)],
                                       payload: OpPayload(at: 1, changes: [try .page(id, record)]))
        try await setup.local.replacePending([op])
        await setup.local.close()
        let next = PersistentSpacePageStore()
        let reopened = try await next.open(applicationSupport: root, keyStore: keys)
        var expected = SpaceState()
        expected.apply(op.payload.changes)
        #expect(next.pages[id] == expected.page(id))
        #expect(try await reopened.local.load().pending.isEmpty)
        #expect(try await reopened.local.load().frames.first?.op == op.op)
        try await next.close()
    }

    @Test func missingKeyAndCorruptionNeverCreateAnEmptyReplacement() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let first = PersistentSpacePageStore()
        let setup = try await first.open(applicationSupport: root, keyStore: keys)
        let id = first.createPage(title: "Kept secret")
        try await first.close()
        let key = try #require(try keys.load(spaceId: setup.header.spaceId.rawValue))
        try keys.delete(spaceId: setup.header.spaceId.rawValue)
        let missing = PersistentSpacePageStore()
        await #expect(throws: SpaceLocalSetupError.self) { try await missing.open(applicationSupport: root, keyStore: keys) }
        try keys.save(key, spaceId: setup.header.spaceId.rawValue)
        let next = PersistentSpacePageStore()
        let reopened = try await next.open(applicationSupport: root, keyStore: keys)
        #expect(next.pages[id]?.title == "Kept secret")
        try await next.close()
        let pending = SpaceLocalStore.directory(applicationSupport: root, spaceID: reopened.header.spaceId).appendingPathComponent("pending.cws")
        try Data("corrupt".utf8).write(to: pending)
        let broken = PersistentSpacePageStore()
        await #expect(throws: (any Error).self) { try await broken.open(applicationSupport: root, keyStore: keys) }
        #expect(!broken.isOpen)
    }

    @Test func observerEditsKeepTheirOrderAndSavingFailureIsVisible() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let store = PersistentSpacePageStore()
        let setup = try await store.open(applicationSupport: root, keyStore: keys)
        var renamed = false
        let token = store.observe {
            if !renamed, let id = store.pages.keys.first {
                renamed = true
                store.rename(id, "Observer rename")
            }
        }
        let id = store.createPage(title: "Initial")
        try await store.flush()
        store.removeObserver(token)
        #expect(!store.isSaving)
        let local = try await setup.local.load()
        var state = try SpaceState(snapshot: local.snapshot)
        for frame in local.frames { try state.apply(frame, await setup.local.payload(of: frame)) }
        #expect(state.page(id)?.title == "Observer rename")
        await setup.local.close()
        var failures = 0
        store.onFailure = { failures += 1 }
        store.rename(id, "Unsaved edit")
        await #expect(throws: (any Error).self) { try await store.flush() }
        #expect(failures == 1)
        #expect(store.failure != nil)
        store.rename(id, "Rejected edit")
        #expect(store.pages[id]?.title == "Unsaved edit")
    }

    @Test func recursiveGrepFindsNoPlaintextOrRecoveryKeyOnDisk() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let store = PersistentSpacePageStore()
        let setup = try await store.open(applicationSupport: root, keyStore: keys)
        let secret = "CWS-PRIVATE-needle-\(UUID().uuidString)"
        let page = store.createPage(title: secret)
        store.rename(page, secret + " edited")
        store.trash(page)
        try await store.flush()
        try setup.acknowledgeRecovery()
        try await store.close()
        for needle in [secret, try #require(setup.recoveryKey)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = ["-R", "-a", "-l", "-F", "--", needle, root.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 1, "grep must find no plaintext in any local file")
        }
    }
}
