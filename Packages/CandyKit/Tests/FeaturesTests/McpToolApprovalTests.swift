import AppKit
import Testing
import T3Protocol
@testable import T3Store
@testable import Features

@MainActor
struct McpToolApprovalTests {
    private func projection(_ mode: String) throws -> ThreadProjection {
        let value: JSONValue = .object([
            "thread": .object(["id": .string("sandbox"), "runtimeMode": .string(mode)]),
            "updatedAt": .string("2026-10-18T10:00:00Z")
        ])
        return try JSONDecoder().decode(ThreadProjection.self, from: JSONEncoder().encode(value))
    }

    @Test(arguments: ["full-access", "approval-required", "auto-accept-edits", "auto", "unknown", ""])
    func toolCallsRespectTheCurrentAccessMode(_ mode: String) async throws {
        let (window, row, model, entry) = try fixture(mode)
        defer { row.prepareForReuse(); withExtendedLifetime((window, model)) {} }
        var calls: [String] = [], confirmations = 0
        let args: JSONValue = .object(["auto": .bool(true)])
        let actions = McpAppActions(request: { method, input in
            calls.append(method)
            #expect(input["threadId"]?.stringValue == "sandbox")
            #expect(input["itemId"]?.stringValue == "capture")
            #expect(input["name"]?.stringValue == "viewport_capture")
            if method == "mcpApps.toolInfo" { return .object(["callable": .bool(true), "readOnly": .bool(false)]) }
            #expect(input["arguments"] == args)
            return .object(["captured": .bool(true)])
        }, turnItem: { _, _ in nil }, sendMessage: nil)
        do {
            let result = try await row.callTool("viewport_capture", arguments: args, entry: entry, conversation: "sandbox", actions: actions) { _, _ in
                confirmations += 1
                return false
            }
            #expect(mode == "full-access")
            #expect(result["captured"]?.boolValue == true)
        } catch let error as McpAppHostBridge.Refusal {
            #expect(mode != "full-access")
            #expect(error.message == "Declined by the user.")
        }
        #expect(confirmations == (mode == "full-access" ? 0 : 1))
        #expect(calls == (mode == "full-access" ? ["mcpApps.toolInfo", "mcpApps.callTool"] : ["mcpApps.toolInfo"]))
    }

    @Test(arguments: [false, true])
    func restrictedModeStillRunsApprovedAndReadOnlyTools(_ readOnly: Bool) async throws {
        let (window, row, model, entry) = try fixture("approval-required")
        defer { row.prepareForReuse(); withExtendedLifetime((window, model)) {} }
        var confirmed = false, executed = false
        let actions = McpAppActions(request: { method, _ in
            if method == "mcpApps.toolInfo" { return .object(["callable": .bool(true), "readOnly": .bool(readOnly)]) }
            executed = true; return .null
        }, turnItem: { _, _ in nil }, sendMessage: nil)
        _ = try await row.callTool("viewport_capture", arguments: .object([:]), entry: entry, conversation: "sandbox", actions: actions) { _, _ in
            confirmed = true; return true
        }
        #expect(executed)
        #expect(confirmed == !readOnly)
    }

    @Test(arguments: [false, true])
    func fullAccessKeepsCallableAndThreadIdentityChecks(_ callable: Bool) async throws {
        let (window, row, model, entry) = try fixture("full-access")
        defer { row.prepareForReuse(); withExtendedLifetime((window, model)) {} }
        var executed = false, confirmed = false
        let actions = McpAppActions(request: { method, _ in
            if method == "mcpApps.toolInfo" {
                if callable { row.prepareForReuse() }
                return .object(["callable": .bool(callable), "readOnly": .bool(false)])
            }
            executed = true
            return .null
        }, turnItem: { _, _ in nil }, sendMessage: nil)
        do {
            _ = try await row.callTool("viewport_capture", arguments: .object([:]), entry: entry, conversation: "sandbox", actions: actions) { _, _ in
                confirmed = true; return true
            }
            Issue.record("A forbidden or closed app must not run its tool")
        } catch let error as McpAppHostBridge.Refusal {
            #expect(error.message == (callable ? "The app was closed." : "This app cannot call that tool."))
        }
        #expect(!executed && !confirmed)
    }

    @Test func changingAccessWhileToolInfoLoadsRestoresConfirmation() async throws {
        let (window, row, model, entry) = try fixture("full-access")
        defer { row.prepareForReuse(); withExtendedLifetime((window, model)) {} }
        let restricted = try projection("approval-required")
        var confirmed = false, executed = false
        let actions = McpAppActions(request: { method, _ in
            if method == "mcpApps.toolInfo" {
                model.setProjection(restricted)
                return .object(["callable": .bool(true), "readOnly": .bool(false)])
            }
            executed = true; return .null
        }, turnItem: { _, _ in nil }, sendMessage: nil)
        do {
            _ = try await row.callTool("viewport_capture", arguments: .object([:]), entry: entry, conversation: "sandbox", actions: actions) { _, _ in
                confirmed = true; return false
            }
            Issue.record("The restricted mode must ask before running the tool")
        } catch is McpAppHostBridge.Refusal {}
        #expect(confirmed && !executed)
    }

    private func fixture(_ mode: String) throws -> (NSWindow, McpAppRowView, ThreadViewModel, McpAppEntry) {
        let model = ThreadViewModel(); model.setProjection(try projection(mode))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let row = McpAppRowView(); row.context = TimelineContext(); row.context.model = model
        let app = try #require(McpAppReference(.object([
            "attachmentId": .string("capture"), "server": .string("Blender sandbox"),
            "tool": .string("viewport_capture"), "resourceUri": .string("ui://capture")
        ])))
        let entry = McpAppEntry(app: app, sourceThreadId: "sandbox", itemId: "capture", revision: "1")
        row.configure(TimelineItem(row: TimelineRow(id: "capture", createdAt: nil, kind: .mcpApp(entry))))
        window.contentView?.addSubview(row)
        return (window, row, model, entry)
    }
}
