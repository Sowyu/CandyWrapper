import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

/// Deleting a project from Redesign's Settings > Projects list (the user, 2026-11-21): T3's command, T3's
/// prompt, no delete on scratch rows or offline machines, Cancel does nothing, a failure keeps the row.
@MainActor
struct SettingsProjectDeleteTests {
    typealias List = SettingsProjectListTests

    /// ProjectSettingsPanel.tsx:391-397 sends `deleteProject({projectId, force: true})`, which reaches the
    /// server as this `projects.mutate` body (contracts project.ts:220-225).
    @Test func commandMatchesT3() {
        #expect(ProjectRemoval.command(projectId: "p1", commandId: "c1") == .object([
            "type": .string("project.delete"), "commandId": .string("c1"), "projectId": .string("p1"), "force": .bool(true),
        ]))
    }

    @Test func scratchRowsCannotBeDeleted() {
        let scope = List.scope()
        let scratch = SettingsProjectList.entries(scope).filter(\.isScratch)
        #expect(!scratch.isEmpty && scratch.allSatisfy { !$0.canDelete })
        #expect(SettingsProjectList.deletion(key: "a:scratch", scope: scope, threadCount: { _, _ in 0 }) == nil)
        let row = SettingsProjectListView.Row()
        row.entry = scratch[0]
        #expect(row.menuItems.isEmpty)
        #expect(row.more.isHidden)
        var asked = false
        row.onDelete = { asked = true }
        row.keyDown(with: Self.key(51))
        #expect(!asked)
    }

    @Test func emptyProjectCopy() throws {
        let plan = try #require(SettingsProjectList.deletion(key: "a:/Users/dev/code/harbor-docs", scope: List.scope(), threadCount: { _, _ in 0 }))
        #expect(plan.confirmTitle == "Delete project")
        #expect(plan.message == """
            Remove project "harbor-docs"?
            Path: /Users/dev/code/harbor-docs
            Any archived threads are deleted from T3 Code. Provider sessions are kept.
            This removes only the project entries, not the files on disk.
            This action cannot be undone.
            """)
    }

    @Test func projectWithThreadsCopy() throws {
        let plan = try #require(SettingsProjectList.deletion(key: "a:/Users/dev/code/basalt", scope: List.scope(), threadCount: { _, _ in 22 }))
        #expect(plan.confirmTitle == "Delete project and 22 threads")
        #expect(plan.message.hasPrefix("Remove project \"Basalt\" and delete its 22 threads?\n"))
        #expect(plan.message.contains("Those threads and any archived threads are deleted from T3 Code. Provider sessions are kept."))
        let one = try #require(SettingsProjectList.deletion(key: "a:/Users/dev/code/quill", scope: List.scope(), threadCount: { _, _ in 1 }))
        #expect(one.confirmTitle == "Delete project and 1 thread")
    }

    /// One row, two machines: both checkouts go, as T3's Danger section removes `group.memberProjects`.
    @Test func groupedProjectCopy() throws {
        let key = "repo:github.com/example/meridian"
        let plan = try #require(SettingsProjectList.deletion(key: key, scope: List.scope(), threadCount: { env, _ in env == "a" ? 10 : 8 }))
        #expect(plan.members.map(\.projectId) == ["m1", "m2"])
        #expect(plan.confirmTitle == "Delete project and 18 threads")
        #expect(plan.message.contains("This removes 2 grouped project entries."))
        // Scoped to one machine, only its checkout goes and the rest of the group stays.
        var scoped = List.scope(); scoped.selection = SettingsScopeSelection(machine: "b", project: nil)
        let one = try #require(SettingsProjectList.deletion(key: key, scope: scoped, threadCount: { _, _ in 8 }))
        #expect(one.members.map(\.projectId) == ["m2"])
        #expect(one.confirmTitle == "Delete checkout and 8 threads")
        #expect(one.message.contains("Other entries in this grouped project are unaffected."))
    }

    @Test func offlineMachineDisablesDelete() throws {
        var scope = List.scope()
        scope.environments[1].connected = false
        let entry = try #require(SettingsProjectList.entries(scope).first { $0.name == "meridian" })
        #expect(entry.deleteBlockedReason == "Build box is offline.")
        #expect(SettingsProjectList.deletion(key: entry.key, scope: scope, threadCount: { _, _ in 0 }) == nil)
        let row = SettingsProjectListView.Row()
        row.entry = entry
        #expect(row.menuItems.first?.isDisabled == true)
        #expect(row.menuItems.last?.title == "Build box is offline.")
    }

    /// The list asks, Cancel sends nothing, and a failed delete keeps the row and shows no "Deleted" toast.
    @Test func cancelAndFailureKeepTheRow() throws {
        let context = SettingsPagesFidelityTests.context()
        context.scope = List.scope()
        var asked: (message: String, title: String, confirm: @MainActor () -> Void)?
        var sent: [[SettingsScopeProject.Member]] = []
        var toasts: [String] = []
        context.confirmDelete = { asked = ($0, $1, $2) }
        context.deleteProjects = { members, leave, done in sent.append(members); #expect(!leave); done?(false) }
        context.toast = { title, _, _ in toasts.append(title) }
        try List.withRedesign(dark: false) {
            let page = ProjectSettingsView(context: context)
            let list = try #require(List.list(in: page))
            let row = try #require(list.subviews.flatMap(\.subviews).compactMap { $0 as? SettingsProjectListView.Row }.first { $0.entry?.name == "Kite" })
            row.keyDown(with: Self.key(51, command: true))
            let prompt = try #require(asked)
            #expect(prompt.title == "Delete project")
            #expect(sent.isEmpty)
            prompt.confirm()
            #expect(sent.map { $0.map(\.projectId) } == [["Kite"]])
            #expect(toasts.isEmpty)
            #expect(list.shown.contains { $0.name == "Kite" })
        }
    }

    @Test func successToasts() throws {
        let context = SettingsPagesFidelityTests.context()
        context.scope = List.scope()
        var toasts: [String] = []
        context.confirmDelete = { _, _, confirm in confirm() }
        context.deleteProjects = { _, _, done in done?(true) }
        context.toast = { title, _, _ in toasts.append(title) }
        try List.withRedesign(dark: false) {
            let page = ProjectSettingsView(context: context)
            let list = try #require(List.list(in: page))
            list.onDelete?("c:/Users/dev/code/kite")
            #expect(toasts == ["Deleted Kite"])
        }
    }

    /// The dialog in Redesign: T3's lines, Cancel focused, the destructive button naming the loss.
    @Test func redesignBaseline() throws {
        let record = ProcessInfo.processInfo.environment["CANDY_RECORD_REDESIGN_BASELINE"] == "1"
        let plan = try #require(SettingsProjectList.deletion(key: "a:/Users/dev/code/basalt", scope: List.scope(), threadCount: { _, _ in 22 }))
        for dark in [false, true] {
            try List.withRedesign(dark: dark) {
                let name = "settings-projects-delete-confirm.\(dark ? "dark" : "light")"
                let ours = Self.renderDialog(plan, dark: dark)
                let url = RedesignBaselineTests.directory.appendingPathComponent(name + ".png")
                if record { try Snapshot.writePNG(ours, to: url); return }
                guard FileManager.default.fileExists(atPath: url.path) else { Issue.record("Missing Redesign baseline: \(url.path)"); return }
                try FileManager.default.createDirectory(at: RedesignBaselineTests.output, withIntermediateDirectories: true)
                try RedesignBaselineTests.compare(try #require(NSBitmapImageRep(data: Data(contentsOf: url))), ours, name: name)
            }
        }
    }

    /// Return must not confirm: the dialog opens on Cancel, and Escape closes it.
    @Test func cancelHoldsFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let dialog = DialogView(kind: .alertDialog, title: "Remove project \"Kite\"?")
        let cancel = ButtonView("Cancel", variant: .outline), ok = ButtonView("Delete project", variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        dialog.initialFocus = cancel
        let host = ModalHost.present(dialog, in: window, blurBackdrop: false)
        #expect(window.firstResponder === cancel)
        host.close()
    }

    static func renderDialog(_ plan: SettingsProjectDeletion, dark: Bool) -> NSBitmapImageRep {
        let copy = ConfirmCopy.resolve(plan.message)
        let dialog = DialogView(kind: .alertDialog, title: copy.title, message: copy.description)
        dialog.footerButtons = [ButtonView("Cancel", variant: .outline), ButtonView(plan.confirmTitle, variant: .destructive)]
        return RedesignBaselineTests.image(dialog, size: NSSize(width: 512, height: dialog.height(forWidth: 512)), dark: dark)
    }

    static func key(_ code: UInt16, command: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: code)!
    }
}
