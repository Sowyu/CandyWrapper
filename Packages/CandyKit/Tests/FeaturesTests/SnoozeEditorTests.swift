import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SnoozeEditorTests {
    @Test func olderAcknowledgementDoesNotReplaceTheLatestDraft() {
        let editor = SnoozePresetsEditor()
        editor.refresh(SnoozePresetSetting.defaults)
        let first: [SnoozePresetSetting] = [.after(minutes: 15)]
        let second: [SnoozePresetSetting] = [.after(minutes: 30)]
        editor.save(first)
        editor.save(second)
        editor.refresh(first)
        #expect(editor.presets == second)
        editor.refresh(second)
        #expect(editor.presets == second)
        editor.refresh([])
        #expect(editor.presets.isEmpty)
    }

    @Test func failuresAndScopeChangesRestoreTheSavedValueEvenWhenItIsUnchanged() {
        let editor = SnoozePresetsEditor()
        editor.refresh(SnoozePresetSetting.defaults, sourceKey: "one")
        editor.save([])
        // The rows show the saved options soonest first (T3 3824 #26427), so the order may differ.
        editor.refresh(SnoozePresetSetting.defaults, sourceKey: "one", failureRevision: 1)
        #expect(SnoozePresets.same(editor.presets, SnoozePresetSetting.defaults))
        editor.save([])
        editor.refresh(SnoozePresetSetting.defaults, sourceKey: "two", failureRevision: 1)
        #expect(SnoozePresets.same(editor.presets, SnoozePresetSetting.defaults))
    }
}
