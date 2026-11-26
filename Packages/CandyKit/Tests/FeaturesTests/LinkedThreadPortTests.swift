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

/// `connectLinkedEnvironment` (5258 linkedThread.ts:76-110) with linkedThread.test.ts's cases.
struct LinkedThreadConnectTests {
    static func pairing(_ type: String = "credential", urls: [String], credential: String? = "code") throws -> PeerLinkClientPairingResult {
        var json: [String: Any] = ["type": type, "environmentId": "env-b", "label": "Studio", "urls": urls]
        if let credential { json["credential"] = credential }
        return try JSONDecoder().decode(PeerLinkClientPairingResult.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func noPairingAnswerMeansPairingByHand() async {
        let outcome = await LinkedThreadConnect.connect(label: "box", requestPairing: { nil }, reaches: { _ in true }, pair: { _, _ in true })
        #expect(outcome == .manual(label: "box", host: nil))
    }

    @Test func pairsAtTheFirstOfferedAddressThatAnswers() async throws {
        let p = try Self.pairing(urls: ["http://a", "http://b", "http://c"])
        let paired = SendableBox<String?>(nil)
        let outcome = await LinkedThreadConnect.connect(label: "box", requestPairing: { p }, reaches: { $0 != "http://a" },
                                                        pair: { host, code in paired.set("\(host) \(code)"); return true })
        #expect(outcome == .connected)
        #expect(paired.get() == "http://b code")
    }

    @Test func noAnsweringAddressIsUnreachableUnderTheServersLabel() async throws {
        let p = try Self.pairing(urls: ["http://a"])
        let outcome = await LinkedThreadConnect.connect(label: "box", requestPairing: { p }, reaches: { _ in false }, pair: { _, _ in true })
        #expect(outcome == .unreachable(label: "Studio"))
    }

    @Test func unsupportedOrRefusedPairingFallsBackToTheCodeWithAnAddress() async throws {
        let unsupported = try Self.pairing("unsupported", urls: ["http://a", "http://b"], credential: nil)
        let none = await LinkedThreadConnect.connect(label: "box", requestPairing: { unsupported }, reaches: { _ in false }, pair: { _, _ in true })
        #expect(none == .manual(label: "Studio", host: "http://a"))
        let found = await LinkedThreadConnect.connect(label: "box", requestPairing: { unsupported }, reaches: { $0 == "http://b" }, pair: { _, _ in true })
        #expect(found == .manual(label: "Studio", host: "http://b"))
        let p = try Self.pairing(urls: ["http://a"])
        let refused = await LinkedThreadConnect.connect(label: "box", requestPairing: { p }, reaches: { _ in true }, pair: { _, _ in false })
        #expect(refused == .manual(label: "Studio", host: "http://a"))
    }

    @Test func noticesCarryT3sCopy() {
        // LinkedThreadPane.tsx:109-145.
        #expect(LinkedThreadConnect.notice(.idle, label: "box") == nil)
        #expect(LinkedThreadConnect.notice(.connecting, label: "box")?.title == "Connecting to box…")
        #expect(LinkedThreadConnect.notice(.unreachable(label: "Studio"), label: "box")?.title == "Studio is not reachable from this device")
        let manual = LinkedThreadConnect.notice(.manual(label: "Studio", host: nil), label: "box")
        #expect(manual?.title == "Studio needs a pairing code")
        #expect(manual?.action == "Enter code")
    }
}

final class SendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
