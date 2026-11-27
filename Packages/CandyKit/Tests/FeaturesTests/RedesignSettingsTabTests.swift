import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Redesign: the master switch is the theme picker's setting, the Redesign-only rows live only here, and
/// search finds the tab and each row.
@MainActor @Suite struct RedesignSettingsTabTests {
    private let previous = ThemeRuntime.input

    private func library() -> ThemeLibrary {
        let lib = ThemeLibrary(defaults: UserDefaults(suiteName: "cw.redesign-tab.tests.\(UUID().uuidString)")!, pinned: nil)
        lib.controlsAppearance = false
        return lib
    }

    @Test func masterSwitchAndThemePickerAgreeBothWays() {
        defer { ThemeRuntime.apply(previous) }
        let lib = library()
        lib.setTheme("ocean")
        let page = RedesignSettingsView(context: SettingsPagesFidelityTests.context(), library: lib)
        #expect(!page.master.isOn)
        #expect(page.gated.allSatisfy { $0.inertReason == RedesignSettingsView.offReason })
        // The theme picker turns Redesign on: the switch follows and the rows wake.
        lib.setTheme(ThemeDefinition.dither.id)
        #expect(page.master.isOn)
        // Every row wakes. Gradient is the only background, so Animate background shows and the removed rows are gone.
        #expect(page.gated.allSatisfy { $0.inertReason == nil })
        func hidden(_ id: String) -> Bool? { page.anchor(id)?.isHidden }
        #expect(hidden("redesign-gradient-animate") == false && !page.useIn.isHidden)
        for gone in Self.removedRows { #expect(page.anchor(gone) == nil, "\(gone)") }
        // The switch turns it off, and on again: the picker follows.
        page.master.onChange?(false)
        #expect(!lib.isRedesignOn && !page.master.isOn)
        lib.setTheme("ocean")
        page.master.onChange?(true)
        #expect(lib.isRedesignOn && lib.preference == ThemeDefinition.dither.id && page.master.isOn)
        // Off from the switch brings back the theme it replaced.
        page.master.onChange?(false)
        #expect(!lib.isRedesignOn && lib.preference == "ocean" && !page.master.isOn)
    }

    @Test func theOldStackedDefaultMovesOnceAndAChosenOffStays() throws {
        let suite = "picker-move-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func store(_ stacked: Bool) throws -> ClientSettingsStore {
            defaults.removePersistentDomain(forName: suite)
            let doc = JSONValue.object(["redesignStackedPicker": .bool(stacked), "chatWidth": .string("wide")])
            defaults.set(try JSONEncoder().encode(doc), forKey: ClientSettingsStore.defaultsKey)
            return ClientSettingsStore(defaults: defaults)
        }
        // A stored true is the old default as far as anyone can tell, so it takes the new one, and the rest stays.
        let moved = try store(true)
        #expect(!moved.current.bool("redesignStackedPicker") && moved.current.string("chatWidth") == "wide")
        // Once: turning it back on afterwards survives the next launch.
        moved.update(["redesignStackedPicker": .bool(true)])
        #expect(ClientSettingsStore(defaults: defaults).current.bool("redesignStackedPicker"))
        // A stored false was chosen and stays.
        #expect(!(try store(false)).current.bool("redesignStackedPicker"))
    }

    @Test func storedSliderValuesClampAtTheirLimits() {
        let low = ClientSettings(decoding: .object(["redesignReadingWidth": .number(400), "redesignTextDim": .number(-1),
                                                    "redesignPickerPaneWidth": .number(90)]))
        #expect(low.int("redesignReadingWidth") == 520)
        #expect(low.int("redesignTextDim") == 0)
        #expect(low["redesignPickerPaneWidth"] == .number(120))
        let high = ClientSettings(decoding: .object(["redesignReadingWidth": .number(2000), "redesignTextDim": .number(110),
                                                     "redesignPickerPaneWidth": .number(1000)]))
        #expect(high.int("redesignReadingWidth") == 1100)
        #expect(high.int("redesignTextDim") == 100)
        #expect(high["redesignPickerPaneWidth"] == .number(800))
    }

    @Test func pickerDefaultsForAnUpgrade() {
        // A stored document from a build without the keys: the details layout (stacked off), account card off.
        let old = ClientSettings(decoding: .object(["glassOpacity": .number(60)]))
        #expect(!old.bool("redesignStackedPicker"))
        #expect(!old.bool("redesignPickerAccount"))
        // Every stored background draws Gradient: only "Animate background" reaches the runtime, the same for each.
        let inputs = ["dither", "blur", "gradient", "flower"].map { stored in
            library().runtimeInput(client: ClientSettings(decoding: .object(["redesignBackground": .string(stored),
                                                                              "redesignGradientAnimate": .bool(false)]))).0
        }
        #expect(inputs.allSatisfy { $0 == inputs[0] && !$0.ditherGradientAnimates })
        #expect(library().runtimeInput(client: old).0.ditherGradientAnimates)
    }

