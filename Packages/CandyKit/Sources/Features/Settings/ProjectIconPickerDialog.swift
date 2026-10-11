import AppKit
import DesignSystem
import T3Protocol

/// `ProjectIconPickerDialog` (settings/ProjectIconPickerDialog.tsx): an icon, an emoji or a monogram, with
/// a color for icons and monograms. Save sends `{faviconPath: null, projectIcon: <choice>}`.
@MainActor
public enum ProjectIconPickerDialog {
    /// `PROJECT_EMOJIS` (projectIconOptions.ts:29-60).
    static let emojis: [(emoji: String, label: String)] = [
        ("💻", "Computer"), ("🛠️", "Tools"), ("🚀", "Rocket"), ("🤖", "Robot"), ("✨", "Sparkles"), ("⚡", "Lightning"),
        ("🌐", "Web"), ("📱", "Mobile"), ("🖥️", "Desktop"), ("⌨️", "Keyboard"), ("⚙️", "Gear"), ("🗄️", "Database"),
        ("☁️", "Cloud"), ("📦", "Package"), ("📚", "Books"), ("🧪", "Test tube"), ("🔒", "Lock"), ("🎮", "Game"),
        ("🎵", "Music"), ("🎬", "Movie"), ("🖼️", "Picture"), ("🛍️", "Shopping"), ("🔥", "Fire"), ("💡", "Idea"),
        ("🧩", "Puzzle"), ("📊", "Chart"), ("🧠", "Brain"), ("🦄", "Unicorn"), ("🐙", "Octopus"), ("🌱", "Seedling"),
    ]

    /// `POPULAR_PROJECT_ICONS`.
    static let popular = ["folder-code", "code-2", "terminal", "globe-2", "server", "database", "bot", "sparkles", "smartphone",
                          "monitor", "cloud-cog", "package", "book-open", "flask-conical", "shield-check", "rocket", "gamepad-2",
                          "music", "image", "shopping-bag", "git-branch", "workflow", "wrench", "layers-3"]

    /// `filterProjectIconNames`: the popular icons, or up to 60 names containing the query.
    // ponytail: searches the icons this app bundles, not all of lucide; ship the full set if users search for missing ones
    public static func filterIcons(_ query: String) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
        guard !normalized.isEmpty else { return popular.filter(icon(named:)) }
        return Array(IconName.allCases.compactMap(\.lucideName).filter { $0.contains(normalized) }.sorted().prefix(60))
    }

    static func icon(named name: String) -> Bool { IconName.allCases.contains { $0.lucideName == name } }

    /// `iconLabel`: "git-branch" reads "Git Branch".
    static func label(_ name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// `ProjectMonogramText`: letters and numbers (with marks and joiners), up to 32.
    public static func isValidMonogram(_ text: String) -> Bool {
        text.count <= 32 && text.range(of: #"^[\p{L}\p{N}][\p{L}\p{N}\p{M}\x{200c}\x{200d}]*$"#, options: .regularExpression) != nil
    }

    /// `firstEmoji`: the first grapheme when it is a pictograph, a flag or a keycap.
    // ponytail: emoji properties stand in for `\p{Extended_Pictographic}`; a few text pictographs differ, use ICU's property if one matters
    public static func firstEmoji(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        let scalars = first.unicodeScalars
        let flag = scalars.count == 2 && scalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
        let keycap = scalars.contains { $0.value == 0x20E3 }
        guard flag || keycap || scalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) }) else { return nil }
        return String(first)
    }

    /// Shows the dialog; `save` gets the chosen `ProjectIconOverride`.
    @discardableResult
    public static func present(in window: NSWindow, current: JSONValue?, projectName: String,
                               save: @escaping @MainActor (JSONValue) -> Void) -> ModalHost {
        let dialog = DialogView(title: "Choose project icon", message: "Choose an icon, emoji, or monogram.")
        dialog.maxWidth = 512 // `sm:w-[32rem]`
        let body = ProjectIconPickerBody(current: current, projectName: projectName)
        dialog.panelContent = [body]
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Save icon")
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        dialog.onClose = { [weak host] in host?.close() }
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak host, weak body] in
            guard let body, let value = body.choice else { return }
            host?.close()
            save(value)
        }
        body.onChange = { [weak dialog, weak body, weak ok] in
            ok?.isEnabled = body?.choice != nil
            dialog?.needsLayout = true
        }
        return host
    }
}

