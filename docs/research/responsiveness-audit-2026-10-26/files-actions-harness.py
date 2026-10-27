#!/usr/bin/env python3
"""Opt-in audit regression; extracts production methods, never opens an app/server.

Run from the repository root with --run. Exit 1 means F1 or F2 is back: a reply
that lands after the user switched pull requests acted on, or erased, the newly
shown one. The stubs compile against the code before and after the fix.
"""
import pathlib
import subprocess
import sys
import tempfile

if sys.argv[1:] != ["--run"]:
    sys.exit("Opt in explicitly: python3 docs/research/responsiveness-audit-2026-10-26/files-actions-harness.py --run")

root = pathlib.Path(__file__).resolve().parents[3]
source = (root / "App/Sources/PullRequestsController.swift").read_text()


def method(name):
    for prefix in ("    func ", "    private func "):
        start = source.find(prefix + name + "(")
        if start >= 0:
            line = source[start:source.index("\n", start)]
            # A one-line method closes on its own line.
            end = start + len(line) if line.rstrip().endswith("}") else source.index("\n    }", start) + len("\n    }")
            return source[start:end].replace("private func ", "func ", 1)
    return ""


# These are required; run and stillShows exist after the fix.
required = ["perform", "comment", "commentAction", "review", "write", "update"]
missing = [name for name in required if not method(name)]
if missing:
    sys.exit(f"Production methods not found: {missing}")
methods = "\n\n".join(method(name) for name in required + ["run", "stillShows"])

