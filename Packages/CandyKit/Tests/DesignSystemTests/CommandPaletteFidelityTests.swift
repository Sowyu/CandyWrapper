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
        case "match":
            var a = CommandPaletteItem("Write a story", icon: .messageSquare, description: "demo-repo · Local", timestamp: "2m ago",
                                       match: "Agent: The lighthouse keeper climbed")
            a.matchIsUser = false
            a.matchHighlights = Array(11..<21)
            var b = CommandPaletteItem("Plan a migration", icon: .messageSquare, description: "demo-repo · Local", timestamp: "16m ago",
                                       match: "You: move the lighthouse policies")
            b.matchIsUser = true
            b.matchHighlights = Array(14..<24)
            v = CommandPaletteView(content: .results([CommandPaletteGroup("Threads", [a, b])]))
            v.input.text = "lighthouse"
            v.highlightedIndex = 0
        case "browse":
            v = CommandPaletteView(content: .results([CommandPaletteGroup("Directories", [
                CommandPaletteItem("..", icon: .cornerLeftUp), CommandPaletteItem("demo-repo", icon: .folder),
                CommandPaletteItem("git-demo", icon: .folder),
            ])]))
            v.input.placeholder = "Enter project path (e.g. ~/projects/my-app)"
            v.input.text = "~/sandbox/"
            v.startIcon = .folderPlus
            let add = ButtonView("Add", variant: .outline, size: .xs)
            add.accessory = KbdGroupView(keys: ["Enter"])
            v.inputAccessory = add
            v.footerTrailing = ButtonView("Open in Finder", variant: .ghostMuted, size: .xs)
            v.footerActionLabel = nil
            return v
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
