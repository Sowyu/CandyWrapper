import AppKit
import DesignSystem
import SpaceModel

extension NSAttributedString.Key {
    /// The paragraph's record, `SpaceParagraphKey.raw`, on every character of the paragraph.
    static let spaceBlock = NSAttributedString.Key("cw.space.block")
    static let spaceBold = NSAttributedString.Key("cw.space.b")
    static let spaceItalic = NSAttributedString.Key("cw.space.i")
    static let spaceCode = NSAttributedString.Key("cw.space.c")
}

/// The record behind one paragraph: a block, or a child page drawn as an item row.
public enum SpaceParagraphKey: Hashable, Sendable {
    case block(BlockID)
    case item(PageID)

    var raw: String {
        switch self {
        case .block(let id): "b" + id.rawValue
        case .item(let id): "i" + id.rawValue
        }
    }

    init?(raw: String) {
        guard let first = raw.first, let id = try? SpaceID(String(raw.dropFirst())) else { return nil }
        switch first {
        case "b": self = .block(id)
        case "i": self = .item(id)
        default: return nil
        }
    }

    var id: RecordID { switch self { case .block(let id), .item(let id): id } }
    var isItem: Bool { if case .item = self { true } else { false } }
}

/// What a paragraph draws besides its text.
struct SpaceParagraph: Equatable {
    var type: BlockType = .p
    var indent = 0
    var lang: String?
    var blob: BlobReference?
    var width: Double?
    var conflict: BlockConflict?
    // Item rows. A child page with a Done value is a to-do and draws as a checklist row; others draw as page links.
    var todo = false
    var done = false
    var due: DateValue?
    var icon: String?
    var view: ViewType = .page

    init(type: BlockType = .p, indent: Int = 0) { self.type = type; self.indent = indent }

    init(block r: BlockRecord) {
        type = r.type; indent = max(0, min(5, r.indent)); lang = r.lang; blob = r.blob; width = r.width; conflict = r.conflict
    }

    init(item r: PageRecord) {
        if case .checkbox(let v)? = r.props[FieldID.done] { todo = true; done = v }
        if case .date(let v)? = r.props[FieldID.due] { due = v }
        icon = r.icon
        view = r.view
    }

    /// A new paragraph made by Return or a split: lists carry on, headings and media turn into text.
    func continued() -> SpaceParagraph {
        switch type {
        case .bullet, .number, .quote, .p: SpaceParagraph(type: type, indent: indent)
        default: SpaceParagraph()
        }
    }
}

/// Look B of the page mockup (docs/space-mockups.md): a 720pt column, headings as small labels, the checklist in
/// one card with right-aligned due dates, an image beside its caption.
enum SpacePageMetrics {
    static let column: CGFloat = 720
    static let indentStep: CGFloat = 24
    static let cardInsetX: CGFloat = 14
    static let cardTop: CGFloat = 4
    static let cardRowPad: CGFloat = 10
    static let addRow: CGFloat = 36
    static let cardBottomMargin: CGFloat = 16
    static let dueWidth: CGFloat = 150
    static let imageTop: CGFloat = 20
    static let captionWidth: CGFloat = 220
    static let conflictHeader: CGFloat = 26

    /// Redesign's accent, as its switch uses it: the chosen accent in dark, the theme's primary in light.
    static let accent = NSColor(name: nil) { appearance in
        appearance.isDark ? ThemeRuntime.ditherAccent.darkColor : Themed.color(\.primary).resolved(in: appearance)
    }

    static func baseFont(_ type: BlockType) -> NSFont {
        switch type {
        case .h1, .h2: DSFont.ui(12, weight: .semibold)
        case .h3: DSFont.ui(12, weight: .medium)
        case .code: DSFont.mono(13)
        case .image, .file: DSFont.ui(12)
        default: DSFont.ui(14)
        }
    }

