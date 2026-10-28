import AppKit
import DesignSystem
import T3Protocol

/// How one inline chip looks: T3's `ContextChip` (ContextChip.tsx) for a kind, with its icon and
/// label. Mentions use `FileTagChipContent`, skills lucide `package`, threads `messages-square`,
/// pull requests their state glyph, a context link without its record `circle-dashed` and a dashed
/// neutral border (`UnresolvedChip`).
public struct ComposerChipLook: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mention(path: String)
        case skill
        case citation
        case thread
        /// `open`, `draft`, `merged`, `closed`, or nil for a pull request whose state is unknown.
        case pullRequest(state: String?)
        /// A draft attachment (`ImageChipButton`, `FileChip`): label middle-truncated to 36, then the size.
        case image
        case file(name: String)
        /// A video file attachment (`FileChip` with `isVideo`): kind `video`, lucide `film`.
        case video
        /// A terminal excerpt (`TerminalContextInlineChip`).
        case reviewComment
        case terminal
        case unresolved
    }
    public var kind: Kind
    public var label: String
    /// `text-3xs` after the label: the size, then the upload state ("42%", "upload failed").
    public var detail: String?
    /// `--context-chip-accent` from content: an image chip's average color once its thumbnail loads
    /// (contextChipParts.tsx:184-192).
    public var accentOverride: NSColor?
    public var previewSource: URL?
    /// Text and icon color from the surrounding markup: a chip rendered as a link inside chat markdown takes
    /// `.chat-markdown a { color: var(--info-foreground) }`.
    public var foregroundOverride: NSColor?
    /// ContextChip's `state` (ContextChip.tsx:50-81): `unresolved` dashes the border and takes `text-foreground`
    /// (a file that must be attached again), `invalid` the destructive colors (a failed upload).
    public enum State: Equatable, Sendable { case unresolved, invalid }
    public var state: State?
    /// A thread chip's project: `ThreadContextChip` draws its `ProjectFavicon` in place of `messages-square`
    /// once the thread's shell names a known project (ThreadContextChip.tsx:18, 32-36).
    public var project: ProjectIconSource?

    public init(kind: Kind, label: String, detail: String? = nil, accentOverride: NSColor? = nil, foregroundOverride: NSColor? = nil,
                state: State? = nil, project: ProjectIconSource? = nil, previewSource: URL? = nil) {
        self.kind = kind; self.label = label; self.detail = detail; self.accentOverride = accentOverride; self.foregroundOverride = foregroundOverride
        self.state = state; self.project = project; self.previewSource = previewSource
    }

    /// Mentions and skills only; every context link shows as unavailable.
    public static func basic(_ token: ComposerInlineToken) -> ComposerChipLook {
        look(for: token, skillLabel: { ProviderSkills.displayName(name: $0, displayName: nil) }, record: { _ in nil })
    }

    /// The chip for a token: a mention shows its basename, a skill its display name
    /// (`skillLabelFor`), a thread its live title, a pull request `#n` in its state's color, and a
    /// link whose record is missing the dashed `UnresolvedChip` (composerContextPresentation.tsx).
    public static func look(for token: ComposerInlineToken, skillLabel: (String) -> String,
                            record: (String) -> JSONValue?, threadTitle: (JSONValue) -> String? = { _ in nil },
                            threadProject: (JSONValue) -> ProjectIconSource? = { _ in nil }) -> ComposerChipLook {
        switch token.kind {
        case .mention(let path):
            let base = path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
            return ComposerChipLook(kind: .mention(path: path), label: base.isEmpty ? path : base)
        case .citation(let citation): return ComposerChipLook(kind: .citation, label: citation.label)
        case .skill(let name):
            return ComposerChipLook(kind: .skill, label: skillLabel(name))
        case .context(let kind, let contextId, let label):
            guard let r = record(contextId), r["kind"]?.stringValue == kind else { return ComposerChipLook(kind: .unresolved, label: label) }
            switch kind {
            case "thread":
                return ComposerChipLook(kind: .thread, label: threadTitle(r) ?? r["title"]?.stringValue ?? label, project: threadProject(r))
            case "terminal":
                return ComposerChipLook(kind: .terminal, label: r["label"]?.stringValue ?? label)
            case "review-comment":
                if let pr = ComposerContext.pullRequest(in: r) { return ComposerChipLook(kind: .pullRequest(state: pr.displayState), label: "#\(pr.number)") }
                return ComposerChipLook(kind: .reviewComment, label: label)
            default:
                return ComposerChipLook(kind: .unresolved, label: label)
            }
        }
    }

    /// `--context-chip-accent` per kind.
    var accent: NSColor? {
        if let accentOverride { return accentOverride }
        return switch kind {
        case .mention: OKLab.oklch(0.62, 0.11, 215)
        case .citation: OKLab.oklch(0.62, 0.16, 259)
        case .skill: OKLab.oklch(0.62, 0.16, 322)
        case .image: OKLab.oklch(0.62, 0.16, 16)
        case .file: OKLab.oklch(0.62, 0.136, 237)
        case .video: OKLab.oklch(0.62, 0.16, 48)
        case .thread: OKLab.oklch(0.62, 0.12, 190)
        case .reviewComment: OKLab.oklch(0.62, 0.16, 292)
        case .terminal: OKLab.oklch(0.62, 0.134, 163)
        case .pullRequest(let state):
            switch state {
            case "open": OKLab.oklch(0.62, 0.134, 163)
            case "draft": OKLab.oklch(0.62, 0.02, 259)
            case "merged": OKLab.oklch(0.62, 0.16, 292)
            case "closed": OKLab.oklch(0.62, 0.16, 16)
            default: OKLab.oklch(0.62, 0.16, 277)
            }
        case .unresolved: nil
        }
    }

    @MainActor var icon: (IconDefinition, NSColor?) {
        switch kind {
        case .mention(let path):
            let meta = FileLinkMeta(filePath: path, targetPath: path, workspaceRelativePath: path,
                                    basename: (path as NSString).lastPathComponent, line: nil, column: nil)
            let (definition, color) = FileChipStyle.icon(for: meta)
            return (definition, color)
        case .citation: return (IconName.quote.definition, nil)
        case .skill: return (IconName.package.definition, nil)
        case .image: return (IconName.image.definition, nil)
        case .file(let name):
            let meta = FileLinkMeta(filePath: name, targetPath: name, workspaceRelativePath: name, basename: name, line: nil, column: nil)
            return FileChipStyle.icon(for: meta)
        case .video: return (IconName.film.definition, nil)
        case .thread: return (IconName.messagesSquare.definition, nil)
        case .reviewComment: return (IconName.messageSquare.definition, nil)
        case .terminal: return (IconName.terminal.definition, nil)
        case .pullRequest(let state):
            let name: IconName = switch state {
            case "draft": .gitPullRequestDraft
            case "merged": .gitMerge
            case "closed": .gitPullRequestClosed
            default: .gitPullRequestArrow
            }
            return (name.definition, nil)
        case .unresolved: return (IconName.circleDashed.definition, nil)
        }
    }

    var foreground: NSColor {
        if let foregroundOverride { return foregroundOverride }
        if state == .unresolved { return Themed.color(\.foreground) }
        if state == .invalid { return Themed.color(\.destructive) }
        guard let accent else { return Themed.color(\.foreground) }
        return OKLab.mix(accent, 0.22, Themed.color(\.contrastForeground))
    }

    var border: NSColor {
        if state == .invalid { return Themed.color(\.destructive, 0.35) }
        guard let accent else { return Themed.color(\.border, 0.7) }
        return OKLab.mix(accent, 0.34, Themed.color(\.contrastBorder))
    }

    var fill: NSColor {
        if state == .invalid { return Themed.color(\.destructive, 0.08) }
        return accent?.withAlphaComponent(0.11) ?? Themed.color(\.accent, 0.4)
    }

    var dashed: Bool { kind == .unresolved || state == .unresolved }

    /// `[button:enabled&,a&]:hover`: the border at 48% and the fill at 17% on interactive chips.
    var hoverBorder: NSColor {
        guard let accent else { return border }
        return OKLab.mix(accent, 0.48, Themed.color(\.contrastBorder))
    }

    var hoverFill: NSColor { accent?.withAlphaComponent(0.17) ?? fill }
}