/// The dialog's panel: the type toggle, the colors, then the icon grid, the emoji grid or the monogram.
final class ProjectIconPickerBody: DSView {
    enum Mode: Int { case lucide, emoji, monogram }
    var onChange: (@MainActor () -> Void)?
    private(set) var mode: Mode
    private var iconName: String
    private var color: String
    private var letters: String
    private var emoji: String
    private let automatic: (monogram: String, color: String)

    private let toggle = ToggleGroupView(items: [("Icons", nil), ("Emoji", nil), ("Monogram", nil)])
    private let colorLabel = LabelView("Color", font: DSFont.ui(12, weight: .medium))
    private var swatches: [ProjectIconSwatch] = []
    private let search = InputView(placeholder: "Search all Lucide icons")
    private let gridDocument = DSView()
    private lazy var grid = ScrollAreaView(documentView: gridDocument, scrollFade: true)
    private var cells: [ProjectIconCell] = []
    private let noIcons = LabelView("No icons found.", font: DSFont.ui(14))
    private let monogram = ProjectMonogramView()
    private let lettersLabel = FormLabel.make("Letters")
    private let lettersInput = InputView()
    private let lettersHint = LabelView("One or two letters or numbers.", font: DSFont.ui(12))
    private let pasteLabel = LabelView("Or paste any emoji", font: DSFont.ui(12, weight: .medium))
    private let pasteInput = InputView(placeholder: "Paste an emoji")

    init(current: JSONValue?, projectName: String) {
        automatic = ProjectMonogramView.identity(projectName)
        let kind = current?["kind"]?.stringValue
        mode = kind == "emoji" ? .emoji : kind == "monogram" ? .monogram : .lucide
        iconName = kind == "lucide" ? current?["name"]?.stringValue ?? "folder-code" : "folder-code"
        color = kind != nil && kind != "emoji" ? current?["color"]?.stringValue ?? automatic.color : automatic.color
        letters = kind == "monogram" ? current?["text"]?.stringValue ?? automatic.monogram : automatic.monogram
        emoji = kind == "emoji" ? current?["emoji"]?.stringValue ?? "💻" : "💻"
        super.init(frame: .zero)
        toggle.selectedIndex = mode.rawValue
        toggle.setAccessibilityLabel("Icon type")
        toggle.onChange = { [weak self] index in
            guard let self else { return }
            guard let index, let next = Mode(rawValue: index) else { self.toggle.selectedIndex = self.mode.rawValue; return }
            self.mode = next
            self.rebuildGrid()
        }
        for (i, name) in ProjectMonogramView.colors.enumerated() {
            let s = ProjectIconSwatch(color: name)
            s.setAccessibilityLabel(name.prefix(1).uppercased() + name.dropFirst())
            s.action = { [weak self] in self?.color = name; self?.refresh() }
            swatches.append(s)
            _ = i
        }
        search.setAccessibilityLabel("Search Lucide icons")
        search.onChange = { [weak self] _ in self?.rebuildGrid() }
        lettersInput.text = letters
        lettersInput.onChange = { [weak self] text in self?.letters = text; self?.refresh() }
        pasteInput.setAccessibilityLabel("Custom emoji")
        pasteInput.onChange = { [weak self] text in
            if let e = ProjectIconPickerDialog.firstEmoji(text) { self?.emoji = e; self?.refresh() }
        }
        noIcons.alignment = .center
        noIcons.lineHeight = 20
        lettersHint.lineHeight = 16
        colorLabel.lineHeight = 16
        pasteLabel.lineHeight = 16
        grid.scrollView.automaticallyAdjustsContentInsets = false
        grid.scrollView.contentInsets = NSEdgeInsets()
        monogram.scale = 3
        for v in [toggle, colorLabel, search, grid, noIcons, monogram, lettersLabel, lettersInput, lettersHint, pasteLabel, pasteInput] as [NSView] {
            addSubview(v)
        }
        swatches.forEach(addSubview)
        rebuildGrid()
    }