# Only transport, payload construction and view dependencies are stubs. The production
# method bodies, including every await and target lookup, stay verbatim.
swift = r'''
import Foundation

typealias JSONValue = String
struct PullRequestRef: Equatable { let number: Int }
struct PullRequestReviewCommentDraft { let id: String }
enum Kind { case success, error }
enum PullRequestPayloads {
    static func comment(_ ref: PullRequestRef, body: String) -> String? { "\(ref.number):\(body)" }
    static func action(_ ref: PullRequestRef, action: String, mergeMethod: String?) -> String { "\(ref.number):\(action)" }
    static func update(_ ref: PullRequestRef, title: String) -> JSONValue? { "\(ref.number):\(title)" }
    static func submitReview(_ ref: PullRequestRef, verdict: String, body: String, comments: [PullRequestReviewCommentDraft]) -> String { "\(ref.number):\(verdict)" }
}
enum PullRequestDetailLogic {
    static func actionSuccess(_ action: String, provider: String?) -> String { action }
    static func actionFailure(_ action: String, provider: String?, inPanel: Bool) -> String { action }
}
enum PullRequestWriteLogic { static func reviewSent(_ verdict: String, provider: String?) -> String { verdict } }
@MainActor final class Supervisor {
    var requests: [(method: String, payload: String)] = []
    var gate: CheckedContinuation<Void, Never>?
    var gated: Set<String> = []
    func request(_ method: String, payload: String) async throws -> Bool {
        requests.append((method, payload))
        if gated.contains(method) { await withCheckedContinuation { gate = $0 } }
        return true
    }
}
@MainActor final class ShellSession { let supervisor = Supervisor() }
@MainActor final class Composer {
    var text: String
    var commentSubmitting: String?
    var reviewPending = false
    var reviewsSubmitted = 0
    init(_ text: String) { self.text = text }
    func commentPosted() { text = ""; commentSubmitting = nil }
    func reviewSubmitted(body: String, comments: [PullRequestReviewCommentDraft]) { reviewsSubmitted += 1; reviewPending = false }
}
struct Detail { var provider: String? = "github" }
@MainActor final class View {
    var pendingAction: String?
    var actionPending = false
    var detail: Detail? = Detail()
    var composer: Composer?
    var closes = 0
    var titleSaving = false
    var titleEditsClosed = 0
    func closeComposer() { closes += 1 }
    func cancelTitleEdit() { titleEditsClosed += 1 }
}
@MainActor final class PullRequestDetailBinding {
    var shells: [String: ShellSession] = [:]
    var environmentId: String?
    var shell: ShellSession? { environmentId.flatMap { shells[$0] } }
    var reference: PullRequestRef?
    var showing = 0
    let view = View()
    var onActed: ((String) -> Void)?
    var acted: [String] = []
    var reloads = 0
    init() { onActed = { [unowned self] in self.acted.append($0) } }
    func toast(_ title: String, _ message: String?, _ kind: Kind) {}
    func reload(invalidate: Bool) { reloads += 1 }
    static func failure(_ error: Error, number: Int, provider: String? = nil) -> (String, String) { ("error", "error") }
    /// `show(environmentId:target:)` reuses this binding and replaces its target and composer.
    func showOther(_ shell: ShellSession, number: Int, composer: Composer?) {
        shells["env-B"] = shell; environmentId = "env-B"; reference = PullRequestRef(number: number); view.composer = composer
        showing += 1
    }
    func showA() { environmentId = "env-A"; reference = PullRequestRef(number: 1); showing += 1; view.titleSaving = false }
''' + methods + r'''
}

@MainActor var failures = 0
@MainActor func check(_ safe: Bool, _ label: String) {
    print("\(safe ? "PASS" : "FAIL") \(label)")
    if !safe { failures += 1 }
}

@main struct Audit {
    @MainActor static func waitFor(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Bounded scheduler wait expired: \(description)")
    }

    @MainActor static func make(gating method: String) -> (PullRequestDetailBinding, ShellSession, Composer) {
        let binding = PullRequestDetailBinding()
        let a = ShellSession(), composer = Composer("comment for A")
        a.supervisor.gated = [method]
        binding.shells["env-A"] = a; binding.environmentId = "env-A"; binding.reference = PullRequestRef(number: 1)
        binding.view.composer = composer
        return (binding, a, composer)
    }

    @MainActor static func main() async {
        // F1: comment and close on A, then PR B on another environment shows before the comment returns.
        do {
            let (binding, a, _) = make(gating: "pullRequests.comment")
            let b = ShellSession(), bComposer = Composer("unsent draft on B")
            binding.commentAction("comment for A", "close")
            await waitFor("comment A pending") { a.supervisor.gate != nil }
            binding.showOther(b, number: 2, composer: bComposer)
            a.supervisor.gate?.resume()
            await waitFor("state action sent") { a.supervisor.requests.count + b.supervisor.requests.count >= 2 }
            check(a.supervisor.requests.map(\.payload) == ["1:comment for A", "1:close"], "F1: comment and close both go to A")
            check(b.supervisor.requests.isEmpty, "F1: B receives no close")
            check(bComposer.text == "unsent draft on B" && binding.view.closes == 0, "F1: B's composer keeps its draft and stays open")
        }
        // F2: a plain comment on A lands after B's composer has unsent text.
        do {
            let (binding, a, aComposer) = make(gating: "pullRequests.comment")
            let bComposer = Composer("unsent draft on B")
            binding.comment("comment for A")
            await waitFor("plain comment A pending") { a.supervisor.gate != nil }
            binding.showOther(ShellSession(), number: 2, composer: bComposer)
            a.supervisor.gate?.resume()
            await waitFor("comment completion") { aComposer.text.isEmpty || bComposer.text.isEmpty || binding.view.closes > 0 }
            check(bComposer.text == "unsent draft on B", "F2: A's late success keeps B's unsent comment")
            check(binding.view.closes == 0, "F2: A's late success leaves B's composer open")
            check(binding.reloads == 0, "F2: A's late success does not reload B")
        }
        // F2's review path: a review on A lands while B shows.
        do {
            let (binding, a, aComposer) = make(gating: "pullRequests.submitReview")
            let bComposer = Composer("unsent draft on B")
            binding.review("approve", body: "looks good", comments: [])
            await waitFor("review A pending") { a.supervisor.gate != nil }
            binding.showOther(ShellSession(), number: 2, composer: bComposer)
            a.supervisor.gate?.resume()
            await waitFor("review completion") { aComposer.reviewsSubmitted + bComposer.reviewsSubmitted > 0 }
            check(aComposer.reviewsSubmitted == 1 && bComposer.reviewsSubmitted == 0, "F2 review: A's composer hears A's review")
            check(binding.view.closes == 0, "F2 review: B's composer stays open")
        }
        // A -> B -> A: an old title save lands while a newer title edit is open on A again.
        do {
            let (binding, a, _) = make(gating: "pullRequests.update")
            binding.update(title: "older title")
            await waitFor("title save pending") { a.supervisor.gate != nil }
            binding.showOther(ShellSession(), number: 2, composer: nil)
            binding.showA()
            a.supervisor.gate?.resume()
            await waitFor("title save landed") { a.supervisor.gate != nil && a.supervisor.requests.count == 1 }
            for _ in 0..<200 { await Task.yield() }
            check(binding.view.titleEditsClosed == 0, "A-B-A: the old title save leaves the newer title edit open")
        }
        // Control: with no switch, comment and close finish on the same pull request.
        do {
            let (binding, a, aComposer) = make(gating: "pullRequests.comment")
            binding.commentAction("comment for A", "close")
            await waitFor("comment A pending") { a.supervisor.gate != nil }
            a.supervisor.gate?.resume()
            await waitFor("action settled") { binding.acted == ["close"] }
            check(a.supervisor.requests.map(\.payload) == ["1:comment for A", "1:close"], "control: comment then close on A")
            check(aComposer.text.isEmpty && binding.view.closes == 1 && !binding.view.actionPending, "control: A's composer clears and closes")
        }
        print("pull request ownership failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix="cw-files-actions-audit-") as tmp:
    swift_file = pathlib.Path(tmp) / "Audit.swift"
    binary = pathlib.Path(tmp) / "audit"
    swift_file.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(swift_file), "-o", str(binary)], check=True, timeout=120)
    raise SystemExit(subprocess.run([str(binary)], timeout=15).returncode)
