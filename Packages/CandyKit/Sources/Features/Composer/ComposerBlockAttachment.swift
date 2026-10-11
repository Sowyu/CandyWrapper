import AppKit
import DesignSystem

/// An atomic block prefix keeps the exact Markdown spelling while the editor draws the list
/// marker, checkbox, quote indent or rule. The paragraph style places it (ComposerBlockLayout):
/// a bullet or task atom is its marker box, an ordered or quote atom only holds the indent, and
/// the editor draws numbers and quote rails behind the text (`ComposerEditor.drawBlockDecorations`).
@MainActor
final class ComposerBlockAttachment: NSTextAttachment {
    enum Kind { case bullet, ordered, task(Bool), quote, heading(Int), rule, codeHeader(String, String), codeEnd(String) }
    let source: String
    let kind: Kind
    let bullet: ComposerBlockLayout.BulletStyle

    init(source: String, kind: Kind, width: CGFloat, bullet: ComposerBlockLayout.BulletStyle = .disc) {
        self.source = source
        self.kind = kind
        self.bullet = bullet
        super.init(data: nil, ofType: nil)
        let size: NSSize
        switch kind {
        case .codeHeader: size = NSSize(width: max(40, width - 8), height: 26)
        case .codeEnd: size = NSSize(width: 0.1, height: 1)
        case .heading: size = NSSize(width: 0.1, height: 16)
        case .rule: size = NSSize(width: max(40, width - 8), height: 16)
        case .bullet, .ordered: size = NSSize(width: ComposerBlockLayout.listPadding, height: 16)
        case .task: size = NSSize(width: ComposerBlockLayout.taskGutter, height: 16)
        case .quote: size = NSSize(width: ComposerBlockLayout.quoteIndent, height: 16)
        }
        // The image's bottom edge sits 3pt under the baseline.
        bounds = NSRect(x: 0, y: -3, width: size.width, height: size.height)
        image = NSImage(size: size, flipped: false) { rect in
            Themed.color(\.foreground).setFill()
            Themed.color(\.foreground).setStroke()
            switch kind {
            case .heading, .codeEnd, .ordered, .quote: break
            case .codeHeader(_, let info):
                Themed.color(\.muted).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                (ComposerCodeLanguages.label(info) + " ⌄" as NSString).draw(at: NSPoint(x: 12, y: 7), withAttributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.mutedForeground)])
            case .rule:
                Themed.color(\.mutedForeground).setStroke()
                let path = NSBezierPath(); path.move(to: NSPoint(x: 0, y: 8)); path.line(to: NSPoint(x: rect.width, y: 8)); path.lineWidth = 1; path.stroke()
            case .bullet:
                // Chromium's outside markers at 14px, measured: centred 10.25pt before the text and
                // 4.75pt over the baseline; disc and square 4.5pt, circle 5.25pt with a 0.5pt ring.
                let c = NSPoint(x: rect.width - 10.25, y: 3 + 4.75)
                switch bullet {
                case .disc: NSBezierPath(ovalIn: NSRect(x: c.x - 2.25, y: c.y - 2.25, width: 4.5, height: 4.5)).fill()
                case .square: NSBezierPath(rect: NSRect(x: c.x - 2.25, y: c.y - 2.25, width: 4.5, height: 4.5)).fill()
                case .circle:
                    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 2.375, y: c.y - 2.375, width: 4.75, height: 4.75))
                    ring.lineWidth = 0.5
                    ring.stroke()
                }
            case .task(let checked):
                // Chromium's checkbox at 0.95rem, centred on the line box (flex, `height: 1lh`),
                // in its light and dark color-scheme colors.
                let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                func rgb(_ hex: Int) -> NSColor {
                    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
                }
                let box = NSRect(x: 0, y: 0.4, width: 15.2, height: 15.2)
                if checked {
                    rgb(dark ? 0xA8D3FF : 0x008DFF).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5).fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: box.minX + 3.1, y: box.maxY - 7.7))
                    tick.line(to: NSPoint(x: box.minX + 5.9, y: box.maxY - 10.6))
                    tick.line(to: NSPoint(x: box.minX + 11.6, y: box.maxY - 3.4))
                    tick.lineWidth = 1.8
                    rgb(dark ? 0x4C4C4C : 0xFFFFFF).setStroke()
                    tick.stroke()
                } else {
                    let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                    rgb(dark ? 0x4C4C4C : 0xFFFFFF).setFill()
                    shape.fill()
                    rgb(dark ? 0x979797 : 0x898989).setStroke()
                    shape.lineWidth = 1
                    shape.stroke()
                }
            }
            return true
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A list, quote or heading marker, which starts its line and holds no caret position.
    var isLineMarker: Bool {
        switch kind {
        case .bullet, .ordered, .task, .quote, .heading: true
        default: false
        }
    }

    /// A list atom's parts: the indent, the marker (`-`, `3.`; `-` for a task), and the space after
    /// it (a task's space before its box), plus a task's box and the space after the box.
    var listParts: (indent: String, marker: String, space: String, checked: Bool, contentSpace: String)? {
        let indent = String(source.prefix { $0 == " " || $0 == "\t" })
        var rest = source.dropFirst(indent.count)
        switch kind {
        case .bullet, .ordered:
            let marker = String(rest.prefix { $0 != " " && $0 != "\t" })
            return (indent, marker, String(rest.dropFirst(marker.count)), false, "")
        case .task(let checked):
            rest = rest.dropFirst()
            let space = String(rest.prefix { $0 == " " || $0 == "\t" })
            return (indent, "-", space, checked, String(rest.dropFirst(space.count + 3)))
        default: return nil
        }
    }

    /// The block markers `prefix` tries, compiled once: it runs for every line on every edit.
    private static let blockPatterns: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: [
        #"^([-*_])(?:[ \t]*\1){2,}[ \t]*\r?$"#,
        #"^([ \t]*)-([ \t]+)\[([ xX])\]([ \t]+|$)"#,
        #"^([ \t]*)(\d+[.)])([ \t]+|$)"#,
        #"^([ \t]*)([-*+])([ \t]+|$)"#,
        #"^(#{1,6})([ \t]+)"#,
        #"^>([ \t]*)"#,
    ].map { ($0, try! NSRegularExpression(pattern: $0)) })

    /// `parseOpeningFence`: three or more backticks or tildes, then an info string. A backtick
    /// fence cannot carry a backtick in its info string.
    static func openingFence(_ line: String) -> (fence: String, info: String)? {
        guard let c = line.first, c == "`" || c == "~" else { return nil }
        let run = line.prefix { $0 == c }
        guard run.count >= 3 else { return nil }
        let info = String(line.dropFirst(run.count))
        if c == "`" && info.contains("`") { return nil }
        return (String(run), info)
    }

    /// `isClosingFence`: the opening run's character, at least as long, then only spaces or tabs.
    static func isClosingFence(_ line: String, _ fence: String) -> Bool {
        guard let c = fence.first else { return false }
        var body = Substring(line)
        if body.hasSuffix("\r") { body = body.dropLast() }
        while let last = body.last, last == " " || last == "\t" { body = body.dropLast() }
        return body.count >= max(3, fence.count) && body.allSatisfy { $0 == c }
    }

    static func prefix(_ line: String) -> (source: String, kind: Kind)? {
        func match(_ pattern: String) -> [String]? {
            let ns = line as NSString
            guard let regex = blockPatterns[pattern],
                  let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
        // A thematic break outranks a list: `- - -` and `* * *` are rules (buildTiptapContent).
        if match(#"^([-*_])(?:[ \t]*\1){2,}[ \t]*\r?$"#) != nil { return (line, .rule) }
        if let m = match(#"^([ \t]*)-([ \t]+)\[([ xX])\]([ \t]+|$)"#) {
            return (m[0].replacingOccurrences(of: "[X]", with: "[x]"), .task(m[3].lowercased() == "x"))
        }
        if let m = match(#"^([ \t]*)(\d+[.)])([ \t]+|$)"#) { return (m[0], .ordered) }
        if let m = match(#"^([ \t]*)([-*+])([ \t]+|$)"#) { return (m[0], .bullet) }
        if let m = match(#"^(#{1,6})([ \t]+)"#) { return (m[0], .heading(m[1].count)) }
        if let m = match(#"^>([ \t]*)"#) { return (m[0], .quote) }
        return nil
    }
}
