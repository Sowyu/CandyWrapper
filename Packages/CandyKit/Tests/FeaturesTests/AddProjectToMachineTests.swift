import Foundation
import Testing
import T3Protocol
@testable import Features

/// Add to another machine (T3 #22180, #22254): addProjectToMachine.test.ts, useAddProjectTargets.ts and the dialog's
/// selection rules.
struct AddProjectToMachineTests {
    typealias A = AddProjectToMachine

    @Test func cloneUrlProtocols() {
        // addProjectToMachine.test.ts: GitHub in both forms, ssh:// and a custom port.
        #expect(A.cloneUrlProtocol("git@github.com:pingdotgg/t3code.git") == .ssh)
        #expect(A.cloneUrlProtocol("https://github.com/pingdotgg/t3code.git") == .https)
        #expect(A.cloneUrlProtocol("ssh://git@host.example/team/repo.git") == .ssh)
        #expect(A.cloneUrlProtocol("/Users/me/repo") == nil)
        #expect(A.cloneUrl("git@github.com:pingdotgg/t3code.git", for: .https) == "https://github.com/pingdotgg/t3code.git")
        #expect(A.cloneUrl("https://github.com/pingdotgg/t3code.git", for: .ssh) == "git@github.com:pingdotgg/t3code.git")
        #expect(A.cloneUrl("https://user@github.com/a/b.git", for: .ssh) == "git@github.com:a/b.git")
        #expect(A.cloneUrl(" https://github.com/a/b.git ", for: .https) == "https://github.com/a/b.git")
        #expect(A.cloneUrl("ssh://git@host.example:2222/team/repo.git", for: .https) == nil)
        #expect(A.cloneUrl("http://127.0.0.1:8080/demo.git", for: .ssh) == nil)
        #expect(A.cloneUrl("ssh://git@host.example/team/repo.git", for: .https) == "https://host.example/team/repo.git")
        #expect(A.remoteUrl(source: "git@github.com:a/b.git", protocol: .https) == "https://github.com/a/b.git")
        #expect(A.remoteUrl(source: "http://127.0.0.1:8080/demo.git", protocol: .ssh) == "http://127.0.0.1:8080/demo.git")
        #expect(A.remoteUrl(source: "/local/repo", protocol: nil) == "/local/repo")
    }

    @Test func defaultCopiedFiles() {
        for path in [".env", ".env.local", "apps/web/.env.production", ".envrc", "worker/.dev.vars"] {
            #expect(A.isDefaultCopiedFile(path), "\(path)")
        }
        for path in [".env.", "env", ".environment", "notes.env", "dist/app.js", ".dev.vars.bak"] {
            #expect(!A.isDefaultCopiedFile(path), "\(path)")
        }
    }

    @Test func ignoredFileSelection() {
        let files = [
            A.IgnoredFile(path: ".env", byteLength: 120),
            A.IgnoredFile(path: "apps/web/.env.local", byteLength: 2048),
            A.IgnoredFile(path: ".env.huge", byteLength: A.copyableFileMaxBytes + 1),
            A.IgnoredFile(path: "notes.txt", byteLength: 10),
        ]
        let picked = A.defaultSelection(files)
        #expect(picked == [".env", "apps/web/.env.local"])
        #expect(files[2].tooLarge && !files[0].tooLarge)
        #expect(A.IgnoredFile(path: "x", byteLength: A.copyableFileMaxBytes).tooLarge == false)
        // All picks every copyable file, then None clears them.
        let all = A.toggleAll(files, selected: picked)
        #expect(all == [".env", "apps/web/.env.local", "notes.txt"])
        #expect(A.toggleAll(files, selected: all).isEmpty)
        #expect(A.selectionSummary(files, selected: picked) == "2 of 4 \u{00B7} 2.12 KB")
        #expect(A.selectionSummary(files, selected: []) == "0 of 4")
        #expect(A.filesCaption(0) == "no files")
        #expect(A.filesCaption(1) == "+ 1 file")
        #expect(A.filesCaption(3) == "+ 3 files")
    }

    @Test func decodesTheIgnoredFileList() {
        let reply: JSONValue = .object([
            "files": .array([
                .object(["path": .string(".env"), "byteLength": .number(42)]),
                .object(["path": .string(""), "byteLength": .number(1)]),
                .object(["path": .string("b"), "byteLength": .string("x")]),
            ]),
            "truncated": .bool(true),
        ])
        let (files, truncated) = A.ignoredFiles(reply)
        #expect(files == [A.IgnoredFile(path: ".env", byteLength: 42)])
        #expect(truncated)
        #expect(A.ignoredFiles(nil).files.isEmpty)
    }

