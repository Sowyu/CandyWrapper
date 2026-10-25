import AppKit
import Foundation
import SpaceCrypto
import SpaceEngine
import SpaceLocal
import SpaceModel
import Testing
@testable import Features

/// Page history, restore, Trash and Delete forever (docs/space.md sections 5 and 9).
@MainActor
struct SpaceHistoryTrashTests {
    let minute: Int64 = 60_000

    func newPage(_ store: SpaceDocumentStore, _ title: String, parent: PageID? = nil, at: Int64) -> PageID {
        let id = PageID()
        store.edit([try! RecordChange.page(id, PageRecord(parent: parent, order: try! OrderKey("a0"), title: title, created: at))], at: at)
        return id
    }
    func block(_ id: BlockID, _ text: String, on page: PageID, blob: BlobReference? = nil) -> RecordChange {
        try! RecordChange.block(id, BlockRecord(page: page, order: try! OrderKey("a1"), type: blob == nil ? .p : .image,
                                                text: RichText(t: text), blob: blob))
    }
    func setText(_ id: BlockID, _ text: String) -> RecordChange {
        RecordChange(kind: .block, id: id, set: ["text": try! JSONValue(encoding: RichText(t: text))])
    }

    @Test func duplicateCopiesBlocksWithFreshIdsInOneEdit() throws {
        let store = SpaceReplicaStore()
        let page = newPage(store, "Trip", at: 0)
        let ids = (0..<4).map { _ in BlockID() }.sorted()
        let text = ids[0], conflict = ids[1], child = ids[2], picture = ids[3], inner = BlockID(), gone = BlockID()
        store.edit([try RecordChange.page(child, PageRecord(parent: page, order: OrderKey("a1"), title: "Packing", created: 0))], at: 0)
        let image = BlobReference(id: String(repeating: "a", count: 64), name: "map.png", mime: "image/png", size: 10)
        let conflictInfo = BlockConflict(device: "Other Mac", at: 1)
        store.edit([block(text, "Fly Tuesday", on: page), block(picture, "Map", on: page, blob: image),
                    try RecordChange.block(conflict, BlockRecord(page: page, order: OrderKey("a1"),
                                                               text: RichText(t: "Fly Wednesday"), conflict: conflictInfo)),
                    block(inner, "Socks", on: child), block(gone, "Old", on: page)], at: 1)
        store.edit([RecordChange(kind: .block, id: gone, set: ["trashed": .bool(true)])], at: 2)
        let source = store.content(of: page)
        func labels(_ content: [SpaceContent]) -> [String] {
            content.map { switch $0 { case .block(_, let r): r.text.t; case .page(_, let r): r.title } }
        }
        #expect(labels(source) == ["Fly Tuesday", "Fly Wednesday", "Packing", "Map"])
        let ops = store.replica.pending.count
        let copy = try #require(store.duplicate(page, now: 3))
        #expect(store.replica.pending.count == ops + 1, "pages and blocks go in as one edit")
        #expect(store.pages[copy]?.title == "Trip copy")
        let content = store.content(of: copy)
        #expect(labels(content) == labels(source), "blocks and child pages keep their content order")
        #expect(zip(content, content.dropFirst()).allSatisfy { $0.order < $1.order }, "copied order never depends on ids")
        let blocks = content.compactMap { c -> (BlockID, BlockRecord)? in if case .block(let id, let r) = c { (id, r) } else { nil } }
        #expect(blocks.map(\.1.text.t) == ["Fly Tuesday", "Fly Wednesday", "Map"], "trashed blocks stay behind")
        #expect(blocks.dropFirst().first?.1.conflict == conflictInfo, "the conflict stays after its original")
        #expect(Set(blocks.map(\.0)).isDisjoint(with: [text, conflict, picture, inner, gone]))
        #expect(blocks.allSatisfy { $0.1.page == copy })
        #expect(blocks.first { $0.1.text.t == "Map" }?.1.blob == image, "the copy points at the same blob")
        let childCopy = try #require(store.content(of: copy).compactMap { c -> PageID? in if case .page(let id, _) = c { id } else { nil } }.first)
        #expect(childCopy != child)
        let innerCopy = store.content(of: childCopy).compactMap { c -> BlockRecord? in if case .block(_, let r) = c { r } else { nil } }
        #expect(innerCopy.map(\.text.t) == ["Socks"] && innerCopy.first?.page == childCopy)
        #expect(store.content(of: page) == source && store.block(text)?.page == page, "the original is untouched")
    }

