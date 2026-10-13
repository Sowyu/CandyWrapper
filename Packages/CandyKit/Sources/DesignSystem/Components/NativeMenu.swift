import AppKit

/// A window that can show Glass Native's presentation (docs/glass-native.md). The main window conforms.
@MainActor
public protocol NativeChromeWindow: NSWindow {
    var nativeChrome: Bool { get }
}

public extension NSView {
    /// True in a Glass Native window: menus open as `NSMenu` and the popups that stay custom wear glass.
    var usesNativeChrome: Bool { (window as? NativeChromeWindow)?.nativeChrome ?? false }
}

/// Glass Native's menus: T3's plain menus as an `NSMenu` with the same items, sections, checkmarks, shortcuts and
/// disabled states. Built on open and released on close, so a closed menu holds nothing.
@MainActor
public enum NativeMenu {
    /// An `NSMenu` holds every item but rows with their own controls, a favicon view, a wrapping note, a
    /// trailing badge or detail, and rows that keep the menu open (inline confirms). Those menus stay custom.
    public static func canExpress(_ items: [MenuItem]) -> Bool {
        items.allSatisfy { item in
            if item.accessory != nil || item.leading != nil || item.keepsOpen || item.runsInPlace
                || item.badge != nil || item.trailingDetail != nil { return false }
            switch item.kind {
            case .note: return false
            case .submenu(let children): return canExpress(children)
            default: return true
            }
        }
    }

