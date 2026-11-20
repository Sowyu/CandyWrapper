import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign's docked model picker as one 335pt column (the user's layout, 2026-11-20): provider tabs, search, the list,
/// the Reasoning section with its levels in one segmented line, and the footer.
@MainActor @Suite struct RedesignPickerLayoutTests {
    static func withRedesign(_ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        try body()
    }

    static func catalog(models n: Int) -> ProviderCatalog {
        let claude = ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude",
                                    models: (1...n).map { ServerProviderModel(slug: "m\($0)", name: "Claude Model \($0)") })
        let codex = ServerProvider(instanceId: "codex", driver: "codex", displayName: "Codex",
                                   models: [ServerProviderModel(slug: "gpt", name: "GPT")])
        return ProviderCatalog([claude, codex])
    }

    static let levels = ProviderOptionDescriptor(
        id: "effort", label: "Reasoning", type: .select,
        options: [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra High"), ("max", "Max")]
            .map { ProviderOptionChoice(id: $0.0, label: $0.1, isDefault: $0.0 == "medium") },
        currentValue: .string("high"))
    static let footerOptions = [ProviderOptionDescriptor(id: "fastMode", label: "Fast Mode", type: .boolean, currentValue: .bool(false)),
                                ProviderOptionDescriptor(id: "ultracode", label: "Ultracode", type: .boolean, currentValue: .bool(false))]

    static func dock(models n: Int, extra: [ProviderOptionDescriptor] = []) -> DockedModelPickerView {
        let picker = ModelPickerView(catalog: catalog(models: n), favorites: [], active: "claudeAgent", activeModel: "m1")
        picker.jumpLabel = { $0 < 4 ? "⌘\($0 + 1)" : nil }
        let dock = DockedModelPickerView(picker: picker)
        dock.column.update(descriptors: [levels] + extra, ultrathink: false, locked: false, model: "Opus 5.5")
        dock.footer.update(descriptors: footerOptions, runtimeMode: .fullAccess)
        return dock
    }

    private static func lay(_ dock: DockedModelPickerView, height: CGFloat? = nil) {
        let size = dock.naturalSize
        dock.frame = NSRect(x: 0, y: 0, width: size.width, height: height ?? size.height)
        dock.layoutSubtreeIfNeeded()
    }

    @Test(arguments: [1, 4, 12])
    func oneColumnAtItsWidth(_ models: Int) throws {
        try Self.withRedesign {
            let dock = Self.dock(models: models)
            #expect(dock.stacked)
            Self.lay(dock)
            let picker = dock.picker, w = dock.bounds.width
            #expect(w == 335)
            // Top to bottom: the list part, the Reasoning section, the footer, nothing beside each other.
            #expect(picker.frame.minY == 0 && picker.frame.width == w)
            #expect(dock.column.frame.minY == picker.frame.maxY && dock.column.frame.width == w)
            #expect(dock.footer.frame.minY == dock.column.frame.maxY && dock.footer.frame.maxY == dock.bounds.height)
            // The tabs sit in a row at the top, left to right.
            let tabs = picker.subviews.compactMap { $0 as? RailButtonView }.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
            #expect(tabs.count == 3 && tabs.allSatisfy { $0.frame.minY == 4 })
            // Every model has a full-width row inside the list, and they all show at their natural height.
            let modelRows = picker.rowViews.filter { if case .model = $0.row { true } else { false } }
            #expect(modelRows.count == models)
            #expect(picker.rowViews.allSatisfy { $0.frame.width == w - 12 && $0.frame.height == 32 })
            #expect(picker.search.frame.minY > tabs[0].frame.maxY && picker.rowViews[0].frame.minY >= 0)
            // The five levels share one segmented line across the width.
            #expect(dock.column.levelLines.count == 1)
            let line = try #require(dock.column.levelLines.first)
            #expect(line.frame.width == w - 16 && line.segments.count == 5)
            #expect(line.segments.last!.frame.maxX == line.bounds.width - 2)
            // The footer fits on one line: Standard and Fast, Ultracode, then the access chip at the end.
            let footer = dock.footer.items
            #expect(footer.count == 4 && Set(footer.map { $0.superview === dock.footer ? $0.frame.minY : $0.superview!.frame.minY }).count == 1)
            #expect(dock.footer.permissions!.frame.maxX == w - 8)
        }
    }

    @Test func heightFollowsContentAndTheListScrollsInAShortWindow() throws {
        try Self.withRedesign {
            let heights = [1, 4, 12].map { Self.dock(models: $0).naturalSize.height }
            #expect(heights[0] < heights[1] && heights[1] < heights[2])
            let dock = Self.dock(models: 12)
            let natural = dock.naturalSize.height
            Self.lay(dock, height: natural - 150)
            // The Reasoning section and footer keep their heights; the list gives up the space and scrolls.
            #expect(dock.column.frame.height == dock.column.stackedHeight(width: 335))
            #expect(dock.footer.frame.maxY == dock.bounds.height)
            let list = dock.picker.rowViews.last!
            #expect(list.frame.maxY > list.superview!.bounds.height, "the last rows sit below the fold")
        }
    }

    @Test func moreLevelsWrapAndOptionsFollowAsRows() throws {
        try Self.withRedesign {
            let many = ProviderOptionDescriptor(id: "effort", label: "Reasoning", type: .select,
                                                options: (1...9).map { ProviderOptionChoice(id: "l\($0)", label: "Level \($0)") },
                                                currentValue: .string("l1"))
            let context = ProviderOptionDescriptor(id: "contextWindow", label: "Context window", type: .select,
                                                   options: [ProviderOptionChoice(id: "200k", label: "200K"), ProviderOptionChoice(id: "1m", label: "1M")],
                                                   currentValue: .string("200k"))
            let dock = Self.dock(models: 2)
            dock.column.update(descriptors: [many, context], ultrathink: false, locked: false, model: "Opus 5.5")
            Self.lay(dock)
            #expect(dock.column.levelLines.count >= 2, "levels past the width wrap to another line")
            #expect(dock.column.levelLines.flatMap(\.segments).count == 9)
            let menu = try #require(dock.column.rows.last)
            #expect(!menu.isHidden && menu.frame.minY > dock.column.levelLines.last!.frame.maxY && menu.frame.width == 335 - 12)
        }
    }

    @Test func tabWalksTheSectionsAndArrowsStayInThem() throws {
        try Self.withRedesign {
            let dock = Self.dock(models: 4)
            Self.lay(dock)
            #expect(dock.section == .search)
            dock.tab(backward: false)
            #expect(dock.section == .list && dock.picker.highlightedRow == 0, "the list highlights the selected model")
            #expect(dock.handleKey(.down) && dock.picker.highlightedRow == 1)
            dock.tab(backward: false)
            // The levels: the chosen one has focus, Left and Right move across without wrapping.
            #expect(dock.section == .reasoning && dock.column.focusIndex == 2)
            #expect(dock.column.segments[2]?.focused == true)
            #expect(dock.handleKey(.right) && dock.column.focusIndex == 3)
            #expect(dock.handleKey(.right) && dock.handleKey(.right) && dock.column.focusIndex == 4)
            #expect(dock.handleKey(.left) && dock.column.focusIndex == 3)
            dock.tab(backward: false)
            #expect(dock.section == .footer && dock.footer.focusIndex == 0 && dock.column.focusIndex == nil)
            #expect(dock.handleKey(.right) && dock.footer.focusIndex == 1)
            dock.tab(backward: false)
            #expect(dock.section == .search)
            // Shift-Tab from the search goes up to the tabs, which run across.
            dock.tab(backward: true)
            #expect(dock.section == .tabs)
            #expect(dock.handleKey(.right) && dock.section == .tabs)
            #expect(dock.handleKey(.down) && dock.section == .search)
            // Typing anywhere goes to the search.
            dock.tab(backward: true); dock.tab(backward: true)
            #expect(dock.section == .footer)
            #expect(!dock.handleKey(.character("a")) && dock.section == .search)
            // The permissions shortcut lands on the access chip.
            dock.focusPermissions()
            #expect(dock.section == .footer && dock.footer.focusIndex == dock.footer.items.count - 1)
            // A model pick moves to the levels; Escape is left to the host, which closes the picker.
            #expect(dock.focusEffort(levelsOnly: true) && dock.section == .reasoning)
            #expect(!dock.handleKey(.escape))
        }
    }

    @Test func levelsActAndReturnPicks() throws {
        try Self.withRedesign {
            let dock = Self.dock(models: 4)
            Self.lay(dock)
            var picked: String?
            dock.column.onSelect = { _, value in picked = value }
            dock.column.segments[0]?.action?()
            #expect(picked == "low" && dock.column.focusIndex == 0)
            #expect(dock.column.segments[0]?.focused == false, "a click focuses without the ring")
            dock.focus(.reasoning)
            // Focus starts on the chosen level (High), and Right moves to Extra High.
            #expect(dock.handleKey(.right) && dock.handleKey(.enter) && picked == "xhigh")
            var fast: Bool?
            dock.footer.onBoolean = { _, on in fast = on }
            dock.focus(.footer)
            #expect(dock.handleKey(.right) && dock.handleKey(.space) && fast == true)
        }
    }
}

