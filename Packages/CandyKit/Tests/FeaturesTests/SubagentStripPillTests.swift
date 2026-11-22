import AppKit
import DesignSystem
import Foundation
import Testing
@testable import T3Store
@testable import Features

/// The subagent pill shows one provider icon per live subagent, grouped by the picker's provider order, at most
/// `maxIcons` and "+N", and gives icons to the count before it clips. Set CANDY_PILL_RENDER to a folder for pictures.
@MainActor
struct SubagentStripPillTests {
    static let order = [SubagentStrip.Provider(instanceId: "claude", driver: "claudeAgent", name: "Claude"),
                        SubagentStrip.Provider(instanceId: "codex", driver: "codex", name: "Codex")]

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

    static func pill(_ strip: SubagentStrip, maxWidth: CGFloat = .greatestFiniteMagnitude) -> SubagentStripPillView {
        let pill = SubagentStripPillView()
        pill.configure(strip, providers: order)
        pill.maxWidth = maxWidth
        pill.frame = NSRect(x: 0, y: 0, width: pill.preferredWidth, height: 32)
        pill.layoutSubtreeIfNeeded()
        return pill
    }

    static func shownIcons(_ pill: SubagentStripPillView) -> Int { pill.shownIconCount }

    static func moreText(_ pill: SubagentStripPillView) -> String? {
        pill.subviews.flatMap(\.subviews).compactMap { $0 as? LabelView }.first { !$0.isHidden && $0.text.hasPrefix("+") }?.text
    }

    @Test func fiveClaudeAndOneCodexShowSixIconsInPickerOrder() {
        let pill = Self.pill(Self.strip(["claudeAgent", "codex", "claudeAgent", "claudeAgent", "claudeAgent", "claudeAgent"]))
        #expect(pill.agents.map(\.driver) == ["claudeAgent", "claudeAgent", "claudeAgent", "claudeAgent", "claudeAgent", "codex"])
        #expect(pill.agents.map(\.key) == ["s0", "s2", "s3", "s4", "s5", "s1"])
        #expect(Self.shownIcons(pill) == 6)
        #expect(Self.moreText(pill) == nil)
    }

    @Test func nineShowEightAndPlusOne() {
        let pill = Self.pill(Self.strip(Array(repeating: "claudeAgent", count: 9)))
        #expect(Self.shownIcons(pill) == 8)
        #expect(Self.moreText(pill) == "+1")
    }

    @Test func narrowWidthDropsTheWordsThenMovesIconsIntoTheCount() {
        let measure: (Int) -> CGFloat = { _ in 14 }
        let wide = SubagentStripPillView.fit(count: 6, waiting: true, maxWidth: 1000, wordsWidth: 62, moreWidth: measure)
        #expect(wide == .init(words: true, shown: 6, more: 0))
        let full = SubagentStripPillView.width(wide, wordsWidth: 62, moreWidth: measure)
        let noWords = SubagentStripPillView.fit(count: 6, waiting: true, maxWidth: full - 1, wordsWidth: 62, moreWidth: measure)
        #expect(noWords == .init(words: false, shown: 6, more: 0))
        let tight = SubagentStripPillView.fit(count: 6, waiting: true, maxWidth: 90, wordsWidth: 62, moreWidth: measure)
        #expect(!tight.words && tight.shown < 6 && tight.shown + tight.more == 6)
        #expect(SubagentStripPillView.width(tight, wordsWidth: 62, moreWidth: measure) <= 90)
        // The compact form with one subagent keeps the spinner and its icon.
        #expect(SubagentStripPillView.fit(count: 1, waiting: true, maxWidth: 10, wordsWidth: 62, moreWidth: measure) == .init(words: false, shown: 1, more: 0))
        // In a real pill the label measures itself.
        let pill = Self.pill(Self.strip(Array(repeating: "claudeAgent", count: 6)), maxWidth: 100)
        #expect(pill.preferredWidth <= 100)
        #expect(Self.shownIcons(pill) < 6)
        #expect(Self.moreText(pill) == "+\(6 - Self.shownIcons(pill))")
    }