    static func font(_ type: BlockType, bold: Bool, italic: Bool, code: Bool) -> NSFont {
        let base = baseFont(type)
        var font = code ? DSFont.mono(base.pointSize - 1) : bold ? DSFont.ui(base.pointSize, weight: .semibold) : base
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func color(_ type: BlockType, item done: Bool = false) -> NSColor {
        if done { return Themed.color(\.mutedForeground) }
        switch type {
        case .h1, .h2, .h3, .image, .file: return Themed.color(\.secondaryLabel)
        case .quote: return Themed.color(\.mutedForeground)
        case .code: return Themed.color(\.codeForeground)
        default: return Themed.color(\.foreground, 0.9)
        }
    }

    static func lineHeight(_ type: BlockType, item: Bool) -> CGFloat {
        if item { return 20 }
        switch type {
        case .h1, .h2, .h3: return 16
        case .code: return 20
        case .image, .file: return 18
        default: return 24
        }
    }

    /// Where a row sits in its checklist card.
    struct CardPlace: Hashable { var first: Bool; var last: Bool }

    /// Everything a paragraph style depends on, so equal looks share one style object.
    struct StyleKey: Hashable {
        var type: BlockType, indent: Int, conflict: Bool, item: Bool, todo: Bool, card: CardPlace?, firstInPage: Bool
        var imageWidth: CGFloat?, imageHeight: CGFloat?

        init(_ p: SpaceParagraph, item: Bool, todo: Bool, card: CardPlace?, firstInPage: Bool, image: CGSize?) {
            type = p.type; indent = p.indent; conflict = p.conflict != nil
            self.item = item; self.todo = todo; self.card = card; self.firstInPage = firstInPage
            imageWidth = image?.width; imageHeight = image?.height
        }
    }

    static func paragraphStyle(_ k: StyleKey) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        let line = lineHeight(k.type, item: k.item)
        s.minimumLineHeight = line
        s.maximumLineHeight = line
        let indent = CGFloat(k.indent) * indentStep
        var before: CGFloat = 0, after: CGFloat = 6, head = indent, tail: CGFloat = 0
        if k.item {
            if k.todo {
                let place = k.card ?? CardPlace(first: true, last: true)
                before = cardRowPad + (place.first ? cardTop + 1 : 0)
                after = cardRowPad + (place.last ? addRow + 1 + cardBottomMargin : 0)
                head = cardInsetX + 16 + 12
                tail = -(cardInsetX + dueWidth)
            } else {
                before = 3; after = 3; head = 26
            }
        } else {
            switch k.type {
            case .h1: before = k.firstInPage ? 8 : 36; after = 10
            case .h2: before = k.firstInPage ? 8 : 28; after = 8
            case .h3: before = k.firstInPage ? 8 : 20; after = 8
            case .bullet, .number: head = indent + indentStep; after = 4
            case .quote: head = indent + 16
            case .code: before = 16; after = 18; head = 14; tail = -14
            case .divider: before = 4; after = 4
            case .image:
                let size = k.imageWidth.map { CGSize(width: $0, height: k.imageHeight ?? 0) } ?? CGSize(width: 320, height: 200)
                before = imageTop + max(0, size.height - line)
                head = size.width + 20
            case .file: before = 4; after = 4; head = 26
            default: break
            }
        }
        if k.conflict { before += conflictHeader }
        s.paragraphSpacingBefore = before
        s.paragraphSpacing = after
        s.firstLineHeadIndent = head
        s.headIndent = head
        s.tailIndent = tail
        return s
    }
}

/// Draws a paragraph's decoration around its text: checklist cards, bullets, numbers, quote rules, code wells,
/// dividers, images, link icons and conflict banners. Reads the paragraph from the editor at draw time.
final class SpaceBlockFragment: NSTextLayoutFragment {
    weak var editor: SpacePageEditor?

    @MainActor var paragraphKey: SpaceParagraphKey? {
        guard let paragraph = textElement as? NSTextParagraph else { return nil }
        let text = paragraph.attributedString
        if text.length > 0, let raw = text.attribute(.spaceBlock, at: 0, effectiveRange: nil) as? String { return SpaceParagraphKey(raw: raw) }
        return editor?.tailKey
    }