    /// A settings file with any old Background loads without error and keeps the stored value, which nothing reads.
    @Test func storedBackgroundsStayInPlace() throws {
        for value in ["dither", "blur", "gradient", "flower"] {
            let defaults = try #require(UserDefaults(suiteName: "cw.background-kept.\(UUID().uuidString)"))
            let saved = #"{"redesignBackground":"\#(value)","redesignGradientAnimate":true,"ditherAccent":"violet"}"#
            defaults.set(Data(saved.utf8), forKey: ClientSettingsStore.defaultsKey)
            let store = ClientSettingsStore(defaults: defaults)
            #expect(!store.readFailed)
            #expect(store.current.string("redesignBackground") == value)
            #expect(store.current.string("ditherAccent") == "violet")
            let stored = try #require(defaults.data(forKey: ClientSettingsStore.defaultsKey).flatMap { try? JSONValue(parsing: $0) })
            #expect(stored.objectValue?["redesignBackground"] == .string(value))
        }
    }

    /// The rows that only served Picture, Blur and Flower (the user, 2026-11-27: "lets just only do the gradient theme").
    static let removedRows = ["redesign-picture", "redesign-background", "redesign-ink", "redesign-dot-size", "redesign-tint",
                              "redesign-thread-flower", "redesign-text-dim", "ignore-reduce-transparency"]

    /// A settings file from before the Collapse composer on scroll row went away still loads, and the key drops.
    @Test func aSavedCollapseOnScrollIsIgnored() throws {
        let defaults = try #require(UserDefaults(suiteName: "cw.collapse-gone.\(UUID().uuidString)"))
        defaults.set(Data(#"{"composerCollapseOnScroll":false,"ditherAccent":"violet"}"#.utf8), forKey: ClientSettingsStore.defaultsKey)
        let store = ClientSettingsStore(defaults: defaults)
        #expect(!store.readFailed)
        #expect(store.current.string("ditherAccent") == "violet")
        #expect(ClientSettings.fields["composerCollapseOnScroll"] == nil)
        #expect(SettingsSearch.item("composer-collapse") == nil)
    }

    @Test func searchFindsTheTabAndEveryRow() {
        let ids = ["redesign", "accent-color", "redesign-gradient-animate", "redesign-project-avatars", "redesign-reading-width",
                   "redesign-inset-panel", "redesign-sidebar-rows", "redesign-stacked-picker", "redesign-picker-account",
                   "redesign-legacy-compact-send"]
        #expect(SettingsSearch.search("redesign").first?.id == "redesign")
        for word in ["background", "dither", "halftone"] {
            #expect(SettingsSearch.search(word).contains { $0.id == "redesign-gradient-animate" }, "\(word)")
        }
        for gone in Self.removedRows { #expect(SettingsSearch.item(gone) == nil, "\(gone)") }
        for id in ids {
            let item = SettingsSearch.item(id)
            #expect(item?.to == .redesign, "\(id)")
            #expect(SettingsSearch.search(item?.title ?? id).contains { $0.id == id }, "\(id)")
            #expect(SettingsSearch.items.filter { $0.id == id }.count == 1, "\(id) once")
            #expect(DitherSettingsSection.home(of: .redesign, anchor: id) == .redesign)
        }
        let page = RedesignSettingsView(context: SettingsPagesFidelityTests.context(), library: library())
        for id in ids { #expect(page.anchor(id) != nil, "\(id) on the tab") }
    }

    /// The page reads top to bottom: the switch, the look, the layout, the sidebar, the model picker, then Legacy.
    @Test func sectionsInOrder() {
        let page = RedesignSettingsView(context: SettingsPagesFidelityTests.context(), library: library())
        page.frame = NSRect(x: 0, y: 0, width: 800, height: page.height(forWidth: 800))
        page.layoutSubtreeIfNeeded()
        let order = ["redesign", "accent-color", "redesign-gradient-animate", "redesign-project-avatars", "redesign-reading-width",
                     "redesign-inset-panel", "redesign-sidebar-rows", "redesign-stacked-picker", "redesign-picker-account",
                     "redesign-legacy-compact-send"]
        let ys = order.compactMap { id in page.anchor(id).map { page.convert($0.bounds, from: $0).minY } }
        #expect(ys.count == order.count)
        #expect(ys == (page.isFlipped ? ys.sorted() : ys.sorted(by: >)))
    }

    @Test func movedRowsLeaveTheirOldPages() {
        defer { ThemeRuntime.apply(previous) }
        var input = previous
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let context = SettingsPagesFidelityTests.context()
        let titles = ["Redesign picture", "Background dim", "Dim behind text", "Accent color", "Ignore Reduce Transparency", "Redesign"]
        func rowTitles(_ view: NSView) -> [String] {
            ((view as? SettingsRowView).map { [$0.title] } ?? []) + view.subviews.flatMap(rowTitles)
        }
        for page in [AppearanceSettingsView(context: context), GeneralSettingsView(context: context), BetaSettingsView(context: context)] as [SettingsPageBase] {
            page.frame = NSRect(x: 0, y: 0, width: 800, height: page.height(forWidth: 800))
            page.layoutSubtreeIfNeeded()
            let found = rowTitles(page)
            for t in titles { #expect(!found.contains(t), "\(t) on \(type(of: page))") }
        }
        #expect(DitherSettingsSection.redesign.slices.map(\.page) == [.redesign])
        #expect(DitherSettingsSection.groups.contains { $0.sections.contains(.redesign) })
    }
}
