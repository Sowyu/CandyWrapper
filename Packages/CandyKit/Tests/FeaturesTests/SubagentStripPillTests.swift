import AppKit
import DesignSystem
import Foundation
import Testing
@testable import T3Store
@testable import Features

/// The subagent pill shows each live provider's icon and subagent count in the picker's provider order, and folds
/// groups from the end into "+N" before it clips. Set CANDY_PILL_RENDER to a folder for pictures.
@MainActor
struct SubagentStripPillTests {
    static let order = [SubagentStrip.Provider(instanceId: "claude", driver: "claudeAgent", name: "Claude"),
                        SubagentStrip.Provider(instanceId: "codex", driver: "codex", name: "Codex"),
                        SubagentStrip.Provider(instanceId: "cursor", driver: "cursor", name: "Cursor")]

    static func row(_ key: String, _ driver: String, finished: Bool = false) -> SubagentStrip.Row {
        let instance = driver == "claudeAgent" ? "claude" : driver
        return SubagentStrip.Row(id: key, key: key, number: 1, childThreadId: nil, title: "Task \(key)",
                                 status: finished ? .done : .running, driver: driver, providerInstanceId: instance,
                                 model: nil, canStop: false)
    }

    /// `drivers` in start order; rows list newest first, like `SubagentStrip.make`.
    static func strip(_ drivers: [String], waiting: Bool = true) -> SubagentStrip {
        var s = SubagentStrip()
        s.rows = drivers.enumerated().map { row("s\($0.offset)", $0.element) }.reversed()
        s.activeCount = drivers.count
        s.parentWaiting = waiting
        return s
    }

    static func drivers(_ claude: Int, _ codex: Int, cursor: Int = 0) -> [String] {
        // Interleaved starts, so the grouping has to sort them.
        var out = Array(repeating: "claudeAgent", count: claude)
        for i in 0..<codex { out.insert("codex", at: min(out.count, 1 + 2 * i)) }
        return out + Array(repeating: "cursor", count: cursor)
    }

    static func pill(_ strip: SubagentStrip, maxWidth: CGFloat = .greatestFiniteMagnitude) -> SubagentStripPillView {
        let pill = SubagentStripPillView()
        pill.configure(strip, providers: order)
        pill.maxWidth = maxWidth
        pill.frame = NSRect(x: 0, y: 0, width: pill.preferredWidth, height: 32)
        pill.layoutSubtreeIfNeeded()
        return pill
    }

    static func relayout(_ pill: SubagentStripPillView) {
        pill.frame.size.width = pill.preferredWidth
        pill.layoutSubtreeIfNeeded()
    }

    @Test func fiveClaudeAndOneCodexShowTwoGroupsInPickerOrder() {
        let pill = Self.pill(Self.strip(Self.drivers(5, 1)))
        #expect(pill.shownSlots == ["claudeAgent 5", "codex 1"])
        let twelve = Self.pill(Self.strip(Self.drivers(11, 1)))
        #expect(twelve.shownSlots == ["claudeAgent 11", "codex 1"])
        // One subagent still shows its number.
        #expect(Self.pill(Self.strip(["codex"])).shownSlots == ["codex 1"])
    }

    @Test func countsChangeInPlaceAndAGroupAtZeroLeaves() {
        let drivers = ["claudeAgent", "codex", "claudeAgent", "claudeAgent"]
        let pill = Self.pill(Self.strip(drivers))
        let width = pill.preferredWidth
        var next = Self.strip(drivers)
        next.rows = next.rows.map { $0.key == "s2" ? Self.row("s2", "claudeAgent", finished: true) : $0 }
        next.activeCount = 3
        pill.configure(next, providers: Self.order)
        Self.relayout(pill)
        #expect(pill.shownSlots == ["claudeAgent 2", "codex 1"])
        // Tabular digits: 3 to 2 keeps the width.
        #expect(pill.preferredWidth == width)
        next.rows = next.rows.map { $0.key == "s1" ? Self.row("s1", "codex", finished: true) : $0 }
        next.activeCount = 2
        pill.configure(next, providers: Self.order)
        Self.relayout(pill)
        #expect(pill.shownSlots == ["claudeAgent 2"])
        #expect(pill.preferredWidth < width)
    }

