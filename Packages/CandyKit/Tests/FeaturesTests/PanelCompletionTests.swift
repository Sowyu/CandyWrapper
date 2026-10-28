import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct PanelCompletionTests {
    static let patch = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1,2 @@\n-old\n+new\n stable\n"
    @Test func cardsFollowComposerRecordsAndIgnoreDifferentCode() throws {
        let diff = UnifiedDiff(Self.patch)
        let record = try #require(DiffReviewContext.record(diff: diff, path: "a.swift", start: 0, end: 0, text: "Why?", section: "diff", title: "Diff", id: "review"))
        let anchor = try #require(DiffReviewContext.anchor(record, diff: diff))
        #expect(!anchor.right); #expect(anchor.line == 1)
        #expect(DiffReviewContext.anchor(record, diff: UnifiedDiff(Self.patch.replacingOccurrences(of: "-old", with: "-other"))) == nil)
        let panel = DiffPanelView()
        panel.showPatch(Self.patch, collapsed: false)
        panel.reviewComments = [record]
        #expect(panel.list.annotations.count == 1)
        panel.reviewComments = []
        #expect(panel.list.annotations.isEmpty)
    }
    @Test func deviceVersionPreferenceAndRetryMessages() throws {
        let tool = try JSONDecoder().decode(DevicePanelToolVersion.self, from: Data(#"{"requiredVersion":"2.0","installedVersions":["1.9","1.10"],"runningVersion":null}"#.utf8))
        #expect(tool.displayedVersion == "1.10")
        var installed = tool; installed.installedVersions.append("2.0")
        #expect(installed.displayedVersion == "2.0")
        installed.runningVersion = "1.0"
        #expect(installed.displayedVersion == "1.0")
        let status = try JSONDecoder().decode(DevicePanelHostStatus.self, from: Data(#"{"status":"failed"}"#.utf8))
        #expect(status.message == "Device support could not start.")
    }
    @Test func browserDiscoveryReportsOnlyCustomProfiles() {
        var settings = ClientSettings.defaults
        _ = settings.apply(["browserProfiles": .array([BrowserProfiles.profile("work", "Work")]), "browserDefaultProfileId": .string("work")])
        let payload = BrowserProfiles.reportPayload(settings)
        #expect(payload["profiles"]?.arrayValue?.count == 1)
        #expect(payload["defaultProfileId"] == .string("work"))
    }
    @Test func sheetFocusCyclesAndEscapeRestoresResponder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        panel.referenceViewportWidth = 900
        window.contentView = panel
        panel.mutatePanel { $0.open(.diff); return [] }
        panel.layoutSubtreeIfNeeded()
        #expect(panel.rightPanelSheetOpen)
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        #expect(panel.handleRightPanelSheetKey(tab))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        #expect(panel.handleRightPanelSheetKey(escape))
        #expect(!panel.panelState.isOpen)
    }
    @Test func narrowSheetOffersAnActionableMaximizeControl() throws {
        let old = ThemeRuntime.input; ThemeRuntime.apply(.init()); defer { ThemeRuntime.apply(old) }
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        panel.referenceViewportWidth = 900
        panel.mutatePanel { $0.open(.diff); return [] }
        panel.layoutSubtreeIfNeeded()
        #expect(panel.rightPanelSheetOpen)
        let maximize = try #require(panel.subviews.compactMap { $0 as? ToggleView }.first { $0.accessibilityLabel() == "Maximize panel" })
        #expect(!maximize.isHidden)
        maximize.performAction()
        panel.layoutSubtreeIfNeeded()
        #expect(panel.rightPanelMaximized)
        #expect(!panel.rightPanelSheetOpen)
        #expect(maximize.accessibilityLabel() == "Restore panel size")
    }

    @Test func threeDResourcesAreVisibilityScoped() {
        let stream = DevicePanelStreamView()
        #expect(stream.threeDView == nil)
        stream.setThreeD(true)
        weak var sceneView = stream.threeDView
        #expect(sceneView?.rendersContinuously == false)
        #expect(sceneView?.isPlaying == false)
        stream.clear()
        #expect(stream.threeDView == nil)
        #expect(sceneView?.scene == nil)
        #expect(sceneView?.pointOfView == nil)
        #expect(sceneView?.superview == nil)
    }
}