    /// The monogram as Save would send it (`normalize("NFKC").trim().toUpperCase()`).
    private var monogramText: String {
        letters.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// What Save sends, nil while the monogram is not valid.
    var choice: JSONValue? {
        switch mode {
        case .monogram:
            guard ProjectIconPickerDialog.isValidMonogram(monogramText) else { return nil }
            return .object(["kind": .string("monogram"), "text": .string(monogramText), "color": .string(color)])
        case .lucide: return .object(["kind": .string("lucide"), "name": .string(iconName), "color": .string(color)])
        case .emoji: return .object(["kind": .string("emoji"), "emoji": .string(emoji)])
        }
    }

    private func rebuildGrid() {
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        switch mode {
        case .lucide:
            for name in ProjectIconPickerDialog.filterIcons(search.text) {
                let cell = ProjectIconCell(glyph: IconName.allCases.first { $0.lucideName == name }, emoji: nil)
                cell.setAccessibilityLabel(ProjectIconPickerDialog.label(name))
                cell.action = { [weak self] in self?.iconName = name; self?.refresh() }
                cell.value = name
                cells.append(cell)
            }
        case .emoji:
            for e in ProjectIconPickerDialog.emojis {
                let cell = ProjectIconCell(glyph: nil, emoji: e.emoji)
                cell.setAccessibilityLabel(e.label)
                cell.action = { [weak self] in self?.emoji = e.emoji; self?.refresh() }
                cell.value = e.emoji
                cells.append(cell)
            }
        case .monogram: break
        }
        cells.forEach(gridDocument.addSubview)
        refresh()
    }

    private func refresh() {
        let lucide = mode == .lucide, emojiMode = mode == .emoji, mono = mode == .monogram
        colorLabel.isHidden = emojiMode
        swatches.forEach { $0.isHidden = emojiMode; $0.isSelected = $0.colorName == color }
        search.isHidden = !lucide
        grid.isHidden = mono
        noIcons.isHidden = !(lucide && cells.isEmpty)
        for v in [monogram, lettersLabel, lettersInput, lettersHint] as [NSView] { v.isHidden = !mono }
        pasteLabel.isHidden = !emojiMode
        pasteInput.isHidden = !emojiMode
        for c in cells { c.isSelected = c.value == (lucide ? iconName : emoji); c.tint = color }
        let valid = ProjectIconPickerDialog.isValidMonogram(monogramText)
        monogram.source = ProjectIconSource(title: automatic.monogram, workspaceRoot: "", faviconPath: nil,
                                            override: .monogram(text: valid ? monogramText : automatic.monogram, color: color))
        lettersInput.isInvalid = !valid
        colorLabel.color = Themed.color(\.mutedForeground)
        lettersHint.color = Themed.color(\.mutedForeground)
        pasteLabel.color = Themed.color(\.mutedForeground)
        noIcons.color = Themed.color(\.mutedForeground)
        invalidateIntrinsicContentSize()
        needsLayout = true
        onChange?()
    }

    // MARK: Layout (`DialogPanel flex flex-col` with `space-y-4`)

    private func gridRows(_ width: CGFloat) -> (cell: CGFloat, height: CGFloat) {
        // `grid grid-cols-10 gap-1 p-0.5`, `aspect-square`.
        let cell = ((width - 4 - 9 * 4) / 10).rounded(.down)
        let rows = (cells.count + 9) / 10
        return (cell, rows == 0 ? 0 : 4 + CGFloat(rows) * cell + CGFloat(rows - 1) * 4)
    }

    private func sections(_ width: CGFloat) -> [CGFloat] {
        var h: [CGFloat] = [toggle.intrinsicContentSize.height]
        let swatchRows = CGFloat((swatches.count * 30 + Int(width) - 1) / max(1, Int(width)))
        if mode != .emoji { h.append(16 + 8 + swatchRows * 24 + max(0, swatchRows - 1) * 6) }
        switch mode {
        case .lucide:
            h.append(32)
            if cells.isEmpty { h.append(20 + 64) } else { h.append(min(256, gridRows(width).height)) }
        case .emoji:
            h.append(min(256, gridRows(width).height))
            h.append(16 + 8 + 32)
        case .monogram:
            h.append(8 + 16 + 8 + 32 + 8 + 16 + 8)
        }
        return h
    }

    override var intrinsicContentSize: NSSize {
        let hs = sections(max(1, bounds.width > 0 ? bounds.width : 464))
        return NSSize(width: NSView.noIntrinsicMetric, height: hs.reduce(0, +) + CGFloat(hs.count - 1) * 16)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let hs = sections(w)
        var y: CGFloat = 0
        var i = 0
        let tw = toggle.intrinsicContentSize.width
        toggle.frame = NSRect(x: 0, y: y, width: tw, height: hs[i]); y += hs[i] + 16; i += 1
        if mode != .emoji {
            colorLabel.frame = NSRect(x: 0, y: y, width: w, height: 16)
            var x: CGFloat = 0, sy = y + 24
            for s in swatches {
                if x + 24 > w { x = 0; sy += 30 }
                s.frame = NSRect(x: x, y: sy, width: 24, height: 24)
                x += 30
            }
            y += hs[i] + 16; i += 1
        }
        switch mode {
        case .lucide:
            search.frame = NSRect(x: 0, y: y, width: w, height: 32); y += 32 + 16; i += 1
            if cells.isEmpty {
                noIcons.frame = NSRect(x: 0, y: y + 32, width: w, height: 20)
            } else {
                layoutGrid(y: y, height: hs[i], width: w)
            }
        case .emoji:
            layoutGrid(y: y, height: hs[i], width: w); y += hs[i] + 16
            pasteLabel.frame = NSRect(x: 0, y: y, width: w, height: 16)
            pasteInput.frame = NSRect(x: 0, y: y + 24, width: w, height: 32)
        case .monogram:
            // `flex items-center gap-4 py-2`: the 48px monogram, then the field column.
            monogram.frame = NSRect(x: 0, y: y + 8 + (hs[i] - 16 - 48) / 2, width: 48, height: 48)
            let fx: CGFloat = 48 + 16
            lettersLabel.frame = NSRect(x: fx, y: y + 8, width: w - fx, height: 16)
            lettersInput.frame = NSRect(x: fx, y: y + 8 + 24, width: w - fx, height: 32)
            lettersHint.frame = NSRect(x: fx, y: y + 8 + 24 + 32 + 8, width: w - fx, height: 16)
        }
    }

    private func layoutGrid(y: CGFloat, height: CGFloat, width: CGFloat) {
        grid.frame = NSRect(x: 0, y: y, width: width, height: height)
        let (cell, total) = gridRows(width)
        gridDocument.frame = NSRect(x: 0, y: 0, width: width, height: total)
        for (n, c) in cells.enumerated() {
            c.frame = NSRect(x: 2 + CGFloat(n % 10) * (cell + 4), y: 2 + CGFloat(n / 10) * (cell + 4), width: cell, height: cell)
        }
    }
}

/// A color swatch: `size-6 rounded-full border border-transparent`, the selected one `border-foreground/64`,
/// a `size-4` dot of `bg-<color>-500` inside.
final class ProjectIconSwatch: ControlView {
    let colorName: String
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; updateLayer() } } }
    private let dot = CALayer()
    init(color: String) {
        colorName = color
        super.init(frame: .zero)
        scalesWhenPressed = false
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        dot.cornerRadius = 8
        layer?.addSublayer(dot)
        setAccessibilityRole(.button)
    }
    override func layout() { super.layout(); dot.frame = CGRect(x: 4, y: 4, width: 16, height: 16) }
    override func updateLayer() {
        layer?.borderColor = isSelected ? Themed.color(\.foreground, 0.64).cgColor(in: self) : NSColor.clear.cgColor
        dot.backgroundColor = Themed.base("\(colorName)-500", dark: "\(colorName)-500").cgColor(in: self)
        setAccessibilityValue(isSelected)
    }
}

