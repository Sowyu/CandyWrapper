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
    /// `DEFAULT_TERMINAL_FONT_SIZE` and `CONTENT_PADDING` (surface.ts:20, 36).
    public static let fontSize: CGFloat = 12
    static let padding: CGFloat = 4
    /// `MAX_SCROLLBACK_ROWS` (core.ts:12).
    public static let scrollbackRows = 10_000

    let terminal: InputTerminalView
    /// Keys and pasted text, already encoded for the PTY.
    public var onInput: ((String) -> Void)?
    /// The grid changed (or `resendSize` asked again).
    public var onResize: ((Int, Int) -> Void)?
    /// A link was clicked: an http(s) URL or a path.
    public var onLink: ((String) -> Void)?

    public override init(frame frameRect: NSRect) {
        var options = TerminalOptions.default
        options.scrollback = Self.scrollbackRows
        terminal = InputTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), font: Self.font, options: options)
        super.init(frame: frameRect)
        terminal.terminalDelegate = self
        terminal.surface = self
        // T3 activates links on a plain click and underlines them under the pointer.
        terminal.linkHighlightMode = .hover
        // libghostty's embedder in T3 does not ring; nothing in the drawer reacts to BEL.
        terminal.bellStyle = .none
        terminal.optionAsMetaKey = false
        terminal.lineSpacing = Self.lineSpacing(for: Self.font)
        terminal.installColors(Self.palette)
        addSubview(terminal)
        applyTheme()
    }

    /// The system monospace face (`"SF Mono"` heads T3's family list) at 12px.
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    /// T3's cell is `round(fontSize * 1.35)` tall (renderer.ts `measureGhosttyCell`), 16pt at 12px;
    /// SwiftTerm's is the font's line height times `lineSpacing`.
    static func lineSpacing(for font: NSFont) -> CGFloat {
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let target = max((fontSize * 1.35).rounded(), ceil(natural))
        return (target - 0.001) / natural
    }

    /// libghostty's default 16 colors (Tomorrow Night), which T3 keeps: it sets no palette. Read
    /// from the shipped ghostty-vt.wasm; SwiftTerm derives the 256-color cube the same way.
    static let palette: [SwiftTerm.Color] = [
        0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
        0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
    ].map { (rgb: Int) in
        SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xff) * 257, green: UInt16((rgb >> 8) & 0xff) * 257, blue: UInt16(rgb & 0xff) * 257)
    }

    /// `--terminal-*` (index.css:1146-1149, 1187-1188): the app's background and foreground, a navy
    /// cursor in light and a pale blue one in dark, and a translucent selection of the same hue.
    struct Theme {
        let background, foreground, cursor, selection: NSColor
    }

    /// Resolve under the view's appearance: SwiftTerm stores plain RGB.
    func theme(dark: Bool) -> Theme {
        let fixed = { (color: NSColor) -> NSColor in NSColor(cgColor: color.cgColor(in: self)) ?? color }
        return Theme(background: fixed(Themed.color(\.background)), foreground: fixed(Themed.color(\.foreground)),
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

    public override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        if terminal.frame != frame { terminal.frame = frame }
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

    /// T3's right-click menu (`terminalContextMenuItems`) without "Add to chat", which needs the
    /// composer's terminal context chips.
    // ponytail: no "Add to chat" and no post-selection popup; add both with the terminal context chip
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = menu.addItem(withTitle: "Copy", action: #selector(menuCopy), keyEquivalent: "")
        copy.isEnabled = hasSelection
        menu.addItem(withTitle: "Paste", action: #selector(menuPaste), keyEquivalent: "")
        menu.addItem(withTitle: "Select all", action: #selector(menuSelectAll), keyEquivalent: "")
        menu.addItem(withTitle: "Jump to latest", action: #selector(menuJump), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

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

    override func menu(for event: NSEvent) -> NSMenu? { surface?.contextMenu() }
}
