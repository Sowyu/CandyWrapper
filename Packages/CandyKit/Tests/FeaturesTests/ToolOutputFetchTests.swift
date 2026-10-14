import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Omitted tool output: fetched when its row opens, shown loading, failed, empty or as text.
@MainActor
struct ToolOutputFetchTests {
    /// Records requests; each answer waits for the test to release it.
    final class FakeServer: @unchecked Sendable {
        var requests: [GetTurnItemInput] = []
        var answer: Result<TurnItemDetail.Fetched, Error> = .success(.output("total 8\nhello.py"))
        var loader: ThreadViewModel.TurnItemLoader {
            { [self] input, _ in
                await MainActor.run { self.requests.append(input) }
                return try self.answer.get()
            }
        }
    }

    struct Failure: LocalizedError { var errorDescription: String? { "Thread not found." } }

    /// The 03-turn2 thread with every fold and group open, and its omitted `ls` call.
    static func model(_ server: FakeServer) throws -> (ThreadViewModel, WorkLogEntry) {
        let projection = try #require(try ThreadPreview.projections(transcript: "03-turn2.jsonl").last {
            $0.visibleTurnItems.contains { $0.item.type == .commandExecution && $0.item.outputOmitted }
        })
        let model = ThreadViewModel()
        model.turnItemLoader = server.loader
        model.setProjection(projection)
        for run in projection.runs { model.toggleRun(run.id) }
        for item in model.items { if case .workToggle(let t) = item.row.kind { model.toggleGroup(t.groupId) } }
        let entry = try #require(entries(model).first { $0.projectedItem?.item.input?.stringValue == "ls -la && git status --short" })
        return (model, entry)
    }

    static func entries(_ model: ThreadViewModel) -> [WorkLogEntry] {
        model.items.flatMap { item -> [WorkLogEntry] in
            if case .work(let e, _, _) = item.row.kind { return e }
            return []
        }
    }

    static func state(_ model: ThreadViewModel, _ id: String) -> ToolOutputState? {
        model.items.lazy.compactMap { $0.ui.outputs[id] }.first
    }

    static func settle(_ server: FakeServer, _ model: ThreadViewModel, _ id: String) async {
        for _ in 0..<200 where state(model, id) == .loading { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func fetchesOnlyWhenTheRowOpens() async throws {
        let server = FakeServer()
        let (model, entry) = try Self.model(server)
        #expect(server.requests.isEmpty)
        #expect(!WorkDetail.of(entry, label: "", workspaceRoot: nil).isEmpty, "an omitted output keeps the row expandable")

        model.toggleEntry(entry.id)
        #expect(Self.state(model, entry.id) == .loading)
        await Self.settle(server, model, entry.id)
        #expect(Self.state(model, entry.id) == .fetched(.output("total 8\nhello.py")))
        let row = try #require(entry.projectedItem)
        #expect(server.requests == [TurnItemDetail.request(row)])

        // Closing and reopening within the idle window reuses the result.
        model.toggleEntry(entry.id)
        model.toggleEntry(entry.id)
        #expect(server.requests.count == 1)
        #expect(Self.state(model, entry.id) == .fetched(.output("total 8\nhello.py")))
    }

    @Test func aClosedRowDropsItsOutputAfterTheIdleWindow() async throws {
        let server = FakeServer()
        let (model, entry) = try Self.model(server)
        model.outputIdleTTL = .milliseconds(20)
        model.toggleEntry(entry.id)
        await Self.settle(server, model, entry.id)
        model.toggleEntry(entry.id)
        // Wait for the eviction itself: a busy main actor (the fidelity suites) delays it past any fixed sleep.
        for _ in 0..<500 where model.holdsOutput(entry.id) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.holdsOutput(entry.id))
        model.toggleEntry(entry.id)
        #expect(Self.state(model, entry.id) == .loading)
        await Self.settle(server, model, entry.id)
        #expect(server.requests.count == 2)
    }

    @Test func aFailureShowsTheServerMessage() async throws {
        let server = FakeServer()
        server.answer = .failure(Failure())
        let (model, entry) = try Self.model(server)
        model.toggleEntry(entry.id)
        await Self.settle(server, model, entry.id)
        #expect(Self.state(model, entry.id) == .failed("Thread not found."))
    }

    @Test func rowTextForEachState() throws {
        let (_, entry) = try Self.model(FakeServer())
        func blocks(_ s: ToolOutputState?) -> [String] { WorkDetail.of(entry, label: "", workspaceRoot: nil, output: s).blocks.map(\.text) }
        let command = "ls -la && git status --short"
        #expect(blocks(nil) == [command])
        #expect(blocks(.loading) == [command, "Loading output…"])
        #expect(blocks(.failed("boom")) == [command, "Couldn't load output: boom"])
        #expect(blocks(.fetched(.gone)) == [command, "Couldn't load output: Output is no longer available."])
        #expect(blocks(.fetched(.output(nil))) == [command, "No output."])
        #expect(blocks(.fetched(.output("a\nb"))) == [command, "a\nb"])
        #expect(blocks(.fetched(.mismatch)) == [command])
        // Images draw above the text, and an output of only images is not "No output." (V2ItemInspector.tsx:149-175).
        let row = try #require(entry.projectedItem)
        let images = WorkDetail.of(entry, label: "", workspaceRoot: nil, output: .fetched(.output("a", images: 2))).blocks.map(\.kind)
        #expect(images == [.mono(.command), .image(.toolOutput(.init(threadId: row.sourceThreadId, itemId: row.sourceItemId, index: 0))),
                           .image(.toolOutput(.init(threadId: row.sourceThreadId, itemId: row.sourceItemId, index: 1))), .mono(.output)])
        #expect(blocks(.fetched(.output(nil, images: 1))) == [command, ""])
        #expect(WorkDetail.of(entry, label: "", workspaceRoot: nil, output: .loading).blocks.last?.kind == .mono(.note))
    }

    /// A read's viewed image sits first (`mt-1`), in a 16:9 slot at most 16rem tall until its size is known,
    /// then in its own framed box (MessagesTimeline.tsx:5723-5734, ChatMarkdown.tsx:1391-1520).
    @Test func aViewedImageTakesTheSlotThenItsOwnBox() {
        let path = "/tmp/demo-repo/viewed-\(UUID().uuidString).png"
        let e = WorkLogEntry(id: "r", createdAt: T3Timestamp("2026-10-12T00:00:00.000Z"), label: "Read", detail: path,
                             tone: .tool, viewedImagePath: path, requestKind: "file-read", itemType: .dynamicTool)
        let detail = WorkDetail.of(e, label: "Read", workspaceRoot: "/tmp/demo-repo")
        #expect(detail.blocks.first?.kind == .image(.file(path, workspaceRoot: "/tmp/demo-repo")))
        #expect(detail.blocks.first?.gap == 2)
        let view = WorkDetailView()
        view.detail = detail
        let slot = view.height(forWidth: 600)
        MarkdownImages.record(CGSize(width: 240, height: 160), for: "media-file:" + path)
        // 480 x 256 (16:9 capped at 16rem), then 240 x 160 inside the 1px frame.
        let settled = view.height(forWidth: 600)
        #expect(abs(slot - settled - (256 - 162)) < 0.01, "slot \(slot), settled \(settled)")
    }

    /// A Claude Read of an image outside the workspace: the result's own image shows once, and the file preview,
    /// whose path may be gone by now, neither fetches nor leaves an "Image unavailable" card.
    @Test func aReadImageShowsTheResultImageOnce() throws {
        let path = "/tmp/pwshot-\(UUID().uuidString)/8-ground.png"
        let at = "2026-10-14T10:00:00.000Z"
        let item = try TurnItem(json: .object([
            "id": .string("read-1"), "threadId": .string("t"), "type": .string("dynamic_tool"), "toolName": .string("Read"),
            "input": .object(["file_path": .string(path)]), "outputOmitted": .bool(true), "ordinal": .number(1),
            "status": .string("completed"), "startedAt": .string(at), "updatedAt": .string(at),
        ]))
        let row = ProjectedTurnItem(local: item)
        let e = WorkLogEntry(id: "r", createdAt: T3Timestamp(at), label: "Read", detail: path, tone: .tool, viewedImagePath: path,
                             requestKind: "file-read", itemType: .dynamicTool, projectedItem: row)
        let root = "/Users/me/project"
        func kinds(_ output: ToolOutputState?) -> [WorkDetail.Kind] {
            WorkDetail.of(e, label: "Read", workspaceRoot: root, output: output).blocks.map(\.kind)
        }
        let file = WorkDetail.Kind.image(.file(path, workspaceRoot: root))
        let result = WorkDetail.Kind.image(.toolOutput(.init(threadId: row.sourceThreadId, itemId: row.sourceItemId, index: 0)))
        // Closed or loading: nothing fetches the file while the result may still carry the image.
        #expect(!kinds(nil).contains(file))
        #expect(!kinds(.loading).contains(file))
        // The fetched item as the server answers it: Anthropic content with the image's bytes (the user's
        // case), or the 2861 sandbox's file summary without them.
        func fetched(_ output: JSONValue) throws -> ToolOutputState {
            guard case .object(var o) = item.raw else { throw CancellationError() }
            o["outputOmitted"] = .bool(false); o["output"] = output
            return .fetched(TurnItemDetail.resolve(GetTurnItemResult(item: try TurnItem(json: .object(o))), wireType: .dynamicTool))
        }
        let withBytes = try fetched(.array([
            .object(["type": .string("text"), "text": .string(path)]),
            .object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string("iVBORw0KGgo=")])]),
        ]))
        let summary = try fetched(.object(["type": .string("image"), "file": .object(["type": .string("image/png"), "sizeBytes": .number(51712)])]))
        // The result carries it: one image, the result's.
        #expect(kinds(withBytes).filter { if case .image = $0 { true } else { false } } == [result])
        // A result without the bytes falls back to the file, as T3 does, and a file that failed takes no space.
        #expect(kinds(summary).first == file)
        #expect(kinds(.fetched(.output(path))).first == file)
        MarkdownImages.failed.insert("media-file:" + path)
        defer { MarkdownImages.failed.remove("media-file:" + path) }
        #expect(!kinds(.fetched(.output(path))).contains(file))
        let view = WorkDetailView()
        view.detail = WorkDetail.of(e, label: "Read", workspaceRoot: root, output: .fetched(.output(path)))
        #expect(view.height(forWidth: 600) < 60)
    }
}
