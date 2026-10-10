import Foundation
import Testing
@testable import T3Protocol

/// `subscribeVcsStatus` events and git payloads, from a recording of the sandbox server (2026-10-10,
/// `scripts/record-transcript.swift ... git`, repo with a local bare remote).
struct VcsTests {
    static func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    @Test func statusStream() {
        let snapshot = Self.json(#"{"_tag":"snapshot","local":{"branchChanges":{"baseRef":"origin/main","deletions":0,"insertions":0},"hasPrimaryRemote":true,"hasWorkingTreeChanges":false,"isDefaultRef":true,"isRepo":true,"refName":"main","workingTree":{"deletions":0,"files":[],"insertions":0}},"remote":null}"#)
        var s = VcsStatus.apply(snapshot, to: nil)
        #expect(s?.refName == "main" && s?.isDefaultRef == true && s?.hasUpstream == false && s?.branchChanges?.baseRef == "origin/main")
        let remote = Self.json(#"{"_tag":"remoteUpdated","remote":{"aheadCount":2,"aheadOfDefaultCount":0,"behindCount":1,"hasUpstream":true,"pr":null}}"#)
        s = VcsStatus.apply(remote, to: s)
        #expect(s?.hasUpstream == true && s?.aheadCount == 2 && s?.behindCount == 1 && s?.refName == "main")
        let local = Self.json(#"{"_tag":"localUpdated","local":{"hasPrimaryRemote":true,"hasWorkingTreeChanges":true,"isDefaultRef":false,"isRepo":true,"refName":"dev","workingTree":{"deletions":1,"files":[{"path":"a","insertions":3,"deletions":1}],"insertions":3}}}"#)
        s = VcsStatus.apply(local, to: s)
        // The local part replaces, the remote part stays.
        #expect(s?.refName == "dev" && s?.workingTree.files.count == 1 && s?.aheadCount == 2 && s?.branchChanges == nil)
        #expect(VcsStatus.apply(Self.json(#"{"_tag":"other"}"#), to: s) == s)
        // A remote update before any snapshot assumes a repository with no ref.
        let early = VcsStatus.apply(remote, to: nil)
        #expect(early?.isRepo == true && early?.refName == nil && early?.aheadCount == 2)
    }

    @Test func refsAndResults() throws {
        let refs = try Self.json(#"{"hasPrimaryRemote":true,"isRepo":true,"nextCursor":null,"refs":[{"current":true,"isDefault":true,"isRemote":false,"name":"main","worktreePath":"/Users/user/sandbox/git-demo"},{"current":false,"isDefault":false,"isRemote":false,"name":"feature/demo","worktreePath":null}],"totalCount":2}"#)
            .decode(as: VcsListRefsResult.self)
        #expect(refs.refs.map(\.name) == ["main", "feature/demo"] && refs.nextCursor == nil && refs.refs[0].worktreePath != nil)

        let finished = GitActionProgressEvent(json: Self.json(#"{"kind":"action_finished","actionId":"a","cwd":"/r","action":"commit","result":{"action":"commit","branch":{"status":"skipped_not_requested"},"commit":{"status":"created","commitSha":"b6c4c32"},"push":{"status":"skipped_not_requested"},"pr":{"status":"skipped_not_requested"},"toast":{"title":"Committed b6c4c32","description":"Add notes","cta":{"kind":"none"}}}}"#))
        guard case .finished(let result)? = finished else { Issue.record("not finished"); return }
        #expect(result.toast.title == "Committed b6c4c32" && result.toast.cta.kind == "none" && result.branch.status == "skipped_not_requested")
        #expect(GitActionProgressEvent(json: Self.json(#"{"kind":"phase_started","phase":"commit","label":"Committing..."}"#)) == .phaseStarted(label: "Committing..."))
        #expect(GitActionProgressEvent(json: Self.json(#"{"kind":"action_failed","phase":"push","message":"rejected"}"#)) == .failed(message: "rejected"))

        let providers = SourceControlProviderDiscovery.list(Self.json(#"{"versionControlSystems":[],"sourceControlProviders":[{"kind":"github","label":"GitHub","status":"missing","installHint":"Install gh","auth":{"status":"unknown","account":{"_tag":"None"},"host":{"_tag":"None"},"detail":{"_tag":"Some","value":"not found"}}},{"kind":"gitlab","label":"GitLab","status":"available","installHint":"","auth":{"status":"authenticated","account":{"_tag":"Some","value":"me"},"host":{"_tag":"Some","value":"gitlab.com"},"detail":{"_tag":"None"}}}]}"#))
        #expect(providers.count == 2 && providers[0].detail == "not found" && providers[1].account == "me" && providers[1].host == "gitlab.com")
    }

    /// Payloads as GitActionsControl.tsx and BranchToolbarBranchSelector.tsx build them: optional fields only when set.
    @Test func payloads() {
        #expect(VcsRPC.runStackedActionInput(actionId: "id", cwd: "/r", action: .commit)
                == .object(["actionId": .string("id"), "cwd": .string("/r"), "action": .string("commit")]))
        #expect(VcsRPC.runStackedActionInput(actionId: "id", cwd: "/r", action: .commitPushPr, commitMessage: "m", featureBranch: true,
                                             filePaths: ["a"], threadId: "t", projectId: nil)
                == .object(["actionId": .string("id"), "cwd": .string("/r"), "action": .string("commit_push_pr"), "commitMessage": .string("m"),
                            "featureBranch": .bool(true), "filePaths": .array([.string("a")]), "threadId": .string("t")]))
        #expect(VcsRPC.listRefsInput(cwd: "/r") == .object(["cwd": .string("/r"), "limit": .number(100)]))
        #expect(VcsRPC.listRefsInput(cwd: "/r", query: "fe", cursor: 100)
                == .object(["cwd": .string("/r"), "limit": .number(100), "query": .string("fe"), "cursor": .number(100)]))
        #expect(VcsRPC.createRefInput(cwd: "/r", refName: "x") == .object(["cwd": .string("/r"), "refName": .string("x"), "switchRef": .bool(true)]))
        #expect(VcsRPC.publishInput(cwd: "/r", provider: "github", repository: " me/repo ", visibility: "private", remoteName: " ", protocol: "ssh")
                == .object(["cwd": .string("/r"), "provider": .string("github"), "repository": .string("me/repo"), "visibility": .string("private"),
                            "remoteName": .string("origin"), "protocol": .string("ssh")]))
    }

    @Test func errorText() {
        let e = RPCTypedError(tag: "TextGenerationError", fields: ["operation": .string("generateCommitMessage"), "detail": .string("Failed to spawn Codex CLI process")])
        #expect(GitErrorText.message(e) == "Text generation failed in generateCommitMessage: Failed to spawn Codex CLI process")
        let g = RPCTypedError(tag: "GitCommandError", fields: ["operation": .string("push"), "cwd": .string("/r"), "detail": .string("rejected"), "reason": .string("remote_unreachable")])
        #expect(GitErrorText.message(g) == "Git command failed in push (/r): rejected (remote_unreachable)")
    }
}
