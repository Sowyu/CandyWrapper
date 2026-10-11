import AppKit
import Testing
import T3Store
import T3Protocol
@testable import Features

@MainActor
struct SweepPanelsTests {
    @Test func miniPlayerEdgesKeepOppositeCornerAndBounds() {
        let start = CGRect(x: 300, y: 200, width: 320, height: 200)
        for direction in BrowserMiniPlayerResizeDirection.allCases {
            let rect = direction.resized(start, delta: CGPoint(x: -70, y: -45), container: CGSize(width: 1000, height: 800))
            #expect(rect.minX >= 12 && rect.minY >= 12 && rect.maxX <= 988 && rect.maxY <= 788)
            #expect(abs(rect.width / rect.height - 1.6) < 0.01)
            if direction.west { #expect(rect.maxX == start.maxX) }
            if direction.north { #expect(rect.maxY == start.maxY) }
        }
    }
    @Test func expandedChromeDoesNotScheduleADeferredCollapse() {
        let composer = ComposerView()
        composer.collapseOnScroll = true
        var blocked = true
        composer.restingBlocked = { blocked }
        composer.recordTimelineScroll(delta: -40, canScroll: true, towardEnd: false)
        #expect(!composer.isResting)
        blocked = false
        #expect(!composer.isResting)
        composer.recordTimelineScroll(delta: -40, canScroll: true, towardEnd: false)
        #expect(composer.isResting)
        composer.expandFromScroll()
        #expect(!composer.isResting)
    }
    @Test func oneFailedFanoutTargetKeepsItsRetryRoute() {
        let pickers = ComposerPickers(store: ComposerSelectionStore(defaults: nil), draftKey: "draft", context: ComposerSelectionContext(catalog: ProviderCatalog([])))
        pickers.supportsMultipleModels = true
        let selection = ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5")
        pickers.setMultiple([selection], for: "draft")
        #expect(pickers.currentMultiple == [selection])
        pickers.setMultiple(nil, for: "draft")
        #expect(pickers.currentMultiple == nil)
    }
    @Test func languageSearchKeepsCurrentUnknownAndAliases() {
        #expect(ComposerCodeLanguages.filtered(" JAVA ", current: "swift").map(\.id) == ["java", "javascript"])
        #expect(ComposerCodeLanguages.filtered("custom", current: "custom meta").map(\.id) == ["custom"])
        #expect(ComposerCodeLanguages.filtered("", current: "JS meta").count == ComposerCodeLanguages.entries.count)
        #expect(ComposerCodeLanguages.filtered("missing", current: "swift").isEmpty)
        #expect(ComposerCodeLanguages.replacing("swift linenos", with: "python") == "python linenos")
    }
    @Test func customPresetsUseDriverIdsAndDefaults() {
        let codex = ComposerCustomModelPresets.descriptors("codex")
        #expect(codex.map { $0["id"]?.stringValue } == ["reasoningEffort", "serviceTier"])
        #expect(codex[0]["options"]?.arrayValue?.first { $0["isDefault"]?.boolValue == true }?["id"]?.stringValue == "medium")
        #expect(ComposerCustomModelPresets.descriptors("claudeAgent").count == 3)
        #expect(ComposerCustomModelPresets.descriptors("unknown").isEmpty)
    }
    @Test func diffTreeExpansionPreservesPathsAndOrdering() {
        let diff = UnifiedDiff("diff --git a/src/a.swift b/src/a.swift\n--- a/src/a.swift\n+++ b/src/a.swift\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/test/b.swift b/test/b.swift\n--- a/test/b.swift\n+++ b/test/b.swift\n@@ -1 +1 @@\n-before\n+after\n")
        var model = DiffPanelSearch.tree(diff)
        #expect(model.allExpanded)
        let paths = model.directoryPaths
        _ = model.setAllExpanded(false)
        #expect(!model.allExpanded)
        #expect(model.rows.allSatisfy { $0.isDirectory })
        _ = model.setAllExpanded(true)
        #expect(model.directoryPaths == paths)
        #expect(model.rows.filter { !$0.isDirectory }.map(\.path) == ["src/a.swift", "test/b.swift"])
    }
    @Test func panelOverflowScrollsWithoutChangingActiveSurface() {
        let view = RightPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
        var state = RightPanelState()
        for index in 0..<12 { state.openFile("File-\(index).swift") }
        view.apply(state); view.layoutSubtreeIfNeeded()
        #expect(view.state.activeSurfaceId == state.activeSurfaceId)
        #expect(view.subviews.contains { !$0.isHidden && $0.accessibilityLabel() == "Scroll tabs left" })
    }
}