    override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        // Fragment coordinates start where the fragment does, which can be past an indent; cover the whole column.
        let x = -layoutFragmentFrame.minX - 64
        return CGRect(x: x, y: min(base.minY, -2), width: width + 128, height: max(base.maxY, layoutFragmentFrame.height + 2) - min(base.minY, -2))
    }

    /// Hit targets in text container coordinates.
    struct Targets {
        var checkbox: CGRect?
        var due: CGRect?
        var addRow: CGRect?
        var row: CGRect?
        var keep: CGRect?
        var discard: CGRect?
        var image: CGRect?
    }

    var lineBox: CGRect {
        let f = layoutFragmentFrame
        guard let line = textLineFragments.first else { return CGRect(x: f.minX, y: f.minY, width: f.width, height: 20) }
        return CGRect(x: f.minX, y: f.minY + line.typographicBounds.minY, width: f.width, height: line.typographicBounds.height)
    }

    /// The middle of the capitals on the first line: decorations sit there, since a tall line puts its extra room
    /// above the glyphs.
    /// No text besides the paragraph separator.
    var isEmptyParagraph: Bool {
        guard let paragraph = textElement as? NSTextParagraph else { return true }
        let s = paragraph.attributedString.string
        return s.isEmpty || s == "\n" || s == "\u{2029}"
    }

    @MainActor var glyphMidY: CGFloat {
        let box = lineBox
        guard let line = textLineFragments.first else { return box.midY }
        var font = DSFont.ui(14)
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let f = paragraph.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { font = f }
        return box.minY + line.glyphOrigin.y - font.capHeight / 2
    }

    @MainActor func targets() -> Targets {
        var t = Targets()
        guard let editor, let key = paragraphKey, let p = editor.paragraphs[key] else { return t }
        let f = layoutFragmentFrame
        let width = textLayoutManager?.textContainer?.size.width ?? f.width
        let left: CGFloat = 0
        let line = lineBox
        let mid = glyphMidY
        if key.isItem {
            if editor.isTodoRow(key) {
                let place = editor.cardPlace(key)
                let top = f.minY + (place.first ? SpacePageMetrics.cardTop : 0)
                let bottom = f.maxY - (place.last ? SpacePageMetrics.cardBottomMargin : 0)
                let rowBottom = place.last ? bottom - SpacePageMetrics.addRow : bottom
                t.row = CGRect(x: left, y: top, width: width, height: rowBottom - top)
                t.checkbox = CGRect(x: left + SpacePageMetrics.cardInsetX - 4, y: mid - 12, width: 24, height: 24)
                let dueWidth = editor.dueLabelWidth(p)
                t.due = CGRect(x: left + width - SpacePageMetrics.cardInsetX - dueWidth - 4, y: mid - 12, width: dueWidth + 8, height: 24)
                if place.last { t.addRow = CGRect(x: left, y: rowBottom, width: width, height: SpacePageMetrics.addRow) }
            } else {
                t.row = CGRect(x: left, y: f.minY, width: width, height: f.height)
            }
        }
        if p.conflict != nil {
            let y = f.minY + (p.type == .image ? 0 : 0)
            let labelWidth = editor.conflictLabel(p).size().width
            let keepX = left + labelWidth + 12
            t.keep = CGRect(x: keepX - 4, y: y + 2, width: 40, height: 20)
            t.discard = CGRect(x: keepX + 40, y: y + 2, width: 56, height: 20)
        }
        if p.type == .image, let size = editor.imageSize(p) {
            t.image = CGRect(x: left, y: f.minY + SpacePageMetrics.imageTop + (p.conflict != nil ? SpacePageMetrics.conflictHeader : 0), width: size.width, height: size.height)
        }
        return t
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // NSTextView draws on the main thread.
        nonisolated(unsafe) let fragment = self, context = context
        MainActor.assumeIsolated { fragment.drawDecorated(at: point, in: context) }
    }

    @MainActor private func drawDecorated(at point: CGPoint, in context: CGContext) {
        guard let editor, let key = paragraphKey, let p = editor.paragraphs[key] else {
            super.draw(at: point, in: context)
            return
        }
        let f = layoutFragmentFrame
        let dx = point.x - f.minX, dy = point.y - f.minY
        func moved(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        let t = targets()
        let line = moved(lineBox)
        let midY = glyphMidY + dy
        let width = textLayoutManager?.textContainer?.size.width ?? f.width
        let left = dx
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if editor.isTodoRow(key), let row = t.row.map(moved) {
            let place = editor.cardPlace(key)
            let card = CGRect(x: row.minX, y: row.minY, width: row.width, height: row.height + (t.addRow?.height ?? 0))
            let path = Self.cardPath(card.insetBy(dx: 0.5, dy: 0), top: place.first ? 12 : 0, bottom: place.last ? 12 : 0)
            Themed.color(\.card).setFill()
            path.fill()
            Themed.color(\.border).setStroke()
            let outline = Self.cardOutline(card.insetBy(dx: 0.5, dy: 0), top: place.first ? 12 : 0, bottom: place.last ? 12 : 0, first: place.first, last: place.last)
            outline.lineWidth = 1
            outline.stroke()
            if !place.first { Themed.color(\.border).setFill(); CGRect(x: row.minX + 1, y: row.minY, width: row.width - 2, height: 1).fill() }
            if let add = t.addRow.map(moved) {
                Themed.color(\.border).setFill()
                CGRect(x: add.minX + 1, y: add.minY, width: add.width - 2, height: 1).fill()
                SpacePageIcons.draw(.plus, in: CGRect(x: add.minX + SpacePageMetrics.cardInsetX, y: add.midY - 7, width: 14, height: 14), color: Themed.color(\.placeholder))
                NSAttributedString(string: "New to-do", attributes: [.font: DSFont.ui(13), .foregroundColor: Themed.color(\.placeholder)])
                    .draw(at: CGPoint(x: add.minX + SpacePageMetrics.cardInsetX + 24, y: add.midY - 9))
            }
            if let box = t.checkbox.map(moved) { Self.drawCheckbox(CGRect(x: box.minX + 4, y: box.midY - 8, width: 16, height: 16), on: p.done) }
            if let due = t.due.map(moved) { editor.drawDue(p, rightEdge: due.maxX - 4, midY: due.midY) }
        } else if key.isItem {
            let icon = CGRect(x: left, y: midY - 8, width: 16, height: 16)
            if let emoji = p.icon, !emoji.isEmpty {
                NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 13)]).draw(at: CGPoint(x: icon.minX, y: icon.minY - 1))
            } else {
                SpacePageIcons.draw(SpacePageIcons.viewIcon(p.view), in: icon, color: Themed.color(\.iconMuted))
            }
        }

        if !key.isItem {
            let indentX = left + CGFloat(p.indent) * SpacePageMetrics.indentStep
            switch p.type {
            case .bullet:
                Themed.color(\.foreground, 0.75).setFill()
                let d: CGFloat = 5
                let dot = CGRect(x: indentX + 9, y: midY - d / 2, width: d, height: d)
                if p.indent % 2 == 1 {
                    Themed.color(\.foreground, 0.75).setStroke()
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5)); ring.lineWidth = 1; ring.stroke()
                } else { NSBezierPath(ovalIn: dot).fill() }
            case .number:
                let label = NSAttributedString(string: "\(editor.number(of: key)).", attributes: [.font: DSFont.ui(14).withMonospacedDigits(), .foregroundColor: Themed.color(\.mutedForeground)])
                let w = label.size().width
                label.draw(at: CGPoint(x: indentX + SpacePageMetrics.indentStep - 6 - w, y: midY - label.size().height / 2))
            case .quote:
                Themed.color(\.border, 1).setFill()
                let textTop = line.minY, textBottom = moved(CGRect(x: 0, y: f.maxY - 6, width: 0, height: 0)).minY
                CGRect(x: indentX + 1, y: textTop, width: 2, height: max(line.height, textBottom - textTop)).fill()
            case .code:
                let top = point.y + 4 + (p.conflict != nil ? SpacePageMetrics.conflictHeader : 0)
                let well = CGRect(x: left, y: top, width: width, height: point.y + f.height - 6 - top)
                Themed.color(\.codeBackground).setFill()
                NSBezierPath(roundedRect: well, xRadius: 8, yRadius: 8).fill()
            case .divider:
                Themed.color(\.border).setFill()
                CGRect(x: left, y: midY.rounded(.down), width: width, height: 1).fill()
            case .image:
                if let r = t.image.map(moved) { editor.drawImage(p, in: r) }
            case .file:
                SpacePageIcons.draw(.paperclip, in: CGRect(x: left, y: midY - 8, width: 16, height: 16), color: Themed.color(\.iconMuted))
                let name = p.blob?.name ?? "File"
                let size = p.blob.map { ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) } ?? ""
                let s = NSMutableAttributedString(string: name, attributes: [.font: DSFont.ui(14), .foregroundColor: Themed.color(\.foreground, 0.9)])
                s.append(NSAttributedString(string: "  " + size, attributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.secondaryLabel)]))
                s.draw(at: CGPoint(x: left + 26, y: midY - 9))
            default: break
            }
        }

        if p.conflict != nil {
            SpacePageMetrics.accent.withAlphaComponent(0.5).setFill()
            CGRect(x: left - 14, y: point.y + 2, width: 2, height: f.height - 6).fill()
            let label = editor.conflictLabel(p)
            label.draw(at: CGPoint(x: left, y: point.y + 4))
            let action: [NSAttributedString.Key: Any] = [.font: DSFont.ui(12, weight: .medium), .foregroundColor: Themed.color(\.foreground)]
            if let keep = t.keep.map(moved) { NSAttributedString(string: "Keep", attributes: action).draw(at: CGPoint(x: keep.minX + 4, y: keep.minY + 2)) }
            if let discard = t.discard.map(moved) { NSAttributedString(string: "Discard", attributes: action).draw(at: CGPoint(x: discard.minX + 4, y: discard.minY + 2)) }
        }

        super.draw(at: point, in: context)

        // An empty last paragraph has no fragment of its own; TextKit gives the paragraph before an extra line.
        if textLineFragments.count > 1, let extra = textLineFragments.last, extra.characterRange.length == 0,
           let tail = editor.tailKey, let tp = editor.paragraphs[tail], let hint = editor.placeholder(for: tail, tp, empty: true) {
            let s = NSAttributedString(string: hint, attributes: [.font: SpacePageMetrics.baseFont(tp.type), .foregroundColor: Themed.color(\.placeholder)])
            let y = point.y + extra.typographicBounds.minY + extra.glyphOrigin.y - DSFont.ui(14).ascender
            s.draw(at: CGPoint(x: left + editor.headIndent(tail, tp), y: y))
        }
        if let hint = editor.placeholder(for: key, p, empty: isEmptyParagraph) {
            let font = key.isItem ? DSFont.ui(14) : SpacePageMetrics.baseFont(p.type)
            let s = NSAttributedString(string: hint, attributes: [.font: font, .foregroundColor: Themed.color(\.placeholder)])
            let x = left + editor.headIndent(key, p)
            s.draw(at: CGPoint(x: x, y: midY + font.capHeight / 2 - font.ascender))
        }
    }

    @MainActor static func drawCheckbox(_ r: CGRect, on: Bool) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
        if on {
            SpacePageMetrics.accent.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let check = NSBezierPath()
            check.move(to: CGPoint(x: r.minX + 4, y: r.midY + 0.5))
            check.line(to: CGPoint(x: r.minX + 7, y: r.midY + 3.5))
            check.line(to: CGPoint(x: r.maxX - 3.5, y: r.minY + 5))
            check.lineWidth = 1.75
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            path.lineWidth = 1.5
            Themed.color(\.foreground, 0.28).setStroke()
            path.stroke()
        }
    }

    /// A rect with rounded top or bottom corners only, for one row of a card. Flipped coordinates.
    static func cardPath(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.minX, y: r.minY + top))
        if top > 0 { p.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX + top, y: r.minY), radius: top) }
        p.line(to: CGPoint(x: r.maxX - top, y: r.minY))
        if top > 0 { p.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX, y: r.minY + top), radius: top) }
        p.line(to: CGPoint(x: r.maxX, y: r.maxY - bottom))
        if bottom > 0 { p.appendArc(from: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.maxX - bottom, y: r.maxY), radius: bottom) }
        p.line(to: CGPoint(x: r.minX + bottom, y: r.maxY))
        if bottom > 0 { p.appendArc(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.minX, y: r.maxY - bottom), radius: bottom) }
        p.close()
        return p
    }

    /// The card's border for one row: the sides, plus the rounded top or bottom edge on the first or last row.
    static func cardOutline(_ r: CGRect, top: CGFloat, bottom: CGFloat, first: Bool, last: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.minX, y: first ? r.minY + top : r.minY))
        p.line(to: CGPoint(x: r.minX, y: last ? r.maxY - bottom : r.maxY))
        if last {
            p.appendArc(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.minX + bottom, y: r.maxY), radius: bottom)
            p.line(to: CGPoint(x: r.maxX - bottom, y: r.maxY))
            p.appendArc(from: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.maxY - bottom), radius: bottom)
        } else {
            p.move(to: CGPoint(x: r.maxX, y: r.maxY))
        }
        p.line(to: CGPoint(x: r.maxX, y: first ? r.minY + top : r.minY))
        if first {
            p.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX - top, y: r.minY), radius: top)
            p.line(to: CGPoint(x: r.minX + top, y: r.minY))
            p.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX, y: r.minY + top), radius: top)
        }
        return p
    }
}

/// Icons drawn straight into a layout fragment, through the same definitions IconView uses.
@MainActor
enum SpacePageIcons {
    static func viewIcon(_ view: ViewType) -> IconName {
        switch view {
        case .board: .columns2
        case .table: .table2
        case .timetable: .calendar
        default: .fileText
        }
    }

    static func draw(_ name: IconName, in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let icon = IconView(name: name, size: rect.width, strokeColor: color)
        icon.frame = CGRect(origin: .zero, size: rect.size)
        icon.layoutSubtreeIfNeeded()
        guard let layer = icon.layer else { return }
        layer.layoutIfNeeded()
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        layer.render(in: context)
        context.restoreGState()
    }
}

extension NSFont {
    func withMonospacedDigits() -> NSFont {
        let d = fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                      NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

extension NSColor {
    /// The color as it draws under `appearance`.
    func resolved(in appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance { out = NSColor(cgColor: self.cgColor) ?? self }
        return out
    }
}
