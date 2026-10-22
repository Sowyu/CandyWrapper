import AppKit
import DesignSystem
import SwiftTerm
import T3Store

/// One terminal: SwiftTerm's AppKit view (parser, buffer, CoreText drawing, selection, IME) with
/// T3's look (apps/web/src/terminal/ghostty/: surface.ts, renderer.ts, ThreadTerminalDrawer.tsx
/// `terminalThemeFromApp`). The server owns the PTY; this view only feeds output in and reports
/// input and grid size out. Created while its drawer shows and released when it hides, so a
/// closed drawer costs no memory, drawing or timers.
@MainActor
public final class TerminalSurfaceView: DSView, @preconcurrency TerminalViewDelegate {
    /// `CONTENT_PADDING` (surface.ts:36).
    static let padding: CGFloat = 4
    /// `MAX_SCROLLBACK_ROWS` (core.ts:12).
    public static let scrollbackRows = 10_000

    let terminal: InputTerminalView
    /// The terminal's own scrollbar (surface.ts:694-700, :1835-1853): a 6px lane 1px from the right edge and 4px from
    /// the top and bottom, drawn while there is scrollback. SwiftTerm's scroller stays hidden and reserves no columns,
    /// like T3's grid, which only subtracts the padding (surface.ts:725).
    private let scrollbar = ScrollAreaScroller(style: .terminal)
    /// Keys and pasted text, already encoded for the PTY.
    public var onInput: ((String) -> Void)?
    /// The grid changed (or `resendSize` asked again).
    public var onResize: ((Int, Int) -> Void)?
    /// A link was clicked: an http(s) URL or a path.
    public var onLink: ((String) -> Void)?
    /// A click landed in the terminal (in a split, it becomes the active pane).
    public var onFocus: (() -> Void)?
    /// "Add to chat" with the selection: its text and its 1-based buffer lines. Nil hides the item.
    public var onAddToChat: ((_ text: String, _ lineStart: Int, _ lineEnd: Int) -> Void)?

