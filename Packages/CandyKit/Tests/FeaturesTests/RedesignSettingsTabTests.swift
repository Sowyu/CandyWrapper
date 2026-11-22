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
        // Animate background waits for Flower; the default Background is Picture. Dim behind text works in all three.
        #expect(page.gated.allSatisfy { [nil, RedesignSettingsView.animateReason].contains($0.inertReason) })
        #expect(page.anchor("redesign-text-dim").flatMap { $0 as? SettingsRowView }?.inertReason == nil)
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

    @Test func pickerDefaultsForAnUpgrade() {
        // A stored document from a build without the keys: the details layout (stacked off), account card off.
        let old = ClientSettings(decoding: .object(["glassOpacity": .number(60)]))
        #expect(!old.bool("redesignStackedPicker"))
        #expect(!old.bool("redesignPickerAccount"))
        // Background is Dither, as 1.15.1 drew it, and Blur reaches the theme runtime.
        #expect(old.string("redesignBackground") == "dither")
        #expect(!library().runtimeInput(client: old).0.ditherBlur)
        let blur = ClientSettings(decoding: .object(["redesignBackground": .string("blur")]))
        #expect(library().runtimeInput(client: blur).0.ditherBlur)
        // 1.16.0's Gradient still loads, and shows Flower, whose field it became.
        let gradient = ClientSettings(decoding: .object(["redesignBackground": .string("gradient")]))
        #expect(gradient.string("redesignBackground") == "gradient")
        #expect(library().runtimeInput(client: gradient).0.ditherFlower)
        #expect(!library().runtimeInput(client: gradient).0.ditherBlur)
        // Flower reaches the runtime alone; "Animate background" keeps Gradient's stored key.
        let flower = ClientSettings(decoding: .object(["redesignBackground": .string("flower"), "redesignGradientAnimate": .bool(false)]))
        #expect(flower.string("redesignBackground") == "flower")
        let flowerInput = library().runtimeInput(client: flower).0
        #expect(flowerInput.ditherFlower && !flowerInput.ditherBlur)
        #expect(!flowerInput.ditherGradientAnimates)
    }

    /// A 1.16.0 settings file with Background set to Gradient loads without error, as Flower, and is saved so once.
    @Test func gradientFromSixteenLoadsAsFlower() throws {
        let defaults = try #require(UserDefaults(suiteName: "cw.gradient-move.\(UUID().uuidString)"))
        let saved = #"{"redesignBackground":"gradient","redesignGradientAnimate":true,"ditherAccent":"violet"}"#
        defaults.set(Data(saved.utf8), forKey: ClientSettingsStore.defaultsKey)
        let store = ClientSettingsStore(defaults: defaults)
        #expect(!store.readFailed)
        #expect(store.current.string("redesignBackground") == "flower")
        #expect(store.current.string("ditherAccent") == "violet")
        let stored = try #require(defaults.data(forKey: ClientSettingsStore.defaultsKey).flatMap { try? JSONValue(parsing: $0) })
        #expect(stored.objectValue?["redesignBackground"] == .string("flower"))
    }

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
        let ids = ["redesign", "redesign-picture", "redesign-text-dim", "accent-color", "ignore-reduce-transparency",
                   "redesign-stacked-picker", "redesign-picker-account", "redesign-background", "redesign-gradient-animate", "redesign-tint"]
        #expect(SettingsSearch.search("redesign").first?.id == "redesign")
        for word in ["flower", "lotus"] {
            #expect(SettingsSearch.search(word).contains { $0.id == "redesign-background" }, "\(word)")
            #expect(SettingsSearch.search(word).contains { $0.id == "redesign-gradient-animate" }, "\(word)")
        }
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

    @Test func dimBehindTextSearchWords() {
        for word in ["dim", "text", "column", "band", "readable"] {
            #expect(SettingsSearch.search(word).contains { $0.id == "redesign-text-dim" }, "\(word)")
        }
    }

    @Test func dimBehindTextPositionPerBackground() {
        // A settings file saved before the setting loads at the default.
        #expect(ClientSettings(decoding: .object(["redesignBackground": .string("flower")])).int("redesignTextDim") == TextDim.standard)
        var c = ClientSettings(decoding: nil)
        #expect(RedesignSettingsView.textDimPosition(c) == TextDim.standard)
        c.apply(["redesignTextDim": .number(20)])
        #expect(RedesignSettingsView.textDimPosition(c) == 20)
        // Blur shows its own saved dim, mapped onto the same track.
        c.apply(["redesignBackground": .string("blur")])
        #expect(RedesignSettingsView.textDimPosition(c) == TextDim.standard)
        c.apply(["ditherBackgroundDim": .number(90)])
        #expect(RedesignSettingsView.textDimPosition(c) == 100)
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
