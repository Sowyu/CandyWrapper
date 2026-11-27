import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Review pictures for the Redesign integration pass: Appearance with Redesign on, three searches and the dialogs whose
/// wording changed, dark and light. Opt in with CANDY_REDESIGN_INTEGRATION_PICTURES=<folder>.
@MainActor @Suite struct RedesignIntegrationPictures {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDY_REDESIGN_INTEGRATION_PICTURES"] != nil))
    func render() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CANDY_REDESIGN_INTEGRATION_PICTURES"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance }
        let lib = ThemeLibrary(defaults: UserDefaults(suiteName: "cw.redesign.pictures.\(UUID().uuidString)")!, pinned: nil)
        lib.controlsAppearance = false
        lib.setTheme("ocean")
        lib.setRedesign(true)
        var redesign = SettingsSearchAvailability()
        redesign.redesign = true
        for dark in [false, true] {
            var input = ThemeRuntimeInput(
                light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
            input.ditherLight = true; input.ditherDark = true
            ThemeRuntime.apply(input)
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            func save(_ name: String, _ view: NSView, _ size: NSSize) throws {
                let image = RedesignBaselineTests.image(view, size: size, dark: dark)
                try Snapshot.writePNG(image, to: folder.appendingPathComponent("\(name).\(dark ? "dark" : "light").png"))
            }
            let page = AppearanceSettingsView(context: SettingsPagesFidelityTests.context())
            page.themes = lib
            page.refresh()
            try save("appearance-after", page, NSSize(width: 800, height: min(2200, page.height(forWidth: 800))))
            if let row = page.anchor("thread-details-items") { try save("thread-details-row", row, NSSize(width: 800, height: row.frame.height > 0 ? row.frame.height : 72)) }
            for query in ["glass", "gradient", "details"] {
                let nav = SettingsSidebarView()
                nav.searchItems = SettingsSearch.available(redesign)
                nav.setQuery(query)
                try save("search-\(query)", nav, NSSize(width: 256, height: 420))
            }
            let ssh = SshPasswordPromptDialog(state: SshPasswordPromptState(target: "dev@sandbox.local"))
            try save("dialog-ssh", ssh, NSSize(width: 480, height: 340))
            try save("dialog-relay-install", RelayClientInstallDialog.make(version: "1.4.2"), NSSize(width: 480, height: 320))
        }
    }
}