extension NSAttributedString.Key {
    /// The prompt text a chip stands for (its `source`).
    static let composerChipSource = NSAttributedString.Key("CandyComposerChipSource")
}

/// One chip in the prompt editor: a single attachment character that deletes, selects and moves
/// as one unit, drawn as T3's chip box at 14px text (`text-[0.86em]`, `h-[1.41em]`, `align-middle`).
final class ComposerChipAttachment: NSTextAttachment {
    let look: ComposerChipLook
    let source: String
    /// The label after `truncate` within the editor's width (`max-w-full`).
    private let label: String
    private let size: CGSize
    private let parentXHeight: CGFloat

    @MainActor init(look: ComposerChipLook, source: String, maxWidth: CGFloat) {
        self.look = look
        self.source = source
        (label, size) = Self.measure(look, maxWidth: maxWidth)
        parentXHeight = ComposerEditor.font.xHeight
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The label after `truncate` within `maxWidth` (`max-w-full`), and the chip's size.
    @MainActor static func measure(_ look: ComposerChipLook, maxWidth: CGFloat) -> (label: String, size: CGSize) {
        let font = chipFont
        func width(_ s: String) -> CGFloat { TextLine(NSAttributedString(string: s, attributes: [.font: font])).width }
        let detailWidth = look.detail.map { 0.33 * FileChipStyle.em(size) + TextLine(NSAttributedString(string: $0, attributes: [.font: detailFont])).width } ?? 0
        let reserve = FileChipStyle.leading(size) + FileChipStyle.trailing(size) + detailWidth
        var text = look.label
        if width(text) + reserve > maxWidth {
            while !text.isEmpty, width(text + "…") + reserve > maxWidth { text.removeLast() }
            text += "…"
        }
        return (text, CGSize(width: width(text) + reserve, height: FileChipStyle.height(size)))
    }

    static let size: CGFloat = 14
    @MainActor static var chipFont: NSFont { FileChipStyle.font(size) }
    /// `text-3xs`.
    @MainActor static var detailFont: NSFont { DSFont.ui(10) }

    /// `vertical-align: middle`: the chip's center sits x-height / 2 above the baseline.
    var chipBounds: CGRect { CGRect(x: 0, y: parentXHeight / 2 - size.height / 2, width: size.width, height: size.height) }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        chipBounds
    }

