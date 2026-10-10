import AppKit
import Testing
@testable import DesignSystem

/// The whole command palette popup against T3's markup in Chromium (spec from
/// scripts/gen-command-palette-spec.py). Report: /tmp/candywrapper-fidelity/report-command-palette.html.
@MainActor
struct CommandPaletteFidelityTests {
    static func palette(_ name: String) -> CommandPaletteView {
        let v: CommandPaletteView
        switch name {
        case "root":
            v = CommandPaletteView(content: .results([CommandPaletteGroup("Actions", [
                CommandPaletteItem("New thread in ", icon: .squarePen, shortcut: "⇧⌘O", titleEmphasis: "demo-repo"),
                CommandPaletteItem("New thread in...", icon: .squarePen, isSubmenu: true),
                CommandPaletteItem("Add project", icon: .folderPlus),
                CommandPaletteItem("Change appearance", icon: .monitor, shortcut: "⌥⇧⌘A", isSubmenu: true),
                CommandPaletteItem("Open settings", icon: .settings),
            ])]))
            v.highlightedIndex = 0
        case "submenu":
            v = CommandPaletteView(content: .results([CommandPaletteGroup("Change appearance", [
                CommandPaletteItem("System", icon: .monitor, note: "Current"),
                CommandPaletteItem("Light", icon: .sun),
                CommandPaletteItem("Dark", icon: .moon),
            ])]))
            v.input.placeholder = "Search..."
            v.showsBackButton = true
            v.showsBackHint = true
        case "search":
            v = CommandPaletteView(content: .results([
                CommandPaletteGroup("Projects", [CommandPaletteItem("demo-repo", icon: .folder, description: "Local · /Users/mrm/demo-repo")]),
                CommandPaletteGroup("Threads", [
                    CommandPaletteItem("Reply with markdown only", icon: .messageSquare, description: "demo-repo · Local", timestamp: "18m ago"),
                    CommandPaletteItem("Add notes and docstring", icon: .messageSquare, description: "demo-repo · Local", timestamp: "2d ago"),
                ]),
            ]))
            v.input.text = "demo"
            v.highlightedIndex = 0
        default:
            v = CommandPaletteView(content: .empty(message: nil, actionsOnly: false))
            v.input.text = "zzzz"
        }
        v.footerActionLabel = "Select"
        return v
    }

    @Test func commandPalette() throws {
        let mean = try FormsFidelityTests.run("command-palette", title: "Command palette") { n, _, _ in Self.palette(n["case"]!) }
        print(String(format: "FIDELITY command-palette: mean differing %.2f%%", mean * 100))
        #expect(mean < 0.05)
    }
}