    @Test func narrowWidthDropsTheWordsThenFoldsGroupsIntoTheCount() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 7 }
        let counts = [5, 1, 2]
        let wide = SubagentStripPillView.fit(counts: counts, waiting: true, maxWidth: 1000, wordsWidth: 62, textWidth: measure)
        #expect(wide == .init(words: true, shown: 3, more: 0))
        let full = SubagentStripPillView.width(wide, counts: counts, wordsWidth: 62, textWidth: measure)
        let noWords = SubagentStripPillView.fit(counts: counts, waiting: true, maxWidth: full - 1, wordsWidth: 62, textWidth: measure)
        #expect(noWords == .init(words: false, shown: 3, more: 0))
        let two = SubagentStripPillView.fit(counts: counts, waiting: true, maxWidth: 135, wordsWidth: 62, textWidth: measure)
        #expect(two == .init(words: false, shown: 2, more: 2))
        #expect(SubagentStripPillView.width(two, counts: counts, wordsWidth: 62, textWidth: measure) <= 135)
        // The smallest form keeps one group.
        #expect(SubagentStripPillView.fit(counts: [1], waiting: true, maxWidth: 10, wordsWidth: 62, textWidth: measure) == .init(words: false, shown: 1, more: 0))
        let pill = Self.pill(Self.strip(Self.drivers(5, 1, cursor: 2)), maxWidth: 110)
        #expect(pill.preferredWidth <= 110)
        #expect(pill.shownSlots == ["claudeAgent 5", "+3"])
    }

    @Test func tooltipAndAccessibilitySayItInWords() {
        let pill = Self.pill(Self.strip(Self.drivers(11, 1)))
        let row = pill.subviews.first { $0.accessibilityLabel()?.isEmpty == false }
        #expect(row?.accessibilityLabel() == "Waiting on 11 Claude and 1 Codex subagents. Show subagents.")
        #expect(row?.currentTooltip == "Waiting on 11 Claude and 1 Codex subagents")
        let running = Self.pill(Self.strip(["codex"], waiting: false))
        #expect(running.subviews.first { $0.accessibilityLabel()?.isEmpty == false }?.accessibilityLabel() == "1 Codex subagent running. Show subagents.")
    }

    @Test func unknownProviderGetsTheAgentIconWithItsCount() {
        let pill = Self.pill(Self.strip(["mystery", "mystery"]))
        #expect(pill.shownSlots == ["mystery 2"])
        let icon = pill.subviews.flatMap(\.subviews).compactMap { $0 as? IconView }.first { $0.name == .bot && !$0.isHidden }
        #expect(icon != nil)
    }

    /// Pictures for review: 1, 3, 6, 12 and three providers, wide and compact, dark and light.
    @Test func renderPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["CANDY_PILL_RENDER"] else { return }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let sets: [(String, [String])] = [("1", Self.drivers(1, 0)), ("3", Self.drivers(2, 1)), ("6", Self.drivers(5, 1)),
                                          ("12", Self.drivers(11, 1)), ("three", Self.drivers(4, 2, cursor: 1) + ["mystery"])]
        for redesign in [true, false] {
            var input = previous
            input.ditherLight = redesign; input.ditherDark = redesign
            ThemeRuntime.apply(input)
            for dark in [true, false] {
                for (name, drivers) in sets {
                    for (form, max) in [("wide", CGFloat.greatestFiniteMagnitude), ("compact", CGFloat(90))] {
                        let pill = SubagentStripPillView()
                        pill.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        pill.configure(Self.strip(drivers), providers: Self.order)
                        pill.maxWidth = max
                        pill.frame = NSRect(x: 8, y: 8, width: pill.preferredWidth, height: 32)
                        let host = NSView(frame: NSRect(x: 0, y: 0, width: pill.frame.width + 16, height: 48))
                        host.appearance = pill.appearance
                        host.wantsLayer = true
                        host.layer?.backgroundColor = (dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
                        host.addSubview(pill)
                        host.layoutSubtreeIfNeeded()
                        let rep = Snapshot.image(of: host, size: host.frame.size, scale: 2, dark: dark)
                        let file = "count-\(redesign ? "redesign" : "default")-\(dark ? "dark" : "light")-\(name)-\(form).png"
                        try Snapshot.writePNG(rep, to: dir.appendingPathComponent(file))
                    }
                }
            }
        }
    }
}
