import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// 27-welcome: the 4928 Welcome page at 1100 × 780 (design/reference-4928, plans/main.json "27-welcome"): Sandbox
/// Mac with Claude and Codex ready, the other agents folded under Add more agents, and three projects none of
/// which is recent enough to be picked.
@MainActor @Suite(.fidelity)
struct WelcomePageFidelityTests {
    static let ceilings: FidelityCeilings = ["welcome": .init(0.01)]

    static func provider(_ driver: String, ready: Bool) -> ServerProvider {
        var p = ServerProvider(instanceId: ProviderInstanceId(driver), driver: driver, enabled: ready, installed: ready,
                               status: ready ? .ready : .disabled)
        p.auth = .object(["status": .string(ready ? "authenticated" : "unknown")])
        return p
    }

    static func model() -> WelcomePageModel {
        let defaults = UserDefaults(suiteName: "WelcomePageFidelityTests")!
        defaults.removePersistentDomain(forName: "WelcomePageFidelityTests")
        let model = WelcomePageModel(environmentId: "sandbox", label: "Sandbox Mac", defaults: defaults)
        model.settings = .object(["providerInstances": .object([:])])
        model.providers = [provider("claudeAgent", ready: true), provider("codex", ready: true)]
            + ["antigravity", "cursor", "fx", "grok", "kiro", "muse", "opencode", "pi"].map { provider($0, ready: false) }
        let old = "2026-01-02T00:00:00.000Z"
        model.scan = .init(pending: false, error: nil, truncated: false, candidates: ["demo-repo", "notes", "scratch"].map {
            OnboardingProjectCandidate(environmentId: "sandbox", path: "/Users/Shared/cw-sandbox-4928/\($0)", title: $0,
                                       sources: ["claudeAgent"], threadCount: 1, lastActiveAt: old, git: .none)
        })
        return model
    }

    static func page(dark: Bool) -> WelcomePageView {
        let view = WelcomePageView(model: model(), context: SettingsPageContext())
        view.heading = "Welcome to T3 Code" // T3's name, so the comparison covers the layout; the app shows its own.
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func welcome() throws {
        let previous = FontRuntime.input
        defer { FontRuntime.apply(previous) }
        var fonts = FontRuntimeInput()
        fonts.smoothing = false
        FontRuntime.apply(fonts)
        var scores: [(String, Double)] = []
        for dark in [false, true] {
            let base = "27-welcome.\(dark ? "dark" : "light")"
            let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo
                .appendingPathComponent("design/reference-4928/\(base).png"))))
            let ours = Snapshot.image(of: Self.page(dark: dark), size: NSSize(width: 1100, height: 780), scale: 2, dark: dark)
            let (score, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
            let out = Fidelity.root.appendingPathComponent("welcome")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Snapshot.writePNG(ref, to: out.appendingPathComponent(base + ".ref.png"))
            try Snapshot.writePNG(ours, to: out.appendingPathComponent(base + ".ours.png"))
            try Snapshot.writePNG(diff, to: out.appendingPathComponent(base + ".diff.png"))
            scores.append((base, score))
        }
        Self.ceilings.check("welcome", scores)
    }
}