    /// TextKit 2 hosts the chip as a view, which redraws itself in the editor's appearance.
    override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        ChipViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
    }

    var chipLabel: String { label }

    /// Drawing without views (offscreen snapshots): a 2x bitmap in the editor's appearance.
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        let look = look, label = label, size = size
        nonisolated(unsafe) let container = textContainer
        return MainActor.assumeIsolated {
            let appearance = container?.textView?.effectiveAppearance ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
            let scale = max(2, container?.textView?.window?.backingScaleFactor ?? 2)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            appearance.performAsCurrentDrawingAppearance {
                let (icon, iconColor) = look.icon
                Self.draw(look: look, label: label, icon: icon, iconColor: iconColor, in: CGRect(origin: .zero, size: size), ctx: ctx)
            }
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }
    }

    /// The chip box, icon and label in a flipped context. `thumbnail` replaces the icon with the
    /// picture (`size-[1.17em] rounded-sm object-cover`); `hovered` draws the interactive hover colors.
    @MainActor static func draw(look: ComposerChipLook, label: String, icon: IconDefinition, iconColor: NSColor?, in rect: CGRect, ctx: CGContext,
                                hovered: Bool = false, thumbnail: CGImage? = nil) {
        let em = FileChipStyle.em(size)
        let radius = 0.5 * em
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: box, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil)
        ctx.setFillColor((hovered ? look.hoverFill : look.fill).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor((hovered ? look.hoverBorder : look.border).cgColor)
        ctx.setLineWidth(1)
        if look.dashed { ctx.setLineDash(phase: 0, lengths: [3, 3]) }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        let iconSize = 1.17 * em
        let iconRect = CGRect(x: rect.minX + 1 + 0.5 * em, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
        if let thumbnail {
            ctx.saveGState()
            // `rounded-sm`: calc(var(--radius) - 4px), 6px.
            ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: min(6, iconRect.width / 2), cornerHeight: min(6, iconRect.height / 2), transform: nil))
            ctx.clip()
            // `object-cover`: the shorter side fills the square.
            let scale = max(iconRect.width / CGFloat(thumbnail.width), iconRect.height / CGFloat(thumbnail.height))
            let w = CGFloat(thumbnail.width) * scale, h = CGFloat(thumbnail.height) * scale
            ctx.translateBy(x: iconRect.midX - w / 2, y: iconRect.midY + h / 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(thumbnail, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        } else if case .thread = look.kind, let project = look.project {
            // `ProjectFavicon` at `size-[1.17em] self-center`: the 16px favicon scaled into the icon box.
            ctx.saveGState()
            ctx.translateBy(x: iconRect.minX, y: iconRect.minY)
            ctx.scaleBy(x: iconSize / 16, y: iconSize / 16)
            ProjectMonogramView.draw(project, identity: ProjectMonogramView.identity(project), ctx: ctx)
            ctx.restoreGState()
        } else {
            MarkdownView.drawIcon(icon, in: iconRect, color: (iconColor ?? look.foreground).cgColor, ctx: ctx)
        }
        // The label's `leading-tight` line box, centered in the chip.
        let line = TextLine(NSAttributedString(string: label, attributes: [.font: chipFont, .foregroundColor: look.foreground]))
        let lineHeight = 1.25 * em
        let baseline = line.baseline(top: rect.minY + (rect.height - lineHeight) / 2, lineHeight: lineHeight)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: iconRect.maxX + 0.33 * em, y: baseline)
        CTLineDraw(line.line, ctx)
        if let detail = look.detail {
            let d = TextLine(NSAttributedString(string: detail, attributes: [.font: detailFont, .foregroundColor: look.foreground]))
            ctx.textPosition = CGPoint(x: iconRect.maxX + 0.33 * em + line.width + 0.33 * em, y: d.baseline(top: rect.minY + (rect.height - 14) / 2, lineHeight: 14))
            CTLineDraw(d.line, ctx)
        }
        ctx.restoreGState()
    }
}