    @Test func targets() {
        func candidate(_ id: String, _ label: String, connected: Bool = true, canClone: Bool = true, tracks: Bool = true) -> A.Candidate {
            .init(target: .init(environmentId: id, label: label, machine: "server"), connected: connected, canClone: canClone, tracksClones: tracks)
        }
        let candidates = [
            candidate("local", "This Mac"), candidate("b", "Studio"), candidate("a", "Air"),
            candidate("off", "Offline", connected: false), candidate("ro", "Read only", canClone: false),
            candidate("old", "Old server", tracks: false), candidate("member", "Has it"),
        ]
        let out = A.targets(remoteUrl: "git@github.com:a/b.git", sourceEnvironmentId: "local", projectEnvironmentIds: ["member"], candidates: candidates)
        #expect(out.map(\.environmentId) == ["a", "b"])
        #expect(A.targets(remoteUrl: nil, sourceEnvironmentId: "local", projectEnvironmentIds: [], candidates: candidates).isEmpty)
        #expect(A.targets(remoteUrl: "", sourceEnvironmentId: "local", projectEnvironmentIds: [], candidates: candidates).isEmpty)
    }

    @Test func subdirectoryAndDestination() {
        #expect(A.projectSubdirectory(repositoryRoot: "/r/repo", workspaceRoot: "/r/repo/apps/web") == "apps/web")
        #expect(A.projectSubdirectory(repositoryRoot: "/r/repo/", workspaceRoot: "/r/repo/apps") == "apps")
        #expect(A.projectSubdirectory(repositoryRoot: "/r/repo", workspaceRoot: "/r/repo") == "")
        #expect(A.projectSubdirectory(repositoryRoot: "/r/repo", workspaceRoot: "/r/repository") == "")
        #expect(A.projectSubdirectory(repositoryRoot: nil, workspaceRoot: "/r/repo/x") == "")
        #expect(A.projectSubdirectory(repositoryRoot: "C:\\r", workspaceRoot: "C:\\r\\a\\b") == "a/b")
        #expect(A.defaultDestination(baseDirectory: nil, remoteUrl: "git@github.com:a/demo.git") == "~/demo")
        #expect(A.defaultDestination(baseDirectory: " ~/code ", remoteUrl: "https://github.com/a/demo") == "~/code/demo")
        #expect(A.defaultDestination(baseDirectory: "/srv/", remoteUrl: "http://127.0.0.1:47398/demo.git") == "/srv/demo")
    }

    @Test func requestPayloads() {
        #expect(A.listIgnoredFilesPayload(cwd: "/r/repo") == .object(["cwd": .string("/r/repo")]))
        #expect(A.readFilePayload(cwd: "/r/repo", relativePath: ".env") == .object(["cwd": .string("/r/repo"), "relativePath": .string(".env")]))
        #expect(A.cloneStartPayload(projectId: "p1", title: "Demo", createdAt: "2026-10-22T00:00:00.000Z",
                                    remoteUrl: "git@github.com:a/b.git", destinationPath: "~/b") == .object([
            "projectId": .string("p1"), "title": .string("Demo"), "createdAt": .string("2026-10-22T00:00:00.000Z"),
            "remoteUrl": .string("git@github.com:a/b.git"), "destinationPath": .string("~/b"),
        ]))
        #expect(A.writeFilePayload(cwd: "/c/b", subdirectory: "", relativePath: ".env", contents: "A=1") == .object([
            "cwd": .string("/c/b"), "relativePath": .string(".env"), "contents": .string("A=1"),
        ]))
        #expect(A.writeFilePayload(cwd: "/c/b", subdirectory: "apps/web", relativePath: ".env", contents: "")["relativePath"] == .string("apps/web/.env"))
        #expect(A.copyFailureTitle(count: 1, machine: "Studio") == "Could not copy 1 file to Studio")
        #expect(A.copyFailureTitle(count: 2, machine: "Studio") == "Could not copy 2 files to Studio")
    }

    @Test func copyingFilesHoldsSends() {
        #expect(ComposerLogic.projectCloneSendBlockReason(running: false, done: true, copyingFiles: true) == "Copying files")
        #expect(ComposerLogic.projectCloneSendBlockReason(running: nil, done: false, copyingFiles: true) == "Copying files")
        #expect(ComposerLogic.projectCloneSendBlockReason(running: true, done: false, copyingFiles: true) == "Cloning repository")
        #expect(ComposerLogic.projectCloneSendBlockReason(running: false, done: false, copyingFiles: true) == "Repository not cloned")
    }

    @MainActor @Test func runOnListOffersTheDialog() {
        let runOn = RunOnControl()
        runOn.options = [RunOnOption(environmentId: "local", label: "This Mac", machine: "laptop")]
        runOn.selectedId = "local"
        #expect(!runOn.interactive)
        #expect(runOn.addToMachineMenuItem() == nil)
        var opened: [String?] = []
        runOn.onAddToMachine = { opened.append($0) }
        runOn.addTargets = [.init(environmentId: "b", label: "Studio", machine: "server")]
        #expect(runOn.interactive)
        let items = runOn.listItems()
        #expect(items.last?.title == "Add to another machine")
        #expect(items.last?.mutedUntilHighlighted == true)
        items.last?.action?()
        guard let sub = runOn.addToMachineMenuItem(), case .submenu(let children) = sub.kind else { Issue.record("no submenu"); return }
        #expect(children.map(\.title) == ["Studio"])
        children[0].action?()
        #expect(opened == [nil, "b"])
    }
}