    @Test func aFinishedSubagentLeavesItsIcon() {
        let drivers = ["claudeAgent", "codex", "claudeAgent"]
        let pill = Self.pill(Self.strip(drivers))
        let before = pill.preferredWidth
        var next = Self.strip(drivers)
        next.rows = next.rows.map { $0.key == "s1" ? Self.row("s1", "codex", finished: true) : $0 }
        next.activeCount = 2
        pill.configure(next, providers: Self.order)
        pill.frame.size.width = pill.preferredWidth
        pill.layoutSubtreeIfNeeded()
        #expect(pill.agents.map(\.key) == ["s0", "s2"])
        #expect(Self.shownIcons(pill) == 2)
        #expect(before - pill.preferredWidth == SubagentStripPillView.icon + SubagentStripPillView.iconGap)
    }

    @Test func tooltipAndAccessibilitySayItInWords() {
        let pill = Self.pill(Self.strip(["claudeAgent", "codex", "claudeAgent", "claudeAgent", "claudeAgent", "claudeAgent"]))
        let row = pill.subviews.first { $0.accessibilityLabel()?.isEmpty == false }
        #expect(row?.accessibilityLabel() == "Waiting on 5 Claude and 1 Codex subagents. Show subagents.")
        #expect(row?.currentTooltip == "Waiting on 5 Claude and 1 Codex subagents")
        let running = Self.pill(Self.strip(["codex"], waiting: false))
        #expect(running.subviews.first { $0.accessibilityLabel()?.isEmpty == false }?.accessibilityLabel() == "1 Codex subagent running. Show subagents.")
    }

    @Test func unknownProviderGetsTheAgentIcon() {
        let pill = Self.pill(Self.strip(["mystery"]))
        let icon = pill.subviews.flatMap(\.subviews).compactMap { $0 as? IconView }.first { $0.frame.minX >= 24 && $0.frame.width == 12 && $0.name == .bot }
        #expect(icon != nil)
    }

    /// Pictures for review: 1, 3, 6 and 12 subagents, wide and compact, dark and light, spaced and stacked.
    @Test func renderPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["CANDY_PILL_RENDER"] else { return }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous); SubagentStripPillView.iconGap = 4 }
        let sets: [(String, [String])] = [
            ("1", ["claudeAgent"]),
            ("3", ["claudeAgent", "codex", "claudeAgent"]),
            ("6", ["claudeAgent", "codex", "claudeAgent", "claudeAgent", "claudeAgent", "claudeAgent"]),
            ("12", ["claudeAgent", "codex", "claudeAgent", "cursor", "claudeAgent", "codex", "claudeAgent", "mystery", "claudeAgent", "claudeAgent", "codex", "claudeAgent"]),
        ]
        for redesign in [true, false] {
            var input = previous
            input.ditherLight = redesign; input.ditherDark = redesign
            ThemeRuntime.apply(input)
            for dark in [true, false] {
                for (variant, gap) in [("spaced", CGFloat(4)), ("stacked", CGFloat(-3))] {
                    SubagentStripPillView.iconGap = gap
                    for (name, drivers) in sets {
                        for (form, max) in [("wide", CGFloat.greatestFiniteMagnitude), ("compact", CGFloat(80))] {
                            let pill = SubagentStripPillView()
                            pill.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            pill.configure(Self.strip(drivers), providers: Self.order)
                            pill.maxWidth = max
                            pill.frame = NSRect(x: 0, y: 0, width: pill.preferredWidth, height: 32)
                            let host = NSView(frame: NSRect(x: 0, y: 0, width: pill.frame.width + 16, height: 48))
                            host.appearance = pill.appearance
                            host.wantsLayer = true
                            host.layer?.backgroundColor = (dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
                            pill.frame.origin = NSPoint(x: 8, y: 8)
                            host.addSubview(pill)
                            host.layoutSubtreeIfNeeded()
                            let rep = Snapshot.image(of: host, size: host.frame.size, scale: 2, dark: dark)
                            let file = "\(redesign ? "redesign" : "default")-\(dark ? "dark" : "light")-\(variant)-\(name)-\(form).png"
                            try Snapshot.writePNG(rep, to: dir.appendingPathComponent(file))
                        }
                    }
                }
            }
        }
    }
}