    @Test func historyListsVersionsAndRestoreIsOneUndoableEdit() async throws {
        let store = SpaceReplicaStore()
        let page = newPage(store, "Essay", at: 0)
        let a = BlockID()
        store.edit([block(a, "First draft", on: page)], at: minute)
        store.edit([setText(a, "Final draft")], at: 30 * minute)

        let view = SpacePageView(store: store)
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        view.show(page)
        view.showHistory()
        let history = try #require(view.history)
        await history.load()
        #expect(history.versions.count == 2)
        #expect(history.versions.map(\.edits) == [1, 2])
        #expect(history.selected == 1, "the version before the current one is picked first")
        #expect(history.preview?.textView.string.contains("First draft") == true)
        #expect(history.preview?.textView.isEditable == false)
        #expect(history.restore.isEnabled)
        history.select(0)
        #expect(!history.restore.isEnabled, "the current version has nothing to restore")
        history.select(1)

        let before = store.replica.pending.count
        history.restore.action?()
        #expect(view.history == nil)
        #expect(store.replica.pending.count == before + 1, "restore writes one change through the apply path")
        #expect(store.block(a)?.text.t == "First draft")
        #expect(view.editor?.textView.string.contains("First draft") == true)

        view.editor?.performUndo()
        #expect(store.block(a)?.text.t == "Final draft")
    }

    @Test func trashListsNewestFirstAndRestoresIntoTheTree() {
        let store = InMemorySpacePageStore()
        let parent = store.createPage(title: "Uni", now: 1)
        let child = store.createPage(in: parent, title: "COMP2310", now: 2)
        let other = store.createPage(title: "Journal", now: 3)
        store.trash(child, now: 10)
        store.trash(other, now: 20)
        let trash = SpaceTrashView(store: store)
        #expect(store.trashed == [other, child])
        #expect(trash.rows.map(\.title.text) == ["Journal", "COMP2310"])

        trash.rows[1].restore.action?()
        #expect(store.pages[child]?.trashed == false)
        #expect(store.pages[child]?.parent == parent)
        #expect(trash.rows.map(\.title.text) == ["Journal"])
    }

    @Test func deleteForeverAsksFirstAndTakesThePagesInside() {
        let store = InMemorySpacePageStore()
        let parent = store.createPage(title: "Old project", now: 1)
        let child = store.createPage(in: parent, title: "Notes", now: 2)
        let keep = store.createPage(title: "Keep", now: 3)
        store.trash(parent, now: 10)
        let trash = SpaceTrashView(store: store)
        var asked: (String, @MainActor () -> Void)?
        trash.confirmDelete = { title, done in asked = (title, done) }

        trash.rows[0].delete.action?()
        #expect(asked?.0 == "Old project")
        #expect(store.pages[parent] != nil, "nothing goes before the confirm")
        asked?.1()
        #expect(store.pages[parent] == nil && store.pages[child] == nil)
        #expect(store.pages[keep] != nil)
        #expect(trash.rows.isEmpty)
    }

    /// The encrypted local copy: history and restore read and write its log, and Delete forever drops the page's
    /// blobs from the cache but keeps one another page still uses. All of it survives a reopen.
    @Test func persistentHistoryRestoreAndDeleteForeverSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("space-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = SpaceKeyStore.inMemory()
        let first = PersistentSpacePageStore()
        let setup = try await first.open(applicationSupport: root, keyStore: keys)
        let own = Data("only on this page".utf8), shared = Data("also on another page".utf8)
        let ownID = setup.keys.blobId(of: own), sharedID = setup.keys.blobId(of: shared)
        try await setup.local.cacheBlob(own, id: ownID)
        try await setup.local.cacheBlob(shared, id: sharedID)

        let page = newPage(first, "Trip", at: 0)
        let child = newPage(first, "Packing", parent: page, at: 0)
        let other = newPage(first, "Album", at: 0)
        let text = BlockID()
        first.edit([block(text, "Fly Tuesday", on: page),
                    block(BlockID(), "", on: page, blob: BlobReference(id: ownID, name: "a.png", mime: "image/png", size: 17)),
                    block(BlockID(), "", on: child, blob: BlobReference(id: sharedID, name: "b.png", mime: "image/png", size: 20)),
                    block(BlockID(), "", on: other, blob: BlobReference(id: sharedID, name: "b.png", mime: "image/png", size: 20))],
                   at: minute)
        first.edit([setText(text, "Fly Wednesday")], at: 40 * minute)

        let versions = try await first.history(of: page)
        #expect(versions.count == 2)
        first.edit(first.restoreChanges(versions[1]))
        #expect(first.block(text)?.text.t == "Fly Tuesday")

        first.trash(page)
        #expect(first.trashed == [page])
        first.restore(page)
        #expect(first.isLive(page) && first.isLive(child))
        first.trash(page)
        first.remove(page)
        try await first.flush()
        #expect(first.pages[page] == nil && first.pages[child] == nil && first.pages[other] != nil)
        #expect(try await setup.local.cachedBlob(id: ownID) == nil)
        #expect(try await setup.local.cachedBlob(id: sharedID) == shared)
        try await first.close()

        let next = PersistentSpacePageStore()
        let reopened = try await next.open(applicationSupport: root, keyStore: keys)
        #expect(next.pages[page] == nil && next.pages[child] == nil)
        #expect(next.pages[other]?.title == "Album")
        #expect(next.trashed.isEmpty)
        #expect(try await reopened.local.cachedBlob(id: ownID) == nil)
        // The log keeps the deleted page's history.
        #expect(try await next.history(of: page).count >= 2)
        try await next.close()
    }
}
