import AppKit
import DesignSystem
import T3Protocol

/// The `appIcon` and `appIconAppearance` client settings. Sticker is the bundle's icon (`AppIcon.icon`). Every
/// icon, Sticker included, also has a light and a dark Dock image (`IconPinkLight`, `IconPinkDark` and so on in
/// `AppIconVariants.xcassets`), which `scripts/icon/render-variants` renders from the `AppIcon*.icon` documents.
///
/// macOS has no `setAlternateIconName` (AppKit 27 only offers `applicationIconImage`), so a choice shows in the
/// Dock only while the app runs; Finder, Launchpad and the Dock after quitting keep Sticker. The images are flat
/// bitmaps, so they don't follow the Clear or Tinted icon styles. Sticker in Auto hands the Dock the bundle icon
/// while one of those styles is on, so it keeps following them. `NSWorkspace.setIcon(_:forFile:)` would change Finder too, but it writes `Icon\r` and FinderInfo
/// into the bundle, which fails `codesign --verify --strict`, and Sparkle's next update drops it (docs/decisions.md).
@MainActor
public enum AppIconChoice {
    static let key = "appIcon"
    static let appearanceKey = "appIconAppearance"
    /// The picker's order: value and label. The label names the image sets.
    static let options: [(value: String, label: String)] = [
        ("sticker", "Sticker"), ("pink", "Pink"), ("grape", "Grape"), ("mint", "Mint"), ("lemon", "Lemon"),
        ("orange", "Orange"), ("classic", "Classic"),
    ]
    /// Posted when the system appearance changes, so the picker's thumbnails follow Auto.
    static let systemAppearanceChanged = Notification.Name("AppIconChoice.systemAppearanceChanged")
    /// The system's appearance, not the app's: themes force `NSApp.appearance`, and Auto follows the system.
    static var systemDark = readSystemDark()
    /// Clear or Tinted under System Settings > Appearance > Icon and widget style.
    static var styledIcons = readStyledIcons()
    private static var shown: String?

    /// The image set that shows `value` in `appearance` ("auto", "light" or "dark").
    static func imageName(_ value: String, appearance: String, systemDark: Bool) -> String {
        let label = options.first { $0.value == value }?.label ?? "Sticker"
        let dark = appearance == "dark" || (appearance != "light" && systemDark)
        return "Icon\(label)\(dark ? "Dark" : "Light")"
    }

    /// The Dock's image set, or nil for the bundle icon, which the system styles itself. The default icon style
    /// stays light in Dark mode, so only Clear and Tinted get the bundle icon.
    static func dockImageName(_ value: String, appearance: String, systemDark: Bool, styledIcons: Bool) -> String? {
        value == "sticker" && appearance == "auto" && styledIcons ? nil : imageName(value, appearance: appearance, systemDark: systemDark)
    }

    /// Applies the saved choice at launch and follows it and the system appearance from then on.
    public static func start() {
        ClientSettingsStore.shared.observe { keys in
            if keys.contains(key) || keys.contains(appearanceKey) || keys.contains("hydration") { apply() }
        }
        // Event-driven: the distributed notification fires once per Light/Dark switch.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                systemDark = readSystemDark()
                styledIcons = readStyledIcons()
                NotificationCenter.default.post(name: systemAppearanceChanged, object: nil)
                apply()
            }
        }
        apply()
    }

    private static func readSystemDark() -> Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    // ponytail: the icon style's global default key, unset on this Mac's default style, so Clear and Tinted are
    // unverified; check it on a Mac set to Tinted if Sticker stops following it.
    private static func readStyledIcons() -> Bool {
        let theme = UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? ""
        return theme.contains("Clear") || theme.contains("Tinted")
    }

    private static func apply() {
        let settings = ClientSettingsStore.shared.current
        let name = dockImageName(settings.string(key), appearance: settings.string(appearanceKey), systemDark: systemDark,
                                 styledIcons: styledIcons)
        guard name != shown else { return }
        shown = name
        // nil gives the Dock the bundle's icon back, styled by the system again.
        NSApp.applicationIconImage = name.flatMap { NSImage(named: $0) }
    }
}

extension AppearanceSettingsView {
    /// CandyWrapper's own: the app icon, in every theme (the user, 2026-10-23).
    func appIconRow() -> SettingsRowView {
        let picker = AppIconPickerView()
        let r = row(nil, title: "App icon", detail: "The icon in the Dock while CandyWrapper runs. Finder keeps the Sticker icon.", control: picker)
        anchors["app-icon"] = r
        picker.onPick = { [weak self] value in self?.context.writeClient?([AppIconChoice.key: .string(value)]) }
        binder.add { [weak self, weak picker] in
            guard let self else { return }
            picker?.iconAppearance = self.client.string(AppIconChoice.appearanceKey)
            picker?.value = self.client.string(AppIconChoice.key)
        }
        return r
    }

