import AppKit
import Testing
import T3Protocol
@testable import Features

/// The small areas sweep: logic ported from threadRoutes.ts, BranchToolbar.logic.ts and
/// pullRequestStackSnapshot.ts (with its test cases).
struct SmallAreasSweepTests {
    @Test func missingThreadRoute() {
        // Not in a loaded shell after it was listed: index while the environment has threads, else the empty state.
        #expect(MissingThreadRoute.resolve(shellLoaded: true, listed: false, seenBefore: true, environmentHasThreads: true) == .landOnIndex)
        #expect(MissingThreadRoute.resolve(shellLoaded: true, listed: false, seenBefore: true, environmentHasThreads: false) == .noActiveThread)
        // A thread launched a moment ago, a shell still loading, or a listed thread stays.
        #expect(MissingThreadRoute.resolve(shellLoaded: true, listed: false, seenBefore: false, environmentHasThreads: true) == .keep)
        #expect(MissingThreadRoute.resolve(shellLoaded: false, listed: false, seenBefore: true, environmentHasThreads: true) == .keep)
        #expect(MissingThreadRoute.resolve(shellLoaded: true, listed: true, seenBefore: true, environmentHasThreads: true) == .keep)
    }

    @Test func localCheckoutBranchMismatch() {
        let hit = BranchToolbarLogic.localCheckoutBranchMismatch(envMode: .local, worktreePath: nil, threadBranch: "feature", currentBranch: "main")
        #expect(hit?.threadBranch == "feature" && hit?.currentBranch == "main")
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(envMode: .local, worktreePath: nil, threadBranch: "main", currentBranch: "main") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(envMode: .worktree, worktreePath: nil, threadBranch: "a", currentBranch: "b") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(envMode: .local, worktreePath: "/w", threadBranch: "a", currentBranch: "b") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(envMode: .local, worktreePath: nil, threadBranch: nil, currentBranch: "b") == nil)
        #expect(BranchToolbarLogic.localCheckoutBranchMismatch(envMode: .local, worktreePath: nil, threadBranch: "a", currentBranch: nil) == nil)
    }

    static func link(stack: Bool = true, syncedAt: String = "2026-09-09T10:00:00Z") throws -> ThreadPullRequestLink {
        let stackJSON = stack ? """
            {"kind":"native","id":"stack","number":3,"url":"https://github.com/acme/web/pull/3","base":"main",
             "layers":[{"number":1,"headBranch":"bottom","state":"open"},{"number":2,"headBranch":"top","state":"open"}]}
            """ : "null"
        let json = """
            {"host":"github.com","repository":"acme/web","number":2,"url":"https://github.com/acme/web/pull/2","source":"manual",
             "linkedAt":"2026-09-09T10:00:00Z","snapshot":{"title":"Top layer","headBranch":"top","baseBranch":"bottom","state":"open",
             "isDraft":false,"updatedAt":null,"syncedAt":"\(syncedAt)"},"stack":\(stackJSON)}
            """
        return try JSONDecoder().decode(ThreadPullRequestLink.self, from: Data(json.utf8))
    }

    static let reference = PullRequestRef(projectId: "project", host: "github.com", repository: "acme/web", number: 2)

    @Test func savedStackKeepsEveryLayerWithoutHeadShas() throws {
        let saved = PullRequestWriteLogic.savedStack([try Self.link()], reference: Self.reference)
        #expect(saved?.layers == [
            .init(number: 1, headBranch: "bottom", state: "open"),
            .init(number: 2, title: "Top layer", isDraft: false, headBranch: "top", state: "open"),
        ])
        #expect(PullRequestWriteLogic.savedStack([try Self.link()], reference: .init(projectId: "project", host: "github.com", repository: "acme/web", number: 1))?.number == 3)
    }

    @Test func savedStackStaysInItsHostAndRepository() throws {
        let link = try Self.link()
        #expect(PullRequestWriteLogic.savedStack([link], reference: .init(projectId: "p", host: "enterprise.example", repository: "acme/web", number: 2)) == nil)
        #expect(PullRequestWriteLogic.savedStack([link], reference: .init(projectId: "p", host: "github.com", repository: "other/web", number: 2)) == nil)
        #expect(PullRequestWriteLogic.savedStack([link], reference: .init(projectId: "p", host: nil, repository: "acme/web", number: 2)) == nil)
    }

    @Test func savedStackHonorsANewerRemoval() throws {
        let removed = try Self.link(stack: false, syncedAt: "2026-09-09T11:00:00Z")
        #expect(PullRequestWriteLogic.savedStack([try Self.link(), removed], reference: Self.reference) == nil)
    }

    @Test func fileChipMenuLabels() throws {
        #expect(OpenInEditors.menuLabel("cursor") == "Open in Cursor")
        #expect(OpenInEditors.menuLabel(nil) == "Open in editor")
        #expect(OpenInEditors.menuLabel("file-manager") == "Open in editor")
        func config(_ json: String) throws -> ServerProviderConfig { try JSONDecoder().decode(ServerProviderConfig.self, from: Data(json.utf8)) }
        let mac = try config(#"{"availableEditors":["file-manager"],"shellRevealInFileManager":true,"environment":{"platform":{"os":"darwin"}}}"#)
        #expect(OpenInEditors.revealLabel(mac) == "Reveal in Finder")
        let wsl = try config(#"{"availableEditors":["file-manager"],"shellRevealInFileManager":true,"shellRevealInFileManagerKind":"file-explorer","environment":{"platform":{"os":"linux"}}}"#)
        #expect(OpenInEditors.revealLabel(wsl) == "Reveal in File Explorer")
        let linux = try config(#"{"availableEditors":["file-manager"],"shellRevealInFileManager":true,"environment":{"platform":{"os":"linux"}}}"#)
        #expect(OpenInEditors.revealLabel(linux) == "Reveal in Files")
        #expect(OpenInEditors.revealLabel(try config(#"{"availableEditors":["cursor"],"shellRevealInFileManager":true}"#)) == nil)
        #expect(OpenInEditors.revealLabel(try config(#"{"availableEditors":["file-manager"]}"#)) == nil)
    }

    @Test func terminalFontSettings() {
        #expect(TerminalFontSettings.families(#""JetBrains Mono", Menlo ,'M+ 1m'"#) == ["JetBrains Mono", "Menlo", "M+ 1m"])
        // A proportional or missing face falls back to the platform monospace face; sizes out of range use 12.
        let fallback = TerminalFontSettings.font(family: "Helvetica", size: 13)
        #expect(fallback.isFixedPitch && fallback.pointSize == 13)
        #expect(TerminalFontSettings.font(family: "No Such Font", size: 40).pointSize == 12)
        #expect(TerminalFontSettings.font(family: "Menlo", size: 14).familyName == "Menlo")
        // The bundled symbols face covers powerline glyphs through the cascade list.
        let cascade = TerminalFontSettings.font(family: "", size: 12).fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        #expect(cascade?.first?.object(forKey: .family) as? String == "Symbols Nerd Font Mono")
        #expect(NSFont(name: "SymbolsNFM", size: 12) != nil)
    }

    @Test func t3ProjectFile() {
        let file = T3ProjectFile.parse("""
            {
              // shared with the team
              "$schema": "https://t3.codes/schema/t3.json",
              "scripts": [
                { "name": " Dev ", "command": "npm run dev", "icon": "play", "previewUrl": "localhost:3000", "autoOpenPreview": true, },
                /* a comma inside a string stays: */ { "name": "Lint", "command": "echo a,]", "unknown": 1 },
              ],
            }
            """)
        #expect(file?.scripts.map(\.name) == ["Dev", "Lint"])
        #expect(file?.scripts.last?.command == "echo a,]")
        // Any invalid field makes the whole file absent.
        #expect(T3ProjectFile.parse(#"{"scripts":[{"name":"x","command":"y","icon":"rocket"}]}"#) == nil)
        #expect(T3ProjectFile.parse(#"{"scripts":[{"name":"  ","command":"y"}]}"#) == nil)
        #expect(T3ProjectFile.parse(#"{"defaultThreadEnvMode":"cloud"}"#) == nil)
        #expect(T3ProjectFile.parse("not json") == nil)

        let existing = [ProjectScript(id: "dev", name: "dev", command: "other")]
        let scripts = file?.scripts ?? []
        #expect(T3ProjectFile.importable(scripts, existing: existing).map(\.name) == ["Lint"])
        let input = T3ProjectFile.importInput(scripts[0], canWriteSettings: true)
        #expect(input.icon == "play" && input.previewUrl == "localhost:3000" && input.autoOpenPreview && input.keybinding == "")
        let lint = T3ProjectFile.importInput(scripts[1], canWriteSettings: false)
        #expect(lint.icon == "play" && !lint.autoOpenPreview && lint.keybinding == nil && !lint.waitForSetup)
    }

    @Test func automaticEnvironment() {
        func auto(enabled: Bool = true, machines: Int = 2, locked: Bool = false, selection: String? = nil, resolved: String? = nil,
                  attachments: Bool = false, branch: String? = nil, worktree: String? = nil) -> Bool {
            ProviderLoadBalanceLogic.isAutomatic(enabled: enabled, canBalance: machines > 1, locked: locked, selection: selection, resolved: resolved,
                                                 hasAttachments: attachments, branch: branch, worktreePath: worktree)
        }
        // A fresh draft routes itself by default once balancing is on.
        #expect(auto())
        #expect(!auto(enabled: false))
        #expect(!auto(machines: 1))
        #expect(!auto(locked: true))
        #expect(!auto(selection: "manual"))
        // Attachments made before a machine was chosen stay put; after the choice they ride along.
        #expect(!auto(attachments: true))
        #expect(auto(resolved: "env-2", attachments: true))
        // A branch picked outside Auto, or a worktree, pins the machine.
        #expect(!auto(branch: "main"))
        #expect(auto(selection: "auto", branch: "main"))
        #expect(!auto(worktree: "/w"))
    }
}
