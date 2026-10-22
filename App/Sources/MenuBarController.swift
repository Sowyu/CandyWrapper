import AppKit
import Features
import T3Protocol

/// CandyWrapper's menu bar item, after Capy's tray (docs/research/capy-menubar.md): a template candy icon
/// whose menu, rebuilt each time it opens, lists recent threads and starts new ones. Only the
/// `menuBarItemEnabled` client setting adds or removes it; nothing ticks or watches the store meanwhile.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let snapshot: () -> ShellSnapshot?
    var openThread: (ThreadId) -> Void = { _ in }
    var viewAllThreads: () -> Void = {}
    var newThread: () -> Void = {}
    var quit: () -> Void = {}

    init(snapshot: @escaping () -> ShellSnapshot?) {
        self.snapshot = snapshot
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("menuBarItemEnabled") || keys.contains("hydration") { self?.apply() }
        }
        apply()
    }

    private func apply() {
        let on = ClientSettingsStore.shared.current.bool("menuBarItemEnabled")
        if on, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.icon
            item.button?.toolTip = "CandyWrapper"
            item.button?.setAccessibilityLabel("CandyWrapper")
            // Left and right click both open the menu, as Capy's `mouse-down` handler does on macOS.
            item.menu = menu
            self.item = item
        } else if !on, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for row in MenuBarMenu.rows(snapshot()) {
            switch row {
            case .label(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .thread(let id, let title): menu.addItem(action(title) { [weak self] in self?.openThread(id) })
            case .viewAll: menu.addItem(action("View all threads…") { [weak self] in self?.viewAllThreads() })
            case .newThread: menu.addItem(action("New Thread") { [weak self] in self?.newThread() })
            case .separator: menu.addItem(.separator())
            case .quit: menu.addItem(action("Quit CandyWrapper") { [weak self] in self?.quit() })
            }
        }
    }

    private func action(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Action(run)
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }

    private final class Action {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    /// The candy from design/icon/glyph.svg in one colour, as a template so the menu bar tints it.
    /// The gloss stroke is left out: at 18 points it would be under a point wide.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // Rotated and scaled by 1.02, the glyph spans about 760 by 620 units; fit its width to the image.
            let scale = rect.width / 780 * 1.02
            cg.translateBy(x: rect.midX, y: rect.midY)
            cg.scaleBy(x: scale, y: scale)
            cg.rotate(by: -.pi / 6)
            let path = CGMutablePath()
            for side in [CGFloat(1), -1] {
                let flip = CGAffineTransform(scaleX: side, y: 1)
                for tri in [[(-196, 0), (-336.5, -156), (-399.7, -50.8)], [(-196, 0), (-403.9, -29.2), (-403.9, 29.2)],
                            [(-196, 0), (-399.7, 50.8), (-336.5, 156)]] {
                    path.addLines(between: tri.map { CGPoint(x: $0.0, y: $0.1) }, transform: flip)
                    path.closeSubpath()
                }
                path.addRoundedRect(in: CGRect(x: -208, y: -62, width: 44, height: 124), cornerWidth: 22, cornerHeight: 22, transform: flip)
            }
            path.addRoundedRect(in: CGRect(x: -150, y: -125, width: 300, height: 250), cornerWidth: 125, cornerHeight: 125)
            cg.addPath(path)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CandyWrapper"
        return image
    }()
}