    /// Auto follows the system's Light or Dark appearance, whatever the theme.
    func appIconAppearanceRow() -> SettingsRowView {
        let values = ["auto", "light", "dark"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Auto", nil), ("Light", nil), ("Dark", nil)], selected: 0)
        toggle.setAccessibilityLabel("App icon appearance")
        let r = row(nil, title: "App icon appearance", detail: "Auto uses the dark icon while macOS is in Dark mode.", control: toggle)
        toggle.onChange = { [weak self, weak toggle] i in
            guard let self else { return }
            // Clicking the pressed segment unpresses it; the choice stays.
            guard let i else { toggle?.selectedIndex = values.firstIndex(of: self.client.string(AppIconChoice.appearanceKey)) ?? 0; return }
            self.context.writeClient?([AppIconChoice.appearanceKey: .string(values[i])])
        }
        binder.add { [weak self, weak toggle] in
            guard let self else { return }
            toggle?.selectedIndex = values.firstIndex(of: self.client.string(AppIconChoice.appearanceKey)) ?? 0
        }
        return r
    }
}

/// A row of icon thumbnails with labels; the chosen one has a 2px `ring`.
final class AppIconPickerView: DSView {
    var value = "sticker" { didSet { tiles.forEach { $0.isActive = $0.value == value } } }
    /// The thumbnails show the variant the Dock would get.
    var iconAppearance = "auto" { didSet { if iconAppearance != oldValue { refreshImages() } } }
    var onPick: ((String) -> Void)?
    private var tiles: [Tile] = []
    private static let gap: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("App icon")
        for (v, label) in AppIconChoice.options {
            let t = Tile(value: v, label: label)
            t.action = { [weak self] in self?.onPick?(v) }
            tiles.append(t)
            addSubview(t)
        }
        tiles[0].isActive = true
        refreshImages()
        NotificationCenter.default.addObserver(self, selector: #selector(systemAppearanceChanged), name: AppIconChoice.systemAppearanceChanged, object: nil)
    }

    @objc private func systemAppearanceChanged() { if iconAppearance == "auto" { refreshImages() } }

    private func refreshImages() {
        for t in tiles {
            t.icon.image = NSImage(named: AppIconChoice.imageName(t.value, appearance: iconAppearance, systemDark: AppIconChoice.systemDark)) ?? NSImage()
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(tiles.count) * (Tile.width + Self.gap) - Self.gap, height: Tile.height) }

    override func layout() {
        super.layout()
        for (i, t) in tiles.enumerated() { t.frame = NSRect(x: CGFloat(i) * (Tile.width + Self.gap), y: 0, width: Tile.width, height: Tile.height) }
    }

    final class Tile: ControlView {
        static let width: CGFloat = 48, height: CGFloat = 64
        let value: String
        var isActive = false { didSet { restyle(); setAccessibilityValue(isActive) } }
        private let decoration = BoxDecorationLayer()
        let icon = ImageGlyphView(image: NSImage())
        private let label = LabelView("", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground))

        init(value: String, label text: String) {
            self.value = value
            super.init(frame: .zero)
            scalesWhenPressed = false
            transitions = .colors
            decoration.host = self
            layer?.addSublayer(decoration)
            label.text = text
            label.lineHeight = 16
            label.alignment = .center
            addSubview(icon)
            addSubview(label)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(text) app icon")
            restyle()
        }

        override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

        private func restyle() {
            var box = BoxStyle()
            box.radius = 12
            box.fill = state.hovered && !isActive ? Themed.color(\.accent, 0.3) : .clear
            box.border = .clear
            if isActive { box.shadows = [BoxShadow(spread: 2, color: Themed.color(\.ring), inset: true)] }
            decoration.boxStyle = box
            label.color = isActive ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        }

        override func layout() {
            super.layout()
            let side = Self.width
            decoration.layout(boxSize: NSSize(width: side, height: side))
            // The images carry macOS's Dock margin (412 of 512, scripts/icon/render-variants), so the view is
            // drawn larger by that ratio and the tile itself fills the ring box.
            let inner = side - 4, full = (inner * 512 / 412).rounded()
            icon.frame = NSRect(x: (side - full) / 2, y: (side - full) / 2, width: full, height: full)
            label.frame = NSRect(x: 0, y: side, width: side, height: 16)
        }
    }
}