    /// `select`: a Select's list, where picking a radio row runs its action (`MenuPopupView.Style.select`).
    public static func make(_ items: [MenuItem], select: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item.kind {
            case .separator:
                if menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
                continue
            case .label:
                menu.addItem(NSMenuItem.sectionHeader(title: item.title))
                continue
            default: break
            }
            let native = NativeMenuAction(title: item.title, action: nil, keyEquivalent: "")
            native.isEnabled = !item.isDisabled
            native.toolTip = item.tooltip
            if let subtitle = item.subtitle, #available(macOS 14.4, *) { native.subtitle = subtitle }
            if item.isDestructive {
                native.attributedTitle = NSAttributedString(string: item.title, attributes: [
                    .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemRed])
            }
            native.image = image(for: item)
            if let shortcut = item.shortcut, let key = keyEquivalent(shortcut) {
                native.keyEquivalent = key.key
                native.keyEquivalentModifierMask = key.modifiers
            }
            switch item.kind {
            case .checkbox(let on):
                native.state = on ? .on : .off
                native.handler = { item.onToggle?(!on) }
            case .radio(let on):
                native.state = on ? .on : .off
                // As `MenuPopupView.activate`: a radio reports a new pick, and runs its action when it closes on click.
                native.handler = {
                    if !on { item.onToggle?(true) }
                    if select || item.closesOnClick { item.action?() }
                }
            case .submenu(let children):
                native.submenu = make(children, select: select)
            default:
                native.handler = item.action
            }
            menu.addItem(native)
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    /// Opens `items` beside `trigger` where the custom popup would sit, and returns once the menu closes. The trigger
    /// shows its pressed state meanwhile.
    public static func popUp(_ items: [MenuItem], from trigger: NSView, placement: PopupPlacement, minimumWidth: CGFloat,
                             anchorRect: CGRect?) {
        let menu = make(items)
        menu.minimumWidth = minimumWidth
        popUp(menu, from: trigger, placement: placement, anchorRect: anchorRect)
    }

    static func popUp(_ menu: NSMenu, from trigger: NSView, placement: PopupPlacement, anchorRect: CGRect?) {
        let anchor = anchorRect ?? trigger.bounds
        let size = menu.size
        var x: CGFloat
        switch placement.align {
        case .start: x = anchor.minX + placement.alignOffset
        case .center: x = anchor.midX - size.width / 2
        case .end: x = anchor.maxX - size.width - placement.alignOffset
        }
        // The point is the menu's top left corner in the trigger's coordinates.
        let below = placement.side != .top
        let flipped = trigger.isFlipped
        let edge = below ? (flipped ? anchor.maxY : anchor.minY) : (flipped ? anchor.minY : anchor.maxY)
        let gap = placement.sideOffset
        var y: CGFloat
        if below { y = flipped ? edge + gap : edge - gap } else { y = flipped ? edge - gap - size.height : edge + gap + size.height }
        if placement.side == .right { x = anchor.maxX + gap; y = flipped ? anchor.minY : anchor.maxY }
        if placement.side == .left { x = anchor.minX - gap - size.width; y = flipped ? anchor.minY : anchor.maxY }
        let control = trigger as? ControlView
        control?.isPopupOpen = true
        menu.popUp(positioning: nil, at: CGPoint(x: x, y: y), in: trigger)
        control?.isPopupOpen = false
        control?.nativeMenuDidClose()
    }

    /// A Select's list as the system pop-up menu: the picked row over the trigger, as `NSPopUpButton` and T3's
    /// `alignItemWithTrigger` place it, or under the trigger when nothing is picked or the select drops down.
    public static func popUpSelect(_ items: [MenuItem], from trigger: NSView, selectedRow: Int?, aligned: Bool,
                                   placement: PopupPlacement = .dropdown) {
        let menu = make(items, select: true)
        menu.minimumWidth = trigger.bounds.width
        guard aligned, let row = selectedRow, row < menu.items.count, items.count == menu.items.count else {
            popUp(menu, from: trigger, placement: placement, anchorRect: nil)
            return
        }
        let control = trigger as? ControlView
        control?.isPopupOpen = true
        menu.popUp(positioning: menu.items[row], at: CGPoint(x: 0, y: trigger.isFlipped ? trigger.bounds.maxY - 4 : 4), in: trigger)
        control?.isPopupOpen = false
        control?.nativeMenuDidClose()
    }

    /// A context menu at `point` in `view`'s coordinates.
    public static func popUpContextMenu(_ items: [MenuItem], in view: NSView, at point: CGPoint) {
        make(items).popUp(positioning: nil, at: point, in: view)
    }

    // MARK: Pieces

    /// `⇧⌘K` and the like (keybindings.ts:191-224) as a key equivalent. Nil for anything it can't read.
    static func keyEquivalent(_ shortcut: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        var rest = ""
        for c in shortcut {
            switch c {
            case "⌘": modifiers.insert(.command)
            case "⇧": modifiers.insert(.shift)
            case "⌥": modifiers.insert(.option)
            case "⌃": modifiers.insert(.control)
            default: rest.append(c)
            }
        }
        let named: [String: String] = [
            "↵": "\r", "⏎": "\r", "Enter": "\r", "⌫": "\u{8}", "⌦": "\u{7f}", "Esc": "\u{1b}", "⎋": "\u{1b}", "Tab": "\t",
            "Space": " ", "↑": String(UnicodeScalar(NSUpArrowFunctionKey)!), "↓": String(UnicodeScalar(NSDownArrowFunctionKey)!),
            "←": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "→": String(UnicodeScalar(NSRightArrowFunctionKey)!),
        ]
        if let key = named[rest] { return (key, modifiers) }
        guard rest.count == 1 else { return nil }
        return (rest.lowercased(), modifiers)
    }

    /// The row's leading mark: a full-color image, a tinted glyph, or T3's Lucide icon as a template.
    static func image(for item: MenuItem) -> NSImage? {
        if let image = item.image { return image }
        if let glyph = item.glyph {
            let img = image(glyph, size: 12, color: nil)
            img?.isTemplate = true
            return img
        }
        guard let icon = item.icon else { return nil }
        return image(icon.definition, size: 16, color: icon.isBrand ? nil : item.iconColor)
            .map { img in if !icon.isBrand && item.iconColor == nil { img.isTemplate = true }; return img }
    }

    /// Draws an icon definition the way `IconView` does, into an image. Lucide's `currentColor` paints black, so the
    /// image works as a template; a color paints it as it is.
    static func image(_ definition: IconDefinition, size: CGFloat, color: NSColor?) -> NSImage? {
        let vb = definition.viewBox
        guard vb.width > 0, vb.height > 0 else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = min(rect.width / vb.width, rect.height / vb.height)
            ctx.translateBy(x: (rect.width - vb.width * scale) / 2, y: (rect.height - vb.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            let current = (color ?? .black).cgColor
            func resolve(_ c: IconColor) -> CGColor? {
                switch c {
                case .none: nil
                case .current: current
                case .rgba(let v): CGColor(srgbRed: CGFloat(v >> 24 & 0xff) / 255, green: CGFloat(v >> 16 & 0xff) / 255,
                                           blue: CGFloat(v >> 8 & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
                }
            }
            for element in definition.elements {
                guard let path = try? element.cgPath() else { continue }
                let p = element.paint
                ctx.saveGState()
                ctx.translateBy(x: -vb.x + p.offsetX, y: -vb.y + p.offsetY)
                ctx.setAlpha(p.opacity)
                if let fill = resolve(p.fill) {
                    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath(using: p.evenOdd ? .evenOdd : .winding)
                }
                if let stroke = resolve(p.stroke) {
                    ctx.addPath(path)
                    ctx.setStrokeColor(stroke)
                    ctx.setLineWidth(p.strokeWidth)
                    ctx.setLineCap(p.lineCap == .round ? .round : p.lineCap == .square ? .square : .butt)
                    ctx.setLineJoin(p.lineJoin == .round ? .round : p.lineJoin == .bevel ? .bevel : .miter)
                    ctx.strokePath()
                }
                ctx.restoreGState()
            }
            return true
        }
        return image
    }
}

@MainActor
final class NativeMenuAction: NSMenuItem {
    var handler: (@MainActor () -> Void)? {
        didSet { target = self; action = handler == nil ? nil : #selector(run) }
    }
    @objc private func run() { handler?() }
}

// MARK: - Glass for the popups that stay custom

/// The popups an `NSMenu` can't hold (search fields, rich rows, badges) keep their content and wear Liquid Glass
/// in Glass Native, at the spec's 12 pt radius for popovers. The glass view exists only while the popup is open.
@MainActor
public enum NativePopupMaterial {
    public static let radius: CGFloat = 12

    /// Puts a glass surface behind `view`'s content, once, and returns it. Nil below macOS 26.
    public static func attach(to view: NSView, radius: CGFloat = NativePopupMaterial.radius) -> NSView? {
        guard let glass = makeGlass(radius: radius) else { return nil }
        glass.frame = view.bounds
        glass.autoresizingMask = [.width, .height]
        view.addSubview(glass, positioned: .below, relativeTo: nil)
        // Below the view's own sublayers too: the box's hairline, a footer fill.
        glass.layer?.zPosition = -1
        return glass
    }

    /// A glass surface at `radius` with the popover tint. Nil below macOS 26.
    public static func makeGlass(radius: CGFloat) -> NSView? {
        guard #available(macOS 26, *) else { return nil }
        let glass = NSGlassEffectView()
        glass.cornerRadius = radius
        glass.tintColor = tint
        return glass
    }

    /// The popover color at the Glass opacity, so text reads over the timeline as classic's `dropdown-glass` does.
    public static var tint: NSColor { Themed.color(\.popover, Double(0.5 * ThemeRuntime.glassOpacity)) }

    /// The box over the glass: no fill and no drop shadow of its own, a hairline at the edge.
    public static func box(radius: CGFloat = NativePopupMaterial.radius) -> BoxStyle {
        var box = BoxStyle()
        box.radius = radius
        box.border = Themed.color(\.contrastForeground, 0.1)
        return box
    }
}
