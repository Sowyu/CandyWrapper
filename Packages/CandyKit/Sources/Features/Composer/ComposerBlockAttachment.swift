import AppKit
import DesignSystem

/// An atomic block prefix keeps the exact Markdown spelling while the editor draws
/// the corresponding list marker, checkbox, quote rail, or rule.
@MainActor
final class ComposerBlockAttachment: NSTextAttachment {
    enum Kind { case bullet, ordered, task(Bool), quote, heading(Int), rule, codeHeader(String, String), codeEnd(String) }
    let source: String
    let kind: Kind

    init(source: String, kind: Kind, width: CGFloat) {
        self.source = source
        self.kind = kind
        super.init(data: nil, ofType: nil)
        let indent = CGFloat(source.prefix { $0 == " " || $0 == "\t" }.count) * 4
        let size: NSSize
        switch kind {
        case .codeHeader: size = NSSize(width: max(40, width - 8), height: 26)
        case .codeEnd: size = NSSize(width: 0.1, height: 1)
        case .heading: size = NSSize(width: 0.1, height: 16)
        case .rule: size = NSSize(width: max(40, width - 8), height: 16)
        case .ordered: size = NSSize(width: indent + 25, height: 16)
        default: size = NSSize(width: indent + 20, height: 16)
        }
        bounds = NSRect(x: 0, y: -3, width: size.width, height: size.height)
        image = NSImage(size: size, flipped: false) { rect in
            Themed.color(\.mutedForeground).setStroke()
            Themed.color(\.foreground).setFill()
            switch kind {
            case .heading, .codeEnd: break
            case .codeHeader(_, let info):
                Themed.color(\.muted).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                (ComposerCodeLanguages.label(info) + " ⌄" as NSString).draw(at: NSPoint(x: 12, y: 7), withAttributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.mutedForeground)])
            case .rule:
                let path = NSBezierPath(); path.move(to: NSPoint(x: 0, y: 8)); path.line(to: NSPoint(x: rect.width, y: 8)); path.lineWidth = 1; path.stroke()
            case .quote:
                let path = NSBezierPath(); path.move(to: NSPoint(x: 2, y: 0)); path.line(to: NSPoint(x: 2, y: 16)); path.lineWidth = 2; path.stroke()
            case .bullet: NSBezierPath(ovalIn: NSRect(x: indent + 5, y: 6, width: 4, height: 4)).fill()
            case .ordered:
                (source.trimmingCharacters(in: .whitespaces) as NSString).draw(at: NSPoint(x: indent, y: 0), withAttributes: [.font: ComposerEditor.font, .foregroundColor: Themed.color(\.foreground)])
            case .task(let checked):
                let box = NSRect(x: indent + 1, y: 2, width: 12, height: 12)
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).stroke()
                if checked {
                    let path = NSBezierPath(); path.move(to: NSPoint(x: indent + 3, y: 8)); path.line(to: NSPoint(x: indent + 6, y: 5)); path.line(to: NSPoint(x: indent + 11, y: 11)); path.lineWidth = 1.5; path.stroke()
                }
            }
            return true
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The block markers `prefix` tries, compiled once: it runs for every line on every edit.
    private static let blockPatterns: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: [
        #"^([ \t]*)-([ \t]+)\[([ xX])\]([ \t]+|$)"#,
        #"^([ \t]*)(\d+[.)])([ \t]+|$)"#,
        #"^([ \t]*)([-*+])([ \t]+|$)"#,
        #"^(#{1,6})([ \t]+)"#,
        #"^>([ \t]?)"#,
        #"^(---|\*\*\*|___)[ \t]*$"#,
    ].map { ($0, try! NSRegularExpression(pattern: $0)) })

    static func prefix(_ line: String) -> (source: String, kind: Kind)? {
        func match(_ pattern: String) -> [String]? {
            let ns = line as NSString
            guard let regex = blockPatterns[pattern],
                  let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
        if let m = match(#"^([ \t]*)-([ \t]+)\[([ xX])\]([ \t]+|$)"#) {
            return (m[0].replacingOccurrences(of: "[X]", with: "[x]"), .task(m[3].lowercased() == "x"))
        }
        if let m = match(#"^([ \t]*)(\d+[.)])([ \t]+|$)"#) { return (m[0], .ordered) }
        if let m = match(#"^([ \t]*)([-*+])([ \t]+|$)"#) { return (m[0], .bullet) }
        if let m = match(#"^(#{1,6})([ \t]+)"#) { return (m[0], .heading(m[1].count)) }
        if let m = match(#"^>([ \t]?)"#) { return (m[0], .quote) }
        if match(#"^(---|\*\*\*|___)[ \t]*$"#) != nil { return (line, .rule) }
        return nil
    }
}
