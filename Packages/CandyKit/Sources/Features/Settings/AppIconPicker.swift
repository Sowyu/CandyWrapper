import AppKit
import DesignSystem
import T3Protocol

/// The `appIcon` client setting: Sticker is the bundle's icon (`AppIcon.icon`); the colored stickers and Classic
/// are alternates (`AppIconPink.icon` and so on) that actool compiles into Assets.car
/// (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
///
/// macOS has no `setAlternateIconName` (AppKit 27 only offers `applicationIconImage`), so an alternate shows in
/// the Dock only while the app runs; Finder, Launchpad and the Dock after quitting keep Sticker. An alternate is
/// a flat bitmap there, so it doesn't follow the Dark, Clear or Tinted icon styles; Sticker, the bundle icon, does.
/// `NSWorkspace.setIcon(_:forFile:)` would change Finder too, but it writes `Icon\r` and FinderInfo into the
/// bundle, which fails `codesign --verify --strict`, and Sparkle's next update drops it (docs/decisions.md).
@MainActor
public enum AppIconChoice {
    static let key = "appIcon"
    /// The picker's order: value, label and the icon's name in Assets.car.
    static let options: [(value: String, label: String, image: String)] = [
        ("sticker", "Sticker", "AppIcon"), ("pink", "Pink", "AppIconPink"), ("grape", "Grape", "AppIconGrape"),
        ("mint", "Mint", "AppIconMint"), ("lemon", "Lemon", "AppIconLemon"), ("orange", "Orange", "AppIconOrange"),
        ("classic", "Classic", "AppIconClassic"),
    ]
    private static var shown = "sticker"

    /// Applies the saved choice at launch and follows it from then on.
    public static func start() {
        ClientSettingsStore.shared.observe { keys in
            if keys.contains(key) || keys.contains("hydration") { apply() }
        }
        apply()
    }

    private static func apply() {
        let value = ClientSettingsStore.shared.current.string(key)
        guard value != shown else { return }
        shown = value
        // nil gives the Dock the bundle's icon back, styled by the system again.
        let name = options.first { $0.value == value && $0.value != "sticker" }?.image
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
            picker?.value = self.client.string(AppIconChoice.key)
        }
        return r
    }
}

/// A row of icon thumbnails with labels; the chosen one has a 2px `ring`.
final class AppIconPickerView: DSView {
    var value = "sticker" { didSet { tiles.forEach { $0.isActive = $0.value == value } } }
    var onPick: ((String) -> Void)?
    private var tiles: [Tile] = []
    private static let gap: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("App icon")
        for (v, label, image) in AppIconChoice.options {
            let t = Tile(value: v, label: label, image: image)
            t.action = { [weak self] in self?.onPick?(v) }
            tiles.append(t)
            addSubview(t)
        }
        tiles[0].isActive = true
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
        private let icon: ImageGlyphView
        private let label = LabelView("", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground))

        init(value: String, label text: String, image: String) {
            self.value = value
            icon = ImageGlyphView(image: NSImage(named: image) ?? NSImage())
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
            // The rendition has Apple's margin built in, so the icon fills the ring box.
            icon.frame = NSRect(x: 2, y: 2, width: side - 4, height: side - 4)
            label.frame = NSRect(x: 0, y: side, width: side, height: 16)
        }
    }
}