private final class ChipViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let chip = textAttachment as? ComposerChipAttachment else { return }
        let look = chip.look, label = chip.chipLabel, size = chip.chipBounds.size
        view = MainActor.assumeIsolated { ChipView(look: look, label: label, frame: NSRect(origin: .zero, size: size)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        (textAttachment as? ComposerChipAttachment)?.chipBounds ?? .zero
    }
}

/// The chip as a view: clicks fall through to the editor, which places the caret or selects.
private final class ChipView: NSView {
    let look: ComposerChipLook
    let label: String
    private var thumbnail: CGImage?
    private var load: Task<Void, Never>?
    init(look: ComposerChipLook, label: String, frame: NSRect) {
        self.look = look
        self.label = label
        super.init(frame: frame)
        setAccessibilityElement(false)
        // A fractional chip width must crop, never stretch the backing bitmap (that resample made the chip soft).
        layerContentsPlacement = .topLeft
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// TextKit places the chip at `vertical-align: middle`, usually between device pixels; snapping the origin to the
    /// nearest pixel keeps the box edges and the label sharp. Moves at most half a pixel off the text's middle.
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(snapped(newOrigin)) }
    override var frame: NSRect {
        get { super.frame }
        set { super.frame = NSRect(origin: snapped(newValue.origin), size: newValue.size) }
    }
    private func snapped(_ origin: NSPoint) -> NSPoint {
        guard let superview, window != nil else { return origin }
        return superview.backingAlignedRect(NSRect(origin: origin, size: .zero), options: .alignAllEdgesNearest).origin
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setFrameOrigin(frame.origin)
        load?.cancel(); load = nil
        if window == nil { thumbnail = nil }
        else if let source = look.previewSource {
            load = Task { [weak self] in
                let image = await ComposerImageIO.thumbnail(source, side: 40, cover: true)
                guard !Task.isCancelled, let self else { return }
                thumbnail = image
                needsDisplay = true
            }
        }
        needsDisplay = true
    }
    /// A move to a screen with another scale redraws at the new one.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setFrameOrigin(frame.origin)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (icon, iconColor) = look.icon
        ComposerChipAttachment.draw(look: look, label: label, icon: icon, iconColor: iconColor, in: bounds, ctx: ctx, thumbnail: thumbnail)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