    public override init(frame frameRect: NSRect) {
        var options = TerminalOptions.default
        options.scrollback = Self.scrollbackRows
        terminal = InputTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), font: TerminalFontSettings.current(), options: options)
        super.init(frame: frameRect)
        terminal.terminalDelegate = self
        terminal.surface = self
        // T3 activates links on a plain click and underlines them under the pointer, found by its rules.
        terminal.linkHighlightMode = .hover
        terminal.getTerminal().implicitLinkDetector = TerminalLinks.detector
        // libghostty's embedder in T3 does not ring; nothing in the drawer reacts to BEL.
        terminal.bellStyle = .none
        terminal.optionAsMetaKey = false
        terminal.lineSpacing = Self.lineSpacing(for: terminal.font)
        terminal.hidesScroller = true
        terminal.onScrollerUpdate = { [weak self] in self?.syncScrollbar() }
        addSubview(terminal)
        scrollbar.target = self
        scrollbar.action = #selector(scrollbarMoved)
        addSubview(scrollbar)
        syncScrollbar()
        applyTheme()
    }

    private func syncScrollbar() {
        scrollbar.isHidden = !terminal.canScroll
        scrollbar.isEnabled = terminal.canScroll
        scrollbar.knobProportion = terminal.scrollThumbsize
        scrollbar.doubleValue = terminal.scrollPosition
    }

    @objc private func scrollbarMoved() {
        switch scrollbar.hitPart {
        case .knob, .knobSlot: terminal.scroll(toPosition: scrollbar.doubleValue)
        case .decrementPage: terminal.pageUp()
        case .incrementPage: terminal.pageDown()
        default: break
        }
    }

    /// ProviderAuthTerminal uses 13px in the default face (ProviderAuthTerminal.tsx:19-59); thread terminals follow the
    /// Terminal font settings.
    public func setFontSize(_ points: CGFloat) {
        fixedFontSize = points
        applyFont(TerminalFontSettings.font(family: "", size: points))
    }

    private var fixedFontSize: CGFloat?

    private func applyFont(_ font: NSFont) {
        guard font != terminal.font else { return }
        terminal.font = font
        terminal.lineSpacing = Self.lineSpacing(for: font)
        needsLayout = true
    }

    /// The Terminal (or, in simple typography, the code) font settings (ThreadTerminalDrawer.tsx:428-539 `setFont`).
    /// DSView calls this on a font settings change and when a detached surface returns to a window.
    public override func fontRuntimeDidChange() {
        super.fontRuntimeDidChange()
        if fixedFontSize == nil { applyFont(TerminalFontSettings.current()) }
    }

    /// T3's cell is `round(fontSize * 1.35)` tall (renderer.ts `measureGhosttyCell`), 16pt at 12px;
    /// SwiftTerm's is the font's line height times `lineSpacing`.
    static func lineSpacing(for font: NSFont) -> CGFloat {
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let target = max((font.pointSize * 1.35).rounded(), ceil(natural))
        return (target - 0.001) / natural
    }

    /// VS Code's default ANSI colors per appearance (ThreadTerminalDrawer.tsx `TERMINAL_PALETTES`, T3 3105 37e2acda5);
    /// before that T3 kept libghostty's Tomorrow Night, which looked washed out. Colors 16 to 255 keep their defaults.
    static func palette(dark: Bool) -> [SwiftTerm.Color] {
        (dark ? [0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
                 0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xe5e5e5]
              : [0x000000, 0xcd3131, 0x107c10, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555,
                 0x666666, 0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5]).map { (rgb: Int) in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xff) * 257, green: UInt16((rgb >> 8) & 0xff) * 257, blue: UInt16(rgb & 0xff) * 257)
        }
    }

    /// `--terminal-*` (index.css:1146-1149, 1187-1188): the app's background and foreground, a navy
    /// cursor in light and a pale blue one in dark, and a translucent selection of the same hue.
    struct Theme {
        let background, foreground, cursor, selection: NSColor
    }

    /// Resolve under the view's appearance: SwiftTerm stores plain RGB.
    func theme(dark: Bool) -> Theme {
        let fixed = { (color: NSColor) -> NSColor in NSColor(cgColor: color.cgColor(in: self)) ?? color }
        return Theme(background: fixed(WindowGlass.pick(stock: Themed.color(\.background), frost: .clear)), foreground: fixed(Themed.color(\.foreground)),
                     cursor: dark ? NSColor(srgbRed: 180 / 255, green: 203 / 255, blue: 1, alpha: 1)
                                  : NSColor(srgbRed: 38 / 255, green: 56 / 255, blue: 78 / 255, alpha: 1),
                     selection: dark ? NSColor(srgbRed: 180 / 255, green: 203 / 255, blue: 1, alpha: 0.25)
                                     : NSColor(srgbRed: 37 / 255, green: 63 / 255, blue: 99 / 255, alpha: 0.2))
    }

    private var appliedDark: Bool?

    private func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != appliedDark else { return }
        appliedDark = dark
        let theme = theme(dark: dark)
        terminal.installColors(Self.palette(dark: dark))
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.cursor
        terminal.selectedTextBackgroundColor = theme.selection
        terminal.selectedTextForegroundColor = theme.foreground
        layer?.backgroundColor = theme.background.cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func updateLayer() { applyTheme() }

    /// Whether the grid sits on the bottom edge (scrollback exists), as last laid out.
    private var anchoredBottom = false

    /// `terminalContentOriginY` (surface.ts:152-169, 1900-1915): at the top like a fresh terminal until scrollback
    /// exists, then on the bottom edge with the sub-row remainder above row 0, so the prompt stays put while the
    /// height changes within a row.
    public override func layout() {
        super.layout()
        var frame = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        anchoredBottom = terminal.canScroll
        let rows = max(1, terminal.getTerminal().rows)
        let cell = terminal.getOptimalFrameSize().height / CGFloat(rows)
        if anchoredBottom, cell > 0, frame.height > cell {
            let fit = (frame.height / cell).rounded(.down) * cell
            frame.origin.y += frame.height - fit
            frame.size.height = fit + 0.01
        }
        if terminal.frame != frame { terminal.frame = frame }
        let lane = ScrollAreaScroller.laneWidth
        scrollbar.frame = NSRect(x: bounds.maxX - 1 - lane, y: Self.padding, width: lane, height: max(0, bounds.height - 2 * Self.padding))
    }

    /// Output that creates or clears scrollback moves the grid between the edges.
    private func checkAnchor() {
        if terminal.canScroll != anchoredBottom { needsLayout = true }
    }

    // MARK: Output

    public func apply(_ action: TerminalRenderAction) {
        switch action {
        case .reset(let history):
            // Replaying history must not answer old queries (the server already strips them),
            // and nothing the reset itself produces goes to the shell.
            terminal.muted = true
            terminal.getTerminal().resetToInitialState()
            terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
            if !history.isEmpty { terminal.feed(text: history) }
            terminal.muted = false
            terminal.selectNone()
        case .write(let data):
            terminal.feed(text: data)
        case .message(let message):
            terminal.feed(text: TerminalSessionModel.messageText(message))
        }
        checkAnchor()
    }

    /// Reports the current grid again (after the session became writable).
    public func resendSize() {
        let t = terminal.getTerminal()
        onResize?(t.cols, t.rows)
    }

    public var grid: (cols: Int, rows: Int) { (terminal.getTerminal().cols, terminal.getTerminal().rows) }

    public func focus() { window?.makeFirstResponder(terminal) }

    /// `terminalFocus` (lib/terminalFocus.ts): the terminal has the keyboard.
    public var isFocused: Bool { window != nil && window?.firstResponder === terminal }

    public var hasSelection: Bool { terminal.selectionActive }

    public var selectionText: String? { terminal.getSelection() }

    public func selectAllText() { terminal.selectAll() }

    public func scrollToBottom() { terminal.scroll(toPosition: 1) }

    // MARK: TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !terminal.muted, let text = String(bytes: data, encoding: .utf8), !text.isEmpty else { return }
        onInput?(text)
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        onLink?(link)
    }

    public func bell(source: TerminalView) {}

    public func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52 from the shell, as xterm and Ghostty allow writes.
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func clipboardRead(source: TerminalView) -> Data? { nil }

    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: Context menu

    /// T3's right-click menu (`terminalContextMenuItems`, ThreadTerminalDrawer.tsx:276-309): the
    /// selection items, disabled without a selection, then Paste, Select all and Jump to latest.
    func contextMenu() -> NSMenu {
        let menu = selectionMenu()
        for item in menu.items { item.isEnabled = hasSelection }
        menu.addItem(withTitle: "Paste", action: #selector(menuPaste), keyEquivalent: "")
        menu.addItem(withTitle: "Select all", action: #selector(menuSelectAll), keyEquivalent: "")
        menu.addItem(withTitle: "Jump to latest", action: #selector(menuJump), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    /// `terminalSelectionMenuItems`: "Add to chat" (when the composer takes it) and "Copy".
    private func selectionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if onAddToChat != nil { menu.addItem(withTitle: "Add to chat", action: #selector(menuAddToChat), keyEquivalent: "") }
        menu.addItem(withTitle: "Copy", action: #selector(menuCopy), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    /// The selection's text and 1-based lines (`terminalSelectionLineRange`), nil when blank.
    var selectionContext: (text: String, lineStart: Int, lineEnd: Int)? {
        guard hasSelection, let raw = selectionText else { return nil }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: #"^\n+|\n+$"#, with: "", options: .regularExpression)
        guard !text.isEmpty, let selection = terminal.selection else { return nil }
        let start = min(selection.start.row, selection.end.row) + 1
        return (text, start, max(start, max(selection.start.row, selection.end.row) + 1))
    }

    @objc private func menuAddToChat() {
        guard let context = selectionContext else { return }
        onAddToChat?(context.text, context.lineStart, context.lineEnd)
        terminal.selectNone()
        focus()
    }

    /// The post-selection popup (`observeSelectionActions`, selectionActions.ts:35-130): after a
    /// drag or multi-click selection ends, Add to chat and Copy open at the pointer. A double or
    /// triple click waits 500 ms for the gesture to finish. One-shot, nothing runs after.
    func selectionEnded(clickCount: Int, at point: NSPoint) {
        pendingPopup?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.selectionContext != nil, self.window?.isKeyWindow == true else { return }
            self.selectionMenu().popUp(positioning: nil, at: point, in: self.terminal)
        }
        pendingPopup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (clickCount >= 2 ? 0.5 : 0), execute: work)
    }

    /// A new click or a right-click cancels a popup that has not opened yet.
    func cancelSelectionPopup() { pendingPopup?.cancel(); pendingPopup = nil }
    private var pendingPopup: DispatchWorkItem?

    @objc private func menuCopy() { terminal.copy(self); focus() }
    @objc private func menuPaste() { terminal.paste(self); focus() }
    @objc private func menuSelectAll() { selectAllText(); focus() }
    @objc private func menuJump() { scrollToBottom(); focus() }
}

/// SwiftTerm's view with the drawer's hooks: a mute switch for replays and the context menu.
final class InputTerminalView: TerminalView {
    weak var surface: TerminalSurfaceView?
    /// True while a reset replays history: terminal replies are dropped.
    var muted = false

    override func menu(for event: NSEvent) -> NSMenu? {
        surface?.cancelSelectionPopup()
        return surface?.contextMenu()
    }

    /// SwiftTerm clears its cells to transparent and lets the layer's background show. A dialog's blurred snapshot
    /// draws views without layer backgrounds, so the cells came out transparent and the live terminal showed through
    /// sharp above the dim. T3 blurs the terminal with the rest (`backdrop-filter`): paint the background behind the glyphs.
    /// The snapshot shares one context with every view drawn before the terminal, so the text position their labels
    /// left behind would shift its glyphs: start from the identity text matrix.
    override func draw(_ dirtyRect: NSRect) {
        let snapshot = ModalHost.isTakingSnapshot ? NSGraphicsContext.current?.cgContext : nil
        snapshot?.textMatrix = .identity
        super.draw(dirtyRect)
        guard let context = snapshot else { return }
        context.saveGState()
        context.setBlendMode(.destinationOver)
        context.setFillColor(nativeBackgroundColor.cgColor)
        context.fill(dirtyRect)
        context.restoreGState()
    }

    /// A press in a pane makes it the active one (the grid cell's `onMouseDown`).
    override func mouseDown(with event: NSEvent) {
        surface?.cancelSelectionPopup()
        surface?.onFocus?()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount >= 2 || selectionActive, selectionActive else { return }
        surface?.selectionEnded(clickCount: event.clickCount, at: convert(event.locationInWindow, from: nil))
    }
}

/// The terminal face (surface.ts:20-130): the Terminal font setting when it names an installed fixed-pitch family,
/// else the platform's monospace face, with the bundled Symbols Nerd Font and the common Nerd Fonts as glyph
/// fallbacks so prompt symbols and devicons draw on any machine.
enum TerminalFontSettings {
    /// `MIN_TERMINAL_FONT_SIZE`, `MAX_TERMINAL_FONT_SIZE` (surface.ts:21-22).
    static let sizes: ClosedRange<CGFloat> = 6...32
    /// `TERMINAL_GLYPH_FALLBACKS` without the generic `monospace`.
    static let glyphFallbacks = ["Symbols Nerd Font Mono", "Symbols Nerd Font", "JetBrainsMono Nerd Font", "JetBrainsMono NF",
                                 "FiraCode Nerd Font", "Hack Nerd Font", "MesloLGS NF", "CaskaydiaCove Nerd Font", "PowerlineSymbols"]

    /// Simple typography treats the terminal as another monospace surface: the code font and size; Advanced uses the
    /// terminal's own (`resolveTerminalFontPreference`, appearanceFonts.ts:30-50, ThreadTerminalDrawer.tsx:428-441).
    static func current() -> NSFont {
        let p = FontRuntime.input
        return font(family: p.advanced ? p.terminalFamily : p.codeFamily, size: p.advanced ? p.terminalSize : p.codeSize)
    }

    /// The family list as written (`quoteTerminalFontFamilies`): comma separated, quotes dropped.
    static func families(_ list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
    }

    /// The first installed family of `family` when it is fixed pitch (`isMonospaceFamily` refuses a proportional
    /// face), else SF Mono; 12pt when the size is out of range.
    static func font(family: String, size: CGFloat) -> NSFont {
        let points = sizes.contains(size) ? size : 12 // `DEFAULT_TERMINAL_FONT_SIZE`
        let base = families(family).lazy.compactMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: points) }
            .first { $0.isFixedPitch } ?? NSFont.monospacedSystemFont(ofSize: points, weight: .regular)
        _ = registerSymbols
        let cascade = glyphFallbacks.map { NSFontDescriptor(fontAttributes: [.family: $0]) }
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: points) ?? base
    }

    /// `ensureTerminalSymbolsFont`: the bundled symbols-only face, registered for this process on first use.
    /// T3 ships it as WOFF2; ours is the same font rebuilt as TTF from those tables (same cmap and outlines),
    /// so CoreText maps the file instead of unpacking 12 MB of WOFF2 into heap that never goes away.
    private static let registerSymbols: Void = {
        guard let url = Bundle.module.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}
