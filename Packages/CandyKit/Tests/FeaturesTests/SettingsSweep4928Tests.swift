import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The Nightly 4928 settings row sweep (settings-6): each check fails on the logic before it.
@MainActor
struct SettingsSweep4928Tests {
    /// #36437: closing Settings back to the page it opened over leaves no Settings stop behind.
    @Test func closedSettingsLeavesNoHistoryStop() {
        let h = RouteHistory()
        h.record(.thread(ThreadId("a")))
        h.record(.settings(.general))
        h.record(.settings(.appearance))
        h.record(.thread(ThreadId("a")))
        #expect(h.entries == [.thread(ThreadId("a"))])
        #expect(!h.canGoForward && !h.canGoBack)
        // Closing to another page still pushes.
        h.record(.settings(.general))
        h.record(.usage)
        #expect(h.entries == [.thread(ThreadId("a")), .settings(.general), .usage])
    }

    /// #23479: a favorite the provider stopped reporting keeps a row.
    @Test func unreportedFavoriteKeepsItsRow() {
        let models = ProvidersLogic.displayModels(live: [], custom: [], favorites: ["gone-model"], hidden: [], order: [])
        #expect(models.map(\.slug) == ["gone-model"])
        #expect(models.first?.name == "gone-model")
    }

    /// #23450: the inheritance popover names a background activity profile.
    @Test func inheritedProfileHasAName() {
        let value: JSONValue = .object(["schemaVersion": .number(1), "profile": .string("battery-saver"), "overrides": .object([:])])
        #expect(SettingsPageBase.format("backgroundActivity", value) == "Battery saver")
        #expect(SettingsPageBase.format("backgroundActivity", .object(["profile": .string("custom")])) == "Advanced")
    }

    /// #36856: the project menu follows the selected environment.
    @Test func projectMenuFollowsEnvironment() {
        func member(_ env: String, _ id: String) -> SettingsScopeProject.Member {
            .init(environmentId: env, projectId: id, title: id, workspaceRoot: "/\(id)")
        }
        let a = SettingsScopeProject(key: "a", displayName: "A", members: [member("e1", "a")])
        let b = SettingsScopeProject(key: "b", displayName: "B", members: [member("e2", "b")])
        var scope = SettingsScopeState(environments: [], primaryId: nil, projects: [a, b])
        #expect(scope.projectMenu.map(\.key) == ["a", "b"])
        scope.selection = SettingsScopeSelection(machine: "e2")
        #expect(scope.projectMenu.map(\.key) == ["b"])
    }

    /// #36789 and #29851: a cleared run time fails instead of saving 09:00; a saved 9:05 opens padded.
    @Test func scheduledRunTime() {
        var d = ScheduledTaskDraft()
        d.title = "t"; d.prompt = "p"; d.scheduleMode = .fixed; d.timeOfDay = ""
        let result = ScheduledTaskLogic.upsertInput(d, projectId: "p", projectExists: true, selection: ("c", "m"), storedSecret: false)
        #expect(result == .failure(.invalidRunTime("Pick a time.")))
        let task = ScheduledTask(id: "t", title: "t", prompt: "p", schedule: .fixedTime(timeOfDay: "9:05", weekdays: nil), projectId: "p")
        #expect(ScheduledTaskLogic.draft(task).timeOfDay == "09:05")
    }

    /// #23465: Home and End jump the hue.
    @Test func hueSliderHomeAndEnd() throws {
        let slider = ColorHueSliderView(hue: 120)
        var seen: [Double] = []
        slider.onChange = { seen.append($0) }
        for code: UInt16 in [115, 119] {
            let chars = String(Character(UnicodeScalar(code == 115 ? NSHomeFunctionKey : NSEndFunctionKey)!))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            slider.keyDown(with: event)
        }
        #expect(seen == [0, 360])
    }

    /// #18187: a confirmation opens on its primary action.
    @Test func confirmationFocusesPrimary() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let dialog = DialogView(kind: .alertDialog, title: "Remove?", message: "Gone for good.")
        let cancel = ButtonView("Cancel", variant: .outline), remove = ButtonView("Remove", variant: .destructive)
        dialog.footerButtons = [cancel, remove]
        let host = ModalHost.present(dialog, in: window, blurBackdrop: false)
        #expect(window.firstResponder === remove)
        #expect(ModalHost.confirmationPresented(in: window))
        host.close(animated: false)
    }
}
