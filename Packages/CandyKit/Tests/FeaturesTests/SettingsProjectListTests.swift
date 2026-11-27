import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

/// Redesign's Settings > Projects list (the user, 2026-11-21): sort, the No project labels, folding, grouping,
/// search, and the page in light and dark.
@MainActor
struct SettingsProjectListTests {
    /// With no projects the empty state offers Add project, which runs the app's add-project flow.
    @Test func emptyStateAddsAProject() {
        let list = SettingsProjectListView(entries: [], select: { _ in })
        #expect(list.noProjects.state.action == nil)
        var added = 0
        list.onAddProject = { added += 1 }
        let action = list.noProjects.state.action
        #expect(action?.title == "Add project")
        action?.handler()
        #expect(added == 1)
    }

    static let machines = [("a", "Studio Mac"), ("b", "Build box"), ("c", "Travel laptop")]

    /// 19 projects over 3 machines: 15 plain ones, one grouped across two machines, three scratch folders.
    static func scope() -> SettingsScopeState {
        func project(_ name: String, _ env: String, threads: Int, pinned: Bool = false) -> SettingsScopeProject {
            let root = "/Users/dev/code/" + name.lowercased().replacingOccurrences(of: " ", with: "-")
            return SettingsScopeProject(key: env + ":" + root, displayName: name,
                                        members: [.init(environmentId: env, projectId: name, title: name, workspaceRoot: root)],
                                        threadCount: threads, pinned: pinned)
        }
        var projects = [
            project("orchard", "a", threads: 12), project("Lantern", "a", threads: 4, pinned: true), project("pebble-api", "a", threads: 31),
            project("Quill", "a", threads: 1), project("harbor-docs", "a", threads: 0), project("Moss", "b", threads: 7),
            project("ferris-wheel", "b", threads: 2), project("Tundra", "b", threads: 9), project("acorn", "b", threads: 3),
            project("Kite", "c", threads: 5), project("drift-notes", "c", threads: 14), project("Nimbus", "c", threads: 6),
            project("velvet", "c", threads: 2), project("Basalt", "a", threads: 22), project("cinder-ui", "c", threads: 8),
        ]
        projects.append(SettingsScopeProject(key: "repo:github.com/example/meridian", displayName: "meridian", members: [
            .init(environmentId: "a", projectId: "m1", title: "meridian", workspaceRoot: "/Users/dev/code/meridian"),
            .init(environmentId: "b", projectId: "m2", title: "meridian", workspaceRoot: "/home/dev/meridian")],
            threadCount: 18))
        for (env, _) in machines {
            projects.append(SettingsScopeProject(key: env + ":scratch", displayName: "No project", members: [
                .init(environmentId: env, projectId: "s-" + env, title: "No project", workspaceRoot: "/Users/dev/.t3/scratch")],
                threadCount: env == "a" ? 3 : 1, isScratch: true))
        }
        return SettingsScopeState(environments: machines.map { SettingsScopeEnvironment(id: $0.0, label: $0.1, settings: ServerSettingsValues(.object([:]))) },
                                  primaryId: "a", projects: projects)
    }

    @Test func sortsPinnedThenNameWithScratchLast() {
        let names = SettingsProjectList.entries(Self.scope()).map(\.name)
        #expect(names.count == 19)
        #expect(names.first == "Lantern")
        #expect(Array(names[1...4]) == ["acorn", "Basalt", "cinder-ui", "drift-notes"])
        #expect(Array(names.suffix(3)) == ["No project · Build box", "No project · Studio Mac", "No project · Travel laptop"])
    }

    @Test func scratchRowsNameTheirMachineAndFoldDuplicates() {
        var scope = Self.scope()
        scope.projects.append(SettingsScopeProject(key: "a:scratch-2", displayName: "No project", members: [
            .init(environmentId: "a", projectId: "s2", title: "No project", workspaceRoot: "/Users/dev/.t3/scratch")], threadCount: 2, isScratch: true))
        let scratch = SettingsProjectList.entries(scope).filter(\.isScratch)
        #expect(scratch.count == 3)
        let studio = scratch.first { $0.machines == ["Studio Mac"] }
        #expect(studio?.threadCount == 5)
        #expect(studio?.detail == "/Users/dev/.t3/scratch")
        #expect(studio?.accessibilityLabel == "No project · Studio Mac, Studio Mac, 5 threads")
    }

    @Test func groupedProjectIsOneRowListingItsMachines() {
        let rows = SettingsProjectList.entries(Self.scope())
        let meridian = rows.filter { $0.name == "meridian" }
        #expect(meridian.count == 1)
        #expect(meridian[0].key == "repo:github.com/example/meridian")
        #expect(meridian[0].detail == "2 machines: Studio Mac, Build box")
        #expect(meridian[0].accessibilityLabel == "meridian, 2 machines, Studio Mac, Build box, 18 threads")
        let quill = rows.first { $0.name == "Quill" }
        #expect(quill?.detail == "Studio Mac · /Users/dev/code/quill")
        #expect(quill?.accessibilityLabel == "Quill, Studio Mac, 1 thread")
    }

