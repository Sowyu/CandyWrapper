#!/usr/bin/env python3
"""Opt-in audit reproduction; extracts production methods, never opens an app/server.

Run from the repository root with --run. Exit 0 means both existing bugs reproduced.
Compilation and execution belong to the parent audit's centralized execution lane.
"""
import pathlib
import subprocess
import sys
import tempfile

if sys.argv[1:] != ["--run"]:
    sys.exit("Opt in explicitly: python3 docs/research/responsiveness-audit-2026-10-26/files-actions-harness.py --run")

root = pathlib.Path(__file__).resolve().parents[3]
source = (root / "App/Sources/PullRequestsController.swift").read_text()


def method(signature):
    start = source.index("    " + signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


methods = "\n\n".join(method(s) for s in [
    "func perform(_ action: String, mergeMethod: String?) {",
    "private func comment(_ body: String) {",
    "private func commentAction(_ body: String, _ action: String) {",
])

# Only transport, payload construction and view dependencies are stubs. The three
# production method bodies, including every await and target lookup, stay verbatim.
swift = r'''
import Foundation

struct PullRequestRef { let number: Int }
enum Kind { case success, error }
enum PullRequestPayloads {
    static func comment(_ ref: PullRequestRef, body: String) -> String? { "\(ref.number):\(body)" }
    static func action(_ ref: PullRequestRef, action: String, mergeMethod: String?) -> String { "\(ref.number):\(action)" }
}
enum PullRequestDetailLogic {
    static func actionSuccess(_ action: String) -> String { action }
    static func actionFailure(_ action: String) -> String { action }
}
@MainActor final class Supervisor {
    var requests: [(method: String, payload: String)] = []
    var commentGate: CheckedContinuation<Void, Never>?
    func request(_ method: String, payload: String) async throws -> Bool {
        requests.append((method, payload))
        if method == "pullRequests.comment" {
            await withCheckedContinuation { commentGate = $0 }
        }
        return true
    }
}
@MainActor final class ShellSession { let supervisor = Supervisor() }
@MainActor final class Composer {
    var text = "unsent draft on B"
    var commentSubmitting: String?
    func commentPosted() { text = ""; commentSubmitting = nil }
}
@MainActor final class View {
    var pendingAction: String?
    var actionPending = false
    var composer: Composer? = Composer()
    var closes = 0
    func closeComposer() { closes += 1 }
}
@MainActor final class PullRequestDetailBinding {
    var shell: ShellSession?
    var reference: PullRequestRef?
    let view = View()
    var onActed: ((String) -> Void)?
    func toast(_ title: String, _ message: String?, _ kind: Kind) {}
    func reload(invalidate: Bool) {}
    static func failure(_ error: Error, number: Int) -> (String, String) { ("error", "error") }
    func triggerCommentAction() { commentAction("comment for A", "close") }
    func triggerComment() { comment("comment for A") }
''' + methods + r'''
}

@main struct Audit {
    @MainActor static func waitFor(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Bounded scheduler wait expired: \(description)")
    }
    @MainActor static func main() async {
        // show(environmentId:target:) reuses this binding and replaces its target.
        // Direct assignment here excludes AppKit and tests the async ownership only.
        let binding = PullRequestDetailBinding()
        let a = ShellSession(), b = ShellSession()
        binding.shell = a; binding.reference = PullRequestRef(number: 1)
        binding.triggerCommentAction()
        await waitFor("comment A pending") { a.supervisor.commentGate != nil }
        binding.shell = b; binding.reference = PullRequestRef(number: 2)
        binding.view.composer = Composer()
        a.supervisor.commentGate?.resume()
        await waitFor("state action completed") { !b.supervisor.requests.isEmpty }
        precondition(a.supervisor.requests.first?.payload == "1:comment for A")
        precondition(b.supervisor.requests.first?.method == "pullRequests.runAction")
        precondition(b.supervisor.requests.first?.payload == "2:close")
        print("REPRODUCED F1: comment sent to A; close sent to B after switching environment/PR")

        let second = PullRequestDetailBinding()
        let c = ShellSession(), d = ShellSession()
        second.shell = c; second.reference = PullRequestRef(number: 1)
        second.triggerComment()
        await waitFor("plain comment A pending") { c.supervisor.commentGate != nil }
        second.shell = d; second.reference = PullRequestRef(number: 2)
        let newComposer = Composer()
        second.view.composer = newComposer
        c.supervisor.commentGate?.resume()
        await waitFor("late completion touched B composer") { second.view.closes > 0 }
        precondition(newComposer.text.isEmpty)
        precondition(d.supervisor.requests.isEmpty)
        print("REPRODUCED F2: A comment success erased B's unsent draft and closed B's composer")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="cw-files-actions-audit-") as tmp:
    swift_file = pathlib.Path(tmp) / "Audit.swift"
    binary = pathlib.Path(tmp) / "audit"
    swift_file.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(swift_file), "-o", str(binary)], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=15)
