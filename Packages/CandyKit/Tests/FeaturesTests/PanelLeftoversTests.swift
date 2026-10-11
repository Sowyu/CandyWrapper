import AppKit
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct PanelLeftoversTests {
    @Test func sshDraftAndIndependentEnvironmentIDs() throws {
        #expect(DeviceHostEditing.draft(id: "a", label: "Mac", target: "-oProxyCommand=x", identity: "", port: "") == nil)
        #expect(DeviceHostEditing.draft(id: "a", label: "Mac", target: "user@host", identity: "", port: "65536") == nil)
        #expect(DeviceHostEditing.draft(id: "a", label: "Mac", target: "two hosts", identity: "", port: "22") == nil)
        let original = try #require(DeviceHostEditing.draft(id: "shared", label: "Mac", target: "user@host", identity: " key ", port: "22"))
        var local = original.objectValue!; local["id"] = .string("local-id")
        var changed = original.objectValue!; changed["target"] = .string("new-host")
        let other = DeviceHostEditing.draft(id: "other", label: "Other", target: "other", identity: "", port: "")!
        let updated = try DeviceHostEditing.update([.object(local), other], host: .object(changed), original: original, remove: false)
        #expect(updated[0]["id"] == .string("local-id"))
        #expect(updated[0]["target"] == .string("new-host"))
        #expect(updated[1] == other)
        #expect(try DeviceHostEditing.update(updated, host: .object(changed), original: original, remove: false) == updated)
        #expect(try DeviceHostEditing.update([.object(local), other], host: original, original: original, remove: true) == [other])
        #expect(throws: DeviceHostEditing.DeviceHostEditError.self) {
            try DeviceHostEditing.update([.object(local), .object(local)], host: original, original: original, remove: false)
        }
    }
    @Test func coordinatesAndPlatformActions() {
        #expect(DeviceToolsActions.location("nan", "0") == nil)
        #expect(DeviceToolsActions.location("91", "0") == nil)
        #expect(DeviceToolsActions.location("0", "-181") == nil)
        #expect(DeviceToolsActions.location("-90", "180")?["longitude"] == .number(180))
        #expect(!DeviceToolsActions.permissions(platform: "android").contains { $0.0 == "faceid" })
        #expect(DeviceToolsActions.permissions(platform: "ios").contains { $0.0 == "faceid" })
    }
    @Test func profileNormalizationAndExplicitOpen() {
        var settings = ClientSettings.defaults
        _ = settings.apply(["browserProfiles": .array([
            BrowserProfiles.profile("default", "Fake"), BrowserProfiles.profile("work", "Work", "incognito"),
            BrowserProfiles.profile("work", "Duplicate"), BrowserProfiles.profile("bad\nkey", "Bad")]),
            "browserDefaultProfileId": .string("work")])
        let profiles = BrowserProfiles.resolved(settings)
        #expect(profiles.count == 3)
        #expect(profiles.last?["kind"] == .string("persistent"))
        #expect(BrowserProfiles.defaultId(settings) == "work")
        #expect(PreviewRPC.openPayload(threadId: "thread", profileId: "incognito")["profileId"] == .string("incognito"))
        _ = settings.apply(["browserDefaultProfileId": .string("incognito")])
        #expect(BrowserProfiles.defaultId(settings) == "default")
    }
    @Test func reviewRangeKeepsBothSidesAndFileRelativeOffsets() throws {
        let diff = UnifiedDiff("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
        -old
        +new
         stable
        """)
        let record = try #require(DiffReviewContext.record(diff: diff, path: "a.swift", start: 1, end: 0, text: " Fix this ", section: "turn", title: "Turn 1", id: "test"))
        #expect(record["startIndex"] == .number(0)); #expect(record["endIndex"] == .number(1))
        #expect(record["diff"] == .string("@@ -1,1 +1,1 @@\n-old\n+new"))
        #expect(record["text"] == .string("Fix this"))
        let deletion = try #require(DiffReviewContext.record(diff: diff, path: "a.swift", start: 0, end: 0, text: "Why?", section: "turn", title: "Turn", id: "d"))
        #expect(deletion["label"] == .string("a.swift L1 (before)"))
    }
    @Test func deviceTabsPreserveRenameAndRestore() throws {
        var state = RightPanelState(); state.open(.device)
        let a = DevicePanelSurface(hostId: "local", deviceId: "ios/a", platform: "ios", name: "Phone")
        let b = DevicePanelSurface(hostId: "remote", deviceId: "emu", platform: "android", name: "Android")
        state.openDevice(a); state.renameDevice(a.id, title: "  Test phone  "); state.openDevice(b); state.openDevice(a)
        #expect(state.surfaces.count == 2); #expect(state.active?.title == "Test phone")
        #expect(a.id == "device:local:ios%2Fa")
        let decoded = try JSONDecoder().decode(RightPanelState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        var restored = RightPanelState(); ClosedPanelTabs.restore(state.active!, into: &restored)
        #expect(restored.active?.title == "Test phone")
    }
    @Test func narrowPanelWidth() {
        #expect(RightPanelSheetBackdropView.width(viewport: 700, container: 500) == 384)
        #expect(RightPanelSheetBackdropView.width(viewport: 900, container: 660) == 378)
        #expect(RightPanelSheetBackdropView.width(viewport: 300, container: 250) == 250)
    }
}
