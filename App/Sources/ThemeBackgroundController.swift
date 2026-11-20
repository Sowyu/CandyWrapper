import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// Feeds `ThemeBackground` (themeBackground.ts): the primary environment's published image for the theme on
/// screen, minted through `assets.createUrl` (`environment-theme-background`), and the window's visibility, so a
/// hidden or minimized window holds no image.
@MainActor
final class ThemeBackgroundController {
    private let environments: Environments
    private weak var window: NSWindow?
    private var appearance: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow, environments: Environments) {
        self.window = window
        self.environments = environments
        let background = ThemeBackground.shared
        background.fetch = { [weak environments] env, themeId in
            guard let session = environments?.session(env) else { return nil }
            let payload: JSONValue = .object(["resource": .object(["_tag": .string("environment-theme-background"), "themeId": .string(themeId)])])
            guard let reply = try? await session.supervisor.request("assets.createUrl", payload: payload),
                  let relative = reply["relativeUrl"]?.stringValue else { return nil }
            return try? await session.http.asset(relative, token: session.token, maxBytes: ThemeBackground.maxBytes)
        }
        background.onChange = { ThemeBackgroundView.setImage($0) }
        _ = ThemeLibrary.shared.observe { [weak self] in self?.update() }
        appearance = NSApp.observe(\.effectiveAppearance) { _, _ in Task { @MainActor [weak self] in self?.update() } }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.updateVisibility() }
            })
        }
        // A failed download retries when the network comes back (#37843); the path monitor pushes this, nothing polls.
        tokens.append(center.addObserver(forName: NetworkSignals.online, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeBackground.shared.networkOnline() }
        })
        update()
    }

    /// The theme painting the appearance on screen and its published image revision.
    func update() {
        let library = ThemeLibrary.shared
        let themeId = library.owner(of: library.resolvedAppearance)
        ThemeBackground.shared.apply(environmentId: environments.primaryId, themeId: themeId, revision: library.backgroundRevision(themeId))
    }

    private func updateVisibility() {
        guard let window else { return }
        ThemeBackground.shared.setVisible(window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }
}
