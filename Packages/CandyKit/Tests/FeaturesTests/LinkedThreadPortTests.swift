import AppKit
import Testing
@testable import Features
import T3Store
import T3Protocol

/// The rest of the linked thread port (5258, notes 1.1).
@MainActor
struct LinkedThreadPortTests {
    @Test func unreachableEnvironmentNeedsALoadedCatalogAndAPrimary() {
        // presentation.ts:30-47: nothing is unreachable before the catalog and the primary are known.
        #expect(!ThreadEnvironmentReach.unreachable(environmentId: "b", catalogReady: false, primaryId: "a", enabledIds: []))
        #expect(!ThreadEnvironmentReach.unreachable(environmentId: "b", catalogReady: true, primaryId: nil, enabledIds: []))
        #expect(!ThreadEnvironmentReach.unreachable(environmentId: nil, catalogReady: true, primaryId: "a", enabledIds: []))
        // The primary and enabled saved environments are reachable; a disabled or unknown one is not.
        #expect(!ThreadEnvironmentReach.unreachable(environmentId: "a", catalogReady: true, primaryId: "a", enabledIds: []))
        #expect(!ThreadEnvironmentReach.unreachable(environmentId: "b", catalogReady: true, primaryId: "a", enabledIds: ["b"]))
        #expect(ThreadEnvironmentReach.unreachable(environmentId: "c", catalogReady: true, primaryId: "a", enabledIds: ["b"]))
    }

    @Test func unavailablePageCarriesT3sCopy() {
        let view = ThreadUnavailableStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(view.empty.title == "Thread unavailable")
        #expect(view.empty.message == "This thread is on an environment this app is not connected to.")
        var opened = false
        view.onOpenEnvironments = { opened = true }
        view.empty.action?.handler()
        #expect(opened)
    }
}

struct SideThreadOpenTests {
    @Test func resolvesT3sPlaces() {
        // sideThread.ts:59-73.
        #expect(SideThreadOpen.resolve(preference: "panel", intent: .primary, panelAvailable: true) == .panel)
        #expect(SideThreadOpen.resolve(preference: "panel", intent: .alternate, panelAvailable: true) == .main)
        #expect(SideThreadOpen.resolve(preference: "main", intent: .primary, panelAvailable: true) == .main)
        #expect(SideThreadOpen.resolve(preference: "main", intent: .alternate, panelAvailable: true) == .panel)
        #expect(SideThreadOpen.resolve(preference: "panel", intent: .primary, panelAvailable: false) == .main)
        #expect(SideThreadOpen.intent(command: true, middleButton: false) == .alternate)
        #expect(SideThreadOpen.intent(command: false, middleButton: true) == .alternate)
        #expect(SideThreadOpen.intent(command: false, middleButton: false) == .primary)
    }
}
