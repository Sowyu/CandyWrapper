import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Redesign > Reading width, and the rows' fade above the composer group. Synchronous on the main actor, so
/// the global theme and the shared settings are set and put back between other suites' tests.
@MainActor @Suite struct ReadingWidthTests {
    private func withRedesign(dark: Bool = true, _ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        let saved = ClientSettingsStore.shared.current
        defer {
            ThemeRuntime.apply(previous)
            ClientSettingsStore.shared.update(["redesignReadingWidth": saved["redesignReadingWidth"], "chatWidth": saved["chatWidth"]])
        }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        input.ditherGradientAnimates = false
        ThemeRuntime.apply(input)
        ClientSettingsStore.shared.update(["redesignReadingWidth": .number(864), "chatWidth": .string("comfortable")])
        try body()
    }

    private func thread(width: CGFloat = 1240, dark: Bool = true) throws -> ThreadPanelView {
        let panel = ComposerFidelityTests.panel(width: width, dark: dark)
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    private func setReading(_ width: CGFloat, _ panel: ThreadPanelView) {
        ClientSettingsStore.shared.update(["redesignReadingWidth": .number(Double(width))])
        panel.timeline.applyReadingWidth()
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
    }

    @Test func theDefaultKeepsTodaysColumn() throws {
        #expect(ThreadChatWidth.readingDefault == 864)
        #expect(ClientSettings.fields["redesignReadingWidth"]?.defaultValue == .number(864))
        // A settings file saved before the setting loads at the default.
        #expect(ClientSettings(decoding: .object(["chatWidth": .string("comfortable")])).int("redesignReadingWidth") == 864)
        // The default themes never read it.
        #expect(ThreadChatWidth.maximum("comfortable", dither: false, reading: 600) == 736)
        try withRedesign {
            let panel = try thread()
            #expect(panel.composer.frame.width == 864)
            #expect(panel.composer.frame.minX == ((1240 - 864) / 2).rounded())
            #expect(panel.timeline.laneFrame.width == 864)
        }
    }

    @Test func aSmallerWidthMovesEverythingOnTheColumn() throws {
        try withRedesign {
            let panel = try thread()
            let composer = panel.composer.frame, lane = panel.timeline.laneFrame
            setReading(620, panel)
            #expect(panel.composer.frame.width == 620)
            #expect(panel.timeline.laneFrame.width == 620)
            // Both edges move in by the same amount, centred as before.
            #expect(panel.composer.frame.minX - composer.minX == 122)
            #expect(TL.snap(panel.timeline.laneFrame.x) - TL.snap(lane.x) == 122)
            // The pill row under the composer sits inside the new column.
            #expect(panel.composer.contextWindowMeter.isHidden || panel.composer.contextWindowMeter.frame.maxX <= panel.composer.frame.maxX)
        }
    }

    @Test func theRowsTrailTheSliderButTheComposerDoesNot() throws {
        try withRedesign {
            let panel = try thread()
            ClientSettingsStore.shared.update(["redesignReadingWidth": .number(700)])
            panel.layoutSubtreeIfNeeded()
            #expect(panel.composer.frame.width == 700)
            #expect(panel.timeline.laneFrame.width == 864)
            panel.timeline.applyReadingWidth()
            panel.layoutSubtreeIfNeeded()
            #expect(panel.timeline.laneFrame.width == 700)
        }
    }

    @Test func aNarrowWindowClamps() throws {
        try withRedesign {
            let panel = try thread(width: 700)
            setReading(900, panel)
            // 48pt each side, as at any width.
            #expect(abs(panel.composer.frame.width - (700 - 96)) < 0.5)
            #expect(abs(panel.timeline.laneFrame.width - (700 - 96)) < 0.5)
        }
    }

    @Test func wideAndFullIgnoreTheSlider() {
        #expect(ThreadChatWidth.maximum("wide", dither: true, reading: 600) == 1152)
        #expect(ThreadChatWidth.maximum("full", dither: true, reading: 600) > 10000)
        #expect(ThreadChatWidth.maximum("comfortable", dither: true, reading: 600) == 600)
        #expect(RedesignSettingsView.readingWidthReason("wide") == "Chat width is set to Wide in Appearance.")
        #expect(RedesignSettingsView.readingWidthReason("full") == "Chat width is set to Full in Appearance.")
        #expect(RedesignSettingsView.readingWidthReason("comfortable") == nil)
    }

    @Test func theRowAtTheTopStaysPut() throws {
        try withRedesign {
            let panel = try thread(width: 1240)
            panel.timeline.scroll(toFraction: 0.5)
            panel.layoutSubtreeIfNeeded()
            let before = try #require(panel.timeline.captureAnchor())
            setReading(560, panel)
            let after = try #require(panel.timeline.captureAnchor())
            #expect(after.id == before.id)
            #expect(abs(after.offset - before.offset) <= 1)
        }
    }

    @Test func charactersPerLineFollowTheWidth() {
        let at864 = RedesignSettingsView.charactersPerLine(864), at520 = RedesignSettingsView.charactersPerLine(520)
        #expect((100...140).contains(at864), "\(at864)")
        #expect(at520 < at864 && at520 % 5 == 0)
    }

    @Test func theRowWritesEveryStepAndRestsUnderWideAndFull() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        let lib = ThemeLibrary(defaults: UserDefaults(suiteName: "cw.reading-width.tests.\(UUID().uuidString)")!, pinned: nil)
        lib.controlsAppearance = false
        lib.setTheme(ThemeDefinition.dither.id)
        let context = SettingsPagesFidelityTests.context()
        var writes: [[String: JSONValue]] = []
        context.writeClient = { patch in writes.append(patch); _ = context.client.apply(patch) }
        let page = RedesignSettingsView(context: context, library: lib)
        let row = try #require(page.anchor("redesign-reading-width") as? SettingsRowView)
        #expect(row.inertReason == nil)
        func slider(_ view: NSView) -> SettingsSliderControl? { view as? SettingsSliderControl ?? view.subviews.lazy.compactMap(slider).first }
        let control = try #require(slider(row))
        #expect(control.value == 864 && control.output.text == "864 pt")
        // A drag sends each step.
        control.slider.onChange?(700); control.slider.onChange?(640)
        #expect(writes.map { $0["redesignReadingWidth"] } == [.number(700), .number(640)])
        page.refresh()
        #expect(control.output.text == "640 pt")
        _ = context.client.apply(["chatWidth": .string("wide")])
        page.refresh()
        #expect(row.inertReason == "Chat width is set to Wide in Appearance.")
        _ = context.client.apply(["chatWidth": .string("comfortable")])
        page.refresh()
        #expect(row.inertReason == nil)
    }

    @Test func searchFindsTheRow() {
        for word in ["width", "column", "line length", "reading", "narrow", "wide"] {
            #expect(SettingsSearch.search(word).contains { $0.id == "redesign-reading-width" }, "\(word)")
        }
        #expect(SettingsSearch.item("redesign-reading-width")?.to == .redesign)
    }
}