/// Hover in the stacked picker follows the real pointer and never sticks.
@MainActor @Suite struct RedesignPickerHoverTests {
    private func host(_ dock: DockedModelPickerView) -> NSWindow {
        let size = dock.naturalSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let content = DSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        dock.frame = content.bounds
        content.addSubview(dock)
        dock.layoutSubtreeIfNeeded()
        return window
    }

    private func pixels(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.tiffRepresentation)
    }

    private func point(of row: ModelRowView) -> NSPoint { row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil) }

    @Test func rowHoverClearsOnExitScrollAndLostKeyWindow() throws {
        try RedesignPickerLayoutTests.withRedesign {
            let dock = RedesignPickerLayoutTests.dock(models: 12)
            let window = host(dock)
            defer { window.close() }
            let picker = dock.picker
            let resting = try pixels(picker)
            picker.syncPointerHighlight(at: point(of: picker.rowViews[2]))
            #expect(picker.highlightedRow == 2)
            // Off the rows (the search), the hover goes.
            picker.syncPointerHighlight(at: picker.search.convert(NSPoint(x: 4, y: 4), to: nil))
            #expect(picker.highlightedRow == nil)
            #expect(try pixels(picker) == resting, "an exit leaves the rows as they were")
            // A lost key window clears a pointer hover.
            picker.syncPointerHighlight(at: point(of: picker.rowViews[3]))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            #expect(picker.highlightedRow == nil)
            // The list scrolled under a still pointer: the row now under it takes the hover.
            picker.frame.size.height = 200
            picker.layoutSubtreeIfNeeded()
            let p = point(of: picker.rowViews[1])
            picker.syncPointerHighlight(at: p)
            #expect(picker.highlightedRow == 1)
            let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -64, wheel2: 0, wheel3: 0))
            picker.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
            picker.layoutSubtreeIfNeeded()
            picker.syncPointerHighlight(at: p)
            let under = picker.rowViews.firstIndex { $0.frame.contains($0.superview!.convert(p, from: nil)) }
            #expect(picker.highlightedRow == under && under != 1, "highlight \(String(describing: picker.highlightedRow)) under \(String(describing: under)) frames \(picker.rowViews.prefix(5).map(\.frame.minY)) list \(String(describing: picker.rowViews.first?.superview?.frame))")
            // A keyboard highlight survives the pointer leaving and the window losing key.
            picker.syncPointerHighlight(at: .zero)
            #expect(picker.handleKey(.down) && picker.highlightedRow == 0)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            picker.syncPointerHighlight(at: picker.search.convert(NSPoint(x: 4, y: 4), to: nil))
            #expect(picker.highlightedRow == 0)
        }
    }

    @Test func segmentsAndTabsReturnToRestAfterHover() throws {
        try RedesignPickerLayoutTests.withRedesign {
            let dock = RedesignPickerLayoutTests.dock(models: 4)
            let window = host(dock)
            defer { window.close() }
            let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            let controls: [ControlView] = Array(dock.column.segments.values) + dock.footer.items
                + dock.picker.subviews.compactMap { $0 as? RailButtonView }
            for control in controls {
                let parent = try #require(control.superview)
                let resting = try pixels(parent)
                control.mouseEntered(with: enter)
                #expect(control.state.hovered)
                control.mouseExited(with: exit)
                #expect(!control.state.hovered)
                #expect(try pixels(parent) == resting, "\(type(of: control)) is back at rest")
            }
            // The keyboard focus ring shows only after keyboard input: a pick from the pointer focuses without it.
            dock.focusEffort(levelsOnly: true)
            #expect(!dock.column.segments.values.contains { $0.focused })
            dock.footer.focus(permissions: true)
            #expect(!dock.footer.items.contains { ($0 as? ComposerPermissionsTriggerView)?.focused == true })
        }
    }
}

/// Writes the stacked picker to `CW_EXPORT_DIR` for eyeballing. An export tool, not a test: runs only with CW_EXPORT=1.
@MainActor @Suite struct RedesignPickerExport {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CW_EXPORT"] != nil, "export tool, set CW_EXPORT=1"))
    func stacked() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CW_EXPORT_DIR"] ?? NSTemporaryDirectory())
        try RedesignPickerLayoutTests.withRedesign {
            for n in [1, 4, 12] {
                let popup = PickerPopupView(RedesignPickerLayoutTests.dock(models: n))
                for theme in ["light", "dark"] {
                    let size = CGSize(width: popup.popupSize.width + 16, height: popup.popupSize.height + 16)
                    let image = PickersFidelityTests.render(popup, size: size, backdrop: .gray, dark: theme == "dark",
                                                            contentFrame: CGRect(origin: CGPoint(x: 8, y: 8), size: popup.popupSize))
                    try Snapshot.writePNG(image, to: dir.appendingPathComponent("stacked-\(n).\(theme).png"))
                }
            }
        }
    }
}