/// A grid cell: `aspect-square rounded-md border border-transparent hover:bg-accent`, the selected one
/// `border-border bg-accent`; a `size-5` icon in the chosen color, or a `text-xl` emoji.
final class ProjectIconCell: ControlView {
    var value = ""
    var isSelected = false { didSet { if isSelected != oldValue { updateLayer() } } }
    var tint = "gray" { didSet { if tint != oldValue { updateLayer() } } }
    private let icon: IconView?
    private let emojiLabel: LabelView?
    init(glyph: IconName?, emoji: String?) {
        icon = glyph.map { IconView(name: $0, size: 20) }
        emojiLabel = emoji.map { LabelView($0, font: NSFont.systemFont(ofSize: 20)) }
        super.init(frame: .zero)
        scalesWhenPressed = false
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        icon.map(addSubview)
        if let emojiLabel { emojiLabel.alignment = .center; emojiLabel.lineHeight = 28; addSubview(emojiLabel) }
        setAccessibilityRole(.button)
    }
    override func layout() {
        super.layout()
        icon?.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        emojiLabel?.frame = NSRect(x: 0, y: (bounds.height - 28) / 2, width: bounds.width, height: 28)
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); updateLayer() }
    override func updateLayer() {
        let hot = isSelected || state.hovered
        layer?.backgroundColor = hot ? Themed.color(\.accent).cgColor(in: self) : nil
        layer?.borderColor = isSelected ? Themed.color(\.border).cgColor(in: self) : NSColor.clear.cgColor
        icon?.strokeColor = Themed.base("\(tint)-600", dark: "\(tint)-400")
        setAccessibilityValue(isSelected)
    }
}