    /// The Projects notes from the polish audit: an empty project shows no "0 threads", and a pinned row says it is
    /// pinned, since it sorts first.
    @Test func emptyCountIsBlankAndPinnedRowSaysSo() {
        let rows = SettingsProjectList.entries(Self.scope())
        var lantern = try! #require(rows.first { $0.name == "Lantern" })
        #expect(lantern.pinned && lantern.accessibilityLabel.hasPrefix("Lantern, pinned, "))
        lantern.threadCount = 0
        #expect(lantern.threadLabel.isEmpty && !lantern.accessibilityLabel.contains("0 threads"))
    }

    @Test func searchMatchesNameMachineAndPath() {
        let rows = SettingsProjectList.entries(Self.scope())
        #expect(SettingsProjectList.filter(rows, query: "").count == 19)
        #expect(SettingsProjectList.filter(rows, query: "MOSS").map(\.name) == ["Moss"])
        #expect(Set(SettingsProjectList.filter(rows, query: "build box").map(\.name))
                == ["acorn", "ferris-wheel", "meridian", "Moss", "Tundra", "No project · Build box"])
        #expect(SettingsProjectList.filter(rows, query: "code/pebble").map(\.name) == ["pebble-api"])
        #expect(SettingsProjectList.filter(rows, query: "zzz").isEmpty)
    }

    @Test func pageShowsSearchOnlyForLongListsAndClicksSelect() throws {
        let context = SettingsPagesFidelityTests.context()
        context.scope = Self.scope()
        var picked: SettingsScopeSelection?
        context.selectScope = { picked = $0 }
        try Self.withRedesign(dark: true) {
            let page = ProjectSettingsView(context: context)
            let list = try #require(Self.list(in: page))
            #expect(!list.search.isHidden)
            list.search.input.text = "nothing-here"; list.search.input.onChange?("nothing-here")
            #expect(list.shown.isEmpty)
            #expect(list.takeRouteModalEscape())
            #expect(list.shown.count == 19)
            let row = try #require(list.subviews.flatMap(\.subviews).compactMap { $0 as? SettingsProjectListView.Row }.first { $0.entry?.name == "Kite" })
            row.action?()
            #expect(picked == SettingsScopeSelection(machine: nil, project: "c:/Users/dev/code/kite"))
            var short = Self.scope(); short.projects = Array(short.projects.prefix(5))
            context.scope = short
            page.refresh()
            #expect(Self.list(in: page) === list)
            #expect(list.search.isHidden)
        }
    }

    /// Redesign baseline cases for this page; recorded with CANDY_RECORD_REDESIGN_BASELINE=1 like the rest.
    @Test func redesignBaseline() throws {
        let record = ProcessInfo.processInfo.environment["CANDY_RECORD_REDESIGN_BASELINE"] == "1"
        for dark in [false, true] {
            try Self.withRedesign(dark: dark) {
                let ours = Self.render(dark: dark)
                let url = RedesignBaselineTests.directory.appendingPathComponent("settings-projects-list.\(dark ? "dark" : "light").png")
                if record { try Snapshot.writePNG(ours, to: url); return }
                guard FileManager.default.fileExists(atPath: url.path) else { Issue.record("Missing Redesign baseline: \(url.path)"); return }
                try FileManager.default.createDirectory(at: RedesignBaselineTests.output, withIntermediateDirectories: true)
                try RedesignBaselineTests.compare(try #require(NSBitmapImageRep(data: Data(contentsOf: url))), ours,
                                                  name: "settings-projects-list.\(dark ? "dark" : "light")")
            }
        }
    }

    /// Writes the report pictures when CANDY_PROJECTS_LIST_PICTURES names a folder: the pills before, the list
    /// after, and a search, in light and dark.
    @Test func pictures() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANDY_PROJECTS_LIST_PICTURES"] else { return }
        let folder = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try Self.withRedesign(dark: dark) {
                let before = SettingsScopeNoticeView("Choose a project to manage its name, icon, checkouts and actions.",
                                                     choices: Self.scope().projectMenu.map { ($0.displayName, {}) })
                let size = NSSize(width: 800, height: before.height(forWidth: 800))
                try Snapshot.writePNG(RedesignBaselineTests.image(before, size: size, dark: dark), to: folder.appendingPathComponent("before-\(suffix).png"))
                try Snapshot.writePNG(Self.render(dark: dark), to: folder.appendingPathComponent("after-\(suffix).png"))
                try Snapshot.writePNG(Self.render(dark: dark, query: "box"), to: folder.appendingPathComponent("search-box-\(suffix).png"))
                try Snapshot.writePNG(Self.render(dark: dark, query: "qqq"), to: folder.appendingPathComponent("search-empty-\(suffix).png"))
            }
        }
    }

    static func render(dark: Bool, query: String = "") -> NSBitmapImageRep {
        let context = SettingsPagesFidelityTests.context()
        context.scope = scope()
        let page = ProjectSettingsView(context: context)
        if !query.isEmpty, let list = list(in: page) { list.search.input.text = query; list.search.input.onChange?(query) }
        return RedesignBaselineTests.image(page, size: NSSize(width: 800, height: page.height(forWidth: 800)), dark: dark)
    }

    static func list(in view: NSView) -> SettingsProjectListView? {
        if let list = view as? SettingsProjectListView { return list }
        return view.subviews.lazy.compactMap { list(in: $0) }.first
    }

    static func withRedesign(dark: Bool, _ body: () throws -> Void) throws {
        let previous = ThemeRuntime.input, fonts = FontRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); FontRuntime.apply(fonts); NSApp?.appearance = appearance }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input); FontRuntime.apply(.init())
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try body()
    }
}
